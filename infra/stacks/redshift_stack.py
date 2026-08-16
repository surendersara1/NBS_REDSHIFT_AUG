"""RedshiftStack — the teaching cluster.

Node choice, and why (verified against the Redshift Management Guide,
"Node type details", 2026-08):

    ra3.large  single-node   2 vCPU · 16 GiB · 1 TB managed storage · node range 1
    rg.large   multi-node    2 vCPU · 16 GiB · node range 2-16   <- minimum 2 nodes
    dc2.large  single-node   2 vCPU · 15 GiB · 160 GB local SSD  <- legacy, no
                                                                    managed storage

ra3.large is the smallest *modern* node that can run as a single node, so it
is both the cheapest RA3 footprint and the one whose behaviour matches what
the team will meet on a real project (managed storage, data sharing,
concurrency scaling). rg.large would be ~2x the cost because it cannot run
below two nodes. dc2.large is cheaper still but is the previous generation
and teaches storage behaviour the team will never see again.

Access model: no public endpoint. Learners connect through Redshift Query
Editor v2 in the console, which reaches the cluster over the Redshift Data
API rather than a VPC route. That removes VPN/security-group/psql setup for
eight people on day one. Set `publicly_accessible=True` and open the SG only
if you specifically want to teach JDBC/psql connectivity.
"""
from aws_cdk import (
    CfnOutput,
    RemovalPolicy,
    Stack,
    aws_ec2 as ec2,
    aws_iam as iam,
    aws_kms as kms,
    aws_redshift as redshift,
    aws_s3 as s3,
)
from constructs import Construct


class RedshiftStack(Stack):
    def __init__(
        self,
        scope: Construct,
        construct_id: str,
        *,
        prefix: str,
        stage: str,
        vpc: ec2.IVpc,
        raw_bucket: s3.IBucket,
        curated_bucket: s3.IBucket,
        glue_database_name: str,
        table_bucket_arn: str,
        table_bucket_name: str,
        namespace_name: str,
        cmk: kms.IKey,
        nodes: int = 1,
        **kwargs,
    ) -> None:
        super().__init__(scope, construct_id, **kwargs)

        retain = stage == "prod"
        removal = RemovalPolicy.RETAIN if retain else RemovalPolicy.DESTROY

        # ------------------------------------------------------------------
        # A) Spectrum + data lake role.
        #    Redshift assumes this to read S3 and resolve Glue metadata. It is
        #    attached to the cluster, then named explicitly in
        #    CREATE EXTERNAL SCHEMA ... IAM_ROLE '<arn>'.
        # ------------------------------------------------------------------
        self.spectrum_role = iam.Role(
            self,
            "SpectrumRole",
            role_name=f"{prefix}-rs-spectrum-{stage}",
            assumed_by=iam.ServicePrincipal("redshift.amazonaws.com"),
            description="Redshift Spectrum: S3 read, Glue catalog read, UNLOAD write",
        )

        raw_bucket.grant_read(self.spectrum_role)
        # UNLOAD writes; COPY reads back. Both needed on curated.
        curated_bucket.grant_read_write(self.spectrum_role)
        cmk.grant_encrypt_decrypt(self.spectrum_role)

        self.spectrum_role.add_to_policy(
            iam.PolicyStatement(
                sid="GlueCatalogRead",
                actions=[
                    "glue:GetCatalog",
                    "glue:GetDatabase",
                    "glue:GetDatabases",
                    "glue:GetTable",
                    "glue:GetTables",
                    "glue:GetPartition",
                    "glue:GetPartitions",
                    "glue:BatchGetPartition",
                ],
                resources=[
                    f"arn:aws:glue:{self.region}:{self.account}:catalog",
                    f"arn:aws:glue:{self.region}:{self.account}:database/{glue_database_name}",
                    f"arn:aws:glue:{self.region}:{self.account}:table/{glue_database_name}/*",
                ],
            )
        )

        # CREATE EXTERNAL DATABASE / external table DDL from inside Redshift.
        self.spectrum_role.add_to_policy(
            iam.PolicyStatement(
                sid="GlueCatalogWrite",
                actions=[
                    "glue:CreateDatabase",
                    "glue:CreateTable",
                    "glue:UpdateTable",
                    "glue:DeleteTable",
                    "glue:BatchCreatePartition",
                    "glue:CreatePartition",
                    "glue:UpdatePartition",
                    "glue:DeletePartition",
                ],
                resources=[
                    f"arn:aws:glue:{self.region}:{self.account}:catalog",
                    f"arn:aws:glue:{self.region}:{self.account}:database/{glue_database_name}",
                    f"arn:aws:glue:{self.region}:{self.account}:table/{glue_database_name}/*",
                ],
            )
        )

        # ------------------------------------------------------------------
        # B) S3 Tables role.
        #    Copied from the canonical policy in the Redshift Database
        #    Developer Guide, "Query Amazon S3 Tables from Amazon Redshift".
        #    The s3tablescatalog/* ARN shapes are exact — wildcards at the
        #    wrong level silently produce "catalog not found" rather than
        #    AccessDenied, which is much harder to debug.
        # ------------------------------------------------------------------
        self.s3tables_role = iam.Role(
            self,
            "S3TablesRole",
            role_name=f"{prefix}-rs-s3tables-{stage}",
            assumed_by=iam.ServicePrincipal("redshift.amazonaws.com"),
            description="Redshift -> S3 Tables via the s3tablescatalog federated catalog",
        )

        self.s3tables_role.add_to_policy(
            iam.PolicyStatement(
                sid="GlueDataCatalogPermissions",
                actions=[
                    "glue:GetCatalog",
                    "glue:GetDatabase",
                    "glue:GetDatabases",
                    "glue:GetTable",
                    "glue:GetTables",
                    "glue:UpdateTable",
                    "glue:DeleteTable",
                ],
                resources=[
                    f"arn:aws:glue:{self.region}:{self.account}:catalog",
                    f"arn:aws:glue:{self.region}:{self.account}:catalog/s3tablescatalog",
                    f"arn:aws:glue:{self.region}:{self.account}:catalog/s3tablescatalog/*",
                    f"arn:aws:glue:{self.region}:{self.account}:database/s3tablescatalog/*/*",
                    f"arn:aws:glue:{self.region}:{self.account}:table/s3tablescatalog/*/*/*",
                    f"arn:aws:glue:{self.region}:{self.account}:database/*",
                    f"arn:aws:glue:{self.region}:{self.account}:table/*/*",
                ],
            )
        )

        self.s3tables_role.add_to_policy(
            iam.PolicyStatement(
                sid="S3TablesDataAccessPermissions",
                actions=[
                    "s3tables:GetTableBucket",
                    "s3tables:GetNamespace",
                    "s3tables:GetTable",
                    "s3tables:GetTableMetadataLocation",
                    "s3tables:GetTableData",
                    "s3tables:ListTableBuckets",
                    "s3tables:ListNamespaces",
                    "s3tables:ListTables",
                    "s3tables:CreateTable",
                    "s3tables:PutTableData",
                    "s3tables:UpdateTableMetadataLocation",
                    "s3tables:DeleteTable",
                ],
                resources=[
                    f"arn:aws:s3tables:{self.region}:{self.account}:bucket/*",
                    f"arn:aws:s3tables:{self.region}:{self.account}:bucket/*/table/*",
                ],
            )
        )
        cmk.grant_encrypt_decrypt(self.s3tables_role)

        # ------------------------------------------------------------------
        # C) Networking for the cluster.
        # ------------------------------------------------------------------
        subnet_group = redshift.CfnClusterSubnetGroup(
            self,
            "SubnetGroup",
            description=f"{prefix} coaching cluster subnets",
            subnet_ids=vpc.select_subnets(
                subnet_type=ec2.SubnetType.PRIVATE_ISOLATED
            ).subnet_ids,
        )

        self.security_group = ec2.SecurityGroup(
            self,
            "ClusterSg",
            vpc=vpc,
            # Plain ASCII only. CloudFormation validates GroupDescription
            # against ^([a-z,A-Z,0-9,. _\-:/()#,@[\]+=&;{}!$*])*$ and an
            # em-dash fails it at deploy time with a pattern error that does
            # not name the offending field.
            description="Redshift coaching cluster: no ingress by default",
            allow_all_outbound=True,
        )
        # Intra-SG ingress so Glue connections (if added later) can reach 5439.
        self.security_group.add_ingress_rule(
            peer=self.security_group,
            connection=ec2.Port.tcp(5439),
            description="Self-referencing: Glue/EC2 in this SG may reach Redshift",
        )

        # ------------------------------------------------------------------
        # D) The cluster.
        #    manage_master_password=True hands credential rotation to Secrets
        #    Manager. Never put a MasterUserPassword literal in CDK — it lands
        #    in the synthesized template and in CloudFormation's console.
        # ------------------------------------------------------------------
        self.cluster = redshift.CfnCluster(
            self,
            "Cluster",
            cluster_identifier=f"{prefix}-{stage}",
            # 1 node  -> single-node (ra3.large supports node range 1)
            # 2+ nodes -> multi-node; ra3.large multi-node range is 2-16
            cluster_type=("single-node" if nodes == 1 else "multi-node"),
            number_of_nodes=(None if nodes == 1 else nodes),
            node_type="ra3.large",
            db_name="coaching",
            master_username="nbsadmin",
            manage_master_password=True,          # -> Secrets Manager, auto-rotated
            master_password_secret_kms_key_id=cmk.key_id,
            cluster_subnet_group_name=subnet_group.ref,
            vpc_security_group_ids=[self.security_group.security_group_id],
            publicly_accessible=False,            # Query Editor v2 does not need this
            encrypted=True,
            kms_key_id=cmk.key_id,
            iam_roles=[
                self.spectrum_role.role_arn,
                self.s3tables_role.role_arn,
            ],
            # No default role is set: aws_cdk.aws_redshift.CfnCluster in this
            # version exposes only `iam_roles`, not DefaultIamRoleArn. Every
            # COPY / UNLOAD / CREATE EXTERNAL SCHEMA in sql/ therefore names
            # its IAM_ROLE explicitly, which is better practice anyway —
            # `IAM_ROLE default` hides which identity did the read.
            automated_snapshot_retention_period=1 if not retain else 7,
            port=5439,
            enhanced_vpc_routing=True,            # forces S3 traffic through the VPC endpoint
        )
        self.cluster.apply_removal_policy(removal)
        self.cluster.add_dependency(subnet_group)

        CfnOutput(self, "ClusterIdentifier", value=self.cluster.ref)
        CfnOutput(
            self,
            "ClusterEndpoint",
            value=self.cluster.attr_endpoint_address,
        )
        # The CFN return value is the nested attribute MasterPasswordSecret.SecretArn.
        # get_att is used rather than a generated attr_* property so this does not
        # depend on how the L1 codegen flattened the nested name.
        CfnOutput(
            self,
            "MasterSecretArn",
            value=self.cluster.get_att("MasterPasswordSecret.SecretArn").to_string(),
            description="Secrets Manager secret holding the nbsadmin password",
        )
        CfnOutput(self, "SpectrumRoleArn", value=self.spectrum_role.role_arn)
        CfnOutput(self, "S3TablesRoleArn", value=self.s3tables_role.role_arn)
        CfnOutput(self, "TableBucketArn", value=table_bucket_arn)
        CfnOutput(self, "TableBucketNameOut", value=table_bucket_name)
        CfnOutput(self, "NamespaceNameOut", value=namespace_name)
        CfnOutput(self, "DatabaseName", value="coaching")

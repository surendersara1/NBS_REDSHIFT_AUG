"""FoundationStack — network, buckets, and the CMK everything else encrypts with.

Kept deliberately small. A teaching cluster does not need NAT gateways
(~$32/mo each); Redshift reaches S3 and Glue through gateway/interface
endpoints instead, which cost nothing for the gateway and very little for
the interface.
"""
from aws_cdk import (
    CfnOutput,
    RemovalPolicy,
    Stack,
    aws_ec2 as ec2,
    aws_kms as kms,
    aws_s3 as s3,
)
from constructs import Construct


class FoundationStack(Stack):
    def __init__(
        self,
        scope: Construct,
        construct_id: str,
        *,
        project: str,
        stage: str,
        raw_bucket_name: str,
        **kwargs,
    ) -> None:
        super().__init__(scope, construct_id, **kwargs)

        retain = stage == "prod"
        removal = RemovalPolicy.RETAIN if retain else RemovalPolicy.DESTROY

        # ------------------------------------------------------------------
        # A) CMK. One key for the whole teaching estate — buckets, Redshift,
        #    and the S3 Tables bucket in LakehouseStack all reference it.
        # ------------------------------------------------------------------
        self.cmk = kms.Key(
            self,
            "Cmk",
            alias=f"alias/{project}-{stage}",
            description="NBS Redshift coaching — S3, Redshift, and S3 Tables encryption",
            enable_key_rotation=True,
            removal_policy=removal,
        )

        # ------------------------------------------------------------------
        # B) VPC. Two AZs because a Redshift cluster subnet group requires at
        #    least one subnet, but ClusterSubnetGroup is far less painful to
        #    resize later with two. No NAT: nat_gateways=0 keeps this free.
        # ------------------------------------------------------------------
        self.vpc = ec2.Vpc(
            self,
            "Vpc",
            max_azs=2,
            nat_gateways=0,
            ip_addresses=ec2.IpAddresses.cidr("10.42.0.0/16"),
            subnet_configuration=[
                ec2.SubnetConfiguration(
                    name="public",
                    subnet_type=ec2.SubnetType.PUBLIC,
                    cidr_mask=24,
                ),
                ec2.SubnetConfiguration(
                    name="isolated",
                    subnet_type=ec2.SubnetType.PRIVATE_ISOLATED,
                    cidr_mask=24,
                ),
            ],
        )

        # S3 gateway endpoint — free, and required for COPY/UNLOAD to reach S3
        # from an isolated subnet without a NAT gateway.
        self.vpc.add_gateway_endpoint(
            "S3Endpoint",
            service=ec2.GatewayVpcEndpointAwsService.S3,
        )

        # Glue interface endpoint — Spectrum's external schema resolves table
        # metadata through the Glue Data Catalog API.
        self.vpc.add_interface_endpoint(
            "GlueEndpoint",
            service=ec2.InterfaceVpcEndpointAwsService.GLUE,
            subnets=ec2.SubnetSelection(
                subnet_type=ec2.SubnetType.PRIVATE_ISOLATED
            ),
        )

        # ------------------------------------------------------------------
        # C) Buckets.
        #
        #    NOTE ON THE NAME: S3 bucket names must be lowercase and may not
        #    contain underscores, so the requested "NBS_RAW_SUREN" is not a
        #    legal bucket name — CloudFormation rejects it at create time.
        #    The kebab-case equivalent "nbs-raw-suren" is used instead.
        #    See docs/NAMING.md.
        # ------------------------------------------------------------------
        self.raw_bucket = s3.Bucket(
            self,
            "RawBucket",
            bucket_name=raw_bucket_name,
            encryption=s3.BucketEncryption.KMS,
            encryption_key=self.cmk,
            block_public_access=s3.BlockPublicAccess.BLOCK_ALL,
            enforce_ssl=True,
            versioned=True,
            removal_policy=removal,
            auto_delete_objects=not retain,
        )

        # UNLOAD target + Spectrum-readable silver dumps.
        self.curated_bucket = s3.Bucket(
            self,
            "CuratedBucket",
            bucket_name=f"{raw_bucket_name}-curated",
            encryption=s3.BucketEncryption.KMS,
            encryption_key=self.cmk,
            block_public_access=s3.BlockPublicAccess.BLOCK_ALL,
            enforce_ssl=True,
            removal_policy=removal,
            auto_delete_objects=not retain,
        )

        # Glue job .py files and the Spark event log.
        self.scripts_bucket = s3.Bucket(
            self,
            "ScriptsBucket",
            bucket_name=f"{raw_bucket_name}-scripts",
            encryption=s3.BucketEncryption.KMS,
            encryption_key=self.cmk,
            block_public_access=s3.BlockPublicAccess.BLOCK_ALL,
            enforce_ssl=True,
            removal_policy=removal,
            auto_delete_objects=not retain,
        )

        CfnOutput(self, "RawBucketName", value=self.raw_bucket.bucket_name)
        CfnOutput(self, "CuratedBucketName", value=self.curated_bucket.bucket_name)
        CfnOutput(self, "ScriptsBucketName", value=self.scripts_bucket.bucket_name)
        CfnOutput(self, "CmkArn", value=self.cmk.key_arn)

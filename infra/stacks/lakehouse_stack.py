"""LakehouseStack — S3 Tables (Iceberg) bronze/silver + the Glue jobs that fill them.

Shape of the medallion here:

    raw     s3://nbs-raw-suren/parent/, /child/        CSV, as landed
    bronze  S3 Tables  coaching.bronze_customers        Iceberg, typed, deduped
                       coaching.bronze_orders
    silver  S3 Tables  coaching.silver_customer_orders  Iceberg, the Glue join
    gold    Redshift   analytics.*                      native tables + MVs

Only L1 constructs exist for S3 Tables — there are no L2 grants, so every
IAM statement against them is hand-written in RedshiftStack.

Iceberg schema note: the `type` values below are Iceberg primitive names,
not Glue/Hive type strings. It is "long", not "bigint"; and a decimal is
written "decimal(18, 2)" with a space after the comma.
"""
from aws_cdk import (
    CfnOutput,
    Duration,
    RemovalPolicy,
    Stack,
    aws_glue as glue,
    aws_iam as iam,
    aws_kms as kms,
    aws_s3 as s3,
    aws_s3_deployment as s3deploy,
    aws_s3tables as s3t,
)
from constructs import Construct


class LakehouseStack(Stack):
    def __init__(
        self,
        scope: Construct,
        construct_id: str,
        *,
        prefix: str,
        prefix_snake: str,
        stage: str,
        raw_bucket: s3.IBucket,
        curated_bucket: s3.IBucket,
        scripts_bucket: s3.IBucket,
        cmk: kms.IKey,
        **kwargs,
    ) -> None:
        super().__init__(scope, construct_id, **kwargs)

        retain = stage == "prod"
        removal = RemovalPolicy.RETAIN if retain else RemovalPolicy.DESTROY

        # The namespace lives INSIDE this learner's own table bucket, so it
        # needs no learner suffix - two learners can both have `coaching`.
        # Keeping it constant means sql/03 reads the same for everyone.
        namespace_name = "coaching"
        self.namespace_name = namespace_name

        # ------------------------------------------------------------------
        # A) S3 Tables bucket. Ref returns the ARN, not the name — use the
        #    attr_* accessors explicitly.
        # ------------------------------------------------------------------
        self.table_bucket = s3t.CfnTableBucket(
            self,
            "TableBucket",
            table_bucket_name=f"{prefix}-tables-{stage}",   # 3-63 lowercase, no dots
            encryption_configuration=s3t.CfnTableBucket.EncryptionConfigurationProperty(
                sse_algorithm="aws:kms",
                kms_key_arn=cmk.key_arn,
            ),
            unreferenced_file_removal=s3t.CfnTableBucket.UnreferencedFileRemovalProperty(
                status="Enabled",
                unreferenced_days=7,
                noncurrent_days=3,
            ),
        )
        self.table_bucket_arn = self.table_bucket.attr_table_bucket_arn
        # Needed verbatim by the Glue resource link and the Lake Formation
        # grants in scripts/bootstrap_s3tables.sh, so it is exported rather
        # than re-derived from the ARN by string surgery at three call sites.
        self.table_bucket_name = f"{prefix}-tables-{stage}"

        self.namespace = s3t.CfnNamespace(
            self,
            "Namespace",
            table_bucket_arn=self.table_bucket_arn,
            namespace=namespace_name,
        )
        self.namespace.add_dependency(self.table_bucket)

        # ------------------------------------------------------------------
        # B) Bronze + silver Iceberg tables.
        # ------------------------------------------------------------------
        bronze_customers_schema = {
            "fields": [
                {"name": "customer_id", "type": "long", "required": True},
                {"name": "customer_name", "type": "string", "required": True},
                {"name": "segment", "type": "string", "required": False},
                {"name": "country", "type": "string", "required": False},
                {"name": "signup_date", "type": "date", "required": False},
                {"name": "ingested_at", "type": "timestamptz", "required": True},
            ]
        }
        bronze_orders_schema = {
            "fields": [
                {"name": "order_id", "type": "long", "required": True},
                {"name": "customer_id", "type": "long", "required": True},
                {"name": "order_ts", "type": "timestamptz", "required": True},
                {"name": "status", "type": "string", "required": False},
                {"name": "quantity", "type": "int", "required": False},
                {"name": "unit_price", "type": "decimal(18, 2)", "required": False},
                {"name": "ingested_at", "type": "timestamptz", "required": True},
            ]
        }
        silver_join_schema = {
            "fields": [
                {"name": "order_id", "type": "long", "required": True},
                {"name": "customer_id", "type": "long", "required": True},
                {"name": "customer_name", "type": "string", "required": False},
                {"name": "segment", "type": "string", "required": False},
                {"name": "country", "type": "string", "required": False},
                {"name": "order_ts", "type": "timestamptz", "required": False},
                {"name": "status", "type": "string", "required": False},
                {"name": "quantity", "type": "int", "required": False},
                {"name": "unit_price", "type": "decimal(18, 2)", "required": False},
                {"name": "gross_amount", "type": "decimal(18, 2)", "required": False},
                {"name": "joined_at", "type": "timestamptz", "required": True},
            ]
        }

        self.tables = {}
        for logical, name, schema in [
            ("BronzeCustomers", "bronze_customers", bronze_customers_schema),
            ("BronzeOrders", "bronze_orders", bronze_orders_schema),
            ("SilverCustomerOrders", "silver_customer_orders", silver_join_schema),
        ]:
            tbl = s3t.CfnTable(
                self,
                logical,
                table_bucket_arn=self.table_bucket_arn,
                namespace=namespace_name,
                table_name=name,
                open_table_format="ICEBERG",
                iceberg_metadata=s3t.CfnTable.IcebergMetadataProperty(
                    iceberg_schema=s3t.CfnTable.IcebergSchemaProperty(
                        schema_field_list=[
                            s3t.CfnTable.SchemaFieldProperty(
                                name=f["name"],
                                type=f["type"],
                                required=f.get("required", False),
                            )
                            for f in schema["fields"]
                        ]
                    )
                ),
                # LOWERCASE. AWS::S3Tables::Table Compaction.Status accepts
                # only 'enabled'/'disabled', while the TableBucket's
                # UnreferencedFileRemoval.Status above accepts 'Enabled'/
                # 'Disabled'. Same service, same template, opposite casing.
                # `cdk synth` reports the mismatch as a W3030 warning rather
                # than an error, so it survives synth and fails the deploy.
                compaction=s3t.CfnTable.CompactionProperty(
                    status="enabled",
                    target_file_size_mb=128,
                ),
                # Lowercase, same as Compaction.Status above.
                snapshot_management=s3t.CfnTable.SnapshotManagementProperty(
                    status="enabled",
                    min_snapshots_to_keep=3,
                    max_snapshot_age_hours=168,
                ),
            )
            tbl.add_dependency(self.namespace)
            self.tables[name] = tbl

        # ------------------------------------------------------------------
        # C) Glue database for the raw CSV layer. This is what Redshift
        #    Spectrum points its external schema at — the S3 Tables side is
        #    reached separately through the s3tablescatalog federated catalog.
        # ------------------------------------------------------------------
        self.glue_database_name = f"{prefix_snake}_raw_{stage}"
        self.glue_db = glue.CfnDatabase(
            self,
            "RawDatabase",
            catalog_id=self.account,
            database_input=glue.CfnDatabase.DatabaseInputProperty(
                name=self.glue_database_name,
                description=(
                    "Raw CSV landing zone for the NBS Redshift coaching platform. "
                    "parent = customers, child = orders. Read by Redshift Spectrum."
                ),
                location_uri=f"s3://{raw_bucket.bucket_name}/",
            ),
        )

        # ------------------------------------------------------------------
        # D) Glue job role.
        # ------------------------------------------------------------------
        self.glue_role = iam.Role(
            self,
            "GlueJobRole",
            role_name=f"{prefix}-glue-{stage}",
            assumed_by=iam.ServicePrincipal("glue.amazonaws.com"),
            managed_policies=[
                iam.ManagedPolicy.from_aws_managed_policy_name("service-role/AWSGlueServiceRole")
            ],
        )
        raw_bucket.grant_read(self.glue_role)
        curated_bucket.grant_read_write(self.glue_role)
        scripts_bucket.grant_read(self.glue_role)
        cmk.grant_encrypt_decrypt(self.glue_role)

        self.glue_role.add_to_policy(
            iam.PolicyStatement(
                sid="S3TablesReadWrite",
                actions=[
                    "s3tables:GetTableBucket",
                    "s3tables:GetNamespace",
                    "s3tables:GetTable",
                    "s3tables:GetTableMetadataLocation",
                    "s3tables:GetTableData",
                    "s3tables:PutTableData",
                    "s3tables:UpdateTableMetadataLocation",
                    "s3tables:ListNamespaces",
                    "s3tables:ListTables",
                    "s3tables:ListTableBuckets",
                ],
                resources=[
                    f"arn:aws:s3tables:{self.region}:{self.account}:bucket/*",
                    f"arn:aws:s3tables:{self.region}:{self.account}:bucket/*/table/*",
                ],
            )
        )
        self.glue_role.add_to_policy(
            iam.PolicyStatement(
                sid="GlueCatalogAccess",
                actions=[
                    "glue:GetCatalog", "glue:GetDatabase", "glue:GetDatabases",
                    "glue:GetTable", "glue:GetTables", "glue:CreateTable",
                    "glue:UpdateTable", "glue:GetPartitions", "glue:BatchCreatePartition",
                ],
                resources=["*"],   # federated s3tablescatalog ARNs are dynamic
            )
        )

        # ------------------------------------------------------------------
        # E) Ship the job scripts and the sample CSVs with the stack, so a
        #    single `cdk deploy` leaves the environment runnable.
        # ------------------------------------------------------------------
        s3deploy.BucketDeployment(
            self,
            "DeployGlueScripts",
            sources=[s3deploy.Source.asset("../glue")],
            destination_bucket=scripts_bucket,
            destination_key_prefix="jobs/",
            retain_on_delete=False,
        )
        s3deploy.BucketDeployment(
            self,
            "DeploySampleData",
            sources=[s3deploy.Source.asset("../data/seed")],
            destination_bucket=raw_bucket,
            retain_on_delete=False,
        )

        # ------------------------------------------------------------------
        # F) The two Glue jobs.
        #    Glue 5.0 ships Iceberg natively; the --datalake-formats flag
        #    turns it on. The S3 Tables catalog is reached through the
        #    Iceberg REST endpoint, configured in --conf.
        # ------------------------------------------------------------------
        iceberg_conf = (
            "spark.sql.extensions=org.apache.iceberg.spark.extensions."
            "IcebergSparkSessionExtensions "
            "--conf spark.sql.catalog.s3tables=org.apache.iceberg.spark.SparkCatalog "
            "--conf spark.sql.catalog.s3tables.type=rest "
            f"--conf spark.sql.catalog.s3tables.warehouse={self.table_bucket_arn} "
            f"--conf spark.sql.catalog.s3tables.uri=https://s3tables.{self.region}.amazonaws.com/iceberg "
            f"--conf spark.sql.catalog.s3tables.rest.sigv4-enabled=true "
            f"--conf spark.sql.catalog.s3tables.rest.signing-name=s3tables "
            f"--conf spark.sql.catalog.s3tables.rest.signing-region={self.region} "
            "--conf spark.sql.defaultCatalog=s3tables"
        )

        common_args = {
            "--datalake-formats": "iceberg",
            "--conf": iceberg_conf,
            "--enable-metrics": "true",
            "--enable-continuous-cloudwatch-log": "true",
            "--enable-observability-metrics": "true",
            "--job-language": "python",
            "--TempDir": f"s3://{scripts_bucket.bucket_name}/tmp/",
            "--RAW_BUCKET": raw_bucket.bucket_name,
            "--NAMESPACE": namespace_name,
        }

        self.job_raw_to_bronze = glue.CfnJob(
            self,
            "JobRawToBronze",
            name=f"{prefix}-raw-to-bronze-{stage}",
            role=self.glue_role.role_arn,
            glue_version="5.0",
            worker_type="G.1X",
            number_of_workers=2,          # smallest useful Spark shape
            timeout=30,
            command=glue.CfnJob.JobCommandProperty(
                name="glueetl",
                python_version="3",
                script_location=f"s3://{scripts_bucket.bucket_name}/jobs/job_raw_to_bronze.py",
            ),
            default_arguments=common_args,
            execution_property=glue.CfnJob.ExecutionPropertyProperty(
                max_concurrent_runs=1
            ),
        )

        self.job_bronze_to_silver = glue.CfnJob(
            self,
            "JobBronzeToSilver",
            name=f"{prefix}-bronze-to-silver-{stage}",
            role=self.glue_role.role_arn,
            glue_version="5.0",
            worker_type="G.1X",
            number_of_workers=2,
            timeout=30,
            command=glue.CfnJob.JobCommandProperty(
                name="glueetl",
                python_version="3",
                script_location=f"s3://{scripts_bucket.bucket_name}/jobs/job_bronze_join_to_silver.py",
            ),
            default_arguments=common_args,
            execution_property=glue.CfnJob.ExecutionPropertyProperty(
                max_concurrent_runs=1
            ),
        )

        CfnOutput(self, "TableBucketArnOut", value=self.table_bucket_arn)
        CfnOutput(self, "TableBucketName", value=self.table_bucket_name)
        CfnOutput(self, "NamespaceName", value=namespace_name)
        CfnOutput(self, "GlueDatabaseName", value=self.glue_database_name)
        # The Glue resource link that sql/03 points its external schema at.
        # Created by scripts/bootstrap_s3tables.sh, not by CloudFormation:
        # a resource link is a Glue database whose TargetDatabase lives in a
        # federated catalog, and CFN's AWS::Glue::Database has no property for
        # the federated CatalogId form '<account>:s3tablescatalog/<bucket>'.
        CfnOutput(
            self,
            "ResourceLinkName",
            value=f"{prefix_snake}_s3t_link",
            description="Glue resource link name for the S3 Tables namespace",
        )
        CfnOutput(self, "RawToBronzeJob", value=self.job_raw_to_bronze.ref)
        CfnOutput(self, "BronzeToSilverJob", value=self.job_bronze_to_silver.ref)

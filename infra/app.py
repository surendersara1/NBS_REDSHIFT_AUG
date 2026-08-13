#!/usr/bin/env python3
"""NBS Redshift Coaching Platform — CDK app entrypoint.

Deploys the smallest viable Redshift teaching environment:

    FoundationStack   VPC, raw/curated S3 buckets, KMS CMK
    LakehouseStack    S3 Tables bucket (bronze/silver Iceberg), Glue DB + jobs
    RedshiftStack     ra3.large single-node cluster, Spectrum + S3 Tables IAM

Deploy order is enforced by explicit cross-stack references.

    cdk deploy --all --require-approval never

Context values (cdk.json or -c):
    project     short slug used in resource names   default: nbs-coaching
    stage       dev|prod                            default: dev
    raw_bucket  raw landing bucket name             default: nbs-raw-suren
"""
import os

import aws_cdk as cdk

from stacks.foundation_stack import FoundationStack
from stacks.lakehouse_stack import LakehouseStack
from stacks.redshift_stack import RedshiftStack

app = cdk.App()

project = app.node.try_get_context("project") or "nbs-coaching"
stage = app.node.try_get_context("stage") or "dev"
nodes = int(app.node.try_get_context("nodes") or 2)

account = os.environ.get("CDK_DEFAULT_ACCOUNT")

# S3 bucket names are globally unique across ALL AWS accounts, so a fixed
# default collides the moment a second student deploys — even into their own
# account. Suffixing with the account id makes every student's bucket unique
# without anyone having to think about it. Override with -c raw_bucket=... if
# you want a specific name.
raw_bucket_name = (
    app.node.try_get_context("raw_bucket")
    or (f"nbs-raw-suren-{account}" if account else "nbs-raw-suren")
)

env = cdk.Environment(
    account=account,
    region=os.environ.get("CDK_DEFAULT_REGION", "us-east-1"),
)

foundation = FoundationStack(
    app,
    f"{project}-foundation-{stage}",
    project=project,
    stage=stage,
    raw_bucket_name=raw_bucket_name,
    env=env,
)

lakehouse = LakehouseStack(
    app,
    f"{project}-lakehouse-{stage}",
    project=project,
    stage=stage,
    raw_bucket=foundation.raw_bucket,
    curated_bucket=foundation.curated_bucket,
    scripts_bucket=foundation.scripts_bucket,
    cmk=foundation.cmk,
    env=env,
)

RedshiftStack(
    app,
    f"{project}-redshift-{stage}",
    project=project,
    stage=stage,
    vpc=foundation.vpc,
    raw_bucket=foundation.raw_bucket,
    curated_bucket=foundation.curated_bucket,
    glue_database_name=lakehouse.glue_database_name,
    table_bucket_arn=lakehouse.table_bucket_arn,
    cmk=foundation.cmk,
    nodes=nodes,
    env=env,
)

cdk.Tags.of(app).add("Project", project)
cdk.Tags.of(app).add("Stage", stage)
cdk.Tags.of(app).add("Purpose", "redshift-coaching")

app.synth()

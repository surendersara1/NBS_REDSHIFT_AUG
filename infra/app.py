#!/usr/bin/env python3
"""NBS Redshift Coaching Platform - CDK app entrypoint.

Deploys the smallest viable Redshift teaching environment:

    FoundationStack   VPC, raw/curated/scripts S3 buckets, KMS CMK
    LakehouseStack    S3 Tables bucket (bronze/silver Iceberg), Glue DB + jobs
    RedshiftStack     ra3.large single-node cluster, Spectrum + S3 Tables IAM

Deploy order is enforced by explicit cross-stack references.

    cdk deploy --all -c user=<yourname> --require-approval never

THE `user` CONTEXT IS REQUIRED, and it is the whole reason this file is
interesting.

Every learner deploys their own copy of these stacks, and several of the
resources here have names that must be unique -- globally (S3 buckets) or
per-account (IAM roles, KMS aliases, Glue databases, the cluster identifier,
the S3 Tables bucket, the Glue jobs). If eight people deploy with the same
names into one account, the second through eighth deploys fail with
AlreadyExists on whichever resource CloudFormation reaches first, and they
fail *midway*, leaving a half-built ROLLBACK_COMPLETE stack to clean up.

So: `user` is threaded into every name that needs to be unique, and the app
refuses to synthesize without it. Failing at synth with a readable message is
much kinder than failing 6 minutes into a deploy with
"nbs-coaching-glue-dev already exists".

Context values (cdk.json or -c):
    user        REQUIRED. Short lowercase slug, e.g. `suren`, `priya`.
                2-12 chars, must start with a letter, [a-z0-9] only.
    stage       dev|prod                            default: dev
    nodes       1 = single-node, 2+ = multi-node    default: 1
    raw_bucket  override the derived raw bucket name (rarely needed)
"""
import os
import re
import sys

import aws_cdk as cdk

from stacks.foundation_stack import FoundationStack
from stacks.lakehouse_stack import LakehouseStack
from stacks.redshift_stack import RedshiftStack

app = cdk.App()

# ---------------------------------------------------------------------------
# The per-learner identity. Everything unique hangs off this.
# ---------------------------------------------------------------------------
user = (app.node.try_get_context("user") or "").strip().lower()

if not user:
    sys.exit(
        "\nERROR: -c user=<yourname> is required.\n\n"
        "  Every learner deploys their own stacks. Without a unique user slug,\n"
        "  two people deploying into the same AWS account collide on bucket\n"
        "  names, IAM role names, the KMS alias, the Glue database, the S3\n"
        "  Tables bucket and the cluster identifier.\n\n"
        "  Example:\n"
        "    cdk deploy --all -c user=suren --require-approval never\n"
    )

if not re.fullmatch(r"[a-z][a-z0-9]{1,11}", user):
    sys.exit(
        f"\nERROR: user='{user}' is not usable as a resource name.\n\n"
        "  Rules: 2-12 characters, start with a letter, lowercase letters and\n"
        "  digits only. No hyphens, underscores, dots or capitals -- this slug\n"
        "  goes into S3 bucket names, a KMS alias, IAM role names and a Glue\n"
        "  database name, and those four have mutually incompatible charsets.\n\n"
        "  Good: suren, priya2, devteam\n"
        "  Bad:  Suren, su, nbs_user, my-name, surender-sara-nbs\n"
    )

stage = app.node.try_get_context("stage") or "dev"
nodes = int(app.node.try_get_context("nodes") or 1)

# `project` is the display/tag name and is deliberately NOT part of unique
# names -- `user` carries uniqueness. Keeping project constant means every
# learner's stack is recognisably the same platform.
project = app.node.try_get_context("project") or "nbs-coaching"

# kebab for S3/IAM/KMS/Redshift, snake for Glue databases. Both derived from
# the same slug so a learner can always predict their own resource names.
prefix = f"nbs-{user}"
prefix_snake = f"nbs_{user}"

account = os.environ.get("CDK_DEFAULT_ACCOUNT")

# S3 bucket names are globally unique across ALL AWS accounts. `user` handles
# the same-account case; the account id handles the different-account case
# (two learners in different accounts could still both pick `suren`).
# Length check: 4 + 12 + 5 + 12 = 33 chars, plus "-curated" = 41. Limit is 63.
raw_bucket_name = (
    app.node.try_get_context("raw_bucket")
    or (f"{prefix}-raw-{account}" if account else f"{prefix}-raw")
)

env = cdk.Environment(
    account=account,
    region=os.environ.get("CDK_DEFAULT_REGION", "us-east-1"),
)

foundation = FoundationStack(
    app,
    f"{prefix}-foundation-{stage}",
    prefix=prefix,
    stage=stage,
    raw_bucket_name=raw_bucket_name,
    env=env,
)

lakehouse = LakehouseStack(
    app,
    f"{prefix}-lakehouse-{stage}",
    prefix=prefix,
    prefix_snake=prefix_snake,
    stage=stage,
    raw_bucket=foundation.raw_bucket,
    curated_bucket=foundation.curated_bucket,
    scripts_bucket=foundation.scripts_bucket,
    cmk=foundation.cmk,
    env=env,
)

RedshiftStack(
    app,
    f"{prefix}-redshift-{stage}",
    prefix=prefix,
    stage=stage,
    vpc=foundation.vpc,
    raw_bucket=foundation.raw_bucket,
    curated_bucket=foundation.curated_bucket,
    glue_database_name=lakehouse.glue_database_name,
    table_bucket_arn=lakehouse.table_bucket_arn,
    table_bucket_name=lakehouse.table_bucket_name,
    namespace_name=lakehouse.namespace_name,
    cmk=foundation.cmk,
    nodes=nodes,
    env=env,
)

cdk.Tags.of(app).add("Project", project)
cdk.Tags.of(app).add("Stage", stage)
cdk.Tags.of(app).add("Owner", user)
cdk.Tags.of(app).add("Purpose", "redshift-coaching")

app.synth()

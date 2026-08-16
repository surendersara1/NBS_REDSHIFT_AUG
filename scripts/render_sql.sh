#!/usr/bin/env bash
# Resolve every <PLACEHOLDER> in sql/*.sql from the deployed CDK stack
# outputs, writing runnable copies to sql/_resolved/.
#
# Without this, each learner hand-edits ~60 placeholders across 18 files and
# at least one of them gets an ARN wrong on a Monday morning.
#
# Usage:
#   ./scripts/render_sql.sh --user suren [--stage dev] [--region us-east-1]
#
# Prereqs: the three stacks are deployed for THIS learner, and the AWS CLI is
# authenticated to that account.
set -euo pipefail

USER_SLUG=""
STAGE="dev"
REGION="${AWS_REGION:-us-east-1}"

while [ $# -gt 0 ]; do
  case "$1" in
    --user)   USER_SLUG="$2"; shift 2 ;;
    --stage)  STAGE="$2";     shift 2 ;;
    --region) REGION="$2";    shift 2 ;;
    -h|--help) sed -n '2,12p' "$0"; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; exit 2 ;;
  esac
done

[ -n "${USER_SLUG}" ] || { echo "ERROR: --user <slug> is required (same slug you passed to 'cdk deploy -c user=...')" >&2; exit 2; }

PREFIX="nbs-${USER_SLUG}"
PREFIX_SNAKE="nbs_${USER_SLUG}"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="${ROOT}/sql/_resolved"

echo "Reading stack outputs: ${PREFIX}-*-${STAGE} in ${REGION}"

out() {  # out <stack-suffix> <OutputKey>
  aws cloudformation describe-stacks \
    --region "${REGION}" \
    --stack-name "${PREFIX}-$1-${STAGE}" \
    --query "Stacks[0].Outputs[?OutputKey=='$2'].OutputValue" \
    --output text 2>/dev/null
}

ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
RAW_BUCKET=$(out foundation RawBucketName)
CURATED_BUCKET=$(out foundation CuratedBucketName)
GLUE_DB=$(out lakehouse GlueDatabaseName)
TABLE_BUCKET_NAME=$(out lakehouse TableBucketName)
TABLE_BUCKET_ARN=$(out lakehouse TableBucketArnOut)
NAMESPACE=$(out lakehouse NamespaceName)
RESOURCE_LINK=$(out lakehouse ResourceLinkName)
SPECTRUM_ROLE_ARN=$(out redshift SpectrumRoleArn)
S3TABLES_ROLE_ARN=$(out redshift S3TablesRoleArn)
CLUSTER_ID=$(out redshift ClusterIdentifier)
MASTER_SECRET_ARN=$(out redshift MasterSecretArn)

# Fallbacks: these are derived deterministically from the learner slug, so a
# missing output should not block rendering. If the stack is simply not
# deployed the ARNs below will be empty and the check catches it.
: "${RESOURCE_LINK:=${PREFIX_SNAKE}_s3t_link}"
: "${NAMESPACE:=coaching}"
: "${TABLE_BUCKET_NAME:=${PREFIX}-tables-${STAGE}}"
: "${CLUSTER_ID:=${PREFIX}-${STAGE}}"

missing=0
for v in ACCOUNT_ID RAW_BUCKET CURATED_BUCKET GLUE_DB SPECTRUM_ROLE_ARN \
         S3TABLES_ROLE_ARN TABLE_BUCKET_NAME TABLE_BUCKET_ARN RESOURCE_LINK \
         NAMESPACE CLUSTER_ID MASTER_SECRET_ARN; do
  if [ -z "${!v}" ] || [ "${!v}" = "None" ]; then
    echo "  MISSING: ${v}" >&2
    missing=1
  else
    echo "  ${v}=${!v}"
  fi
done
if [ "${missing}" -ne 0 ]; then
  echo >&2
  echo "Stacks not deployed for user '${USER_SLUG}', or outputs renamed." >&2
  echo "Run:  cd infra && cdk deploy --all -c user=${USER_SLUG}" >&2
  exit 1
fi

mkdir -p "${OUT}"
for f in "${ROOT}"/sql/*.sql; do
  base="$(basename "$f")"
  sed -e "s|<ACCOUNT_ID>|${ACCOUNT_ID}|g" \
      -e "s|<ACCT>|${ACCOUNT_ID}|g" \
      -e "s|<REGION>|${REGION}|g" \
      -e "s|<RAW_BUCKET>|${RAW_BUCKET}|g" \
      -e "s|<CURATED_BUCKET>|${CURATED_BUCKET}|g" \
      -e "s|<GLUE_DB>|${GLUE_DB}|g" \
      -e "s|<TABLE_BUCKET_NAME>|${TABLE_BUCKET_NAME}|g" \
      -e "s|<RESOURCE_LINK>|${RESOURCE_LINK}|g" \
      -e "s|<NAMESPACE>|${NAMESPACE}|g" \
      -e "s|<SPECTRUM_ROLE_ARN>|${SPECTRUM_ROLE_ARN}|g" \
      -e "s|<SPECTRUM_ROLE>|${SPECTRUM_ROLE_ARN}|g" \
      -e "s|<S3TABLES_ROLE_ARN>|${S3TABLES_ROLE_ARN}|g" \
      -e "s|<TABLE_BUCKET_ARN>|${TABLE_BUCKET_ARN}|g" \
      -e "s|<CLUSTER_ID>|${CLUSTER_ID}|g" \
      -e "s|<MASTER_SECRET_ARN>|${MASTER_SECRET_ARN}|g" \
      "$f" > "${OUT}/${base}"
done

echo
echo "Wrote $(ls -1 "${OUT}" | wc -l) resolved files to sql/_resolved/"

# ---------------------------------------------------------------------------
# Two classes of placeholder, and the distinction matters.
#
#   RESOLVED    substituted above from this learner's stack outputs. If any
#               survive, the render is broken and we exit non-zero.
#
#   EXTERNAL    name infrastructure this CDK deliberately does NOT build
#               (Kinesis, MSK, SageMaker, Aurora, DynamoDB, a second Redshift
#               account). They are supposed to survive. The modules using
#               them are concept modules, not runnable labs.
# ---------------------------------------------------------------------------
EXTERNAL='QUERY_ID|YOUR_IAM_ROLE_NAME|CONSUMER_NAMESPACE|CONSUMER_ACCOUNT_ID|PRODUCER_NAMESPACE|PRODUCER_ACCOUNT_ID|KINESIS_ROLE_ARN|KINESIS_STREAM_NAME|MSK_ROLE_ARN|MSK_CLUSTER_ARN|MSK_TOPIC_NAME|SAGEMAKER_ROLE_ARN|ML_S3_BUCKET|AURORA_CLUSTER_ARN|REDSHIFT_NAMESPACE_ARN|DYNAMODB_TABLE_ARN|DYNAMODB_ROLE_ARN|SCHEDULER_ROLE_ARN|EMR_ROLE_ARN|SSH_ROLE_ARN'

remaining=$(grep -oh '<[A-Z_][A-Z_0-9]*>' "${OUT}"/*.sql 2>/dev/null | sort | uniq -c || true)

echo
echo "Placeholders still present (EXPECTED - these name infrastructure this"
echo "platform does not create; see docs/PLACEHOLDERS.md):"
echo "${remaining}" | grep -E "${EXTERNAL}" || echo "  none"

unexpected=$(echo "${remaining}" | grep -vE "${EXTERNAL}" | grep -v '^\s*$' || true)
if [ -n "${unexpected}" ]; then
  echo >&2
  echo "ERROR: these should have been substituted from stack outputs but were not." >&2
  echo "       The rendered SQL is NOT safe to hand to a learner." >&2
  echo "${unexpected}" >&2
  exit 1
fi

echo
echo "OK - every stack-resolvable placeholder was substituted."

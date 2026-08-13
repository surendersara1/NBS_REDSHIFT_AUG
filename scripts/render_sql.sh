#!/usr/bin/env bash
# Resolve every <PLACEHOLDER> in sql/*.sql from the deployed CDK stack
# outputs, writing runnable copies to sql/_resolved/.
#
# Without this, eight people hand-edit 47 placeholders across 16 files and
# at least one of them gets an ARN wrong on a Monday morning.
#
# Usage:
#   ./scripts/render_sql.sh [project] [stage] [region]
#
# Prereqs: the three stacks are deployed, and the AWS CLI is authenticated
# to that account.
set -euo pipefail

PROJECT="${1:-nbs-coaching}"
STAGE="${2:-dev}"
REGION="${3:-${AWS_REGION:-us-east-1}}"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="${ROOT}/sql/_resolved"

echo "Reading stack outputs: ${PROJECT}-*-${STAGE} in ${REGION}"

out() {  # out <stack-suffix> <OutputKey>
  aws cloudformation describe-stacks \
    --region "${REGION}" \
    --stack-name "${PROJECT}-$1-${STAGE}" \
    --query "Stacks[0].Outputs[?OutputKey=='$2'].OutputValue" \
    --output text 2>/dev/null
}

ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
RAW_BUCKET=$(out foundation RawBucketName)
CURATED_BUCKET=$(out foundation CuratedBucketName)
GLUE_DB=$(out lakehouse GlueDatabaseName)
TABLE_BUCKET_ARN=$(out lakehouse TableBucketArnOut)
SPECTRUM_ROLE_ARN=$(out redshift SpectrumRoleArn)
S3TABLES_ROLE_ARN=$(out redshift S3TablesRoleArn)

# The table bucket NAME is the last path segment of its ARN.
TABLE_BUCKET_NAME="${TABLE_BUCKET_ARN##*/}"

missing=0
for v in ACCOUNT_ID RAW_BUCKET CURATED_BUCKET GLUE_DB SPECTRUM_ROLE_ARN \
         S3TABLES_ROLE_ARN TABLE_BUCKET_NAME; do
  if [ -z "${!v}" ] || [ "${!v}" = "None" ]; then
    echo "  MISSING: ${v}" >&2
    missing=1
  else
    echo "  ${v}=${!v}"
  fi
done
if [ "${missing}" -ne 0 ]; then
  echo "Stacks not deployed, or outputs renamed. Run 'cdk deploy --all' first." >&2
  exit 1
fi

mkdir -p "${OUT}"
for f in "${ROOT}"/sql/*.sql; do
  base="$(basename "$f")"
  sed -e "s|<ACCOUNT_ID>|${ACCOUNT_ID}|g" \
      -e "s|<ACCT>|${ACCOUNT_ID}|g" \
      -e "s|<RAW_BUCKET>|${RAW_BUCKET}|g" \
      -e "s|<CURATED_BUCKET>|${CURATED_BUCKET}|g" \
      -e "s|<GLUE_DB>|${GLUE_DB}|g" \
      -e "s|<TABLE_BUCKET_NAME>|${TABLE_BUCKET_NAME}|g" \
      -e "s|<SPECTRUM_ROLE_ARN>|${SPECTRUM_ROLE_ARN}|g" \
      -e "s|<SPECTRUM_ROLE>|${SPECTRUM_ROLE_ARN}|g" \
      -e "s|<S3TABLES_ROLE_ARN>|${S3TABLES_ROLE_ARN}|g" \
      "$f" > "${OUT}/${base}"
done

echo
echo "Wrote $(ls -1 "${OUT}" | wc -l) resolved files to sql/_resolved/"
echo
echo "Remaining placeholders (these are intentional — you fill them in as"
echo "you work; <QUERY_ID> is whichever query you are investigating):"
grep -oh '<[A-Z_]*>' "${OUT}"/*.sql 2>/dev/null | sort | uniq -c || echo "  none"

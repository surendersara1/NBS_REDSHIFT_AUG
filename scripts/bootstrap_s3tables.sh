#!/usr/bin/env bash
# Wire S3 Tables -> Glue Data Catalog -> Redshift for ONE learner.
#
# This script exists because the S3 Tables path has three prerequisites that
# CloudFormation cannot express, and sql/03 fails with a misleading error if
# any of them is missing:
#
#   1. The `s3tablescatalog` federated catalog                 ACCOUNT+REGION
#        Created once. Shared by every learner in the account. Creating it
#        again is a no-op here.
#
#   2. A Glue RESOURCE LINK to this learner's namespace        PER LEARNER
#        Redshift cannot point an external schema at a federated catalog
#        path. It can only point at a resource link in the ordinary catalog
#        that targets the federated path.
#
#   3. Lake Formation grants on the S3 Tables objects          PER LEARNER
#        IAM alone is not sufficient when the catalog is in Lake Formation
#        access-control mode. Granted at all three levels, because a grant
#        on the link without one on the target database produces an EMPTY
#        table list rather than an error.
#
# Idempotent: safe to re-run. Every step tolerates "already exists".
#
# Usage:
#   ./scripts/bootstrap_s3tables.sh --user suren [--stage dev] [--region us-east-1]
#   ./scripts/bootstrap_s3tables.sh --user suren --verify
#   ./scripts/bootstrap_s3tables.sh --user suren --grants-only
#
# Requires: AWS CLI v2, authenticated as a Lake Formation data lake admin.
set -euo pipefail

USER_SLUG=""
STAGE="dev"
REGION="${AWS_REGION:-us-east-1}"
MODE="all"

while [ $# -gt 0 ]; do
  case "$1" in
    --user)        USER_SLUG="$2"; shift 2 ;;
    --stage)       STAGE="$2";     shift 2 ;;
    --region)      REGION="$2";    shift 2 ;;
    --verify)      MODE="verify";  shift ;;
    --grants-only) MODE="grants";  shift ;;
    -h|--help)     sed -n '2,32p' "$0"; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; exit 2 ;;
  esac
done

[ -n "${USER_SLUG}" ] || { echo "ERROR: --user <slug> is required (same slug you passed to 'cdk deploy -c user=...')" >&2; exit 2; }

PREFIX="nbs-${USER_SLUG}"
PREFIX_SNAKE="nbs_${USER_SLUG}"
TABLE_BUCKET="${PREFIX}-tables-${STAGE}"
NAMESPACE="coaching"
RESOURCE_LINK="${PREFIX_SNAKE}_s3t_link"
ROLE_NAME="${PREFIX}-rs-s3tables-${STAGE}"

ACCOUNT=$(aws sts get-caller-identity --query Account --output text)
ROLE_ARN="arn:aws:iam::${ACCOUNT}:role/${ROLE_NAME}"
FED_CATALOG_ID="${ACCOUNT}:s3tablescatalog/${TABLE_BUCKET}"

echo "=============================================================="
echo " learner        ${USER_SLUG}"
echo " account/region ${ACCOUNT} / ${REGION}"
echo " table bucket   ${TABLE_BUCKET}"
echo " namespace      ${NAMESPACE}"
echo " resource link  ${RESOURCE_LINK}"
echo " redshift role  ${ROLE_ARN}"
echo "=============================================================="
echo

fail=0
ok()   { echo "  [ ok ] $*"; }
warn() { echo "  [WARN] $*"; }
bad()  { echo "  [FAIL] $*"; fail=1; }

# ---------------------------------------------------------------------------
# Step 1 - the federated catalog. Account+region wide, created once.
#
# CreateDatabaseDefaultPermissions/CreateTableDefaultPermissions are set to
# IAM_ALLOWED_PRINCIPALS, which puts the catalog in IAM access-control mode:
# IAM permissions alone govern access. We still apply Lake Formation grants
# in step 3, because an account whose catalog was created earlier (or via the
# console) may be in Lake Formation mode instead, where IAM is not enough.
# Applying both costs nothing and removes an entire class of "it works in my
# account but not yours".
# ---------------------------------------------------------------------------
step_catalog() {
  echo "1. Federated catalog 's3tablescatalog' (account+region wide)"
  if aws glue get-catalog --catalog-id s3tablescatalog --region "${REGION}" >/dev/null 2>&1; then
    ok "already exists - shared with every other learner in this account"
  else
    echo "     creating..."
    aws glue create-catalog \
      --region "${REGION}" \
      --name "s3tablescatalog" \
      --catalog-input "{
        \"Description\": \"Federated catalog for S3 Tables\",
        \"FederatedCatalog\": {
          \"Identifier\": \"arn:aws:s3tables:${REGION}:${ACCOUNT}:bucket/*\",
          \"ConnectionName\": \"aws:s3tables\"
        },
        \"CreateDatabaseDefaultPermissions\": [{
          \"Principal\": {\"DataLakePrincipalIdentifier\": \"IAM_ALLOWED_PRINCIPALS\"},
          \"Permissions\": [\"ALL\"]
        }],
        \"CreateTableDefaultPermissions\": [{
          \"Principal\": {\"DataLakePrincipalIdentifier\": \"IAM_ALLOWED_PRINCIPALS\"},
          \"Permissions\": [\"ALL\"]
        }]
      }" >/dev/null
    ok "created"
  fi

  # The child catalog for this learner's table bucket is mounted
  # asynchronously. Give it a moment rather than failing the next step.
  for i in 1 2 3 4 5 6; do
    if aws glue get-catalog --catalog-id "${FED_CATALOG_ID}" --region "${REGION}" >/dev/null 2>&1; then
      ok "child catalog mounted: ${FED_CATALOG_ID}"
      return 0
    fi
    [ "$i" -lt 6 ] && { echo "     waiting for child catalog to mount (${i}/5)..."; sleep 10; }
  done
  bad "child catalog ${FED_CATALOG_ID} never appeared."
  echo "         Does the table bucket exist? Run:"
  echo "           aws s3tables list-table-buckets --region ${REGION}"
  return 1
}

# ---------------------------------------------------------------------------
# Step 2 - the resource link. Per learner.
#
# A resource link is an ordinary Glue database whose TargetDatabase points
# into the federated catalog. Note the CatalogId on the TARGET is the
# composite '<account>:s3tablescatalog/<bucket>' form -- this is the one
# place that composite is correct. Redshift's own CATALOG_ID in sql/03 takes
# a bare account id.
# ---------------------------------------------------------------------------
step_link() {
  echo
  echo "2. Glue resource link '${RESOURCE_LINK}'"
  if aws glue get-database --name "${RESOURCE_LINK}" --region "${REGION}" >/dev/null 2>&1; then
    ok "already exists"
  else
    aws glue create-database \
      --region "${REGION}" \
      --cli-input-json "{
        \"CatalogId\": \"${ACCOUNT}\",
        \"DatabaseInput\": {
          \"Name\": \"${RESOURCE_LINK}\",
          \"TargetDatabase\": {
            \"CatalogId\": \"${FED_CATALOG_ID}\",
            \"DatabaseName\": \"${NAMESPACE}\"
          }
        }
      }" >/dev/null
    ok "created -> ${FED_CATALOG_ID}/${NAMESPACE}"
  fi
}

# ---------------------------------------------------------------------------
# Step 3 - Lake Formation grants. Per learner.
#
# Three levels, and all three are required:
#   a) DESCRIBE on the resource link          (in the ordinary catalog)
#   b) DESCRIBE on the target database        (in the federated catalog)
#   c) SELECT + DESCRIBE on the tables        (TableWildcard = all of them)
#
# Missing (b) or (c) is the nastiest failure in this whole platform:
# CREATE EXTERNAL SCHEMA succeeds, and svv_external_tables comes back EMPTY.
# No error, no AccessDenied. Just nothing.
# ---------------------------------------------------------------------------
grant() {  # grant <description> <resource-json> <permissions...>
  local desc="$1"; local resource="$2"; shift 2
  if aws lakeformation grant-permissions \
       --region "${REGION}" \
       --principal "DataLakePrincipalIdentifier=${ROLE_ARN}" \
       --resource "${resource}" \
       --permissions "$@" >/dev/null 2>&1; then
    ok "${desc}: $*"
  else
    warn "${desc}: grant call failed."
    warn "  Usually means the caller is not a Lake Formation data lake admin."
    warn "  Add yourself: Lake Formation console -> Administrative roles and tasks."
    fail=1
  fi
}

step_grants() {
  echo
  echo "3. Lake Formation grants for ${ROLE_NAME}"

  if ! aws iam get-role --role-name "${ROLE_NAME}" >/dev/null 2>&1; then
    bad "IAM role ${ROLE_NAME} not found. Deploy the stacks first:"
    echo "         cd infra && cdk deploy --all -c user=${USER_SLUG}"
    return 1
  fi

  grant "resource link" \
    "{\"Database\":{\"CatalogId\":\"${ACCOUNT}\",\"Name\":\"${RESOURCE_LINK}\"}}" \
    DESCRIBE

  grant "target database" \
    "{\"Database\":{\"CatalogId\":\"${FED_CATALOG_ID}\",\"Name\":\"${NAMESPACE}\"}}" \
    DESCRIBE

  grant "all tables" \
    "{\"Table\":{\"CatalogId\":\"${FED_CATALOG_ID}\",\"DatabaseName\":\"${NAMESPACE}\",\"TableWildcard\":{}}}" \
    SELECT DESCRIBE
}

# ---------------------------------------------------------------------------
# Verification. Asserts the things sql/03 depends on, and names the fix for
# each failure rather than leaving it as an exercise.
# ---------------------------------------------------------------------------
step_verify() {
  echo
  echo "4. Verification"

  aws glue get-catalog --catalog-id s3tablescatalog --region "${REGION}" >/dev/null 2>&1 \
    && ok "s3tablescatalog exists" \
    || bad "s3tablescatalog missing -> re-run without --verify"

  aws glue get-catalog --catalog-id "${FED_CATALOG_ID}" --region "${REGION}" >/dev/null 2>&1 \
    && ok "child catalog ${TABLE_BUCKET} mounted" \
    || bad "child catalog missing -> check 'aws s3tables list-table-buckets --region ${REGION}'"

  aws glue get-database --name "${RESOURCE_LINK}" --region "${REGION}" >/dev/null 2>&1 \
    && ok "resource link ${RESOURCE_LINK} exists" \
    || bad "resource link missing -> re-run without --verify"

  local tables
  tables=$(aws glue get-tables \
             --region "${REGION}" \
             --catalog-id "${FED_CATALOG_ID}" \
             --database-name "${NAMESPACE}" \
             --query 'length(TableList)' --output text 2>/dev/null || echo "0")
  if [ "${tables}" = "3" ]; then
    ok "3 tables visible in ${NAMESPACE} (bronze x2 + silver)"
  elif [ "${tables}" = "0" ] || [ "${tables}" = "None" ]; then
    bad "0 tables visible. The stacks create 3."
    echo "         Either the lakehouse stack did not deploy, or the grants"
    echo "         are missing. Re-run with --grants-only."
  else
    warn "${tables} tables visible, expected 3. Glue jobs may not have run yet."
  fi

  local grants
  grants=$(aws lakeformation list-permissions \
             --region "${REGION}" \
             --principal "DataLakePrincipalIdentifier=${ROLE_ARN}" \
             --query 'length(PrincipalResourcePermissions)' --output text 2>/dev/null || echo "0")
  [ "${grants}" != "0" ] && [ "${grants}" != "None" ] \
    && ok "${grants} Lake Formation grants on ${ROLE_NAME}" \
    || bad "no Lake Formation grants -> re-run with --grants-only"
}

case "${MODE}" in
  all)    step_catalog && step_link && step_grants; step_verify ;;
  grants) step_grants; step_verify ;;
  verify) step_verify ;;
esac

echo
if [ "${fail}" -eq 0 ]; then
  cat <<EOF
=============================================================='
ALL CHECKS PASSED. sql/03 will resolve.

Next:
  ./scripts/render_sql.sh --user ${USER_SLUG} --stage ${STAGE} --region ${REGION}

Then in Query Editor v2, run sql/_resolved/03_s3tables_federated_catalog.sql
EOF
else
  echo "=============================================================="
  echo "ONE OR MORE CHECKS FAILED. Fix the [FAIL] lines above before sql/03."
  exit 1
fi

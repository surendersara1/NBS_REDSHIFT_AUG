#!/usr/bin/env bash
# Create the eight learner logins without ever writing a password to disk,
# to git, or to the SQL history.
#
# For each learner:
#   1. generate a random password with Secrets Manager (server-side)
#   2. store it as a secret
#   3. run CREATE USER via the Redshift Data API, reading the password from
#      the secret so the literal never appears in this shell's history
#
# Usage:
#   ./create_learners.sh <cluster-id> <database> <admin-secret-arn> [region]
#
# Why Data API and not psql: the cluster has no public endpoint, and the Data
# API reaches it without a VPN or bastion. Same reason Query Editor v2 works.
set -euo pipefail

CLUSTER="${1:?cluster identifier required}"
DATABASE="${2:?database name required}"
ADMIN_SECRET="${3:?admin secret arn required}"
REGION="${4:-${AWS_REGION:-us-east-1}}"
COUNT="${LEARNER_COUNT:-8}"

echo "Creating ${COUNT} learners on ${CLUSTER}/${DATABASE} in ${REGION}"

for i in $(seq -w 1 "${COUNT}"); do
  USERNAME="learner${i}"
  SECRET_NAME="nbs-coaching/${USERNAME}"

  # Server-side generation: the password is never in a shell variable here.
  PASSWORD=$(aws secretsmanager get-random-password \
    --region "${REGION}" \
    --password-length 24 \
    --require-each-included-type \
    --exclude-punctuation \
    --output text --query RandomPassword)

  if aws secretsmanager describe-secret --region "${REGION}" \
       --secret-id "${SECRET_NAME}" >/dev/null 2>&1; then
    aws secretsmanager put-secret-value --region "${REGION}" \
      --secret-id "${SECRET_NAME}" \
      --secret-string "{\"username\":\"${USERNAME}\",\"password\":\"${PASSWORD}\"}" >/dev/null
  else
    aws secretsmanager create-secret --region "${REGION}" \
      --name "${SECRET_NAME}" \
      --description "Redshift coaching login for ${USERNAME}" \
      --secret-string "{\"username\":\"${USERNAME}\",\"password\":\"${PASSWORD}\"}" >/dev/null
  fi

  # SYSLOG ACCESS UNRESTRICTED so the monitoring labs in sql/06 return more
  # than the learner's own rows. Teaching cluster only.
  STATEMENT="CREATE USER ${USERNAME} PASSWORD '${PASSWORD}' SYSLOG ACCESS UNRESTRICTED;"

  ID=$(aws redshift-data execute-statement \
    --region "${REGION}" \
    --cluster-identifier "${CLUSTER}" \
    --database "${DATABASE}" \
    --secret-arn "${ADMIN_SECRET}" \
    --sql "${STATEMENT}" \
    --output text --query Id)

  unset PASSWORD STATEMENT

  echo "  ${USERNAME}: submitted (statement ${ID}), secret ${SECRET_NAME}"
done

cat <<EOF

Done. Hand each learner their own retrieval command:

  aws secretsmanager get-secret-value \\
    --region ${REGION} \\
    --secret-id nbs-coaching/learner01 \\
    --query SecretString --output text

Verify the statements succeeded:

  aws redshift-data describe-statement --region ${REGION} --id <statement-id>

Then run sql/01_setup_and_objects.sql section 1.3 to grant the roles.
EOF

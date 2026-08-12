#!/usr/bin/env bash
# ------------------------------------------------------------------
# destroy.sh — tears down everything deploy.sh created, so you don't
# leave billable resources running after a demo/pilot ends.
# ------------------------------------------------------------------
set -euo pipefail

if [ ! -f config.env ]; then
  echo "Missing config.env — can't determine resource names."
  exit 1
fi
source config.env
export AWS_PROFILE
REGION="$AWS_REGION"

echo "== Deleting API Gateway API ($API_NAME) =="
API_ID=$(aws apigatewayv2 get-apis --region "$REGION" \
  --query "Items[?Name=='$API_NAME'].ApiId" --output text)
if [ -n "$API_ID" ] && [ "$API_ID" != "None" ]; then
  aws apigatewayv2 delete-api --api-id "$API_ID" --region "$REGION"
  echo "Deleted API $API_ID"
else
  echo "No matching API found, skipping."
fi

echo "== Deleting Lambda function ($FUNCTION_NAME) =="
aws lambda delete-function --function-name "$FUNCTION_NAME" --region "$REGION" 2>/dev/null \
  && echo "Deleted." || echo "Not found, skipping."

echo "== Deleting DynamoDB table ($TABLE_NAME) =="
aws dynamodb delete-table --table-name "$TABLE_NAME" --region "$REGION" 2>/dev/null \
  && echo "Deleted." || echo "Not found, skipping."

echo "== Emptying and deleting S3 bucket ($S3_BUCKET) =="
echo "NOTE: this permanently deletes the new-patient intake workbook. Download it first if you want to keep it:"
echo "  aws s3 cp s3://$S3_BUCKET/$S3_KEY ./new-patient-intake-backup.xlsx --region $REGION"
read -p "Continue deleting the bucket and its contents? [y/N] " confirm
if [[ "$confirm" == "y" || "$confirm" == "Y" ]]; then
  aws s3 rm "s3://$S3_BUCKET" --recursive --region "$REGION" 2>/dev/null || true
  aws s3api delete-bucket --bucket "$S3_BUCKET" --region "$REGION" 2>/dev/null \
    && echo "Deleted." || echo "Not found, skipping."
else
  echo "Skipped bucket deletion."
fi

echo "== Deleting IAM role ($ROLE_NAME) =="
aws iam delete-role-policy --role-name "$ROLE_NAME" --policy-name "${ROLE_NAME}-inline-policy" 2>/dev/null || true
aws iam delete-role --role-name "$ROLE_NAME" 2>/dev/null \
  && echo "Deleted." || echo "Not found, skipping."

echo ""
echo "Teardown complete."

#!/usr/bin/env bash
# ------------------------------------------------------------------
# deploy.sh — provisions the full backend for the Lake America chat
# widget in YOUR AWS account, using YOUR AWS CLI credentials.
#
# Nothing in this script or repo ever needs your credentials pasted
# into a chat — it uses whatever `aws configure` has set up locally.
#
# Resources created:
#   - IAM role + policy for the Lambda
#   - DynamoDB table (conversation storage, 30-day TTL)
#   - Lambda function (Python 3.12) running lambda_function.py
#   - API Gateway HTTP API with a POST /chat route -> the Lambda
#   - (You still need to manually verify SES sender/recipient emails —
#     see the printed instructions at the end.)
#
# Usage:
#   1. cp config.env.example config.env   (then edit config.env)
#   2. chmod +x deploy.sh destroy.sh
#   3. ./deploy.sh
# ------------------------------------------------------------------
set -euo pipefail

if [ ! -f config.env ]; then
  echo "Missing config.env. Run: cp config.env.example config.env, then edit it."
  exit 1
fi
source config.env

export AWS_PROFILE
REGION="$AWS_REGION"

echo "== Checking AWS CLI identity =="
aws sts get-caller-identity --region "$REGION" > /dev/null
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text --region "$REGION")
echo "Deploying to account $ACCOUNT_ID in $REGION"

# ------------------------------------------------------------------
# 1. IAM ROLE
# ------------------------------------------------------------------
echo "== Creating IAM role ($ROLE_NAME) =="
if aws iam get-role --role-name "$ROLE_NAME" >/dev/null 2>&1; then
  echo "Role already exists, skipping creation."
else
  aws iam create-role \
    --role-name "$ROLE_NAME" \
    --assume-role-policy-document file://iam-trust-policy.json \
    --region "$REGION" > /dev/null
  echo "Waiting for IAM role to propagate..."
  sleep 10
fi

# Substitute the real bucket name into the IAM policy (the checked-in file
# has a placeholder since it can't know your bucket name ahead of time).
sed "s/REPLACE_WITH_BUCKET_NAME/$S3_BUCKET/" iam-permissions-policy.json > /tmp/iam-permissions-policy.resolved.json

aws iam put-role-policy \
  --role-name "$ROLE_NAME" \
  --policy-name "${ROLE_NAME}-inline-policy" \
  --policy-document file:///tmp/iam-permissions-policy.resolved.json

ROLE_ARN=$(aws iam get-role --role-name "$ROLE_NAME" --query 'Role.Arn' --output text)
echo "Role ARN: $ROLE_ARN"

# ------------------------------------------------------------------
# 2. S3 BUCKET (new-patient intake workbook)
# ------------------------------------------------------------------
echo "== Creating S3 bucket ($S3_BUCKET) =="
if aws s3api head-bucket --bucket "$S3_BUCKET" --region "$REGION" >/dev/null 2>&1; then
  echo "Bucket already exists, skipping creation."
else
  if [ "$REGION" = "us-east-1" ]; then
    aws s3api create-bucket --bucket "$S3_BUCKET" --region "$REGION" > /dev/null
  else
    aws s3api create-bucket --bucket "$S3_BUCKET" --region "$REGION" \
      --create-bucket-configuration LocationConstraint="$REGION" > /dev/null
  fi
  aws s3api put-public-access-block --bucket "$S3_BUCKET" --region "$REGION" \
    --public-access-block-configuration BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true
  echo "Bucket created (private — the workbook holds patient contact info, keep it that way)."
fi

# ------------------------------------------------------------------
# 3. DYNAMODB TABLE
# ------------------------------------------------------------------
echo "== Creating DynamoDB table ($TABLE_NAME) =="
if aws dynamodb describe-table --table-name "$TABLE_NAME" --region "$REGION" >/dev/null 2>&1; then
  echo "Table already exists, skipping creation."
else
  aws dynamodb create-table \
    --table-name "$TABLE_NAME" \
    --attribute-definitions AttributeName=sessionId,AttributeType=S \
    --key-schema AttributeName=sessionId,KeyType=HASH \
    --billing-mode PAY_PER_REQUEST \
    --region "$REGION" > /dev/null
  aws dynamodb wait table-exists --table-name "$TABLE_NAME" --region "$REGION"
  aws dynamodb update-time-to-live \
    --table-name "$TABLE_NAME" \
    --time-to-live-specification "Enabled=true, AttributeName=ttl" \
    --region "$REGION" > /dev/null
fi

# ------------------------------------------------------------------
# 4. LAMBDA FUNCTION
# ------------------------------------------------------------------
echo "== Packaging Lambda (with openpyxl dependency) =="
rm -rf build function.zip
mkdir -p build
pip install openpyxl -t build --quiet --disable-pip-version-check
cp lambda_function.py build/
( cd build && zip -qr ../function.zip . )

echo "== Deploying Lambda function ($FUNCTION_NAME) =="
ENV_VARS="Variables={ANTHROPIC_API_KEY=$ANTHROPIC_API_KEY,DYNAMODB_TABLE=$TABLE_NAME,S3_BUCKET=$S3_BUCKET,S3_KEY=$S3_KEY,ALLOWED_ORIGIN=$ALLOWED_ORIGIN}"

if aws lambda get-function --function-name "$FUNCTION_NAME" --region "$REGION" >/dev/null 2>&1; then
  aws lambda update-function-code \
    --function-name "$FUNCTION_NAME" \
    --zip-file fileb://function.zip \
    --region "$REGION" > /dev/null
  aws lambda wait function-updated --function-name "$FUNCTION_NAME" --region "$REGION"
  aws lambda update-function-configuration \
    --function-name "$FUNCTION_NAME" \
    --environment "$ENV_VARS" \
    --timeout 30 \
    --region "$REGION" > /dev/null
else
  aws lambda create-function \
    --function-name "$FUNCTION_NAME" \
    --runtime python3.12 \
    --role "$ROLE_ARN" \
    --handler lambda_function.lambda_handler \
    --zip-file fileb://function.zip \
    --timeout 30 \
    --memory-size 256 \
    --environment "$ENV_VARS" \
    --region "$REGION" > /dev/null
fi
aws lambda wait function-active --function-name "$FUNCTION_NAME" --region "$REGION"

LAMBDA_ARN=$(aws lambda get-function --function-name "$FUNCTION_NAME" --query 'Configuration.FunctionArn' --output text --region "$REGION")
echo "Lambda ARN: $LAMBDA_ARN"

# ------------------------------------------------------------------
# 5. API GATEWAY (HTTP API) + ROUTE + LAMBDA PERMISSION
# ------------------------------------------------------------------
echo "== Creating API Gateway HTTP API ($API_NAME) =="
EXISTING_API_ID=$(aws apigatewayv2 get-apis --region "$REGION" \
  --query "Items[?Name=='$API_NAME'].ApiId" --output text)

if [ -n "$EXISTING_API_ID" ] && [ "$EXISTING_API_ID" != "None" ]; then
  API_ID="$EXISTING_API_ID"
  echo "API already exists ($API_ID), reusing."
else
  API_ID=$(aws apigatewayv2 create-api \
    --name "$API_NAME" \
    --protocol-type HTTP \
    --target "$LAMBDA_ARN" \
    --cors-configuration "AllowOrigins=$ALLOWED_ORIGIN,AllowMethods=POST,AllowHeaders=content-type" \
    --region "$REGION" \
    --query 'ApiId' --output text)
fi
echo "API ID: $API_ID"

# When using --target on create-api, API Gateway auto-creates a $default
# stage, a catch-all route, and the integration. Grant it permission to
# invoke the Lambda (safe to re-run; AWS will error harmlessly if it exists).
aws lambda add-permission \
  --function-name "$FUNCTION_NAME" \
  --statement-id "apigw-invoke-$API_ID" \
  --action lambda:InvokeFunction \
  --principal apigateway.amazonaws.com \
  --source-arn "arn:aws:execute-api:${REGION}:${ACCOUNT_ID}:${API_ID}/*/*" \
  --region "$REGION" >/dev/null 2>&1 || true

API_ENDPOINT="https://${API_ID}.execute-api.${REGION}.amazonaws.com/"

echo ""
echo "=================================================================="
echo " DEPLOYMENT COMPLETE"
echo "=================================================================="
echo " API endpoint: $API_ENDPOINT"
echo " Intake workbook: s3://$S3_BUCKET/$S3_KEY (created on first captured lead)"
echo ""
echo " NEXT STEPS:"
echo " 1. Point the widget at your live endpoint:"
echo "      ./update-widget-endpoint.sh \"$API_ENDPOINT\""
echo ""
echo " 2. Test it directly:"
echo "      curl -X POST \"$API_ENDPOINT\" -H 'Content-Type: application/json' \\"
echo "        -d '{\"messages\":[{\"role\":\"user\",\"content\":\"Hi, do you take Aetna?\"}]}'"
echo ""
echo " 3. To see the intake workbook after a test conversation with a phone"
echo "    number in it, download it with:"
echo "      aws s3 cp s3://$S3_BUCKET/$S3_KEY ./new-patient-intake.xlsx --region $REGION"
echo "=================================================================="

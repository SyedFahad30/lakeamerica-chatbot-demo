<#
.SYNOPSIS
  deploy.ps1 - PowerShell version of deploy.sh. Provisions the full backend
  for the Lake America chat widget in YOUR AWS account, using the AWS CLI
  credentials already configured on this machine (via `aws configure`).

  Nothing in this script needs your credentials pasted into a chat - it
  uses whatever `aws configure` has already set up locally.

  Resources created:
    - IAM role + policy for the Lambda
    - S3 bucket (new-patient intake workbook)
    - DynamoDB table (conversation storage, 30-day TTL)
    - Lambda function (Python 3.12), packaged with the openpyxl dependency
    - API Gateway HTTP API with a catch-all route -> the Lambda

.USAGE
  1. Copy config.env.example to config.env, then edit it.
  2. Run:  .\deploy.ps1
     (If PowerShell blocks the script: run once as Administrator:
      Set-ExecutionPolicy -Scope CurrentUser RemoteSigned)
#>

# NOTE: intentionally NOT "Stop". With that setting, PowerShell treats any
# stderr line from a native command (like aws.exe) as a terminating error,
# even when redirected to $null — which breaks the exists-checks below.
# We check success explicitly via $LASTEXITCODE instead.
$ErrorActionPreference = "Continue"

# ------------------------------------------------------------------
# 0. LOAD CONFIG
# ------------------------------------------------------------------
if (-not (Test-Path ".\config.env")) {
    Write-Host "Missing config.env. Run: Copy-Item config.env.example config.env, then edit it." -ForegroundColor Red
    exit 1
}

$config = @{}
Get-Content ".\config.env" | ForEach-Object {
    $line = $_.Trim()
    if ($line -and -not $line.StartsWith("#") -and $line.Contains("=")) {
        $parts = $line.Split("=", 2)
        $config[$parts[0].Trim()] = $parts[1].Trim()
    }
}

$Region       = $config["AWS_REGION"]
$Profile      = $config["AWS_PROFILE"]
$FunctionName = $config["FUNCTION_NAME"]
$RoleName     = $config["ROLE_NAME"]
$TableName    = $config["TABLE_NAME"]
$ApiName      = $config["API_NAME"]
$AnthropicKey = $config["ANTHROPIC_API_KEY"]
$Bucket       = $config["S3_BUCKET"]
$S3Key        = $config["S3_KEY"]
$AllowedOrigin = $config["ALLOWED_ORIGIN"]

$AwsArgs = @("--region", $Region)
if ($Profile) { $AwsArgs += @("--profile", $Profile) }

function Invoke-Aws {
    param([string[]]$CmdArgs)
    & aws @CmdArgs @AwsArgs
}

# aws.exe is a native/external command, not a PowerShell cmdlet — when it
# fails, it writes an error to stderr and sets a non-zero exit code, but it
# does NOT throw a catchable PowerShell exception. try/catch around it is a
# no-op. This helper checks $LASTEXITCODE instead, which is the correct way
# to detect whether an external command actually succeeded.
function Test-AwsSuccess {
    param([string[]]$CmdArgs)
    & aws @CmdArgs @AwsArgs *> $null
    return ($LASTEXITCODE -eq 0)
}

Write-Host "== Checking AWS CLI identity ==" -ForegroundColor Cyan
$identity = & aws sts get-caller-identity @AwsArgs | ConvertFrom-Json
$AccountId = $identity.Account
Write-Host "Deploying to account $AccountId in $Region"

# ------------------------------------------------------------------
# 1. IAM ROLE
# ------------------------------------------------------------------
Write-Host "== Creating IAM role ($RoleName) ==" -ForegroundColor Cyan
$roleExists = Test-AwsSuccess -CmdArgs @("iam", "get-role", "--role-name", $RoleName)

if ($roleExists) {
    Write-Host "Role already exists, skipping creation."
} else {
    & aws iam create-role --role-name $RoleName `
        --assume-role-policy-document file://iam-trust-policy.json @AwsArgs | Out-Null
    Write-Host "Waiting for IAM role to propagate..."
    Start-Sleep -Seconds 10
}

# Substitute the real bucket name into the IAM policy (checked-in file has
# a placeholder since it can't know your bucket name ahead of time).
$policyContent = Get-Content ".\iam-permissions-policy.json" -Raw
$resolvedPolicy = $policyContent -replace "REPLACE_WITH_BUCKET_NAME", $Bucket
$resolvedPolicyPath = "$env:TEMP\iam-permissions-policy.resolved.json"
Set-Content -Path $resolvedPolicyPath -Value $resolvedPolicy -NoNewline

& aws iam put-role-policy --role-name $RoleName `
    --policy-name "$RoleName-inline-policy" `
    --policy-document "file://$resolvedPolicyPath" @AwsArgs

$RoleArn = (& aws iam get-role --role-name $RoleName --query 'Role.Arn' --output text @AwsArgs)
Write-Host "Role ARN: $RoleArn"

# ------------------------------------------------------------------
# 2. S3 BUCKET (new-patient intake workbook)
# ------------------------------------------------------------------
Write-Host "== Creating S3 bucket ($Bucket) ==" -ForegroundColor Cyan
$bucketExists = Test-AwsSuccess -CmdArgs @("s3api", "head-bucket", "--bucket", $Bucket)

if ($bucketExists) {
    Write-Host "Bucket already exists, skipping creation."
} else {
    if ($Region -eq "us-east-1") {
        & aws s3api create-bucket --bucket $Bucket @AwsArgs | Out-Null
    } else {
        & aws s3api create-bucket --bucket $Bucket `
            --create-bucket-configuration LocationConstraint=$Region @AwsArgs | Out-Null
    }
    & aws s3api put-public-access-block --bucket $Bucket @AwsArgs `
        --public-access-block-configuration "BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true"
    Write-Host "Bucket created (private - the workbook holds patient contact info, keep it that way)."
}

# ------------------------------------------------------------------
# 3. DYNAMODB TABLE
# ------------------------------------------------------------------
Write-Host "== Creating DynamoDB table ($TableName) ==" -ForegroundColor Cyan
$tableExists = Test-AwsSuccess -CmdArgs @("dynamodb", "describe-table", "--table-name", $TableName)

if ($tableExists) {
    Write-Host "Table already exists, skipping creation."
} else {
    & aws dynamodb create-table --table-name $TableName `
        --attribute-definitions AttributeName=sessionId,AttributeType=S `
        --key-schema AttributeName=sessionId,KeyType=HASH `
        --billing-mode PAY_PER_REQUEST @AwsArgs | Out-Null
    & aws dynamodb wait table-exists --table-name $TableName @AwsArgs
    & aws dynamodb update-time-to-live --table-name $TableName `
        --time-to-live-specification "Enabled=true, AttributeName=ttl" @AwsArgs | Out-Null
}

# ------------------------------------------------------------------
# 4. LAMBDA FUNCTION (packaged with openpyxl)
# ------------------------------------------------------------------
Write-Host "== Packaging Lambda (with openpyxl dependency) ==" -ForegroundColor Cyan
if (Test-Path ".\build") { Remove-Item ".\build" -Recurse -Force }
if (Test-Path ".\function.zip") { Remove-Item ".\function.zip" -Force }
New-Item -ItemType Directory -Path ".\build" | Out-Null

pip install openpyxl -t build --quiet --disable-pip-version-check
Copy-Item ".\lambda_function.py" ".\build\lambda_function.py"

# Compress-Archive preserves folder structure; Lambda needs the contents of
# build\ at the ZIP root, not nested inside a "build" folder.
Compress-Archive -Path ".\build\*" -DestinationPath ".\function.zip"

Write-Host "== Deploying Lambda function ($FunctionName) ==" -ForegroundColor Cyan
$envVarsJson = "Variables={ANTHROPIC_API_KEY=$AnthropicKey,DYNAMODB_TABLE=$TableName,S3_BUCKET=$Bucket,S3_KEY=$S3Key,ALLOWED_ORIGIN=$AllowedOrigin}"

$functionExists = Test-AwsSuccess -CmdArgs @("lambda", "get-function", "--function-name", $FunctionName)

if ($functionExists) {
    & aws lambda update-function-code --function-name $FunctionName `
        --zip-file fileb://function.zip @AwsArgs | Out-Null
    & aws lambda wait function-updated --function-name $FunctionName @AwsArgs
    & aws lambda update-function-configuration --function-name $FunctionName `
        --environment $envVarsJson --timeout 30 @AwsArgs | Out-Null
} else {
    & aws lambda create-function --function-name $FunctionName `
        --runtime python3.12 `
        --role $RoleArn `
        --handler lambda_function.lambda_handler `
        --zip-file fileb://function.zip `
        --timeout 30 `
        --memory-size 256 `
        --environment $envVarsJson @AwsArgs | Out-Null
}
& aws lambda wait function-active --function-name $FunctionName @AwsArgs

$LambdaArn = (& aws lambda get-function --function-name $FunctionName `
    --query 'Configuration.FunctionArn' --output text @AwsArgs)
Write-Host "Lambda ARN: $LambdaArn"

# ------------------------------------------------------------------
# 5. API GATEWAY (HTTP API) + ROUTE + LAMBDA PERMISSION
# ------------------------------------------------------------------
Write-Host "== Creating API Gateway HTTP API ($ApiName) ==" -ForegroundColor Cyan
$existingApiId = (& aws apigatewayv2 get-apis @AwsArgs `
    --query "Items[?Name=='$ApiName'].ApiId" --output text)

if ($existingApiId -and $existingApiId -ne "None") {
    $ApiId = $existingApiId
    Write-Host "API already exists ($ApiId), reusing."
} else {
    $corsConfig = "AllowOrigins=$AllowedOrigin,AllowMethods=POST,AllowHeaders=content-type"
    $ApiId = (& aws apigatewayv2 create-api --name $ApiName `
        --protocol-type HTTP --target $LambdaArn `
        --cors-configuration $corsConfig @AwsArgs `
        --query 'ApiId' --output text)
}
Write-Host "API ID: $ApiId"

try {
    & aws lambda add-permission --function-name $FunctionName `
        --statement-id "apigw-invoke-$ApiId" `
        --action lambda:InvokeFunction `
        --principal apigateway.amazonaws.com `
        --source-arn "arn:aws:execute-api:${Region}:${AccountId}:${ApiId}/*/*" @AwsArgs 2>$null | Out-Null
} catch { }

$ApiEndpoint = "https://$ApiId.execute-api.$Region.amazonaws.com/"

Write-Host ""
Write-Host "==================================================================" -ForegroundColor Green
Write-Host " DEPLOYMENT COMPLETE" -ForegroundColor Green
Write-Host "=================================================================="
Write-Host " API endpoint: $ApiEndpoint"
Write-Host " Intake workbook: s3://$Bucket/$S3Key (created on first captured lead)"
Write-Host ""
Write-Host " NEXT STEPS:"
Write-Host " 1. Point the widget at your live endpoint:"
Write-Host "      .\update-widget-endpoint.ps1 -Endpoint `"$ApiEndpoint`""
Write-Host ""
Write-Host " 2. Test it directly:"
Write-Host "      Invoke-RestMethod -Uri `"$ApiEndpoint`" -Method Post -ContentType 'application/json' -Body '{\"messages\":[{\"role\":\"user\",\"content\":\"Hi, do you take Aetna?\"}]}'"
Write-Host ""
Write-Host " 3. To see the intake workbook after a test conversation with a phone"
Write-Host "    number in it, download it with:"
Write-Host "      aws s3 cp s3://$Bucket/$S3Key .\new-patient-intake.xlsx --region $Region"
Write-Host "=================================================================="

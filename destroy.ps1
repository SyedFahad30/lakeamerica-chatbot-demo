<#
.SYNOPSIS
  destroy.ps1 - tears down everything deploy.ps1 created, so you don't
  leave billable resources running after a demo/pilot ends.
#>

$ErrorActionPreference = "SilentlyContinue"

if (-not (Test-Path ".\config.env")) {
    Write-Host "Missing config.env - can't determine resource names." -ForegroundColor Red
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
$Bucket       = $config["S3_BUCKET"]
$S3Key        = $config["S3_KEY"]

$AwsArgs = @("--region", $Region)
if ($Profile) { $AwsArgs += @("--profile", $Profile) }

Write-Host "== Deleting API Gateway API ($ApiName) ==" -ForegroundColor Cyan
$ApiId = (& aws apigatewayv2 get-apis @AwsArgs --query "Items[?Name=='$ApiName'].ApiId" --output text)
if ($ApiId -and $ApiId -ne "None") {
    & aws apigatewayv2 delete-api --api-id $ApiId @AwsArgs
    Write-Host "Deleted API $ApiId"
} else {
    Write-Host "No matching API found, skipping."
}

Write-Host "== Deleting Lambda function ($FunctionName) ==" -ForegroundColor Cyan
& aws lambda delete-function --function-name $FunctionName @AwsArgs
if ($?) { Write-Host "Deleted." } else { Write-Host "Not found, skipping." }

Write-Host "== Deleting DynamoDB table ($TableName) ==" -ForegroundColor Cyan
& aws dynamodb delete-table --table-name $TableName @AwsArgs | Out-Null
if ($?) { Write-Host "Deleted." } else { Write-Host "Not found, skipping." }

Write-Host "== Emptying and deleting S3 bucket ($Bucket) ==" -ForegroundColor Cyan
Write-Host "NOTE: this permanently deletes the new-patient intake workbook. Download it first if you want to keep it:"
Write-Host "  aws s3 cp s3://$Bucket/$S3Key .\new-patient-intake-backup.xlsx --region $Region"
$confirm = Read-Host "Continue deleting the bucket and its contents? [y/N]"
if ($confirm -eq "y" -or $confirm -eq "Y") {
    & aws s3 rm "s3://$Bucket" --recursive @AwsArgs | Out-Null
    & aws s3api delete-bucket --bucket $Bucket @AwsArgs
    if ($?) { Write-Host "Deleted." } else { Write-Host "Not found, skipping." }
} else {
    Write-Host "Skipped bucket deletion."
}

Write-Host "== Deleting IAM role ($RoleName) ==" -ForegroundColor Cyan
& aws iam delete-role-policy --role-name $RoleName --policy-name "$RoleName-inline-policy" | Out-Null
& aws iam delete-role --role-name $RoleName
if ($?) { Write-Host "Deleted." } else { Write-Host "Not found, skipping." }

Write-Host ""
Write-Host "Teardown complete." -ForegroundColor Green

# Lake America Chat Widget — Real AWS Deployment

This is a complete, deployable version of the chat widget demo — a real
backend, not a browser-only mockup. It's designed to run in **your own AWS
account**, using **your own AWS CLI credentials**, which never need to be
shared in chat.

## What gets deployed

```
Browser widget (chat-widget.js)
        │  POST { sessionId, messages }
        ▼
API Gateway (HTTP API)
        │
        ▼
Lambda (lambda_function.py)
        │  calls Anthropic API server-side (key never exposed to browser)
        │
        ├──▶ DynamoDB (chatbot-conversations) — stores each conversation, 30-day TTL
        └──▶ S3 (.xlsx workbook) — the first time a phone number shows up in a
              conversation, Claude extracts structured fields (name, phone,
              request type, details) and Lambda appends a row to the
              practice's running new-patient intake spreadsheet
```

**Functional scope this covers** (per the spec we agreed on): general inquiry
answers (insurance accepted, clinic hours, weekly doctor availability —
currently placeholder names "Dr. A"/"Dr. B", swap for the real roster before
using this with an actual client), routing to new appointment / existing
patient / refill / billing, no live-calendar booking (captures + says staff
will follow up), no medical advice, hard redirect to 911/ER on urgent
symptoms, and new-patient details logged to Excel instead of email.

## Files in this bundle

| File | Purpose |
|---|---|
| `lambda_function.py` | The backend logic — calls Claude, saves to DynamoDB, emails SES on lead capture |
| `iam-trust-policy.json` | Lets Lambda assume the execution role |
| `iam-permissions-policy.json` | Least-privilege permissions (logs, DynamoDB, SES only) |
| `config.env.example` | Template for your settings/secrets — copy to `config.env` |
| `deploy.sh` | Creates everything in AWS: IAM role, DynamoDB table, Lambda, API Gateway |
| `destroy.sh` | Tears everything down again (avoid ongoing charges after a demo/pilot) |
| `chat-widget.js` | The embeddable widget — now calls your backend instead of Anthropic directly |
| `update-widget-endpoint.sh` | Points `chat-widget.js` at your live API URL automatically |
| `lakeamerica-live-site.html` | A full mock of the Lake America site with the widget already wired in — open this to test end-to-end |

## Prerequisites

1. **AWS CLI v2** installed and configured with credentials that have
   permission to create IAM roles, Lambda functions, API Gateway APIs,
   DynamoDB tables, and S3 buckets.
   ```
   aws configure
   ```
   (or `aws configure --profile <name>` if you use a named profile — set
   `AWS_PROFILE` in `config.env` to match)
2. **An Anthropic API key** (console.anthropic.com → API Keys). This is
   separate from any key used in browser-based demos — it lives only in
   AWS, server-side.
3. **`zip`** and **`pip`** available on your machine (used to package the
   Lambda along with its `openpyxl` dependency, since that's not included
   in AWS's default Python runtime).
4. A **globally unique S3 bucket name** for the intake workbook (bucket
   names are unique across all of AWS, not just your account) — set this
   in `config.env`.

## Steps

```bash
# 1. Configure
cp config.env.example config.env
# edit config.env: set ANTHROPIC_API_KEY, S3_BUCKET (must be globally unique),
# and AWS_REGION/AWS_PROFILE to match your setup

chmod +x deploy.sh destroy.sh update-widget-endpoint.sh

# 2. Deploy
./deploy.sh
# creates the S3 bucket, DynamoDB table, IAM role, Lambda (with openpyxl
# packaged in), and API Gateway — prints your live API endpoint at the end

# 3. Wire the widget to your live endpoint
./update-widget-endpoint.sh "https://your-api-id.execute-api.us-east-1.amazonaws.com/"

# 4. Test end-to-end
open lakeamerica-live-site.html   # (or just double-click it)
# click the chat bubble, have a real conversation as a "new patient" and
# include a phone number near the end, then pull down the workbook to
# confirm the row was added:
aws s3 cp s3://your-bucket-name/new-patient-intake.xlsx ./check.xlsx --region us-east-1
open check.xlsx
```

You can also test the backend directly without the browser:

```bash
curl -X POST "https://your-api-id.execute-api.us-east-1.amazonaws.com/" \
  -H "Content-Type: application/json" \
  -d '{"messages":[{"role":"user","content":"Do you accept Aetna?"}]}'
```

## Cost expectations

At demo/pilot volume (a handful of conversations a day), this runs almost
entirely within AWS free-tier limits:
- Lambda: 1M free requests/month
- API Gateway HTTP API: very low per-request cost, no free tier but pennies at this volume
- DynamoDB: pay-per-request billing, free tier covers light use
- S3: essentially free at this scale — one small .xlsx file, occasional read/write

The Anthropic API call is the main real cost, and it's small — a few cents
per full conversation on Sonnet at 300 max_tokens per reply, plus one small
extra call to extract structured fields when a lead is captured.

## Before handing this to a real client

- Lock `ALLOWED_ORIGIN` in `config.env` down to their actual domain instead
  of `*` (redeploy after changing it).
- Update `DOCTOR_SCHEDULE` in `lambda_function.py` with the real doctor
  names/days — it's currently placeholder data ("Dr. A", "Dr. B").
- The S3 bucket holds real patient names and phone numbers — it's created
  private by default (public access blocked), keep it that way. Consider
  enabling S3 default encryption and versioning for anything beyond a demo.
- Consider adding a custom domain to API Gateway so the endpoint URL looks
  clean rather than the raw `execute-api.amazonaws.com` string.
- Add basic rate-limiting (API Gateway throttling settings) so a bad actor
  can't run up your Anthropic bill by hammering the endpoint.
- Decide how the front desk actually gets the spreadsheet day-to-day (a
  scheduled email of the file, an internal link, syncing to their own
  OneDrive/Google Drive via a small script) — right now it lives only in S3.

## Live Demo
https://d1y2bod9a0pm5b.cloudfront.net/
https://d1y2bod9a0pm5b.cloudfront.net/dashboard.html

## Tearing down

When you're done testing/demoing:



```bash
./destroy.sh
```

This removes the Lambda, API Gateway API, DynamoDB table, and IAM role, and
(after a confirmation prompt, since it holds real data) the S3 bucket and
the intake workbook inside it.

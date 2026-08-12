#!/usr/bin/env bash
# ------------------------------------------------------------------
# update-widget-endpoint.sh
# Points chat-widget.js at your live API Gateway endpoint after deploy.sh
# prints it out.
#
# Usage: ./update-widget-endpoint.sh "https://xxxxx.execute-api.us-east-1.amazonaws.com/"
# ------------------------------------------------------------------
set -euo pipefail

if [ -z "${1:-}" ]; then
  echo "Usage: $0 <api-endpoint-url>"
  exit 1
fi

ENDPOINT="$1"
FILE="chat-widget.js"

if [ ! -f "$FILE" ]; then
  echo "$FILE not found in this directory."
  exit 1
fi

# Replace whatever apiEndpoint currently is with the live URL.
sed -i.bak -E "s#apiEndpoint:.*#apiEndpoint: \"${ENDPOINT}\",#" "$FILE"

echo "Updated $FILE to call: $ENDPOINT"
echo "(backup saved as ${FILE}.bak)"

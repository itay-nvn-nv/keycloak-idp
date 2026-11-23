#!/bin/sh
set -e

# authentik serves /-/health/ready/ once migrations are done and the DB is
# reachable, which is a stronger signal than the login page rendering.
CHECK_INTERVAL_SECONDS="${CHECK_INTERVAL_SECONDS:-10}"
HEALTH_URL="${AK_HOSTNAME%/}/-/health/ready/"

echo "Starting authentik health check..."

while true; do
  echo "Checking authentik: $HEALTH_URL"
  if curl -s -o /dev/null -w "%{http_code}" "$HEALTH_URL" | grep -E "^(2|3)[0-9]{2}$" > /dev/null; then
    echo "authentik is healthy."
    exit 0
  fi

  echo "authentik is NOT healthy. Waiting for ${CHECK_INTERVAL_SECONDS} second(s) before retrying..."
  sleep "$CHECK_INTERVAL_SECONDS"
done

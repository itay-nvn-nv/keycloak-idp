#!/bin/sh
set -e

CHECK_INTERVAL_SECONDS="${CHECK_INTERVAL_SECONDS:-10}"
echo "Starting Keycloak URL health check..."

while true; do
  echo "Checking Keycloak URL: $KC_HOSTNAME"
  if curl -s -o /dev/null -w "%{http_code}" "$KC_HOSTNAME" | grep -E "^(2|3)[0-9]{2}$" > /dev/null; then
    echo "Keycloak URL is healthy."
    echo "All URLs are healthy. Exiting..."
    exit 0
  fi

  echo "Keycloak URL is NOT healthy. Waiting for ${CHECK_INTERVAL_SECONDS} second(s) before retrying..."
  sleep "$CHECK_INTERVAL_SECONDS"
done

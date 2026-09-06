#!/bin/sh
set -e

CHECK_INTERVAL_SECONDS="${CHECK_INTERVAL_SECONDS:-30}"
echo "Starting URL health check with timeout of ${activeDeadlineSeconds} seconds..."

while true; do
  echo "Checking Keycloak URL: $KC_HOSTNAME"
  if curl -s -o /dev/null -w "%{http_code}" "$KC_HOSTNAME" | grep -E "^(2|3)[0-9]{2}$" > /dev/null; then
    echo "Keycloak URL is healthy."
  else
    echo "Keycloak URL is NOT healthy. Waiting for ${CHECK_INTERVAL_SECONDS} second(s) before retrying..."
    sleep "$CHECK_INTERVAL_SECONDS"
    continue
  fi

  echo "Checking App URL: $RUNAI_CTRL_PLANE_URL"
  if curl -s -o /dev/null -w "%{http_code}" "$RUNAI_CTRL_PLANE_URL" | grep -E "^(2|3)[0-9]{2}$" > /dev/null; then
    echo "App URL is healthy."
  else
    echo "App URL is NOT healthy. Waiting for ${CHECK_INTERVAL_SECONDS} second(s) before retrying..."
    sleep "$CHECK_INTERVAL_SECONDS"
    continue
  fi

  echo "All URLs are healthy. Exiting..."
  exit 0
done


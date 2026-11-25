#!/bin/sh
set -e

# Used by authentik integrate (local and in-cluster). Prints the HTTP code
# and curl error so a TCP timeout is obvious instead of a silent retry.

CHECK_INTERVAL_SECONDS="${CHECK_INTERVAL_SECONDS:-10}"
CONNECT_TIMEOUT="${CONNECT_TIMEOUT:-15}"
MAX_TIME="${MAX_TIME:-30}"
MAX_ATTEMPTS="${MAX_ATTEMPTS:-0}"

check_url() {
  name="$1"
  url="$2"
  errfile=$(mktemp)
  set +e
  code=$(curl -sS -o /dev/null -w "%{http_code}" \
    --connect-timeout "$CONNECT_TIMEOUT" \
    --max-time "$MAX_TIME" \
    "$url" 2>"$errfile")
  rc=$?
  set -e
  err=$(tr -d '\n' < "$errfile")
  rm -f "$errfile"

  echo "Checking $name URL: $url"
  if [ "$rc" -eq 0 ] && echo "$code" | grep -E '^(2|3)[0-9]{2}$' >/dev/null; then
    echo "$name URL is healthy (HTTP $code)."
    return 0
  fi

  if [ "$rc" -ne 0 ]; then
    echo "$name URL is NOT healthy (curl exit $rc${code:+, HTTP $code}${err:+; $err})."
  else
    echo "$name URL is NOT healthy (HTTP ${code:-000}${err:+; $err})."
  fi
  return 1
}

attempt=0
echo "Starting URL health check..."
while true; do
  attempt=$((attempt + 1))
  if check_url "authentik" "${AK_HOSTNAME%/}/-/health/ready/" && check_url "App" "$RUNAI_CTRL_PLANE_URL"; then
    echo "All URLs are healthy. Exiting..."
    exit 0
  fi

  if [ "$MAX_ATTEMPTS" -gt 0 ] && [ "$attempt" -ge "$MAX_ATTEMPTS" ]; then
    echo "ERROR: URLs were not healthy after $attempt attempt(s)."
    exit 1
  fi

  echo "Waiting for ${CHECK_INTERVAL_SECONDS} second(s) before retrying..."
  sleep "$CHECK_INTERVAL_SECONDS"
done

#!/bin/sh
set -e

# If a TLS secret is mounted at /tls/tls.crt (self-signed or private CA),
# append it to the image CA bundle so reused curl scripts trust Keycloak
# without losing trust for the public Run:AI control plane.
if [ -f /tls/tls.crt ]; then
  SYSTEM_CA=""
  for f in \
    /etc/ssl/certs/ca-certificates.crt \
    /etc/ssl/cert.pem \
    /etc/pki/tls/certs/ca-bundle.crt
  do
    if [ -f "$f" ]; then
      SYSTEM_CA="$f"
      break
    fi
  done

  if [ -n "$SYSTEM_CA" ]; then
    cat "$SYSTEM_CA" /tls/tls.crt > /tmp/ca-bundle.crt
  else
    cp /tls/tls.crt /tmp/ca-bundle.crt
  fi

  export CURL_CA_BUNDLE=/tmp/ca-bundle.crt
  export SSL_CERT_FILE=/tmp/ca-bundle.crt
  echo "Using custom CA bundle that includes /tls/tls.crt"
fi

exec "$@"

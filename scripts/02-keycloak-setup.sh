#!/bin/sh
set -e

echo "======================================"
echo "KEYCLOAK SETUP"
echo "======================================"

# Step 1: Authenticate with Keycloak
echo ""
echo "[1/2] Authenticating with Keycloak..."
KEYCLOAK_TOKEN=$(curl -s -X POST "$KC_HOSTNAME/realms/master/protocol/openid-connect/token" \
  -H "Content-Type: application/x-www-form-urlencoded" \
  -d "username=$KEYCLOAK_ADMIN" \
  -d "password=$KEYCLOAK_ADMIN_PASSWORD" \
  -d 'grant_type=password' \
  -d 'client_id=admin-cli' | jq -r '.access_token')

if [ -z "$KEYCLOAK_TOKEN" ] || [ "$KEYCLOAK_TOKEN" = "null" ]; then
  echo "ERROR: Failed to obtain Keycloak token"
  exit 1
fi

echo "Successfully obtained Keycloak token"
echo "$KEYCLOAK_TOKEN" > /shared-files/keycloak_token

# Step 2: Import Realm
echo ""
echo "[2/2] Importing Keycloak realm..."

CLEAN_URL="${RUNAI_CTRL_PLANE_URL#*://}"
SAML_CLIENT_ID="runai-$CLEAN_URL/runai"

echo "Preparing realm configuration..."
jq --arg SAML_CLIENT_ID "$SAML_CLIENT_ID" --arg RUNAI_CTRL_PLANE_URL "$RUNAI_CTRL_PLANE_URL" '
  (.. | select(type == "string")) |= gsub("RUNAI_CTRL_PLANE_URL_PLACEHOLDER"; $RUNAI_CTRL_PLANE_URL) |
  (.. | select(type == "string")) |= gsub("SAML_CLIENT_ID_PLACEHOLDER"; $SAML_CLIENT_ID)
' /keycloak-realm-data/realm.json > /shared-files/realm_updated.json

REALM_NAME=$(jq -r '.realm' /shared-files/realm_updated.json)
echo "Target realm: $REALM_NAME"

# Check if realm already exists
echo "Checking if realm already exists..."
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" "$KC_HOSTNAME/admin/realms/$REALM_NAME" \
  -H "authorization: Bearer $KEYCLOAK_TOKEN")

if [ "$HTTP_CODE" = "200" ]; then
  echo "✓ Realm '$REALM_NAME' already exists. Skipping import."
elif [ "$HTTP_CODE" = "404" ]; then
  echo "Realm does not exist. Creating realm..."
  HTTP_CODE=$(curl -s -o /tmp/realm_response.json -w "%{http_code}" -X POST "$KC_HOSTNAME/admin/realms" \
    -H 'accept: application/json, text/plain, */*' \
    -H "authorization: Bearer $KEYCLOAK_TOKEN" \
    -H 'Content-Type: application/json' \
    --data "@/shared-files/realm_updated.json")
  
  if [ "$HTTP_CODE" = "201" ] || [ "$HTTP_CODE" = "200" ]; then
    echo "✓ Realm created successfully"
  else
    echo "ERROR: Failed to create realm (HTTP $HTTP_CODE)"
    cat /tmp/realm_response.json
    exit 1
  fi
else
  echo "ERROR: Unexpected response when checking realm (HTTP $HTTP_CODE)"
  exit 1
fi

echo ""
echo "======================================"
echo "KEYCLOAK SETUP COMPLETE"
echo "======================================"


#!/bin/sh
set -e

echo "======================================"
echo "KEYCLOAK CLIENT PATCH"
echo "======================================"
echo "Aligning imported realm clients with the real Run:AI control plane URL."
echo "Redirect URIs keep RUNAI_IDP_ALIAS_PLACEHOLDER; 03-runai-setup.sh resolves the alias."

load_keycloak_token() {
  if [ -n "$KC_HOSTNAME" ] && [ -n "$KEYCLOAK_ADMIN" ] && [ -n "$KEYCLOAK_ADMIN_PASSWORD" ]; then
    FRESH_TOKEN=$(curl -s -X POST "$KC_HOSTNAME/realms/master/protocol/openid-connect/token" \
      -H "Content-Type: application/x-www-form-urlencoded" \
      -d "username=$KEYCLOAK_ADMIN" \
      -d "password=$KEYCLOAK_ADMIN_PASSWORD" \
      -d 'grant_type=password' \
      -d 'client_id=admin-cli' | jq -r '.access_token')

    if [ -n "$FRESH_TOKEN" ] && [ "$FRESH_TOKEN" != "null" ]; then
      KEYCLOAK_TOKEN="$FRESH_TOKEN"
      return 0
    fi
  fi

  if [ -f /shared-files/keycloak_token ]; then
    KEYCLOAK_TOKEN=$(cat /shared-files/keycloak_token)
  fi
}

load_keycloak_token

if [ -z "$KEYCLOAK_TOKEN" ] || [ "$KEYCLOAK_TOKEN" = "null" ]; then
  echo "ERROR: Failed to obtain Keycloak token"
  exit 1
fi

if [ ! -f /shared-files/realm_updated.json ]; then
  echo "ERROR: /shared-files/realm_updated.json is missing (02-keycloak-setup.sh must run first)"
  exit 1
fi

if [ -z "$KC_HOSTNAME" ]; then
  echo "ERROR: KC_HOSTNAME is not set"
  exit 1
fi

REALM_NAME=$(jq -r '.realm' /shared-files/realm_updated.json)
echo "Realm: $REALM_NAME"
echo "Keycloak URL: $KC_HOSTNAME"
echo "Run:AI control plane: $RUNAI_CTRL_PLANE_URL"

CLIENTS_JSON=$(curl -s "$KC_HOSTNAME/admin/realms/$REALM_NAME/clients" \
  -H "authorization: Bearer $KEYCLOAK_TOKEN")

if [ -z "$CLIENTS_JSON" ] || [ "$CLIENTS_JSON" = "null" ]; then
  echo "ERROR: Failed to list clients in realm '$REALM_NAME'"
  exit 1
fi

patch_live_client() {
  DESIRED="$1"
  MATCH_FILTER="$2"
  LABEL="$3"

  if [ -z "$DESIRED" ] || [ "$DESIRED" = "null" ]; then
    echo "No $LABEL client in realm_updated.json; skipping"
    return 0
  fi

  LIVE=$(echo "$CLIENTS_JSON" | jq -c "$MATCH_FILTER" | head -n1)
  if [ -z "$LIVE" ] || [ "$LIVE" = "null" ]; then
    echo "ERROR: Could not find live $LABEL client ($MATCH_FILTER)"
    echo "$CLIENTS_JSON" | jq -c '.[] | {id, clientId, protocol}' 2>/dev/null || echo "$CLIENTS_JSON"
    exit 1
  fi

  CLIENT_UUID=$(echo "$LIVE" | jq -r '.id // empty')
  LIVE_CLIENT_ID=$(echo "$LIVE" | jq -r '.clientId // empty')

  if [ -z "$CLIENT_UUID" ]; then
    echo "ERROR: Live $LABEL client is missing an id"
    echo "$LIVE"
    exit 1
  fi

  echo ""
  echo "Patching $LABEL client '$LIVE_CLIENT_ID' ($CLIENT_UUID)..."

  UPDATED=$(echo "$LIVE" | jq -c --argjson desired "$DESIRED" '
    .clientId = $desired.clientId |
    .redirectUris = ($desired.redirectUris // .redirectUris) |
    .webOrigins = ($desired.webOrigins // .webOrigins) |
    .rootUrl = (if $desired.rootUrl == null then .rootUrl else $desired.rootUrl end) |
    .baseUrl = (if $desired.baseUrl == null then .baseUrl else $desired.baseUrl end) |
    .adminUrl = (if $desired.adminUrl == null then .adminUrl else $desired.adminUrl end) |
    .attributes = ((.attributes // {}) + ($desired.attributes // {}))
  ')

  if [ "$UPDATED" = "$LIVE" ]; then
    echo "✓ $LABEL client already matches the real control plane URL. Skipping."
    return 0
  fi

  HTTP_CODE=$(curl -s -o /tmp/client_patch_response.json -w "%{http_code}" \
    -X PUT "$KC_HOSTNAME/admin/realms/$REALM_NAME/clients/$CLIENT_UUID" \
    -H 'accept: application/json, text/plain, */*' \
    -H "authorization: Bearer $KEYCLOAK_TOKEN" \
    -H 'Content-Type: application/json' \
    --data "$UPDATED")

  if [ "$HTTP_CODE" = "204" ] || [ "$HTTP_CODE" = "200" ]; then
    NEW_ID=$(echo "$DESIRED" | jq -r '.clientId')
    echo "✓ Updated $LABEL client to clientId='$NEW_ID'"
  else
    echo "ERROR: Failed to update $LABEL client (HTTP $HTTP_CODE)"
    cat /tmp/client_patch_response.json
    exit 1
  fi
}

OIDC_DESIRED=$(jq -c '.clients[] | select(.protocol=="openid-connect")' /shared-files/realm_updated.json)
SAML_DESIRED=$(jq -c '.clients[] | select(.protocol=="saml")' /shared-files/realm_updated.json)

# Imported realms also get Keycloak's built-in OIDC clients (account, admin-cli, ...).
# Always target the lab OIDC client by clientId.
patch_live_client "$OIDC_DESIRED" '.[] | select(.clientId=="lab-oidc-client")' "OIDC"
# There is a single SAML client; its clientId changes from the placeholder entity id
# to runai-<ctrl-plane-host>/runai once the real URL is known.
patch_live_client "$SAML_DESIRED" '.[] | select(.protocol=="saml")' "SAML"

echo ""
echo "======================================"
echo "KEYCLOAK CLIENT PATCH COMPLETE"
echo "======================================"

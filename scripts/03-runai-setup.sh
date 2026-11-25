#!/bin/sh
set -e

echo "======================================"
echo "RUN:AI SETUP (authentik)"
echo "======================================"

# Registers authentik with the control plane: create the IDP connector, resolve
# the alias Run:AI generates for it, rewrite the provider to match, then create
# the sample project and access rule.

SHARED="${SHARED_DIR:-/shared-files}"
OBJECTS="$SHARED/authentik_objects.json"
RESP=/tmp/ak_resp.json

AK_API="${AK_HOSTNAME%/}/api/v3"

if [ ! -f "$OBJECTS" ]; then
  echo "ERROR: $OBJECTS is missing (02-authentik-setup.sh must run first)"
  exit 1
fi

AK_PUBLIC_URL=$(jq -r '.public_url' "$OBJECTS")
OIDC_PROVIDER_PK=$(jq -r '.oidc.provider_pk' "$OBJECTS")
OIDC_APP_SLUG=$(jq -r '.oidc.app_slug' "$OBJECTS")
OIDC_CLIENT_ID=$(jq -r '.oidc.client_id' "$OBJECTS")
OIDC_CLIENT_SECRET=$(jq -r '.oidc.client_secret' "$OBJECTS")
RUNAI_SCOPE_NAME=$(jq -r '.oidc.scope' "$OBJECTS")
SAML_PROVIDER_PK=$(jq -r '.saml.provider_pk' "$OBJECTS")
SAML_APP_SLUG=$(jq -r '.saml.app_slug' "$OBJECTS")

RUNAI_CTRL_PLANE_URL="${RUNAI_CTRL_PLANE_URL%/}"

api_code() {
  _method="$1"; _path="$2"; _body="${3:-}"
  if [ -n "$_body" ]; then
    curl -sS -o "$RESP" -w '%{http_code}' -X "$_method" "$AK_API$_path" \
      -H "Authorization: Bearer $AK_TOKEN" \
      -H 'Content-Type: application/json' \
      -H 'Accept: application/json' \
      --data "$_body"
  else
    curl -sS -o "$RESP" -w '%{http_code}' -X "$_method" "$AK_API$_path" \
      -H "Authorization: Bearer $AK_TOKEN" -H 'Accept: application/json'
  fi
}

ok_code() {
  case "$1" in
    200|201|204) return 0 ;;
    *) return 1 ;;
  esac
}

# Step 1: Authenticate with Run:AI
echo ""
echo "[1/5] Authenticating with Run:AI Control Plane..."
RUNAI_TOKEN=$(curl -s -X POST "$RUNAI_CTRL_PLANE_URL/api/v1/token" \
  --header 'accept: application/json, text/plain, */*' \
  --header 'Content-Type: application/json' \
  --data-raw "{
    \"grantType\": \"password\",
    \"clientID\": \"cli\",
    \"username\": \"$RUNAI_ADMIN_USERNAME\",
    \"password\": \"$RUNAI_ADMIN_PASSWORD\"}" | jq -r .accessToken)

if [ -z "$RUNAI_TOKEN" ] || [ "$RUNAI_TOKEN" = "null" ]; then
  echo "ERROR: Failed to obtain Run:AI token"
  exit 1
fi

echo "✓ Successfully obtained Run:AI token"

# Step 2: Create IDP
echo ""
echo "[2/5] Creating IDP configuration..."

IDP_TYPE_LOWER=$(echo "$RUNAI_IDP_TYPE" | tr '[:upper:]' '[:lower:]')
echo "IDP type: $RUNAI_IDP_TYPE"

select_idp() {
  jq -c --arg t "$IDP_TYPE_LOWER" '
    if type == "array" then
      (map(select(.type == $t)) | .[0]) // .[0] // {}
    else
      {}
    end'
}

echo "Checking if IDP already exists..."
EXISTING_IDPS=$(curl -s "$RUNAI_CTRL_PLANE_URL/api/v1/idps" \
  -H "authorization: Bearer $RUNAI_TOKEN")
IDP_EXISTS=$(echo "$EXISTING_IDPS" | jq -r 'length')

if [ "$IDP_EXISTS" != "0" ] && [ "$IDP_EXISTS" != "null" ]; then
  # Run:AI serves one IDP at a time. Reusing an IDP of the other protocol would
  # silently wire this provider to the wrong broker alias, so stop instead.
  EXISTING_TYPE=$(echo "$EXISTING_IDPS" | jq -r '[.[]?.type] | join(",")')
  if ! echo "$EXISTING_IDPS" | jq -e --arg t "$IDP_TYPE_LOWER" 'any(.[]?; .type == $t)' >/dev/null; then
    echo "ERROR: the control plane already has a '$EXISTING_TYPE' IDP, but '$IDP_TYPE_LOWER' was requested"
    echo "Run:AI allows one IDP at a time. Remove the existing one first:"
    echo "  ./cleanup.sh --integration-only"
    exit 1
  fi
  echo "✓ IDP already exists. Skipping IDP creation."
  IDP_OBJECT=$(echo "$EXISTING_IDPS" | select_idp)
else
  echo "No IDP found. Creating IDP..."

  if [ "$RUNAI_IDP_TYPE" = "OIDC" ]; then
    echo "Creating OIDC IDP..."

    if [ -z "$OIDC_CLIENT_SECRET" ] || [ "$OIDC_CLIENT_SECRET" = "null" ]; then
      echo "ERROR: No client secret recorded for provider $OIDC_PROVIDER_PK"
      exit 1
    fi

    DISCOVER_DOCUMENT_URL="$AK_PUBLIC_URL/application/o/$OIDC_APP_SLUG/.well-known/openid-configuration"
    echo "Discovery document: $DISCOVER_DOCUMENT_URL"

    # The Run:AI claim mappers live in a dedicated scope mapping, so that scope
    # has to be requested alongside openid or the claims are never emitted.
    IDP_BODY=$(jq -n \
      --arg url "$DISCOVER_DOCUMENT_URL" \
      --arg cid "$OIDC_CLIENT_ID" \
      --arg secret "$OIDC_CLIENT_SECRET" \
      --arg scope "$RUNAI_SCOPE_NAME" \
      '{type: "oidc",
        oidcData: {discoverDocumentUrl: $url, clientId: $cid, clientSecret: $secret,
                   scopes: ["openid", "profile", "email", $scope], mandatoryClaim: null},
        mappers: {uid: "UID", gid: "GID", groups: "GROUPS",
                  supplementaryGroups: "SUPPLEMENTARYGROUPS", email: "email"}}')

    HTTP_CODE=$(curl -s -o /tmp/idp_response.json -w "%{http_code}" -X POST "$RUNAI_CTRL_PLANE_URL/api/v1/idps" \
      --header 'accept: application/json, text/plain, */*' \
      --header 'Content-Type: application/json' \
      --header "authorization: Bearer $RUNAI_TOKEN" \
      --data "$IDP_BODY")

    if [ "$HTTP_CODE" = "201" ] || [ "$HTTP_CODE" = "200" ]; then
      echo "✓ OIDC IDP created successfully"
      IDP_OBJECT=$(jq -c '.' /tmp/idp_response.json 2>/dev/null || echo '{}')
    else
      echo "ERROR: Failed to create OIDC IDP (HTTP $HTTP_CODE)"
      cat /tmp/idp_response.json
      exit 1
    fi

  elif [ "$RUNAI_IDP_TYPE" = "SAML" ]; then
    echo "Creating SAML IDP..."

    # Fetch over the public URL so the SSO endpoints inside the metadata are the
    # ones the browser can reach, then send it as a file: the control plane's
    # own metadataXmlUrl fetch is a server-side hop that 504s when authentik is
    # on another cluster.
    XML_METADATA_URL="$AK_PUBLIC_URL/application/saml/$SAML_APP_SLUG/metadata/"
    echo "Fetching SAML metadata from $XML_METADATA_URL ..."
    # That URL 302-redirects to the API download endpoint, so follow redirects
    # rather than reading the empty body of the redirect itself.
    METADATA_XML=$(curl -sSL "$XML_METADATA_URL" || true)

    if ! echo "$METADATA_XML" | grep -q EntityDescriptor; then
      echo "Public metadata URL did not return a descriptor; trying the API endpoint..."
      # Depending on the release this answers with raw XML or with the XML
      # wrapped in a JSON object, so accept either.
      METADATA_RAW=$(curl -sSL "$AK_PUBLIC_URL/api/v3/providers/saml/$SAML_PROVIDER_PK/metadata/" \
        -H "Authorization: Bearer $AK_TOKEN" || true)
      METADATA_XML=$(printf '%s' "$METADATA_RAW" | jq -r '.metadata // empty' 2>/dev/null || true)
      if [ -z "$METADATA_XML" ]; then
        METADATA_XML="$METADATA_RAW"
      fi
    fi

    if [ -z "$METADATA_XML" ] || ! echo "$METADATA_XML" | grep -q EntityDescriptor; then
      echo "ERROR: Failed to fetch SAML metadata from authentik"
      echo "$METADATA_XML" | head -c 500
      echo
      exit 1
    fi

    METADATA_B64=$(printf '%s' "$METADATA_XML" | base64 | tr -d '\n')
    IDP_BODY=$(jq -n --arg b64 "$METADATA_B64" '{
        mappers: {uid: "UID", gid: "GID", groups: "GROUPS",
                  supplementaryGroups: "SUPPLEMENTARYGROUPS", email: "email"},
        type: "saml",
        samlData: {metadataXmlUrl: "", metadataXmlFile: $b64,
                   fileName: "idp-metadata.xml", metadataXmlType: "file"}}')

    HTTP_CODE=$(curl -s -o /tmp/idp_response.json -w "%{http_code}" -X POST "$RUNAI_CTRL_PLANE_URL/api/v1/idps" \
      --header 'accept: application/json, text/plain, */*' \
      --header 'Content-Type: application/json' \
      --header "authorization: Bearer $RUNAI_TOKEN" \
      --data "$IDP_BODY")

    if [ "$HTTP_CODE" = "201" ] || [ "$HTTP_CODE" = "200" ]; then
      echo "✓ SAML IDP created successfully"
      IDP_OBJECT=$(jq -c '.' /tmp/idp_response.json 2>/dev/null || echo '{}')
    else
      echo "ERROR: Failed to create SAML IDP (HTTP $HTTP_CODE)"
      cat /tmp/idp_response.json
      exit 1
    fi

  else
    echo "ERROR: Invalid RUNAI_IDP_TYPE value: '$RUNAI_IDP_TYPE'"
    echo "RUNAI_IDP_TYPE must be either 'OIDC' or 'SAML'"
    exit 1
  fi
fi

# Step 3: Point the authentik provider at the broker endpoint the control plane
# generated. The alias is random (e.g. oidc-78bd78) and cannot be known before
# the IDP exists, which is why the provider is seeded with a placeholder.
echo ""
echo "[3/5] Aligning authentik provider with the IDP broker redirect URI..."

IDP_ALIAS=$(echo "$IDP_OBJECT" | jq -r '.alias // empty')

if [ -z "$IDP_ALIAS" ]; then
  echo "Alias missing from the create response. Reading the IDP back from the control plane..."
  IDP_OBJECT=$(curl -s "$RUNAI_CTRL_PLANE_URL/api/v1/idps" \
    -H "authorization: Bearer $RUNAI_TOKEN" | select_idp)
  IDP_ALIAS=$(echo "$IDP_OBJECT" | jq -r '.alias // empty')
fi

if [ -z "$IDP_ALIAS" ]; then
  echo "ERROR: Could not determine the IDP alias from the control plane"
  echo "$IDP_OBJECT"
  exit 1
fi

REPORTED_REDIRECT_URI=$(echo "$IDP_OBJECT" | jq -r '.redirectUri // empty')
if [ -n "$REPORTED_REDIRECT_URI" ]; then
  IDP_REDIRECT_URI=$(echo "$REPORTED_REDIRECT_URI" | \
    sed "s|/broker/[^/]*/endpoint|/broker/$IDP_ALIAS/endpoint|")
else
  IDP_REDIRECT_URI="$RUNAI_CTRL_PLANE_URL/auth/realms/runai/broker/$IDP_ALIAS/endpoint"
fi

case "$IDP_REDIRECT_URI" in
  *RUNAI_IDP_ALIAS_PLACEHOLDER*)
    echo "ERROR: Failed to resolve the broker redirect URI, alias placeholder still present"
    echo "Resolved URI: $IDP_REDIRECT_URI"
    exit 1
    ;;
esac

echo "IDP alias: $IDP_ALIAS"
echo "Broker redirect URI: $IDP_REDIRECT_URI"

if [ "$RUNAI_IDP_TYPE" = "OIDC" ]; then
  echo "Updating OAuth2 provider $OIDC_PROVIDER_PK ..."
  PATCH_BODY=$(jq -n --arg u "$IDP_REDIRECT_URI" \
    '{redirect_uris: [{matching_mode: "strict", url: $u}]}')
  HTTP_CODE=$(api_code PATCH "/providers/oauth2/$OIDC_PROVIDER_PK/" "$PATCH_BODY")
  if ! ok_code "$HTTP_CODE"; then
    PATCH_BODY=$(jq -n --arg u "$IDP_REDIRECT_URI" '{redirect_uris: $u}')
    HTTP_CODE=$(api_code PATCH "/providers/oauth2/$OIDC_PROVIDER_PK/" "$PATCH_BODY")
  fi
  if ok_code "$HTTP_CODE"; then
    echo "✓ Redirect URI set to the '$IDP_ALIAS' broker endpoint"
  else
    echo "ERROR: Failed to update OAuth2 provider (HTTP $HTTP_CODE)"
    cat "$RESP"
    exit 1
  fi
else
  echo "Updating SAML provider $SAML_PROVIDER_PK ..."
  PATCH_BODY=$(jq -n --arg u "$IDP_REDIRECT_URI" '{acs_url: $u}')
  HTTP_CODE=$(api_code PATCH "/providers/saml/$SAML_PROVIDER_PK/" "$PATCH_BODY")
  if ok_code "$HTTP_CODE"; then
    echo "✓ ACS URL set to the '$IDP_ALIAS' broker endpoint"
  else
    echo "ERROR: Failed to update SAML provider (HTTP $HTTP_CODE)"
    cat "$RESP"
    exit 1
  fi
fi

# Step 4: Create Project
echo ""
echo "[4/5] Creating project 'dev-team'..."

echo "Fetching cluster and department information..."
CLUSTER_DATA=$(curl -s "$RUNAI_CTRL_PLANE_URL/api/v1/org-unit/departments" \
  -H "authorization: Bearer $RUNAI_TOKEN")

CLUSTER_UUID=$(echo "$CLUSTER_DATA" | jq -r '.departments[0].clusterId')
DEPARTMENT_ID=$(echo "$CLUSTER_DATA" | jq -r '.departments[0].id')

if [ -z "$CLUSTER_UUID" ] || [ "$CLUSTER_UUID" = "null" ] || [ -z "$DEPARTMENT_ID" ] || [ "$DEPARTMENT_ID" = "null" ]; then
  echo "ERROR: Failed to get cluster or department information"
  echo "Cluster data: $CLUSTER_DATA"
  exit 1
fi

echo "Cluster UUID: $CLUSTER_UUID"
echo "Department ID: $DEPARTMENT_ID"

echo "Checking if 'dev-team' project already exists..."
EXISTING_PROJECTS=$(curl -s "$RUNAI_CTRL_PLANE_URL/api/v1/org-unit/projects" \
  -H "authorization: Bearer $RUNAI_TOKEN")

if echo "$EXISTING_PROJECTS" | jq -e 'type == "array"' >/dev/null 2>&1; then
  PROJECT_ID=$(echo "$EXISTING_PROJECTS" | jq -r '.[] | select(.name=="dev-team") | .id // empty')
else
  PROJECT_ID=$(echo "$EXISTING_PROJECTS" | jq -r '.projects[]? | select(.name=="dev-team") | .id // empty')
  if [ -z "$PROJECT_ID" ] || [ "$PROJECT_ID" = "null" ]; then
    PROJECT_ID=$(echo "$EXISTING_PROJECTS" | jq -r '.data[]? | select(.name=="dev-team") | .id // empty')
  fi
fi

if [ -n "$PROJECT_ID" ] && [ "$PROJECT_ID" != "null" ]; then
  echo "✓ Project 'dev-team' already exists with ID: $PROJECT_ID"
else
  echo "Project 'dev-team' does not exist. Creating project..."
  PROJECT_DATA=$(curl -s -o /tmp/project_response.json -w "\n%{http_code}" -X POST "$RUNAI_CTRL_PLANE_URL/api/v1/org-unit/projects" \
    -H 'accept: application/json, text/plain, */*' \
    -H "authorization: Bearer $RUNAI_TOKEN" \
    -H 'Content-Type: application/json' \
    --data-raw "{
    \"clusterId\": \"$CLUSTER_UUID\",
    \"parentId\": \"$DEPARTMENT_ID\",
    \"resources\": [
      {
        \"nodePool\": {
          \"name\": \"default\",
          \"id\": \"100000\"
        },
        \"gpu\": {
          \"deserved\": 4,
          \"limit\": -1
        }
      }
    ],
    \"name\": \"dev-team\",
    \"description\": \"\",
    \"schedulingRules\": {
      \"trainingJobTimeLimitSeconds\": null,
      \"interactiveJobTimeLimitSeconds\": null
    }
  }")

  HTTP_CODE=$(echo "$PROJECT_DATA" | tail -n1)
  if [ "$HTTP_CODE" = "201" ] || [ "$HTTP_CODE" = "200" ]; then
    PROJECT_ID=$(jq -r '.id' /tmp/project_response.json)
    echo "✓ Project created successfully with ID: $PROJECT_ID"
  else
    echo "ERROR: Failed to create project (HTTP $HTTP_CODE)"
    cat /tmp/project_response.json
    exit 1
  fi
fi

# Step 5: Create Access Rule
echo ""
echo "[5/5] Creating access rule for 'developer-group'..."

echo "Checking if access rule already exists..."
EXISTING_RULES=$(curl -s "$RUNAI_CTRL_PLANE_URL/api/v1/authorization/access-rules" \
  -H "authorization: Bearer $RUNAI_TOKEN")

RULE_EXISTS=$(echo "$EXISTING_RULES" | jq -r --arg pid "$PROJECT_ID" '
  (if type == "array" then . else (.accessRules // .rules // .data // []) end)
  | map(select(.scopeId == $pid and .subjectId == "developer-group"))
  | (.[0].id // empty)' 2>/dev/null || true)

if [ -n "$RULE_EXISTS" ] && [ "$RULE_EXISTS" != "null" ]; then
  echo "✓ Access rule for 'developer-group' already exists. Skipping."
else
  echo "Creating access rule for 'developer-group'..."
  # roleId 21 is the "AI practitioner" role
  HTTP_CODE=$(curl -s -o /tmp/rule_response.json -w "%{http_code}" -X POST "$RUNAI_CTRL_PLANE_URL/api/v1/authorization/access-rules" \
    -H 'accept: application/json, text/plain, */*' \
    -H "authorization: Bearer $RUNAI_TOKEN" \
    -H 'Content-Type: application/json' \
    --data-raw "{
    \"scopeId\": \"$PROJECT_ID\",
    \"scopeType\": \"project\",
    \"subjectId\": \"developer-group\",
    \"subjectType\": \"group\",
    \"roleId\": 21
  }")

  if [ "$HTTP_CODE" = "201" ] || [ "$HTTP_CODE" = "200" ]; then
    echo "✓ Access rule created successfully"
  else
    echo "ERROR: Failed to create access rule (HTTP $HTTP_CODE)"
    cat /tmp/rule_response.json
    exit 1
  fi
fi

echo ""
echo "======================================"
echo "RUN:AI SETUP COMPLETE"
echo "======================================"

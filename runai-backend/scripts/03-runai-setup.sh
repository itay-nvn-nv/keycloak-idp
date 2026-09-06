#!/bin/sh
set -e

echo "======================================"
echo "RUN:AI SETUP"
echo "======================================"

# The token minted by the previous container has a short lifespan (60s by
# default on the master realm), so re-mint it when admin credentials are
# available instead of reusing the shared one.
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

  KEYCLOAK_TOKEN=$(cat /shared-files/keycloak_token)
}

load_keycloak_token

# Step 1: Authenticate with Run:AI
echo ""
echo "[1/5] Authenticating with Run:AI Control Plane..."
RUNAI_TOKEN=$(curl -s -X POST "$RUNAI_CTRL_PLANE_URL/api/v1/token" \
  --header 'accept: application/json, text/plain, */*' \
  --header 'accept-language: en-US,en;q=0.9' \
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

REALM_NAME=$(jq -r '.realm' /shared-files/realm_updated.json)
IDP_TYPE_LOWER=$(echo "$RUNAI_IDP_TYPE" | tr '[:upper:]' '[:lower:]')
echo "Realm name: $REALM_NAME"
echo "IDP type: $RUNAI_IDP_TYPE"

# Prefer the IDP matching the requested type, falling back to the first one
select_idp() {
  jq -c --arg t "$IDP_TYPE_LOWER" '
    if type == "array" then
      (map(select(.type == $t)) | .[0]) // .[0] // {}
    else
      {}
    end'
}

# Check if IDP already exists
echo "Checking if IDP already exists..."
EXISTING_IDPS=$(curl -s "$RUNAI_CTRL_PLANE_URL/api/v1/idps" \
  -H "authorization: Bearer $RUNAI_TOKEN")
IDP_EXISTS=$(echo "$EXISTING_IDPS" | jq -r 'length')

if [ "$IDP_EXISTS" != "0" ] && [ "$IDP_EXISTS" != "null" ]; then
  echo "✓ IDP already exists. Skipping IDP creation."
  IDP_OBJECT=$(echo "$EXISTING_IDPS" | select_idp)
else
  echo "No IDP found. Creating IDP..."
  
  if [ "$RUNAI_IDP_TYPE" = "OIDC" ]; then
    echo "Creating OIDC IDP..."
    
    # Get OIDC client data
    OIDC_CLIENT_ID=$(jq -r '.clients[0].clientId' /shared-files/realm_updated.json)
    echo "OIDC Client ID: $OIDC_CLIENT_ID"
    
    # Retrieve OIDC client secret from Keycloak
    echo "Retrieving OIDC client secret from Keycloak..."
    CLIENT_INTERNAL_ID=$(curl -s "$KC_HOSTNAME/admin/realms/$REALM_NAME/clients" \
      -H "authorization: Bearer $KEYCLOAK_TOKEN" | \
      jq -r ".[] | select(.clientId==\"$OIDC_CLIENT_ID\") | .id")
    
    if [ -z "$CLIENT_INTERNAL_ID" ] || [ "$CLIENT_INTERNAL_ID" = "null" ]; then
      echo "ERROR: Could not find client with clientId: $OIDC_CLIENT_ID"
      exit 1
    fi
    
    CLIENT_SECRET=$(curl -s "$KC_HOSTNAME/admin/realms/$REALM_NAME/clients/$CLIENT_INTERNAL_ID/client-secret" \
      -H "authorization: Bearer $KEYCLOAK_TOKEN" | \
      jq -r '.value')
    
    if [ -z "$CLIENT_SECRET" ] || [ "$CLIENT_SECRET" = "null" ]; then
      echo "ERROR: Could not retrieve client secret"
      exit 1
    fi
    echo "✓ Retrieved client secret"
    
    DISCOVER_DOCUMENT_URL="$KC_HOSTNAME/realms/$REALM_NAME/.well-known/openid-configuration"
    
    HTTP_CODE=$(curl -s -o /tmp/idp_response.json -w "%{http_code}" -X POST "$RUNAI_CTRL_PLANE_URL/api/v1/idps" \
    --header 'accept: application/json, text/plain, */*' \
    --header 'accept-language: en-US,en;q=0.9' \
    --header 'Content-Type: application/json' \
    --header "authorization: Bearer $RUNAI_TOKEN" \
    --data-raw "{
        \"type\": \"oidc\",
        \"oidcData\": {
            \"discoverDocumentUrl\": \"$DISCOVER_DOCUMENT_URL\",
            \"clientId\": \"$OIDC_CLIENT_ID\",
            \"clientSecret\": \"$CLIENT_SECRET\",
            \"scopes\": [
                \"openid\"
            ],
            \"mandatoryClaim\": null
        },
        \"mappers\": {
            \"uid\": \"UID\",
            \"gid\": \"GID\",
            \"groups\": \"GROUPS\",
            \"supplementaryGroups\": \"SUPPLEMENTARYGROUPS\",
            \"email\": \"email\"
        }
    }")
    
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
    
    ENTITY_ID=$(jq -r '.clients[1].clientId' /shared-files/realm_updated.json)
    echo "Entity ID: $ENTITY_ID"
    XML_METADATA_URL="$KC_HOSTNAME/realms/$REALM_NAME/protocol/saml/descriptor"

    HTTP_CODE=$(curl -s -o /tmp/idp_response.json -w "%{http_code}" -X POST "$RUNAI_CTRL_PLANE_URL/api/v1/idps" \
    --header 'accept: application/json, text/plain, */*' \
    --header 'accept-language: en-US,en;q=0.9' \
    --header 'Content-Type: application/json' \
    --header "authorization: Bearer $RUNAI_TOKEN" \
    --data-raw "{
        \"mappers\": {
            \"uid\": \"UID\",
            \"gid\": \"GID\",
            \"groups\": \"GROUPS\",
            \"supplementaryGroups\": \"SUPPLEMENTARYGROUPS\",
            \"email\": \"email\"},
        \"type\": \"saml\",
        \"samlData\": {
            \"metadataXmlUrl\": \"$XML_METADATA_URL\",
            \"metadataXmlFile\": \"\",
            \"fileName\": \"\",
            \"metadataXmlType\": \"url\"}
    }")
    
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

# Step 3: Align the mock realm client with the broker endpoint of the new IDP.
# The control plane assigns each IDP a random alias (e.g. oidc-78bd78) and
# derives the broker redirect URI from it, so the alias cannot be baked into
# realm.json. The realm still has to be imported first, because creating an
# OIDC IDP requires the realm's client secret and discovery document.
echo ""
echo "[3/5] Aligning Keycloak client with the IDP broker redirect URI..."

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

# The control plane reports the generic broker path (.../broker/oidc/endpoint)
# in redirectUri, but brokers the callback on the alias path
# (.../broker/oidc-78bd78/endpoint), so the alias segment has to be rewritten.
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
  TARGET_CLIENT_ID=$(jq -r '.clients[0].clientId' /shared-files/realm_updated.json)
else
  TARGET_CLIENT_ID=$(jq -r '.clients[1].clientId' /shared-files/realm_updated.json)
fi
echo "Target client: $TARGET_CLIENT_ID"

load_keycloak_token

CLIENT_OBJECT=$(curl -s -G "$KC_HOSTNAME/admin/realms/$REALM_NAME/clients" \
  --data-urlencode "clientId=$TARGET_CLIENT_ID" \
  -H "authorization: Bearer $KEYCLOAK_TOKEN" | \
  jq -c 'if type == "array" then (.[0] // {}) else {} end')

CLIENT_UUID=$(echo "$CLIENT_OBJECT" | jq -r '.id // empty')
if [ -z "$CLIENT_UUID" ]; then
  echo "ERROR: Could not find client '$TARGET_CLIENT_ID' in realm '$REALM_NAME'"
  exit 1
fi

UPDATED_CLIENT=$(echo "$CLIENT_OBJECT" | jq -c --arg uri "$IDP_REDIRECT_URI" '
  .redirectUris = [$uri] |
  if .protocol == "saml" then
    .attributes["saml_single_logout_service_url_post"] = $uri
  else
    .
  end')

if [ "$UPDATED_CLIENT" = "$CLIENT_OBJECT" ]; then
  echo "✓ Client already points at the '$IDP_ALIAS' broker endpoint. Skipping update."
else
  echo "Updating client redirect URI..."
  HTTP_CODE=$(curl -s -o /tmp/client_update_response.json -w "%{http_code}" \
    -X PUT "$KC_HOSTNAME/admin/realms/$REALM_NAME/clients/$CLIENT_UUID" \
    -H 'accept: application/json, text/plain, */*' \
    -H "authorization: Bearer $KEYCLOAK_TOKEN" \
    -H 'Content-Type: application/json' \
    --data "$UPDATED_CLIENT")

  if [ "$HTTP_CODE" = "204" ] || [ "$HTTP_CODE" = "200" ]; then
    echo "✓ Client redirect URI set to the '$IDP_ALIAS' broker endpoint"
  else
    echo "ERROR: Failed to update client '$TARGET_CLIENT_ID' (HTTP $HTTP_CODE)"
    cat /tmp/client_update_response.json
    exit 1
  fi
fi

# Step 4: Create Project
echo ""
echo "[4/5] Creating project 'dev-team'..."

# Get cluster + department ID's
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

# Check if project already exists
echo "Checking if 'dev-team' project already exists..."
EXISTING_PROJECTS=$(curl -s "$RUNAI_CTRL_PLANE_URL/api/v1/org-unit/projects" \
  -H "authorization: Bearer $RUNAI_TOKEN")

# Handle both array and object responses
if echo "$EXISTING_PROJECTS" | jq -e 'type == "array"' >/dev/null 2>&1; then
  PROJECT_ID=$(echo "$EXISTING_PROJECTS" | jq -r '.[] | select(.name=="dev-team") | .id // empty')
else
  # Response might be wrapped in an object like {"projects": [...]}
  PROJECT_ID=$(echo "$EXISTING_PROJECTS" | jq -r '.projects[]? | select(.name=="dev-team") | .id // empty')
  
  # If still empty, try other common patterns
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
    -H 'accept-language: en-US,en;q=0.9' \
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
    PROJECT_ID=$(cat /tmp/project_response.json | jq -r '.id')
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

# Check if access rule already exists
echo "Checking if access rule already exists..."
EXISTING_RULES=$(curl -s "$RUNAI_CTRL_PLANE_URL/api/v1/authorization/access-rules" \
  -H "authorization: Bearer $RUNAI_TOKEN")

# Handle both array and object responses
if echo "$EXISTING_RULES" | jq -e 'type == "array"' >/dev/null 2>&1; then
  RULE_EXISTS=$(echo "$EXISTING_RULES" | jq -r ".[] | select(.scopeId==\"$PROJECT_ID\" and .subjectId==\"developer-group\") | .id // empty")
else
  RULE_EXISTS=$(echo "$EXISTING_RULES" | jq -r ".rules[]? | select(.scopeId==\"$PROJECT_ID\" and .subjectId==\"developer-group\") | .id // empty")
  
  if [ -z "$RULE_EXISTS" ] || [ "$RULE_EXISTS" = "null" ]; then
    RULE_EXISTS=$(echo "$EXISTING_RULES" | jq -r ".data[]? | select(.scopeId==\"$PROJECT_ID\" and .subjectId==\"developer-group\") | .id // empty")
  fi
fi

if [ -n "$RULE_EXISTS" ] && [ "$RULE_EXISTS" != "null" ]; then
  echo "✓ Access rule for 'developer-group' already exists. Skipping."
else
  echo "Creating access rule for 'developer-group'..."
  # roleId 21 is the "AI practitioner" role
  HTTP_CODE=$(curl -s -o /tmp/rule_response.json -w "%{http_code}" -X POST "$RUNAI_CTRL_PLANE_URL/api/v1/authorization/access-rules" \
    -H 'accept: application/json, text/plain, */*' \
    -H 'accept-language: en-US,en;q=0.9' \
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


#!/bin/sh
set -e

echo "======================================"
echo "AUTHENTIK SETUP"
echo "======================================"

# Seeds (and on re-runs, reconciles) the shared realm.json into authentik:
#   groups + users + attributes  ->  /api/v3/core/{groups,users}
#   Keycloak protocol mappers    ->  /api/v3/propertymappings/provider/{scope,saml}
#   Keycloak clients             ->  /api/v3/providers/{oauth2,saml} + /core/applications
#
# Everything is created with plain API calls rather than a blueprint, so the
# objects stay fully editable in the admin UI and nothing re-applies over
# manual changes later.

SEED="${SEED_FILE:-/authentik-seed/realm.json}"
SHARED="${SHARED_DIR:-/shared-files}"
RESP=/tmp/ak_resp.json

AK_API="${AK_HOSTNAME%/}/api/v3"
AK_PUBLIC_URL="${AK_PUBLIC_URL:-$AK_HOSTNAME}"
AK_PUBLIC_URL="${AK_PUBLIC_URL%/}"
AK_BASE_URL="${AK_BASE_URL:-}"
AK_BASE_URL="${AK_BASE_URL%/}"
OIDC_APP_SLUG="${OIDC_APP_SLUG:-runai-oidc}"
SAML_APP_SLUG="${SAML_APP_SLUG:-runai-saml}"
OIDC_CLIENT_ID="${OIDC_CLIENT_ID:-lab-oidc-client}"
RUNAI_SCOPE_NAME="${RUNAI_SCOPE_NAME:-runai}"

if [ -z "$AK_HOSTNAME" ] || [ -z "$AK_TOKEN" ]; then
  echo "ERROR: AK_HOSTNAME and AK_TOKEN are required"
  exit 1
fi

# Providers need an absolute redirect URI even before a real control plane
# exists, which is what the placeholder URL is for.
if [ -z "$RUNAI_CTRL_PLANE_URL" ]; then
  echo "ERROR: RUNAI_CTRL_PLANE_URL is required (use the placeholder URL when no control plane is attached yet)"
  exit 1
fi

if [ ! -f "$SEED" ]; then
  echo "ERROR: seed file not found at $SEED"
  exit 1
fi

mkdir -p "$SHARED"

# ---------------------------------------------------------------- API helpers

api() {
  _method="$1"; _path="$2"; _body="${3:-}"
  if [ -n "$_body" ]; then
    curl -sS -X "$_method" "$AK_API$_path" \
      -H "Authorization: Bearer $AK_TOKEN" \
      -H 'Content-Type: application/json' \
      -H 'Accept: application/json' \
      --data "$_body"
  else
    curl -sS -X "$_method" "$AK_API$_path" \
      -H "Authorization: Bearer $AK_TOKEN" \
      -H 'Accept: application/json'
  fi
}

# Writes the body to $RESP and prints the HTTP status code.
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
      -H "Authorization: Bearer $AK_TOKEN" \
      -H 'Accept: application/json'
  fi
}

ok_code() {
  case "$1" in
    200|201|204) return 0 ;;
    *) return 1 ;;
  esac
}

# Writes to stderr: several callers run inside $(...), where stdout is captured
# into a variable and an error message would otherwise be swallowed.
die_on_code() {
  if ! ok_code "$1"; then
    echo "ERROR: $2 (HTTP $1)" >&2
    cat "$RESP" >&2 2>/dev/null
    echo >&2
    exit 1
  fi
}

# Single-param filtered list; keeps values with spaces safe.
api_find() {
  curl -sS -G "$AK_API$1" \
    --data-urlencode "$2=$3" \
    -H "Authorization: Bearer $AK_TOKEN" \
    -H 'Accept: application/json'
}

# Not every list endpoint exposes a ?name= filter, so match client-side.
find_pk_by_name() {
  curl -sS -G "$AK_API$1" \
    --data-urlencode "page_size=500" \
    -H "Authorization: Bearer $AK_TOKEN" \
    -H 'Accept: application/json' \
    | jq -r --arg n "$2" '[.results[]? | select(.name == $n) | .pk] | first // empty'
}

# ------------------------------------------------------------------ [1] token

echo ""
echo "[1/8] Verifying authentik API token..."
WHOAMI=$(api GET /core/users/me/ || true)
AK_ADMIN=$(echo "$WHOAMI" | jq -r '.user.username // empty')
if [ -z "$AK_ADMIN" ]; then
  echo "ERROR: Could not authenticate against $AK_API with the bootstrap token"
  echo "$WHOAMI" | head -c 500
  echo
  exit 1
fi
echo "Authenticated as '$AK_ADMIN'"

# ----------------------------------------------------------- [2] base URL

echo ""
echo "[2/8] Configuring the instance base URL..."

# AUTHENTIK_WEB__BASE_URL only backfills an empty value at startup, so set it
# here too: that covers instances deployed before the variable was added and
# makes the value follow the hostname when it changes. Scheme and host only --
# authentik appends the web path itself and rejects a URL that carries one.
if [ -n "$AK_BASE_URL" ]; then
  CURRENT_BASE_URL=$(api GET /admin/settings/ | jq -r '.base_url // ""')
  if [ "$CURRENT_BASE_URL" = "$AK_BASE_URL" ]; then
    echo "  = base URL already '$AK_BASE_URL'"
  else
    CODE=$(api_code PATCH /admin/settings/ "$(jq -n --arg u "$AK_BASE_URL" '{base_url: $u}')")
    die_on_code "$CODE" "Failed to set the base URL"
    echo "  + base URL set to '$AK_BASE_URL'"
  fi
else
  echo "  ! AK_BASE_URL not provided; leaving the base URL unset"
fi

# ------------------------------------------------------- [3] flows + signing

echo ""
echo "[3/8] Resolving default flows and signing certificate..."

flow_pk() {
  api_find /flows/instances/ slug "$1" | jq -r '.results[0].pk // empty'
}

# The default flows and certificate come from blueprints that the worker applies
# shortly after it reports ready, so on a fresh install they can lag the server's
# health check by a minute or two.
echo "Waiting for the default blueprints to be applied..."
AUTH_FLOW=""
waited=0
while [ "$waited" -lt 300 ]; do
  AUTH_FLOW=$(flow_pk default-provider-authorization-implicit-consent)
  if [ -z "$AUTH_FLOW" ]; then
    AUTH_FLOW=$(flow_pk default-provider-authorization-explicit-consent)
  fi
  if [ -n "$AUTH_FLOW" ]; then
    break
  fi
  sleep 5
  waited=$((waited + 5))
done
if [ -z "$AUTH_FLOW" ]; then
  echo "ERROR: No default provider authorization flow found after ${waited}s"
  echo "Check the authentik worker logs for blueprint errors."
  exit 1
fi

# Providers gained a required invalidation_flow in recent releases; older
# installs only ship the generic default-invalidation-flow.
INVALIDATION_FLOW=$(flow_pk default-provider-invalidation-flow)
if [ -z "$INVALIDATION_FLOW" ]; then
  INVALIDATION_FLOW=$(flow_pk default-invalidation-flow)
fi

SIGNING_KP=""
waited=0
while [ "$waited" -lt 120 ]; do
  SIGNING_KP=$(api GET "/crypto/certificatekeypairs/?has_key=true" | jq -r '.results[0].pk // empty')
  if [ -n "$SIGNING_KP" ]; then
    break
  fi
  sleep 5
  waited=$((waited + 5))
done
if [ -z "$SIGNING_KP" ]; then
  echo "ERROR: No certificate keypair available to sign tokens/assertions"
  exit 1
fi

echo "Authorization flow: $AUTH_FLOW"
echo "Invalidation flow:  ${INVALIDATION_FLOW:-<none>}"
echo "Signing keypair:    $SIGNING_KP"

# ----------------------------------------------------------------- [3] groups

echo ""
echo "[4/8] Creating groups from $SEED ..."

: > /tmp/groups.map
jq -r '.groups[]?.name' "$SEED" > /tmp/group_names

while IFS= read -r gname; do
  [ -n "$gname" ] || continue
  ggid=$(jq -r --arg n "$gname" '
    .groups[] | select(.name == $n)
    | (.attributes.GID // empty)
    | if type == "array" then .[0] else . end // ""' "$SEED")

  gpk=$(api_find /core/groups/ name "$gname" | jq -r '.results[0].pk // empty')
  if [ -n "$gpk" ]; then
    echo "  = group '$gname' already exists"
  else
    payload=$(jq -n --arg name "$gname" --arg gid "$ggid" \
      '{name: $name, is_superuser: false,
        attributes: (if $gid == "" then {} else {GID: $gid} end)}')
    code=$(api_code POST /core/groups/ "$payload")
    die_on_code "$code" "Failed to create group '$gname'"
    gpk=$(jq -r '.pk' "$RESP")
    echo "  + group '$gname' (GID ${ggid:-none})"
  fi
  printf '%s\t%s\n' "$gname" "$gpk" >> /tmp/groups.map
done < /tmp/group_names

# ------------------------------------------------------------------ [4] users

echo ""
echo "[5/8] Creating users from $SEED ..."

jq -r '.users[]?.username' "$SEED" > /tmp/user_names

while IFS= read -r uname; do
  [ -n "$uname" ] || continue
  u=$(jq -c --arg n "$uname" '.users[] | select(.username == $n)' "$SEED")

  uemail=$(echo "$u" | jq -r '.email // ""')
  ufull=$(echo "$u" | jq -r '[.firstName, .lastName] | map(select(. != null and . != "")) | join(" ")')
  uuid_attr=$(echo "$u" | jq -r '.attributes.UID // ""')
  ugid_attr=$(echo "$u" | jq -r '.attributes.GID // ""')
  upass=$(echo "$u" | jq -r '.credentials[0].value // ""')

  group_pks='[]'
  echo "$u" | jq -r '.groups[]?' > /tmp/user_groups
  while IFS= read -r gname; do
    [ -n "$gname" ] || continue
    gpk=$(awk -F'\t' -v n="$gname" '$1 == n {print $2}' /tmp/groups.map)
    if [ -n "$gpk" ]; then
      group_pks=$(echo "$group_pks" | jq -c --arg p "$gpk" '. + [$p]')
    else
      echo "  ! group '$gname' for user '$uname' was not created; skipping membership"
    fi
  done < /tmp/user_groups

  upk=$(api_find /core/users/ username "$uname" | jq -r '.results[0].pk // empty')
  if [ -n "$upk" ]; then
    echo "  = user '$uname' already exists"
    continue
  fi

  payload=$(jq -n \
    --arg username "$uname" \
    --arg name "$ufull" \
    --arg email "$uemail" \
    --arg uid "$uuid_attr" \
    --arg gid "$ugid_attr" \
    --argjson groups "$group_pks" \
    '{username: $username, name: $name, email: $email, is_active: true,
      path: "users", type: "internal", groups: $groups,
      attributes: {UID: $uid, GID: $gid}}')
  code=$(api_code POST /core/users/ "$payload")
  die_on_code "$code" "Failed to create user '$uname'"
  upk=$(jq -r '.pk' "$RESP")

  if [ -n "$upass" ]; then
    pwpayload=$(jq -n --arg p "$upass" '{password: $p}')
    code=$(api_code POST "/core/users/$upk/set_password/" "$pwpayload")
    die_on_code "$code" "Failed to set password for '$uname'"
  fi
  echo "  + user '$uname' (UID ${uuid_attr:-none}, GID ${ugid_attr:-none})"
done < /tmp/user_names

# -------------------------------------------------------- [5] property maps

echo ""
echo "[6/8] Creating property mappings (Keycloak protocol mapper equivalents)..."

# One scope mapping carries every claim Run:AI maps, so the control plane only
# has to request a single extra scope on top of openid.
RUNAI_CLAIMS_EXPR='groups = [group.name for group in user.ak_groups.all()]
supplementary = [
    int(group.attributes.get("GID"))
    for group in user.ak_groups.all()
    if str(group.attributes.get("GID", "")).isdigit()
]
return {
    "UID": user.attributes.get("UID"),
    "GID": user.attributes.get("GID"),
    "GROUPS": groups,
    "SUPPLEMENTARYGROUPS": supplementary,
    "email": user.email,
}'

ensure_scope_mapping() {
  _name="$1"; _scope="$2"; _expr="$3"; _desc="$4"
  _pk=$(find_pk_by_name /propertymappings/provider/scope/ "$_name")
  if [ -n "$_pk" ]; then
    echo "  = scope mapping '$_name'" >&2
    echo "$_pk"
    return 0
  fi
  _payload=$(jq -n --arg n "$_name" --arg s "$_scope" --arg e "$_expr" --arg d "$_desc" \
    '{name: $n, scope_name: $s, expression: $e, description: $d}')
  _code=$(api_code POST /propertymappings/provider/scope/ "$_payload")
  die_on_code "$_code" "Failed to create scope mapping '$_name'"
  echo "  + scope mapping '$_name' (scope '$_scope')" >&2
  jq -r '.pk' "$RESP"
}

ensure_saml_mapping() {
  _name="$1"; _saml_name="$2"; _friendly="$3"; _expr="$4"
  _pk=$(find_pk_by_name /propertymappings/provider/saml/ "$_name")
  if [ -n "$_pk" ]; then
    echo "  = SAML mapping '$_name'" >&2
    echo "$_pk"
    return 0
  fi
  _payload=$(jq -n --arg n "$_name" --arg s "$_saml_name" --arg f "$_friendly" --arg e "$_expr" \
    '{name: $n, saml_name: $s, friendly_name: $f, expression: $e}')
  _code=$(api_code POST /propertymappings/provider/saml/ "$_payload")
  die_on_code "$_code" "Failed to create SAML mapping '$_name'"
  echo "  + SAML mapping '$_name' (attribute '$_saml_name')" >&2
  jq -r '.pk' "$RESP"
}

RUNAI_SCOPE_PK=$(ensure_scope_mapping \
  "Run:AI Claims" "$RUNAI_SCOPE_NAME" "$RUNAI_CLAIMS_EXPR" \
  "UID / GID / GROUPS / SUPPLEMENTARYGROUPS / email for the Run:AI control plane")

# authentik's shipped openid/email/profile mappings keep the ID token looking
# like a conventional OIDC token alongside the Run:AI claims.
default_scope_pk() {
  curl -sS -G "$AK_API/propertymappings/provider/scope/" \
    --data-urlencode "page_size=500" \
    -H "Authorization: Bearer $AK_TOKEN" -H 'Accept: application/json' \
    | jq -r --arg s "$1" '[.results[]? | select(.scope_name == $s and (.managed // "") != "") | .pk] | first // empty'
}

OIDC_MAPPINGS=$(jq -n --arg p "$RUNAI_SCOPE_PK" '[$p]')
for scope in openid email profile; do
  pk=$(default_scope_pk "$scope")
  if [ -n "$pk" ]; then
    OIDC_MAPPINGS=$(echo "$OIDC_MAPPINGS" | jq -c --arg p "$pk" '. + [$p]')
  fi
done

SAML_UID_PK=$(ensure_saml_mapping "Run:AI UID" "UID" "User ID" \
  'return user.attributes.get("UID")')
SAML_GID_PK=$(ensure_saml_mapping "Run:AI GID" "GID" "Group ID" \
  'return user.attributes.get("GID")')
SAML_GROUPS_PK=$(ensure_saml_mapping "Run:AI GROUPS" "GROUPS" "Groups" \
  'return [group.name for group in user.ak_groups.all()]')
SAML_NAMEID_PK=$(ensure_saml_mapping "Run:AI NameID (email)" "email" "Email" \
  'return user.email')

SAML_MAPPINGS=$(jq -n --arg a "$SAML_UID_PK" --arg b "$SAML_GID_PK" --arg c "$SAML_GROUPS_PK" \
  '[$a, $b, $c]')

# -------------------------------------------------------------- [6] providers

echo ""
echo "[7/8] Creating OIDC and SAML providers..."

RUNAI_URL="${RUNAI_CTRL_PLANE_URL%/}"
# RUNAI_IDP_ALIAS_PLACEHOLDER is intentionally left in place: the control plane
# generates the alias when the IDP is created, so 03-runai-setup.sh rewrites it.
BROKER_URI="$RUNAI_URL/auth/realms/runai/broker/RUNAI_IDP_ALIAS_PLACEHOLDER/endpoint"
CLEAN_URL="${RUNAI_URL#*://}"
SAML_SP_ENTITY_ID="runai-$CLEAN_URL/runai"

echo "Control plane:   $RUNAI_URL"
echo "Broker endpoint: $BROKER_URI"
echo "SAML entity id:  $SAML_SP_ENTITY_ID"

# 03-runai-setup.sh swaps the placeholder for the alias the control plane
# generates. A URI that already carries a real alias for this control plane is
# therefore newer than anything this script can work out, and resetting it to
# the placeholder would break a working integration on a re-run.
has_resolved_alias() {
  case "$1" in
    "$RUNAI_URL/auth/realms/runai/broker/RUNAI_IDP_ALIAS_PLACEHOLDER/endpoint") return 1 ;;
    "$RUNAI_URL/auth/realms/runai/broker/"*"/endpoint") return 0 ;;
    *) return 1 ;;
  esac
}

# grant_types defaults to an empty list on the model, and an empty list rejects
# every grant with "invalid_request". The admin UI fills in a default, so this
# only bites providers created through the API.
OIDC_GRANT_TYPES='["authorization_code","refresh_token"]'

OIDC_PROVIDER_PK=$(find_pk_by_name /providers/oauth2/ "Run:AI OIDC")
if [ -n "$OIDC_PROVIDER_PK" ]; then
  EXISTING=$(api GET "/providers/oauth2/$OIDC_PROVIDER_PK/")
  CURRENT_URI=$(echo "$EXISTING" \
    | jq -r 'if (.redirect_uris | type) == "array"
             then (.redirect_uris[0].url // "")
             else ((.redirect_uris // "") | split("\n")[0]) end')

  patch='{}'
  if has_resolved_alias "$CURRENT_URI"; then
    echo "  = OAuth2 provider 'Run:AI OIDC' keeps its resolved redirect URI"
  else
    echo "  = OAuth2 provider 'Run:AI OIDC' exists; reconciling redirect URI"
    patch=$(echo "$patch" | jq -c --arg u "$BROKER_URI" \
      '.redirect_uris = [{matching_mode: "strict", url: $u}]')
  fi
  if [ "$(echo "$EXISTING" | jq -c '.grant_types // []')" = "[]" ]; then
    echo "  + enabling grant types on 'Run:AI OIDC'"
    patch=$(echo "$patch" | jq -c --argjson g "$OIDC_GRANT_TYPES" '.grant_types = $g')
  fi

  if [ "$patch" != "{}" ]; then
    code=$(api_code PATCH "/providers/oauth2/$OIDC_PROVIDER_PK/" "$patch")
    if ! ok_code "$code"; then
      # Releases before 2024.8 stored redirect URIs as a newline-separated string.
      patch=$(echo "$patch" | jq -c --arg u "$BROKER_URI" \
        'if has("redirect_uris") then .redirect_uris = $u else . end')
      code=$(api_code PATCH "/providers/oauth2/$OIDC_PROVIDER_PK/" "$patch")
      die_on_code "$code" "Failed to update OAuth2 provider"
    fi
  fi
else
  payload=$(jq -n \
    --arg af "$AUTH_FLOW" --arg inf "$INVALIDATION_FLOW" \
    --arg cid "$OIDC_CLIENT_ID" --arg uri "$BROKER_URI" --arg kp "$SIGNING_KP" \
    --argjson maps "$OIDC_MAPPINGS" \
    --argjson grants "$OIDC_GRANT_TYPES" \
    '{name: "Run:AI OIDC",
      authorization_flow: $af,
      client_type: "confidential",
      client_id: $cid,
      grant_types: $grants,
      redirect_uris: [{matching_mode: "strict", url: $uri}],
      property_mappings: $maps,
      signing_key: $kp,
      include_claims_in_id_token: true,
      issuer_mode: "per_provider",
      sub_mode: "user_email"}
     | if $inf == "" then . else . + {invalidation_flow: $inf} end')
  code=$(api_code POST /providers/oauth2/ "$payload")
  if ! ok_code "$code" && grep -q redirect_uris "$RESP" 2>/dev/null; then
    payload=$(echo "$payload" | jq -c --arg u "$BROKER_URI" '.redirect_uris = $u')
    code=$(api_code POST /providers/oauth2/ "$payload")
  fi
  die_on_code "$code" "Failed to create OAuth2 provider"
  OIDC_PROVIDER_PK=$(jq -r '.pk' "$RESP")
  echo "  + OAuth2 provider 'Run:AI OIDC' (pk $OIDC_PROVIDER_PK)"
fi

SAML_PROVIDER_PK=$(find_pk_by_name /providers/saml/ "Run:AI SAML")
if [ -n "$SAML_PROVIDER_PK" ]; then
  CURRENT_ACS=$(api GET "/providers/saml/$SAML_PROVIDER_PK/" | jq -r '.acs_url // ""')
  if has_resolved_alias "$CURRENT_ACS"; then
    echo "  = SAML provider 'Run:AI SAML' keeps its resolved ACS URL"
    patch=$(jq -n --arg aud "$SAML_SP_ENTITY_ID" '{audience: $aud}')
  else
    echo "  = SAML provider 'Run:AI SAML' exists; reconciling ACS URL and audience"
    patch=$(jq -n --arg acs "$BROKER_URI" --arg aud "$SAML_SP_ENTITY_ID" \
      '{acs_url: $acs, audience: $aud}')
  fi
  code=$(api_code PATCH "/providers/saml/$SAML_PROVIDER_PK/" "$patch")
  die_on_code "$code" "Failed to update SAML provider"
else
  payload=$(jq -n \
    --arg af "$AUTH_FLOW" --arg inf "$INVALIDATION_FLOW" \
    --arg acs "$BROKER_URI" --arg aud "$SAML_SP_ENTITY_ID" \
    --arg iss "$AK_PUBLIC_URL/application/saml/$SAML_APP_SLUG/" \
    --arg kp "$SIGNING_KP" --arg nameid "$SAML_NAMEID_PK" \
    --argjson maps "$SAML_MAPPINGS" \
    '{name: "Run:AI SAML",
      authorization_flow: $af,
      acs_url: $acs,
      audience: $aud,
      issuer: $iss,
      sp_binding: "post",
      name_id_mapping: $nameid,
      property_mappings: $maps,
      signing_kp: $kp,
      sign_assertion: true,
      sign_response: false,
      signature_algorithm: "http://www.w3.org/2001/04/xmldsig-more#rsa-sha256",
      digest_algorithm: "http://www.w3.org/2001/04/xmlenc#sha256"}
     | if $inf == "" then . else . + {invalidation_flow: $inf} end')
  code=$(api_code POST /providers/saml/ "$payload")
  die_on_code "$code" "Failed to create SAML provider"
  SAML_PROVIDER_PK=$(jq -r '.pk' "$RESP")
  echo "  + SAML provider 'Run:AI SAML' (pk $SAML_PROVIDER_PK)"
fi

# ----------------------------------------------------------- [7] applications

echo ""
echo "[8/8] Creating applications..."

ensure_application() {
  _slug="$1"; _name="$2"; _provider="$3"
  _existing=$(api_find /core/applications/ slug "$_slug" | jq -r '.results[0].slug // empty')
  if [ -n "$_existing" ]; then
    _patch=$(jq -n --argjson p "$_provider" '{provider: $p}')
    _code=$(api_code PATCH "/core/applications/$_slug/" "$_patch")
    die_on_code "$_code" "Failed to update application '$_slug'"
    echo "  = application '$_slug'"
  else
    _payload=$(jq -n --arg s "$_slug" --arg n "$_name" --argjson p "$_provider" \
      '{slug: $s, name: $n, provider: $p}')
    _code=$(api_code POST /core/applications/ "$_payload")
    die_on_code "$_code" "Failed to create application '$_slug'"
    echo "  + application '$_slug'"
  fi
}

ensure_application "$OIDC_APP_SLUG" "Run:AI (OIDC)" "$OIDC_PROVIDER_PK"
ensure_application "$SAML_APP_SLUG" "Run:AI (SAML)" "$SAML_PROVIDER_PK"

# --------------------------------------------------------------- handoff file

OIDC_CLIENT_SECRET=$(api GET "/providers/oauth2/$OIDC_PROVIDER_PK/" | jq -r '.client_secret // empty')

jq -n \
  --arg public_url "$AK_PUBLIC_URL" \
  --arg oidc_pk "$OIDC_PROVIDER_PK" \
  --arg saml_pk "$SAML_PROVIDER_PK" \
  --arg oidc_slug "$OIDC_APP_SLUG" \
  --arg saml_slug "$SAML_APP_SLUG" \
  --arg client_id "$OIDC_CLIENT_ID" \
  --arg client_secret "$OIDC_CLIENT_SECRET" \
  --arg scope "$RUNAI_SCOPE_NAME" \
  --arg entity_id "$SAML_SP_ENTITY_ID" \
  '{public_url: $public_url,
    oidc: {provider_pk: $oidc_pk, app_slug: $oidc_slug,
           client_id: $client_id, client_secret: $client_secret, scope: $scope},
    saml: {provider_pk: $saml_pk, app_slug: $saml_slug, entity_id: $entity_id}}' \
  > "$SHARED/authentik_objects.json"

echo ""
echo "Wrote $SHARED/authentik_objects.json"
echo ""
echo "======================================"
echo "AUTHENTIK SETUP COMPLETE"
echo "======================================"

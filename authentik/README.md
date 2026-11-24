# Standalone authentik

Isolated [authentik](https://goauthentik.io) on an empty Kubernetes cluster, as a drop-in alternative to the standalone Keycloak path. It can run forever as its own IDP. Attaching a Run:AI control plane is a separate, optional step.

This path does **not** modify `../standalone` or `../runai-backend`. It reuses the shared [`../realm.json`](../realm.json) for users and groups; only the client/provider plumbing is authentik-specific.

Pick this over `../standalone` when you want one admin UI for users, groups, providers, and claim mappings, and you don't need Keycloak specifically. Pick `../standalone` when you want to match the Keycloak that Run:AI itself ships.

## What you get

1. **`deploy.sh`** — Helm release `authentik` (server + worker + PostgreSQL, fronted by an Ingress, a Gateway API HTTPRoute, or a LoadBalancer), a bootstrap admin with an API token, and the shared realm seeded with **placeholder** control-plane URLs.
2. **`integrate.sh`** *(optional)* — given a Run:AI control plane URL, reconcile the providers, create the IDP connector, sample project `dev-team`, and the developer-group access rule.

Both an OIDC and a SAML provider are created, sitting side by side over the same user base. Only one is attached to Run:AI at a time; `RUNAI_IDP_TYPE` picks which.

Placeholder URLs are required at deploy time because the real control plane URL and the IDP alias are not known yet. The seed uses:

```
https://runai-ctrl-plane.placeholder.invalid/auth/realms/runai/broker/RUNAI_IDP_ALIAS_PLACEHOLDER/endpoint
```

Integrate replaces the host with the real URL, then `03-runai-setup.sh` fills in the alias the control plane generates.

## Prerequisites

- `kubectl` pointed at the **authentik** cluster
- `helm` 3
- `jq`
- `openssl` (only for the self-signed TLS option)
- An Ingress controller, a Gateway API gateway, **or** a cloud LoadBalancer (detected automatically; see [Exposure](#exposure))
- A StorageClass for PostgreSQL (persistence is disabled if none exists)
- Outbound access from that cluster to the Run:AI control plane **only when you run integrate**
- The Run:AI control plane must be able to reach the authentik public URL (OIDC discovery / SAML metadata)

## 1) Deploy authentik

```bash
./authentik/deploy.sh
```

You will be asked for a hostname (for example `authentik.example.com`). DNS or `/etc/hosts` must resolve it to the Ingress / LoadBalancer.

Non-interactive example:

```bash
AUTHENTIK_HOSTNAME=authentik.example.com \
AUTHENTIK_TLS_SECRET=my-tls \
INGRESS_CLASS=nginx \
./authentik/deploy.sh
```

Useful environment variables:

| Variable | Meaning |
|--|--|
| `AUTHENTIK_HOSTNAME` | Public hostname (required in non-interactive mode) |
| `AUTHENTIK_NAMESPACE` | Namespace (default `authentik`) |
| `AUTHENTIK_ADMIN_EMAIL` | Bootstrap admin email (default `admin@acme.zzz`) |
| `AUTHENTIK_ADMIN_PASSWORD` | Bootstrap admin password (default: generated) |
| `AUTHENTIK_BOOTSTRAP_TOKEN` | API token used by the scripts (default: generated) |
| `AUTHENTIK_TLS_SECRET` | Existing `kubernetes.io/tls` secret |
| `AUTHENTIK_TLS_SECRET_NAMESPACE` | Copy that secret from another namespace |
| `AUTHENTIK_TLS_MODE` | `existing`, `selfsigned`, or `none` |
| `AUTHENTIK_SKIP_TLS` | Set to skip TLS (HTTP) |
| `EXPOSE_MODE` | `ingress`, `gateway`, or `loadbalancer` (default: detected) |
| `INGRESS_CLASS` | IngressClass name (default: detected) |
| `GATEWAY_NAME` | Gateway to attach the HTTPRoute to (default: detected when unambiguous) |
| `GATEWAY_NAMESPACE` | Namespace of that gateway |
| `AUTHENTIK_URL_PATH` | Serve authentik under a path prefix instead of at the root |
| `AUTHENTIK_STORAGE_CLASS` | PostgreSQL PVC class |
| `AUTHENTIK_USE_EMPTYDIR` | Disable the PostgreSQL PVC |
| `AUTHENTIK_CHART_REPO` | Chart repo (default `https://charts.goauthentik.io`) |
| `AUTHENTIK_CHART_VERSION` | Chart version (default `2026.8.6`) |
| `AUTHENTIK_HELM_RELEASE` | Helm release name (default `authentik`) |
| `OIDC_CLIENT_ID` | OAuth2 client id (default `lab-oidc-client`) |
| `RUNAI_SCOPE_NAME` | Scope carrying the Run:AI claims (default `runai`) |
| `AUTHENTIK_FORCE` | Skip confirmation prompts where applicable |

The admin password and API token are generated on first deploy and **reused** on subsequent runs, because PostgreSQL keeps the password it was initialised with and changing `secret_key` invalidates sessions. Read them back with:

```bash
kubectl -n authentik get secret authentik-admin \
  -o jsonpath='{.data.AUTHENTIK_BOOTSTRAP_PASSWORD}' | base64 -d
```

TLS:

- Prefer a real certificate the remote Run:AI control plane will trust.
- Self-signed is generated locally with `openssl` and stored as a TLS secret. Unlike the Bitnami Keycloak chart, the authentik chart has no self-signed helper. OIDC/SAML from Run:AI will fail until that certificate is trusted on the control plane.
- LoadBalancer mode is HTTP only (no Ingress terminator).

When it finishes, authentik is up with users, groups, mappings, and both providers, and **no** Run:AI connection. Admin console: `https://<hostname>/if/admin/` (`akadmin` / generated password).

## Exposure

How traffic reaches authentik is worked out from the cluster, so `EXPOSE_MODE` is usually unnecessary:

| What the cluster has | What you get |
|--|--|
| An IngressClass and no gateway | `ingress` — the chart's Ingress |
| A Gateway API gateway and no IngressClass | `gateway` — an HTTPRoute attached to that gateway |
| Both | You are asked; non-interactive runs take `ingress` |
| Neither | `loadbalancer` (HTTP only) |

Setting `EXPOSE_MODE` explicitly always wins. The detection treats "a gateway and no IngressClass at all" as the gateway signal because a cluster can keep IngressClass-less leftover Ingress objects from a controller that no longer exists, and those would otherwise look like a working ingress.

In gateway mode the gateway is found automatically when the cluster has exactly one; otherwise set `GATEWAY_NAME` and `GATEWAY_NAMESPACE`. The gateway terminates TLS with its own certificate, so no TLS secret is created. Deploy warns if no listener sets `allowedRoutes` to accept routes from other namespaces, since the HTTPRoute lives in the authentik namespace and would be rejected.

### Sharing a hostname with the control plane

If the only publicly trusted certificate belongs to the control-plane hostname, authentik can live under a path on it instead of getting its own subdomain:

```bash
AUTHENTIK_HOSTNAME=runai.example.com \
AUTHENTIK_URL_PATH=/authentik \
./authentik/deploy.sh
```

That sets `AUTHENTIK_WEB__PATH`, so authentik expects the prefix on **every** request including in-cluster health checks, and the HTTPRoute matches the prefix ahead of the control plane's catch-all `/` route. The instance base URL stays scheme-and-host only — authentik appends the path itself and rejects a base URL that carries one.

## 2) Optional: integrate a remote Run:AI control plane

Run this against the **same kube context** as deploy (so the script can read the API token). Integration runs **on this machine** by default, because it must reach both the authentik URL and the Run:AI control plane. Kind / env-in-a-click clusters often cannot open TCP to a different Run:AI ELB.

```bash
./authentik/integrate.sh
```

Non-interactive:

```bash
RUNAI_CTRL_PLANE_URL=https://runai.example.com \
RUNAI_IDP_TYPE=OIDC \
./authentik/integrate.sh
```

Control-plane login defaults to `test@run.ai` / `Abcd!234` (override with `RUNAI_ADMIN_USERNAME` / `RUNAI_ADMIN_PASSWORD`). `RUNAI_IDP_TYPE` is `OIDC` or `SAML`.

Run:AI serves one IDP at a time. Switching protocol means removing the current one first, otherwise integrate stops rather than wiring the provider to the other protocol's broker alias:

```bash
./authentik/cleanup.sh --integration-only
RUNAI_IDP_TYPE=SAML ./authentik/integrate.sh
```

To run the in-cluster Job instead (only if that cluster can egress to the control plane):

```bash
INTEGRATE_MODE=in-cluster ./authentik/integrate.sh
```

The job:

1. Checks authentik and Run:AI are reachable
2. Re-runs `02-authentik-setup.sh`, which is create-or-reconcile: existing objects get their redirect URI / ACS URL / audience rewritten to the real control plane URL
3. Reuses `03-runai-setup.sh` to create the IDP, rewrite the provider redirect URI with the generated alias, and create project `dev-team` + the developer-group rule

## How this maps to the Keycloak install

| Keycloak | authentik | Where in the UI |
|--|--|--|
| Realm `mock-idp` | *(no equivalent)* — one flat instance | — |
| Client | Application + Provider (split in two) | Applications → Applications / Providers |
| Protocol mapper | Property Mapping | Customisation → Property Mappings |
| User attributes `UID` / `GID` | Attributes (YAML on the user) | Directory → Users → Attributes |
| Group attribute `GID` | Attributes on the group | Directory → Groups |
| Authentication flows | Flows & Stages | Flows & Stages |
| Admin REST API | `/api/v3` | System → API Browser |

Objects are created with plain API calls rather than a blueprint, so everything stays editable in the admin UI and nothing re-applies over manual changes. Re-running `deploy.sh` or `integrate.sh` only touches the control-plane URLs; it will not revert users, groups, or mappings you edited by hand.

### Claims

All Run:AI claims come from a single scope mapping named **Run:AI Claims** bound to the `runai` scope:

| Claim | Source |
|--|--|
| `UID` | `user.attributes.UID` |
| `GID` | `user.attributes.GID` |
| `GROUPS` | names of the user's groups |
| `SUPPLEMENTARYGROUPS` | `GID` attribute of each of the user's groups |
| `email` | `user.email` |

Because the mapping lives on a custom scope, `integrate.sh` asks the control plane for `openid profile email runai`. If you rename the scope, set `RUNAI_SCOPE_NAME` so both sides agree.

`SUPPLEMENTARYGROUPS` has no Keycloak equivalent in `realm.json` — the Keycloak path tells Run:AI to read that claim but never emits it. Here it is populated. Delete the line from the mapping expression in the UI if you want byte-for-byte parity with Keycloak.

## Cleanup

Remove Run:AI objects only (authentik stays):

```bash
./authentik/cleanup.sh --integration-only
```

That deletes every IDP registered on the control plane, the `dev-team` project, and its access rules, then resets the stored control-plane URL to the placeholder. Provider redirect URIs are left pointing at the old alias; the next integrate rewrites them.

Destroy the Helm release and namespace (and Run:AI objects if integrated):

```bash
./authentik/cleanup.sh
```

In gateway mode the HTTPRoute is deleted before the namespace, so the gateway stops advertising the hostname immediately instead of answering for a backend that is shutting down. Nothing is created outside the namespace apart from that route, so there is nothing else to collect.

Type `yes` to confirm, or set `AUTHENTIK_FORCE=1`.

## Differences worth knowing

- **No realms.** Users, groups, and providers are global to the instance. For a single IDP with a single user base this costs nothing; for several isolated mock IDPs, deploy more than one release.
- **The admin is an instance superuser.** There is no realm-scoped admin, so `akadmin` has full control. The password is generated rather than `admin`/`admin` for that reason.
- **Two deployments, not one.** A worker pod runs alongside the server; it owns background tasks. Recent authentik versions no longer need Redis, so the datastore is PostgreSQL alone.
- **Run:AI's docs assume Keycloak.** Anything you escalate to Run:AI support about SSO will be answered in Keycloak terms.

## Layout

```
authentik/
  deploy.sh           # helm upgrade --install + seed job
  integrate.sh
  cleanup.sh
  lib.sh
  manifests/          # seed / integrate Jobs, HTTPRoute
  scripts/            # health checks, API seeding, Run:AI setup
```

Shared with the Keycloak paths:

- `../realm.json` (users and groups only)

The Run:AI-side logic in `scripts/03-runai-setup.sh` (alias resolution, project, access rule) is a deliberate copy of `../runai-backend/scripts/03-runai-setup.sh` rather than a shared file, so this path can change without touching the Keycloak installs. Keep them in sync if the Run:AI API changes.

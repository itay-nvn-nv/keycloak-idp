# keycloak-idp

Turnkey IDP for Run:AI. Three install paths share one set of users and groups:

| Option | When to use | Entry point |
|--|--|--|
| **Run:AI bundled Keycloak** | Keycloak is already running in `runai-backend` on the same cluster as the control plane | [`runai-backend/setup.sh`](runai-backend/setup.sh) |
| **Standalone Keycloak** | Empty cluster, or an IDP that must stay isolated and attach later to a remote control plane | [`standalone/deploy.sh`](standalone/deploy.sh) then optional [`standalone/integrate.sh`](standalone/integrate.sh) |
| **Standalone authentik** | Same as above, but you want one admin UI for users, groups, providers, and claim mappings instead of Keycloak | [`authentik/deploy.sh`](authentik/deploy.sh) then optional [`authentik/integrate.sh`](authentik/integrate.sh) |

[`realm.json`](realm.json) is shared. Do not duplicate it. The Keycloak paths import it as a realm; the authentik path reads its users and groups and creates the equivalent providers and property mappings.

The bundled path is unchanged: it still talks to the in-cluster Keycloak in `runai-backend`, imports the realm, creates the Run:AI IDP, and sets up the sample project. It now lives in `runai-backend/` so it is not mixed with the standalone flow.

---

## Option 1 — Run:AI bundled Keycloak

Uses the Keycloak instance that ships with Run:AI.

```bash
./runai-backend/setup.sh
```

Details, cleanup, and architecture: [`runai-backend/README.md`](runai-backend/README.md).

---

## Option 2 — Standalone Keycloak

Creates an isolated Keycloak with the Bitnami Helm chart (Postgres included) on the current cluster, imports the realm with **placeholder** Run:AI URLs, and stops there. A second, optional script attaches a remote control plane when you have its URL.

```bash
./standalone/deploy.sh
# later, from a cluster that can reach both Keycloak and Run:AI:
./standalone/integrate.sh
```

Details, env vars, TLS, and cleanup: [`standalone/README.md`](standalone/README.md).

---

## Option 3 — Standalone authentik

A Keycloak-free alternative with the same end result: an isolated IDP on the current cluster that exposes both an OIDC and a SAML provider over one user base, and attaches to a remote control plane later. Chosen when the Keycloak admin console is the thing you want to replace — authentik covers users, groups, providers, and claim mappings in one UI.

```bash
./authentik/deploy.sh
# later, from a machine that can reach both authentik and Run:AI:
./authentik/integrate.sh
```

Details, the Keycloak-to-authentik concept mapping, and caveats: [`authentik/README.md`](authentik/README.md).

---

## Pre-configured Users and Groups

All three options use the same users and groups.

### Users

| Name | Email | Username | Password | Group | UID | GID |
|--|--|--|--|--|--|--|
| John Doe | `john.doe@acme.zzz` | `john.doe` | `123456` | `admin-group` | 3010 | 6010 |
| Jane Smith | `jane.smith@acme.zzz` | `jane.smith` | `123456` | `developer-group` | 3020 | 6020 |
| Steve Johnson | `steve.johnson@acme.zzz` | `steve.johnson` | `123456` | `read-only-group` | 3030 | 6030 |
| Jacky Fox | `jacky.fox@acme.zzz` | `jacky.fox` | `123456` | `read-only-group` | 3040 | 6040 |
| Blip Blop | `blip.blop@acme.zzz` | `blip.blop` | `123456` | `read-only-group` | 3050 | 6050 |

### Groups

| Group Name | Group GID | Description |
|--|--|--|
| `admin-group` | 6510 | Full administrative access |
| `developer-group` | 6520 | Development team access (has Run:AI project permissions after integration) |
| `read-only-group` | 6530 | Read-only access |

---

## CLI v1 Support (Optional)

env-in-a-click self-hosted clusters come pre-packaged with OIDC flags in the kube-apiserver deployment:
```
    - --oidc-client-id=runai
    - --oidc-issuer-url=https://my-runai-ctrl-plane.com/auth/realms/runai
    - --oidc-username-prefix=-
```

But if you want to use CLI v1 with the SSO users, you need to add OIDC group flags as well:
```
    - --oidc-groups-claim=groups
    - --oidc-username-claim=email
```

**CLI v2 works regardless, as it authenticates with ctrl plane.**

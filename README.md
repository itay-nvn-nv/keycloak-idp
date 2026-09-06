# keycloak-idp

Turnkey IDP for Run:AI. Two install paths share one realm:

| Option | When to use | Entry point |
|--|--|--|
| **Run:AI bundled Keycloak** | Keycloak is already running in `runai-backend` on the same cluster as the control plane | [`runai-backend/setup.sh`](runai-backend/setup.sh) |
| **Standalone Keycloak** | Empty cluster, or an IDP that must stay isolated and attach later to a remote control plane | [`standalone/deploy.sh`](standalone/deploy.sh) then optional [`standalone/integrate.sh`](standalone/integrate.sh) |

[`realm.json`](realm.json) is shared. Do not duplicate it.

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

## Pre-configured Users and Groups

Both options import the same `mock-idp` realm.

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

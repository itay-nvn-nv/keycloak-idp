# keycloak-idp

Turnkey IDP for Run:AI

## Description

This repository provides an automated setup for integrating Keycloak as an Identity Provider (IDP) with Run:AI. It connects to the existing Keycloak instance in the `runai-backend` namespace and configures it for SSO authentication.

The automated setup script performs the following operations:

1. **Creates a complete IDP configuration** - Imports a pre-configured Keycloak realm (`mock-idp`) with:
   - 5 demo users across different permission levels
   - 3 groups (admin, developer, read-only) with proper GID mappings
   - OIDC and SAML clients configured for Run:AI integration
   - Custom attribute mappers for UID, GID, and group memberships

2. **Integrates with Run:AI Control Plane** - Establishes the IDP connection using either:
   - **OIDC** (OpenID Connect) - Modern, token-based authentication
   - **SAML** - Enterprise-standard SSO protocol
   
   The integration enables users to authenticate to Run:AI using their IDP credentials.

3. **Sets up access control** - Creates a sample project (`dev-team`) and configures an access rule that grants the `developer-group` automatic permissions, demonstrating how SSO groups can be mapped to Run:AI project permissions.

After setup, users can log into Run:AI using their IDP credentials (e.g., `jane.smith@acme.zzz` / `123456`) with group-based access control automatically enforced.

## Setup

To set up the Keycloak IDP, run the automated setup script:

```bash
./setup.sh
```

The script will:
1. Verify the Keycloak instance is running
2. Create ConfigMaps for realm data and setup scripts
3. Automatically gather Run:AI credentials from your cluster
4. Prompt you to select the IDP type (OIDC or SAML)
5. Create the required Secret
6. Apply and monitor the post-install job

### Non-interactive mode

You can also run the script non-interactively by setting the `RUNAI_IDP_TYPE` environment variable:

```bash
RUNAI_IDP_TYPE=OIDC ./setup.sh
# or
RUNAI_IDP_TYPE=SAML ./setup.sh
```

---

## Architecture

The setup uses a Kubernetes Job with 3 init containers that run sequentially:

1. **url-health-check** - Verifies Keycloak and Run:AI control plane are accessible
2. **keycloak-setup** - Authenticates with Keycloak and imports the realm configuration
3. **runai-setup** - Creates the IDP, project, and access rules in Run:AI

All setup scripts are maintained as separate shell files in the `scripts/` directory and mounted into the job via ConfigMap. This provides:
- Better maintainability with proper syntax highlighting
- Independent testing and linting of scripts
- Clear separation of concerns
- Easy debugging with readable logs per container

The job is **idempotent** - it can be run multiple times safely as it checks for existing resources before creating them.

## Pre-configured Users and Groups

The realm includes pre-configured users and groups defined in `realm.json`. You can modify these as needed before running the setup.

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
| `developer-group` | 6520 | Development team access (has RunAI project permissions) |
| `read-only-group` | 6530 | Read-only access |

### Notes

- All users have verified email addresses and are enabled by default
- User UIDs range from 3010-3050, Group GIDs range from 6010-6050 (individual), 6510-6530 (groups)
- The `developer-group` gets automatic access to the "dev-team" project created by the post-install script
- User and group configurations can be modified in the `realm.json` file as needed

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

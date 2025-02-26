# keycloak-idp

Turnkey IDP for Run:AI

## Description
installs/connects to keycloak, according to the option chose:
- **runai-backend** connects to the existing keycloak in runai-backend namespace.
- **standalone** installs a new, separate keycloak instance.

Post install script does the following:
- creates an "IDP": creates realm/users/groups/clients in the keycloak instance, turning it into an independent, customizable IDP
- integrates the IDP SAML client with a self-hosted Run:AI ctrl plane
- creates a project in the self-hosted Run:AI ctrl plane, and a corresponding access rule that grants permission to the `developer-group` SSO group

**Main stock users:**

| email | password | group |
|--|--|--|
| `john.doe@acme.zzz` | `123456` | `admin-group` |
| `jane.smith@acme.zzz` | `123456` | `developer-group` |

Can be modified in the `realm.json` file as needed.

## Instructions for standalone keycloak installation

**1) create keycloak namespace**
```bash
kubectl create namespace keycloak
```

**2) duplicate TLS secret** (requires `yq` utility)
```bash
kubectl -n runai get secret runai-cluster-domain-tls-secret -o yaml | \
yq eval '
  .metadata.namespace = "keycloak" |
  del(.metadata.creationTimestamp) |
  del(.metadata.resourceVersion) |
  del(.metadata.selfLink) |
  del(.metadata.uid)
' - | \
kubectl apply -f -
```

**3) modify keycloak helm chart values file**

edit the `keycloak_helm_values.yaml` file, follow the commented instructions in order to configure the keycloak ingress according to your environment.

**4) install keycloak**
```bash
helm install keycloak bitnami/keycloak \
-n keycloak \
-f keycloak_helm_values.yaml \
--debug
```
before moving to next step, verify
- installation is complete
- pods are in running state
- keycloak URL is accessible

## Instructions for integartion with runai-backend keycloak instance

**1) check keycloak pod is running:**
```bash
kubectl -n runai-backend get pod keycloak-0
```

**2) check keycloak URL is accessible**
```bash
kubectl -n runai-backend get ingress runai-backend-ingress -o jsonpath='{.spec.rules[0].host}'
```

## Run the post-install script

**1) create configmap for keycloak realm data:**
```bash
kubectl -n keycloak create configmap keycloak-realm-data \
--from-file realm.json
```

**2) create secret for runai values**

modify the file `runai-ctrl-plane-data-secret.yaml` as needed and apply:
```bash
kubectl apply -f runai-ctrl-plane-data-secret.yaml
```

**3) apply the post install job**

for standalone:
```bash
kubectl -n keycloak apply -f job_standalone.yaml
```

for runai-backend:
```bash
kubectl -n keycloak apply -f job_runai-backend.yaml
```

verify the job pod is complete.

### CLI v1 support (OPTIONAL)
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

**CLI v2 works regarless, as it authenticates with ctrl plane.**
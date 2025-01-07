# keycloak-idp
## description
- installs keycloak
- creates realm/users/groups/clients
- integrates the SAML client with a self-hosted Run:AI ctrl plane

## instructions

**1) verify keycloak health:**
- pods `keycloak-0` are in running state
- keycloak URL is accessible

**2) create configmap for keycloak realm data:**
```bash
kubectl -n runai-backend create configmap keycloak-realm-data \
--from-file realm.json
```

**3) create secret for runai values**
```bash
kubectl -n runai-backend create secret generic runai-ctrl-plane-data \
--from-literal=RUNAI_CTRL_PLANE_URL=placeholder \
--from-literal=RUNAI_ADMIN_USERNAME=placeholder \
--from-literal=RUNAI_ADMIN_PASSWORD=placeholder
```

**5) apply the post install job**
```bash
kubectl -n keycloak apply -f job.yaml
```
this job creates realm/users/groups/clients, then integrates the SAML client with the self-hosted Run:AI ctrl plane.

**6) IMPORTANT: add OIDC flags to kube-apiserver manifest**
env-in-a-click self-hosted clusters come with these flags:
```
    - --oidc-client-id=runai
    - --oidc-issuer-url=https://itay-selfhosted-219.runailabs-cs.com/auth/realms/runai
    - --oidc-username-prefix=-
```

but in SAML we also need the group+claim flags:
```
    - --oidc-groups-claim=groups
    - --oidc-username-claim=email
```
# keycloak-idp: runai-backend

## instructions

**1) verify keycloak health:**
- check `keycloak-0` is running
- check keycloak URL is accessible

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

**4) apply the post install job**
```bash
kubectl -n keycloak apply -f job.yaml
```
the job performs the following:
- creates realm/users/groups/clients in keycloak
- integrates the SAML client with the self-hosted Run:AI ctrl plane
- creates a dedicated project and access rule

**5) OPTIONAL: add OIDC group flags to kube-apiserver manifest**
env-in-a-click self-hosted clusters come pre-packaged with OIDC flags in the kube-apiserver deployment:
```
    - --oidc-client-id=runai
    - --oidc-issuer-url=https://itay-selfhosted-219.runailabs-cs.com/auth/realms/runai
    - --oidc-username-prefix=-
```

If you want to use CLI v1 with the SSO users, you need to add these flags as well:
```
    - --oidc-groups-claim=groups
    - --oidc-username-claim=email
```

CLI v2 works regarless, as it authenticates with ctrl plane.
# keycloak-idp
## description
- installs keycloak
- creates realm/users/groups/clients
- integrates the SAML client with a self-hosted Run:AI ctrl plane

## instructions

**install keycloak**

```bash
helm install keycloak bitnami/keycloak \
--create-namespace -n keycloak \
-f keycloak_helm_values.yaml \
--debug
```

**create configmap for keycloak realm data:**
```bash
kubectl -n keycloak create secret generic keycloak-realm-data \
--from-file realm.json
```


**create secret for runai values:**

```bash
kubectl -n keycloak create secret generic runai-config \
--from-literal=RUNAI_CTRL_PLANE_URL=placeholder \
--from-literal=RUNAI_ADMIN_USERNAME=placeholder \
--from-literal=RUNAI_ADMIN_PASSWORD=placeholder
```

**apply the job:**

```bash
kubectl apply -f job.yaml
```

this job creates realm/users/groups/clients, then integrates the SAML client with the self-hosted Run:AI ctrl plane.


## expected envs in job manifest:
```
# envs:
KEYCLOAK_URL
KEYCLOAK_ADMIN
KEYCLOAK_ADMIN_PASSWORD
RUNAI_CTRL_PLANE_URL
RUNAI_ADMIN_USERNAME
RUNAI_ADMIN_PASSWORD
```
# keycloak-idp
## description

installs/connects to keycloak, according to the option chose:
- **runai-backend** connects to the existing keycloak in runai-backend namespace.
- **standalone** installs a new, separate keycloak instance.

then a k8s job performs the following:
- creates an "IDP": creates realm/users/groups/clients in the keycloak instance, turning it into an independent, customizable IDP
- integrates the IDP SAML client with a self-hosted Run:AI ctrl plane
- creates a project in the self-hosted Run:AI ctrl plane, and a corresponding access rule that grants permission to an SSO group

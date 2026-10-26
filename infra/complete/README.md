# Complete Lab 04 Bicep

The known-good implementation is composed by the subscription-scoped
`infra/main.bicep` entry point used by Azure Developer CLI. The files in this
directory remain resource-group scoped and can still be built independently.

## Entry points

### `bootstrap.bicep`

Creates the RBAC-enabled Key Vault, VM credential secrets, separate code build
and deployment identities, and a dedicated retail runtime identity. It grants
the selected Microsoft Entra administrator Key Vault Secrets Officer and the
runtime identity Key Vault Secrets User.

### `primary.bicep`

Creates the primary database VNet, two private VMs, Bastion, ACR, DMS, and
workload role assignments. Its `databaseMode` parameter controls Azure SQL:

- `azureSql`: create the Entra-only logical server, private endpoint, private
  DNS zone, and VNet link. Deployment automation imports `eshop_ai` afterward.
- `sqlMi`: omit all Azure SQL logical server and database resources.

### `secondary.bicep`

Creates the secondary database and application VNets, peerings, Log Analytics,
the internal zone-redundant Container Apps environment, and the placeholder
Container App.

- `azureSql`: link the application and secondary VNets to the primary SQL
  private DNS zone.
- `sqlMi`: create the delegated SQL MI subnet and General Purpose Gen5 managed
  instance. Deployment automation imports `eshop_ai` afterward.

The entry point returns a unified infrastructure database FQDN, BACPAC
database name (`eshop_ai`), and type. The Container App separately targets the
future migrated retail database `eshop` through a passwordless environment
variable. For SQL MI, the importer finalizes that variable after provisioning
because the service generates the managed-instance DNS zone. This keeps
Container Apps provisioning independent of the long-running SQL MI resource.

### `global.bicep`

Creates Front Door Premium, its endpoint and route, and one Private Link origin
targeting the Container Apps environment.

### `sqlmi.bicep`

Retained as a standalone compatibility entry point. The AZD path does not call
it because SQL MI is now selected exclusively through `databaseMode`.

## Design caveats

- SQL MI requires a dedicated delegated subnet, NSG, route table, available
  regional quota, and a long provisioning window. Freemium is preferred;
  instructor automation can select paid General Purpose when it is unavailable.
- The optional GitHub setup creates separate infrastructure preview and
  deployment identities. Preview receives Reader on the four lab resource
  groups. Only deployment receives the custom subscription deployment role,
  Contributor, RBAC Administrator, and Key Vault Secrets User.
- Lab 04 grants the code-build identity ACR push. The Lab 06 repository initializer
  additionally ensures registry-scoped Reader access for metadata queries.
  The code-deployment identity
  receives only Container App contributor and Front Door reader permissions at
  resource scope.
- The retail runtime identity receives ACR pull before Container App creation
  and is used for registry authentication, avoiding the creation-time cycle of
  a system-assigned image-pull identity.
- The user-assigned retail runtime identity resolves Key Vault-backed ACA
  secrets. Lab 05 grants its contained `eshop` database user only
  `db_datareader` and `db_datawriter` after migration.
- Deployment environments require a reviewer and exact branch policy. GitHub
  setup verifies both controls and stops when they cannot be enforced.
- The workflow approves only the expected Front Door Private Link request and
  fails closed when unknown or duplicate pending requests are present.
- ACR stays publicly reachable for GitHub-hosted runners, with its administrator
  account disabled. Private ACR would require Premium, Private Link/DNS, and a
  VNet-connected build runner or ACR Tasks.
- The Container Apps environment is internal, zone redundant, and reached by
  Front Door through Private Link.

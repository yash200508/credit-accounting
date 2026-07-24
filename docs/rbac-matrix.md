# Role-Based Access Matrix

All permissions are bounded by active membership and the caller's organization or assigned station. “Trusted workflow” means a future server-side operation using a server-held credential or a narrowly scoped database function; it never means a direct browser/mobile table write.

| Capability | Owner | Manager | Attendant | Customer | Driver | Anonymous |
|---|---|---|---|---|---|---|
| Read organization | Owned organization | Organization of assigned station | Organization of assigned station | Own organization | Parent customer's organization (minimal only) | No |
| Read station | Owned organization | Assigned station | Assigned station | Own home station | Parent customer's home station (minimal only) | No |
| Read customers broadly | Owned organization | Assigned station only | No in Phase 1 | Own row only | No direct table access | No |
| Read credit account/settings | Owned organization | Assigned station only | No | Own only | Minimal parent projection only | No |
| Read driver records | Owned organization | Assigned station only | No | Drivers of own customer | Own row only | No |
| Read driver permissions | Owned organization | Assigned station only | No | Permissions under own customer | Own only | No |
| Read role assignments | Owned organization | Assigned-station non-owner roles plus own | Own assignment only | Own assignment only | Own assignment only | No |
| Assign or change roles directly | No client write | No | No | No | No | No |
| Browse QR hashes | Owner only if operationally required | No direct access | No | No | No | No |
| Create customer + credit account | Trusted function, owned tenant/station | Trusted function, assigned station | No | No | No | No |
| Post fuel credit | Trusted function, owned tenant/station | Trusted function, assigned station | Trusted function, assigned station | No | No | No |
| Read calculated balance | Owned tenant | Assigned station | Receipt only, no balance lookup | Own account | No | No |
| Read ledger/sales | Owned tenant | Assigned station | No broad read | No direct read in Phase 2A | No | No |
| Mutate posted financial records | Never | Never | Never | Never | Never | Never |
| Read audit events | Owned organization | Assigned-station events | No | No | No | No |
| Update/delete audit events | Never | Never | Never | Never | Never | Never |
| Update non-protected settings | Owned organization | Assigned station only | No | No | No | No |

## Assignment scope

- OWNER is organization-scoped and has no station ID.
- MANAGER and ATTENDANT are station-scoped and require an active station membership.
- CUSTOMER and DRIVER are organization-scoped, but their data access additionally requires the Auth user to be linked to the corresponding customer or driver row.
- A role row alone is insufficient: helper functions also require active organization/station membership and active organization/station state.

## Prohibited privilege transitions

Normal clients cannot insert, update, or delete memberships or role assignments. A manager cannot promote themselves, grant owner, move a station to another tenant, or change protected ownership. Those operations require future audited owner/admin workflows with explicit invariants.

The two Phase 2A trusted functions are capabilities, not broad write grants.
They derive the actor and protected ownership fields, validate active
memberships, and write an audit event in the same transaction. Attendants still
cannot create customers or browse customer/account/ledger tables.

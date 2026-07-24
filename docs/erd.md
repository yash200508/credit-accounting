# Entity Relationship Diagram

This diagram adds the Phase 2A credit-posting entities to the Phase 1
foundation.

```mermaid
erDiagram
    AUTH_USERS ||--|| PROFILES : "has profile"
    ORGANIZATIONS ||--o{ STATIONS : contains
    ORGANIZATIONS ||--o{ ORGANIZATION_MEMBERSHIPS : has
    STATIONS ||--o{ STATION_MEMBERSHIPS : has
    AUTH_USERS ||--o{ ORGANIZATION_MEMBERSHIPS : joins
    AUTH_USERS ||--o{ STATION_MEMBERSHIPS : joins
    AUTH_USERS ||--o{ ROLE_ASSIGNMENTS : receives
    ORGANIZATIONS ||--o{ ROLE_ASSIGNMENTS : scopes
    STATIONS ||--o{ ROLE_ASSIGNMENTS : "optionally scopes"

    ORGANIZATIONS ||--o{ CUSTOMERS : owns
    STATIONS ||--o{ CUSTOMERS : "home station"
    AUTH_USERS o|--o| CUSTOMERS : represents
    CUSTOMERS ||--|| CUSTOMER_ACCOUNT_SETTINGS : configures
    CUSTOMERS ||--|| CREDIT_ACCOUNTS : owns
    CREDIT_ACCOUNTS ||--o{ LEDGER_TRANSACTIONS : posts
    CUSTOMERS ||--o{ LEDGER_TRANSACTIONS : incurs
    STATIONS ||--o{ LEDGER_TRANSACTIONS : records
    LEDGER_TRANSACTIONS ||--|{ LEDGER_ENTRIES : balances
    LEDGER_TRANSACTIONS ||--|| FUEL_CREDIT_SALES : describes
    FUEL_PRODUCTS ||--o{ FUEL_CREDIT_SALES : sold_as
    ORGANIZATIONS ||--o{ FUEL_PRODUCTS : configures
    STATIONS o|--o{ FUEL_PRODUCTS : scopes
    ORGANIZATIONS ||--o{ IDEMPOTENCY_KEYS : claims
    CREDIT_ACCOUNTS ||--o{ IDEMPOTENCY_KEYS : protects
    CUSTOMERS ||--o{ CUSTOMER_DRIVERS : authorizes
    AUTH_USERS o|--o| CUSTOMER_DRIVERS : represents
    CUSTOMER_DRIVERS ||--|| DRIVER_PERMISSIONS : limits

    CUSTOMERS ||--o{ QR_CREDENTIALS : "may own"
    CUSTOMER_DRIVERS ||--o{ QR_CREDENTIALS : "may own"
    ORGANIZATIONS ||--o{ INTEREST_POLICIES : defines
    CUSTOMERS o|--o{ INTEREST_POLICIES : overrides
    ORGANIZATIONS ||--o{ AUDIT_EVENTS : records
    STATIONS o|--o{ AUDIT_EVENTS : contextualizes
    ORGANIZATIONS ||--o{ APP_SETTINGS : configures
    STATIONS o|--o{ APP_SETTINGS : "optionally scopes"
```

## Relationship invariants

- Every tenant-owned row carries an organization relationship; station-scoped rows use composite foreign keys to prove that the station belongs to the same organization.
- A driver has one required customer and no relationship to `credit_accounts`.
- A QR credential belongs to exactly one customer or one driver.
- A customer has one credit account and one account-settings row in this initial model.
- An interest policy with no customer is an organization default; a customer relationship makes it an override.
- No stored balance is authoritative; posted AR ledger entries are the source
  of outstanding principal.
- A fuel transaction has one sale and exactly two equal ledger entries.
- Product scope is either organization-wide or one station, always in the same
  organization.
- An organization/operation/idempotency-key tuple identifies one request
  fingerprint and one completed result.

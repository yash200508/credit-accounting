# Entity Relationship Diagram

This diagram includes the Phase 2A credit-posting and Phase 2B repayment
entities on the Phase 1 foundation.

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
    LEDGER_TRANSACTIONS ||--o| CUSTOMER_REPAYMENTS : settles
    CUSTOMER_REPAYMENTS ||--|{ REPAYMENT_ALLOCATIONS : allocates
    CREDIT_ACCOUNTS ||--o{ CUSTOMER_REPAYMENTS : receives
    CUSTOMERS ||--o{ CUSTOMER_REPAYMENTS : pays
    STATIONS ||--o{ CUSTOMER_REPAYMENTS : receives
    CUSTOMER_DRIVERS o|--o{ CUSTOMER_REPAYMENTS : "may deliver"
    AUTH_USERS ||--o{ CUSTOMER_REPAYMENTS : "received by"
    CREDIT_ACCOUNTS ||--o{ REPAYMENT_ALLOCATIONS : reduces
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
- No stored balance is authoritative. Posted principal- and
  interest-receivable entries are the sources of outstanding principal and
  interest.
- A fuel transaction has one sale and exactly two equal ledger entries.
- A repayment has one immutable business record and one or two immutable
  allocations that sum to its total. Its ledger transaction has one cash debit
  and the exact principal and/or interest receivable credits required by its
  mode.
- A driver relationship on a repayment is physical-payer attribution only; the
  customer credit account remains the sole financial account.
- Product scope is either organization-wide or one station, always in the same
  organization.
- An organization/operation/idempotency-key tuple identifies one request
  fingerprint and one operation-specific completed result, preventing a
  repayment key from colliding with a fuel-posting key.

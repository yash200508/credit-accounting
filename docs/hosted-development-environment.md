# Hosted Development Environment

## Boundary

| Item | Phase 2E value |
|---|---|
| Project name | `credit-accounting-development` |
| Safe alias | `credit-accounting-development` |
| Classification | `DEVELOPMENT - FAKE DATA ONLY` |
| Region | `ap-south-1` (Mumbai) |
| Plan | Free, Nano compute |
| Expected cost | US$0 upfront and US$0/month; stop if any charge appears |
| Free-project pausing | Applies after about seven days of low activity |
| Managed backups | Not included on the proposed Free plan |
| PITR | Disabled and not authorized |
| Clients/domains | None |
| Production/real data | Prohibited |

Mumbai is the nearest supported region to the application's users and
gas-station operations in India. The project was created only after approval
at US$0/month and is the separately linked development target. The
non-matching pre-existing Mumbai project remains excluded and untouched.

## Authentication handoff

Authenticate only with `supabase login` and the official personal browser
flow. The user completes the login personally. Do not request, read, paste,
document, or commit their password or access token. After login, use
`supabase projects list --output json` only for read-only discovery, with
output processed so secrets are not displayed.

## Existing-project decision

Before creating anything, inspect accessible projects. An existing project is
usable only if its exact name and purpose match, it has no important or real
users/data, its schema and migration history are empty or expected, and no
other application uses it. Otherwise create the one approved project. Never
reset or overwrite an existing project to make it fit.

## Closed Auth posture

- Global public signup disabled; separately approved fake users may sign in
  after they are created.
- Anonymous sign-ins disabled.
- Email is the only enabled identity provider needed by the fake users.
- Social OAuth and manual linking disabled.
- No production SMTP, wildcard redirect, or production URL.
- JWT expiry is one hour; refresh-token rotation remains enabled.
- Password minimum is 12 with lower/upper/digit/symbol requirements.
- Authorization comes from protected membership and role tables, never
  user-editable metadata.

Seven planned `.example.test` identities will support two owners,
maker-checker, manager, attendant, customer, driver, and cross-tenant
isolation. They have not been created. After separate approval, their
generated passwords will live only in ignored local state.

## API and database posture

The live Data API exposes only `public` and `graphql_public`; `app_private` and
`cron` remain unexposed, and automatic new-table exposure is off. All 30
application tables in `public` have enabled and forced RLS. The `anon` role
has no application access. The `authenticated` role has only RLS-scoped
`SELECT` on `interest_accrual_components`, `interest_accrual_runs`, and
`interest_accruals`, plus execution of the 11 reviewed `SECURITY DEFINER`
application RPCs.

Migration 25 is deployed to the isolated development project. It removes all
public application-table and application-RPC grants from `service_role`; both
allowlists are intentionally empty. `audit_events` has no service-role
mutation or maintenance privilege. The migration also activates default-ACL
hardening so future `postgres`-owned public tables, sequences, and functions
remain private until a reviewed migration grants access explicitly.

The database uses the committed hourly pg_cron job, with no HTTP call or
credential. It is registered exactly once as
`credit-accounting-hourly-interest-accrual`, scheduled at `7 * * * *`, and
executes only `select app_private.run_hourly_interest_accrual();`. The
scheduler has not been manually invoked, and a real wall-clock firing has not
yet been evidenced. No service API key is stored in GitHub; the separately
approval-gated fake-user bootstrap is designed to obtain a server-only key
into process memory from the authenticated CLI and discard it.

## Current status

Repository controls, project creation/linking, empty-state inspection, the
deployment of all 25 migrations, and read-only hosted catalog/security
verification are complete. Local and remote migration histories match
exactly, and the committed hosted verifier passes. Security Advisor still
reports exactly the 11 expected allowlisted rule-0029 warnings; Performance
Advisor still reports 62 unindexed-foreign-key and 115 unused-index
informational findings.

The development project contains no real customer data. Fake Auth/bootstrap
data, hosted functional and concurrency testing, controlled interest
execution, wall-clock cron evidence, backup/restore evidence, and GitHub
development secrets/environment configuration remain behind separate approval
gates. No production project exists within this Phase 2E deployment scope, and
the excluded pre-existing Supabase project remains untouched. Actual evidence
is tracked in `phase-2e-validation-results.md`.

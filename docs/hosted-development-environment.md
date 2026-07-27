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

- Global public signup disabled; existing fake users may sign in.
- Anonymous sign-ins disabled.
- Email is the only enabled identity provider needed by the fake users.
- Social OAuth and manual linking disabled.
- No production SMTP, wildcard redirect, or production URL.
- JWT expiry is one hour; refresh-token rotation remains enabled.
- Password minimum is 12 with lower/upper/digit/symbol requirements.
- Authorization comes from protected membership and role tables, never
  user-editable metadata.

Seven obviously fake `.example.test` identities support two owners,
maker-checker, manager, attendant, customer, driver, and cross-tenant
isolation. Their generated passwords live only in ignored local state.

## API and database posture

The Data API schema list contains `public` and does not contain `app_private`.
All 30 application tables in `public` have enabled and forced RLS. The `anon`
role has no application access. Trusted mutation RPCs are granted to
`authenticated`. Most financial and correction objects already have the
intended raw-grant posture; hosted legacy grants on the 15 foundation tables,
the three authenticated interest-evidence tables, and four service-role RPCs
remain until migration 25 receives separate deployment approval.

Migration 25, currently local and not remotely deployed, removes all current
public table, sequence, and RPC grants from `service_role`; that allowlist is
intentionally empty. It also revokes all generated authenticated privileges
from the three interest-evidence tables before restoring only RLS-scoped
`SELECT`, and makes future `postgres`-owned public objects private by default.

The database uses the committed hourly pg_cron job, with no HTTP call or
credential. No service API key is stored in GitHub: the one-time fake-user
bootstrap obtains a server-only key into process memory from the authenticated
CLI and discards it.

## Current status

Repository controls, project creation/linking, empty-state inspection, the
first 24 hosted migrations, and read-only catalog/advisor verification are
complete. Fake Auth creation, controlled interest execution, hosted behavior
tests, backup/restore evidence, GitHub secrets, and deployment of local
migration 25 remain behind separate approval gates. Actual evidence is tracked
in `phase-2e-validation-results.md`.

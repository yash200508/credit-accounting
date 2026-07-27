# Hosted Development Environment

## Boundary

| Item | Phase 2E value |
|---|---|
| Project name | `credit-accounting-development` |
| Safe alias | `credit-accounting-development` |
| Classification | `DEVELOPMENT - FAKE DATA ONLY` |
| Proposed region | `us-east-2` (Ohio), pending explicit approval |
| Proposed plan | Free, Nano compute, pending no-cost availability check |
| Expected cost | $0 only; stop if the Dashboard or CLI presents any charge |
| Free-project pausing | Applies after inactivity |
| Managed backups | Not included on the proposed Free plan |
| PITR | Disabled and not authorized |
| Clients/domains | None |
| Production/real data | Prohibited |

Ohio is the nearest currently offered CLI region to the operator's
America/Chicago location. The region is not selected until the user approves
that exact action. If `us-east-2` is unavailable, stop and present a revised
region and rationale rather than silently choosing another.

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

The Data API schema list must contain `public` and must not contain
`app_private`. All 30 application tables in `public` have enabled and forced
RLS. The `anon` role has no application access. Trusted mutation RPCs are
granted to `authenticated`; raw financial tables, audit, interest evidence,
and correction evidence have no client or `service_role` mutation grant.

The database uses the committed hourly pg_cron job, with no HTTP call or
credential. No service API key is stored in GitHub: the one-time fake-user
bootstrap obtains a server-only key into process memory from the authenticated
CLI and discards it.

## Current status

Repository controls and the local baseline are implemented. Project discovery,
creation/linking, remote migration, fake Auth creation, the controlled
interest cycle, hosted tests, backup, and restore evidence remain pending until
their explicit approval gates and actual execution are recorded in
`phase-2e-validation-results.md`.

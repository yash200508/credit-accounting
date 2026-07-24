# Phase 1 Validation Results

Validation date: 2026-07-24

Branch: `codex/phase-1-supabase-foundation`

Starting commit: `144bfee2ace5fffd91d2c15dde97bc59da9f6ff6`

## Tooling

| Check | Actual result |
|---|---|
| Node.js | `v24.14.0` |
| npm | `11.18.0` |
| Docker client/server | `29.6.2`; daemon reachable |
| Supabase CLI | `2.109.1` through `npx --yes supabase@2.109.1` |
| Java | Eclipse Adoptium JDK `17.0.17.10-hotspot` |

Only local CLI commands were used. No Supabase login, link, pull, push, remote project reference, production credential, or real customer record was used.

## Local Supabase

`supabase start` completed successfully after images were cached. The active database, API gateway, Auth, REST, Storage, Realtime, Studio, pg-meta, local mail, and Edge Runtime containers started; reported health checks were green where the image defines one.

Local analytics was disabled in `config.toml`. On Windows, the generated configuration otherwise caused the Vector log collector to restart because it could not reach a Docker daemon exposed at unauthenticated `tcp://localhost:2375`. Exposing that endpoint was unnecessary and was not enabled. Image transformation and the connection pooler remain disabled by generated local configuration and are not needed by Phase 1.

The local development stack binds services beyond loopback and uses known development keys, as warned by the CLI. It is suitable only for local development on a trusted host.

## Migration and reset

Clean reset command:

```text
npx --yes supabase@2.109.1 db reset --local
```

Result: PASS.

Applied in order:

1. `20260724162309_core_foundation.sql`
2. `20260724162946_authorization_rls.sql`
3. `supabase/seed.sql`

The final validation destroyed the local database volume, started again, recreated the database, applied both migrations, loaded the deterministic fake seed, and restarted the local services successfully.

## pgTAP

Command:

```text
npx --yes supabase@2.109.1 test db
```

Result: PASS — 1 file, 64 tests, 0 failures.

Coverage includes:

- all 15 protected tables have enabled/forced RLS and at least one explicit policy;
- anonymous table/helper denial;
- Owner A versus Organization B isolation;
- manager assigned-station isolation;
- attendant minimum station access, no broad customer browse, and no credit-limit write;
- customer self-only customer/account/settings access;
- driver self-only record/permissions and minimal parent-account RPC, without direct parent PII;
- no client role mutation or tenant/station ownership spoofing;
- no normal-client audit update/delete and trigger-enforced immutability;
- revoked membership and revoked driver denial;
- absence of unconditional-true policies;
- fixed privileged-function search paths and anonymous execute denial;
- exact paise/rate column types, validated financial/driver/QR/interest constraints, indexed foreign keys, required driver parent relationship, and QR raw-secret absence.

## Database lint

Command:

```text
npx --yes supabase@2.109.1 db lint --local --schema public,app_private --level warning --fail-on error
```

Result: PASS — no schema errors found and no lint results.

## Java regression

Command used JDK 17 at `C:\Program Files\Eclipse Adoptium\jdk-17.0.17.10-hotspot`:

```text
mvn --batch-mode --no-transfer-progress clean verify
```

Result: PASS — 37 tests, 0 failures, 0 errors, 0 skipped; JAR built successfully.

The existing non-blocking Log4j2 SimpleLogger fallback warning remains. No stabilized Java source was changed by Phase 1.

## Skipped or deferred checks

- Remote Supabase validation and production deployment were deliberately skipped because Phase 1 is local-only.
- Real SQLite/customer-data migration was deliberately skipped.
- Flutter, Next.js, final ledger, transaction posting, repayment, interest jobs, inventory, and attendance were deliberately not implemented.
- GitHub Actions execution is pending the branch push and draft pull request; local equivalents are green.

## Remaining risks

- The local Supabase stack uses development defaults and binds to all interfaces; use only on a trusted development machine.
- Role/membership/customer/QR writes still require future trusted, audited workflows.
- Financial ledger semantics, atomic posting, concurrency, reversal, and idempotency remain intentionally unimplemented.
- Java `double` interest behavior requires golden parity tests before server-side interest posting.
- Production secret management, MFA/session policy, rate limiting, monitoring, backup/restore drills, dependency scanning, and a professional security review remain required.

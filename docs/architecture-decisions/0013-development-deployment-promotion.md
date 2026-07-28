# ADR 0013: Manual development deployment and forward promotion

## Status

Accepted.

## Context

Remote migration credentials must not reach pull-request code, forks, or an
unverified target. Two overlapping database deployments can also race
migration-history updates.

## Decision

Keep pull-request validation and hosted deployment separate. Local CI resets a
local stack and runs pgTAP, concurrency, scheduler, lint, Maven, and hygiene.
The hosted workflow is `workflow_dispatch` only, uses the protected GitHub
Environment `development`, and holds the fixed concurrency group
`supabase-development-deployment`.

The workflow itself must run from `main`. Its requested full commit SHA must
be an ancestor of `origin/main` before repository code is executed. The
ephemeral runner then checks out that exact SHA. Immutable action SHAs and
Supabase CLI 2.109.1 are pinned.

The target is accepted only when the Management API confirms the configured
reference has the exact approved development name and region. Auth and
PostgREST configuration are checked without printing the reference or token.
After a dry run displays migration identifiers, only committed migrations are
applied. Remote history, catalogs, RLS, grants, search paths, cron, Security
Advisor, and Performance Advisor are then checked.

Secrets are named `SUPABASE_ACCESS_TOKEN`, `SUPABASE_PROJECT_ID`, and
`SUPABASE_DB_PASSWORD`. Database host, port, name, user, expected project name,
and expected region are non-secret GitHub Environment variables. No secret is
an output, artifact, documentation value, or client variable.

## Rollback

Applied migration history is immutable. Ordinary errors are corrected by a
new reviewed forward-fix migration. Remote reset, migration-row deletion,
renaming, editing deployed files, and backup restoration are not rollback
tools. Security exposure first triggers containment and credential rotation.

## Consequences

- A development deploy requires a deliberate environment approval.
- Pull requests cannot deploy or receive write credentials.
- Historical main commits can be selected, but unmerged commits cannot.
- The first Phase 2E deployment may be performed locally after explicit
  approval; the committed workflow governs subsequent reviewed deployments.

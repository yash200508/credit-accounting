# Development Backup and Restore Runbook

## Scope

This process covers fake hosted development data only. It does not enable
PITR, restore hosted data, prove managed disaster recovery, or define
production RPO/RTO.

## Create a logical backup

Prerequisites are an approved linked development project and TLS PostgreSQL
connection values in `PGHOST`, `PGPORT`, `PGDATABASE`, `PGUSER`,
`PGPASSWORD`, and `PGSSLMODE=require`. Values must be supplied securely and
must not appear on the command line.

```powershell
python scripts/create_development_backup.py
```

The script:

1. Re-verifies exact project name and approved region.
2. Rejects any Auth email outside the fake reserved domain.
3. Runs pinned `supabase db dump --linked` separately for schema and
   application data.
4. Creates non-login fake Auth stubs with null password hashes.
5. Scans for tokens, keys, credentialed URLs, non-fake emails, and unexpected
   phone-shaped data.
6. Writes `.local-backups/<UTC>-credit-accounting-development/manifest.json`
   with migration head, CLI version, sizes, and per-file SHA-256 checksums.

The directory is ignored by Git and repository hygiene rejects tracked backup
formats/directories. Treat it as sensitive and apply operating-system access
controls. Do not sync it into an unreviewed cloud folder.

## Rehearse a local restore

Pass the backup directory printed by the creation command:

```powershell
python scripts/restore_development_backup.py `
  .local-backups/<UTC>-credit-accounting-development
```

The script checks all manifest hashes, copies the repository to an operating
system temporary directory, assigns a unique local project ID and unused port
offset, starts a fresh local Supabase stack, rebuilds migration history,
restores application schema, inserts only non-login Auth stubs, and restores
fake application data.

It then verifies:

- 24 migrations and the Phase 2D head;
- all expected tables, forced RLS, grants, search paths, and functions;
- one safe cron registration;
- balanced ledger entries and linked sale/repayment rows;
- exact repayment allocations;
- reconciled interest components;
- correction/reversal evidence;
- fake-only Auth domains.

The temporary stack is stopped with `--no-backup` and its temporary directory
is removed in `finally`, even after failure. The hosted project is never the
restore target.

Afterward, run the complete local suite in the main worktree. Record backup
manifest checksum, restore result, reconciliation result, and any skipped
check separately.

## Limitations

Usable Auth credentials, sessions, refresh tokens, identities, password
hashes, managed schemas, and platform configuration are intentionally not
restored. Git migrations plus the logical files are required. This is a
development logical recovery rehearsal only.

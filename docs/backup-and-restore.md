# Backup and Restore

Phase 2E uses one development-only logical backup procedure. The proposed
Free/Nano project has no managed backup or PITR entitlement, and neither is
enabled. Backups go only to ignored `.local-backups/`, are checksummed and
scanned, and contain fake application data plus non-login fake Auth stubs.

Restoration is never performed over hosted development. The rehearsal creates
a uniquely named, port-isolated local Supabase stack, verifies the manifest,
restores schema and fake data, reconciles accounting evidence and security
controls, then stops/removes the disposable stack.

See [Development Backup and Restore Runbook](development-backup-restore-runbook.md)
and [ADR 0014](architecture-decisions/0014-logical-backup-and-restore-rehearsal.md).

This is not a production backup policy, hosted disaster-recovery proof, RPO,
RTO, retention schedule, or authorization to reset/restore/delete a remote
project.

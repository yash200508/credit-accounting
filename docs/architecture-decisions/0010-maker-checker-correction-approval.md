# ADR 0010: Maker-Checker Correction Approval

- Status: Accepted
- Date: 2026-07-27

## Context

A reversal can materially change an account balance and available credit. A single privileged actor should not both propose and execute that effect.

## Decision

An active organization owner or assigned station manager may submit a typed correction request. Only an active owner of the affected organization may approve and execute it, and `requester_id <> approver_id` is mandatory.

The state machine is terminal:

```text
PENDING_REVIEW -> APPROVED_AND_EXECUTED
PENDING_REVIEW -> REJECTED
PENDING_REVIEW -> CANCELLED
```

Approval takes an expected version and locks the request row. Rejection requires an owner reason. The requester may cancel a pending request; an owner may also cancel with a reason. Every transition appends an immutable event.

## Consequences

- Owner self-approval is rejected with `COR_SELF_APPROVAL_FORBIDDEN`.
- Managers cannot approve or execute.
- An organization with one active owner must add a second authorized owner before executing a correction.
- Concurrent approval and cancellation attempts resolve to one terminal state.

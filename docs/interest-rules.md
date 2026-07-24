# Interest Rules

## Foundation model

Interest policies support an organization default and optional customer override. Rates use `NUMERIC(9,8)` as an annual decimal fraction: `0.18000000` means 18%. Valid rates are between zero and one inclusive.

The default business assumption is 18% annual simple interest.

Each policy records:

- annual rate;
- grace days;
- grace policy;
- inclusive effective-from date;
- optional exclusive effective-to date;
- active/inactive state.

The initial grace policies are:

- `AFTER_GRACE_ONLY`: no interest during grace; interest starts after grace.
- `RETROACTIVE_AFTER_GRACE`: once grace is exceeded, accrue from the original due boundary.

## Calculation decisions required before posting

Phase 1 stores policy only; it does not post interest. The next interest slice must define and test:

- day-count convention (the current Java logic uses actual days divided by 365);
- whether the due date itself accrues interest;
- effective-date boundary behavior;
- when customer overrides supersede defaults;
- rounding point and rule for sub-paise amounts;
- leap-year treatment;
- payment allocation between principal and interest;
- policy changes while principal remains outstanding;
- reversals and backdated entries.

## Legacy compatibility risk

The Java calculator uses `double`, rounds each date segment to the nearest paise, and computes simple interest on FIFO outstanding principal over `[from, to)`. PostgreSQL policies use exact numeric storage. A golden test corpus must compare old and new calculations, and any intentional difference must be approved before migrating balances.

## Safety

Clients cannot directly post interest or authoritatively calculate it. A future trusted job/function will resolve the effective policy, calculate exact results, post balanced append-only ledger entries, and record an audit event idempotently.

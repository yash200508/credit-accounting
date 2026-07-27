\set ON_ERROR_STOP on
\pset tuples_only on
\pset format unaligned

begin;
set local statement_timeout = '30s';
set local lock_timeout = '5s';

do $phase_2e$
declare
  finding text;
begin
  if (
    select count(*)
    from supabase_migrations.schema_migrations
  ) <> 24 then
    raise exception 'P2E_RESTORE_MIGRATION_COUNT_MISMATCH';
  end if;

  if (
    select max(version)
    from supabase_migrations.schema_migrations
  ) <> '20260727151937' then
    raise exception 'P2E_RESTORE_MIGRATION_HEAD_MISMATCH';
  end if;

  select string_agg(transaction_id::text, ', ')
    into finding
  from (
    select
      transaction_id
    from public.ledger_entries
    group by transaction_id
    having sum(
      case direction
        when 'DEBIT' then amount_paise
        when 'CREDIT' then -amount_paise
      end
    ) <> 0
  ) unbalanced;
  if finding is not null then
    raise exception 'P2E_RESTORE_UNBALANCED_LEDGER: %', finding;
  end if;

  if exists (
    select 1
    from public.fuel_credit_sales sale
    left join public.ledger_transactions transaction
      on transaction.id = sale.transaction_id
    where transaction.id is null
  ) then
    raise exception 'P2E_RESTORE_ORPHAN_FUEL_SALE';
  end if;

  if exists (
    select 1
    from public.customer_repayments repayment
    left join public.ledger_transactions transaction
      on transaction.id = repayment.transaction_id
    where transaction.id is null
  ) then
    raise exception 'P2E_RESTORE_ORPHAN_REPAYMENT';
  end if;

  if exists (
    select 1
    from public.repayment_allocations allocation
    join public.customer_repayments repayment
      on repayment.id = allocation.repayment_id
    group by repayment.id, repayment.total_amount_paise
    having sum(allocation.amount_paise) <> repayment.total_amount_paise
  ) then
    raise exception 'P2E_RESTORE_REPAYMENT_ALLOCATION_MISMATCH';
  end if;

  if exists (
    select 1
    from public.interest_accruals accrual
    left join lateral (
      select coalesce(sum(component.raw_interest_paise), 0) exact_total
      from public.interest_accrual_components component
      where component.interest_accrual_id = accrual.id
    ) component on true
    where component.exact_total <> accrual.raw_interest_paise
  ) then
    raise exception 'P2E_RESTORE_INTEREST_COMPONENT_MISMATCH';
  end if;

  if exists (
    select 1
    from public.financial_reversals reversal
    where not exists (
      select 1
      from public.ledger_entries original_entry
      join public.ledger_entries reversal_entry
        on reversal_entry.transaction_id = reversal.reversal_transaction_id
       and reversal_entry.account_code = original_entry.account_code
       and reversal_entry.amount_paise = original_entry.amount_paise
       and reversal_entry.direction <> original_entry.direction
      where original_entry.transaction_id = reversal.original_transaction_id
    )
  ) then
    raise exception 'P2E_RESTORE_CORRECTION_REVERSAL_EVIDENCE_MISMATCH';
  end if;

  if exists (
    select 1
    from pg_class c
    join pg_namespace n on n.oid = c.relnamespace
    where n.nspname = 'public'
      and c.relkind in ('r', 'p')
      and (not c.relrowsecurity or not c.relforcerowsecurity)
  ) then
    raise exception 'P2E_RESTORE_RLS_MISMATCH';
  end if;

  if to_regprocedure(
    'public.post_fuel_credit_transaction(uuid,uuid,uuid,numeric,uuid,text)'
  ) is null
     or to_regprocedure(
       'public.post_customer_repayment(uuid,uuid,numeric,text,uuid,numeric,numeric,uuid,text,text)'
     ) is null
     or to_regprocedure(
       'public.approve_and_execute_financial_correction(uuid,integer)'
     ) is null then
    raise exception 'P2E_RESTORE_REQUIRED_FUNCTION_MISSING';
  end if;

  if (
    select count(*)
    from cron.job
    where jobname = 'credit-accounting-hourly-interest-accrual'
      and active
  ) <> 1 then
    raise exception 'P2E_RESTORE_CRON_NOT_HANDLED_SAFELY';
  end if;

  if exists (
    select 1
    from auth.users
    where email is not null
      and email !~ '@credit-accounting\.example\.test$'
  ) then
    raise exception 'P2E_RESTORE_NON_FAKE_AUTH_EMAIL';
  end if;
end
$phase_2e$;

select 'PASS: restored migration, ledger, interest, correction, RLS, functions, and cron reconcile';
rollback;

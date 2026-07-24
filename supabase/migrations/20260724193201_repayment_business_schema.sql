alter table public.idempotency_keys
  drop constraint idempotency_keys_completion_shape;

alter table public.idempotency_keys
  alter column fuel_product_id drop not null;

alter table public.idempotency_keys
  add constraint idempotency_keys_id_organization_unique
  unique (id, organization_id);

alter table public.idempotency_keys
  add column response_repayment_id uuid,
  add column response_outstanding_interest_paise bigint,
  add column response_total_due_paise bigint;

create table public.customer_repayments (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations (id),
  station_id uuid not null,
  transaction_id uuid not null,
  credit_account_id uuid not null,
  customer_id uuid not null,
  idempotency_id uuid not null,
  total_amount_paise bigint not null,
  allocation_mode public.repayment_allocation_mode not null,
  payment_method public.repayment_payment_method not null default 'CASH',
  payer_type public.repayment_payer_type not null,
  payer_driver_id uuid,
  received_by uuid not null references auth.users (id),
  source_reference text,
  currency_code text not null default 'INR',
  created_at timestamptz not null default now(),
  constraint customer_repayments_station_tenant_fk
    foreign key (station_id, organization_id)
    references public.stations (id, organization_id),
  constraint customer_repayments_transaction_identity_fk
    foreign key (
      transaction_id,
      organization_id,
      station_id,
      credit_account_id,
      customer_id,
      currency_code
    )
    references public.ledger_transactions (
      id,
      organization_id,
      station_id,
      credit_account_id,
      customer_id,
      currency_code
    ),
  constraint customer_repayments_account_customer_tenant_fk
    foreign key (credit_account_id, customer_id, organization_id)
    references public.credit_accounts (id, customer_id, organization_id),
  constraint customer_repayments_driver_customer_tenant_fk
    foreign key (payer_driver_id, customer_id, organization_id)
    references public.customer_drivers (id, customer_id, organization_id),
  constraint customer_repayments_idempotency_tenant_fk
    foreign key (idempotency_id, organization_id)
    references public.idempotency_keys (id, organization_id),
  constraint customer_repayments_total_positive
    check (total_amount_paise > 0),
  constraint customer_repayments_currency_code_check
    check (currency_code = 'INR'),
  constraint customer_repayments_payer_shape
    check (
      (payer_type = 'CUSTOMER' and payer_driver_id is null)
      or (payer_type = 'DRIVER' and payer_driver_id is not null)
    ),
  constraint customer_repayments_source_reference_format
    check (
      source_reference is null
      or source_reference ~ '^[A-Za-z0-9][A-Za-z0-9._:/-]{0,99}$'
    ),
  constraint customer_repayments_transaction_unique
    unique (transaction_id),
  constraint customer_repayments_idempotency_unique
    unique (idempotency_id),
  constraint customer_repayments_id_organization_unique
    unique (id, organization_id),
  constraint customer_repayments_allocation_identity_unique
    unique (id, organization_id, credit_account_id)
);

create table public.repayment_allocations (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations (id),
  repayment_id uuid not null,
  credit_account_id uuid not null,
  component public.repayment_allocation_component not null,
  amount_paise bigint not null,
  created_at timestamptz not null default now(),
  constraint repayment_allocations_repayment_account_tenant_fk
    foreign key (repayment_id, organization_id, credit_account_id)
    references public.customer_repayments (
      id,
      organization_id,
      credit_account_id
    ),
  constraint repayment_allocations_amount_positive
    check (amount_paise > 0),
  constraint repayment_allocations_component_unique
    unique (repayment_id, component),
  constraint repayment_allocations_id_organization_unique
    unique (id, organization_id)
);

alter table public.idempotency_keys
  add constraint idempotency_keys_response_repayment_tenant_fk
  foreign key (response_repayment_id, organization_id)
  references public.customer_repayments (id, organization_id);

alter table public.idempotency_keys
  add constraint idempotency_keys_operation_input_shape
  check (
    (
      operation = 'FUEL_CREDIT_POSTING'
      and fuel_product_id is not null
    )
    or (
      operation = 'CUSTOMER_REPAYMENT'
      and fuel_product_id is null
    )
  );

alter table public.idempotency_keys
  add constraint idempotency_keys_repayment_balances_non_negative
  check (
    (
      response_outstanding_interest_paise is null
      or response_outstanding_interest_paise >= 0
    )
    and (
      response_total_due_paise is null
      or response_total_due_paise >= 0
    )
  );

alter table public.idempotency_keys
  add constraint idempotency_keys_completion_shape
  check (
    (
      status = 'IN_PROGRESS'
      and response_transaction_id is null
      and response_sale_id is null
      and response_repayment_id is null
      and response_outstanding_principal_paise is null
      and response_outstanding_interest_paise is null
      and response_total_due_paise is null
      and response_available_credit_paise is null
      and response_posted_at is null
      and completed_at is null
    )
    or (
      status = 'COMPLETED'
      and operation = 'FUEL_CREDIT_POSTING'
      and response_transaction_id is not null
      and response_sale_id is not null
      and response_repayment_id is null
      and response_outstanding_principal_paise is not null
      and response_outstanding_interest_paise is null
      and response_total_due_paise is null
      and response_available_credit_paise is not null
      and response_posted_at is not null
      and completed_at is not null
    )
    or (
      status = 'COMPLETED'
      and operation = 'CUSTOMER_REPAYMENT'
      and response_transaction_id is not null
      and response_sale_id is null
      and response_repayment_id is not null
      and response_outstanding_principal_paise is not null
      and response_outstanding_interest_paise is not null
      and response_total_due_paise is not null
      and response_available_credit_paise is not null
      and response_posted_at is not null
      and completed_at is not null
    )
  );

create index customer_repayments_organization_created_idx
  on public.customer_repayments (organization_id, created_at desc);
create index customer_repayments_station_created_idx
  on public.customer_repayments (station_id, created_at desc);
create index customer_repayments_account_created_idx
  on public.customer_repayments (credit_account_id, created_at desc);
create index customer_repayments_customer_created_idx
  on public.customer_repayments (customer_id, created_at desc);
create index customer_repayments_received_by_idx
  on public.customer_repayments (received_by);
create index customer_repayments_driver_idx
  on public.customer_repayments (payer_driver_id)
  where payer_driver_id is not null;

create index repayment_allocations_organization_idx
  on public.repayment_allocations (organization_id);
create index repayment_allocations_account_idx
  on public.repayment_allocations (credit_account_id);

create index idempotency_keys_response_repayment_idx
  on public.idempotency_keys (response_repayment_id)
  where response_repayment_id is not null;

create or replace function app_private.guard_idempotency_mutation()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if tg_op = 'DELETE' then
    raise exception 'idempotency records are immutable'
      using errcode = '42501';
  end if;

  if old.status = 'IN_PROGRESS'
     and new.status = 'COMPLETED'
     and new.id is not distinct from old.id
     and new.organization_id is not distinct from old.organization_id
     and new.station_id is not distinct from old.station_id
     and new.credit_account_id is not distinct from old.credit_account_id
     and new.fuel_product_id is not distinct from old.fuel_product_id
     and new.operation is not distinct from old.operation
     and new.idempotency_key is not distinct from old.idempotency_key
     and new.request_fingerprint is not distinct from old.request_fingerprint
     and new.amount_paise is not distinct from old.amount_paise
     and new.created_by is not distinct from old.created_by
     and new.created_at is not distinct from old.created_at
  then
    return new;
  end if;

  raise exception 'idempotency records are immutable'
    using errcode = '42501';
end;
$$;

create function app_private.assert_repayment_allocations_balanced()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  target_repayment_id uuid;
  repayment_row public.customer_repayments%rowtype;
  allocation_count bigint;
  allocation_total numeric;
  principal_count bigint;
  principal_total numeric;
  interest_count bigint;
  interest_total numeric;
begin
  if tg_table_name = 'customer_repayments' then
    target_repayment_id := coalesce(new.id, old.id);
  else
    target_repayment_id := coalesce(new.repayment_id, old.repayment_id);
  end if;

  select repayment.*
  into repayment_row
  from public.customer_repayments as repayment
  where repayment.id = target_repayment_id;

  if not found then
    return null;
  end if;

  select
    count(*)::bigint,
    coalesce(sum(allocation.amount_paise), 0),
    count(*) filter (
      where allocation.component = 'PRINCIPAL'
    )::bigint,
    coalesce(sum(allocation.amount_paise) filter (
      where allocation.component = 'PRINCIPAL'
    ), 0),
    count(*) filter (
      where allocation.component = 'INTEREST'
    )::bigint,
    coalesce(sum(allocation.amount_paise) filter (
      where allocation.component = 'INTEREST'
    ), 0)
  into
    allocation_count,
    allocation_total,
    principal_count,
    principal_total,
    interest_count,
    interest_total
  from public.repayment_allocations as allocation
  where allocation.repayment_id = target_repayment_id;

  if allocation_total <> repayment_row.total_amount_paise
     or (
       repayment_row.allocation_mode = 'PRINCIPAL_ONLY'
       and (
         allocation_count <> 1
         or principal_count <> 1
         or principal_total <> repayment_row.total_amount_paise
         or interest_count <> 0
       )
     )
     or (
       repayment_row.allocation_mode = 'INTEREST_ONLY'
       and (
         allocation_count <> 1
         or interest_count <> 1
         or interest_total <> repayment_row.total_amount_paise
         or principal_count <> 0
       )
     )
     or (
       repayment_row.allocation_mode = 'SPLIT'
       and (
         allocation_count <> 2
         or principal_count <> 1
         or principal_total <= 0
         or interest_count <> 1
         or interest_total <= 0
       )
     )
  then
    raise exception 'repayment allocations do not match repayment total'
      using errcode = '23514';
  end if;

  return null;
end;
$$;

create or replace function app_private.assert_ledger_transaction_balanced()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  target_transaction_id uuid;
  transaction_row public.ledger_transactions%rowtype;
  repayment_row public.customer_repayments%rowtype;
  entry_count bigint;
  debit_total numeric;
  credit_total numeric;
  ar_debit_count bigint;
  ar_debit_total numeric;
  ar_credit_count bigint;
  ar_credit_total numeric;
  fuel_revenue_credit_count bigint;
  fuel_revenue_credit_total numeric;
  interest_debit_count bigint;
  interest_debit_total numeric;
  interest_credit_count bigint;
  interest_credit_total numeric;
  interest_income_credit_count bigint;
  interest_income_credit_total numeric;
  cash_debit_count bigint;
  cash_debit_total numeric;
  allocation_total numeric;
  principal_allocation_total numeric;
  interest_allocation_total numeric;
  expected_entry_count bigint;
begin
  if tg_table_name = 'ledger_transactions' then
    target_transaction_id := coalesce(new.id, old.id);
  else
    target_transaction_id := coalesce(new.transaction_id, old.transaction_id);
  end if;

  select transaction.*
  into transaction_row
  from public.ledger_transactions as transaction
  where transaction.id = target_transaction_id;

  if not found then
    return null;
  end if;

  select
    count(*)::bigint,
    coalesce(sum(entry.amount_paise) filter (
      where entry.direction = 'DEBIT'
    ), 0),
    coalesce(sum(entry.amount_paise) filter (
      where entry.direction = 'CREDIT'
    ), 0),
    count(*) filter (
      where entry.account_code = 'CUSTOMER_ACCOUNTS_RECEIVABLE'
        and entry.direction = 'DEBIT'
    )::bigint,
    coalesce(sum(entry.amount_paise) filter (
      where entry.account_code = 'CUSTOMER_ACCOUNTS_RECEIVABLE'
        and entry.direction = 'DEBIT'
    ), 0),
    count(*) filter (
      where entry.account_code = 'CUSTOMER_ACCOUNTS_RECEIVABLE'
        and entry.direction = 'CREDIT'
    )::bigint,
    coalesce(sum(entry.amount_paise) filter (
      where entry.account_code = 'CUSTOMER_ACCOUNTS_RECEIVABLE'
        and entry.direction = 'CREDIT'
    ), 0),
    count(*) filter (
      where entry.account_code = 'FUEL_SALES_REVENUE'
        and entry.direction = 'CREDIT'
    )::bigint,
    coalesce(sum(entry.amount_paise) filter (
      where entry.account_code = 'FUEL_SALES_REVENUE'
        and entry.direction = 'CREDIT'
    ), 0),
    count(*) filter (
      where entry.account_code = 'CUSTOMER_INTEREST_RECEIVABLE'
        and entry.direction = 'DEBIT'
    )::bigint,
    coalesce(sum(entry.amount_paise) filter (
      where entry.account_code = 'CUSTOMER_INTEREST_RECEIVABLE'
        and entry.direction = 'DEBIT'
    ), 0),
    count(*) filter (
      where entry.account_code = 'CUSTOMER_INTEREST_RECEIVABLE'
        and entry.direction = 'CREDIT'
    )::bigint,
    coalesce(sum(entry.amount_paise) filter (
      where entry.account_code = 'CUSTOMER_INTEREST_RECEIVABLE'
        and entry.direction = 'CREDIT'
    ), 0),
    count(*) filter (
      where entry.account_code = 'INTEREST_INCOME'
        and entry.direction = 'CREDIT'
    )::bigint,
    coalesce(sum(entry.amount_paise) filter (
      where entry.account_code = 'INTEREST_INCOME'
        and entry.direction = 'CREDIT'
    ), 0),
    count(*) filter (
      where entry.account_code = 'CASH_ON_HAND'
        and entry.direction = 'DEBIT'
    )::bigint,
    coalesce(sum(entry.amount_paise) filter (
      where entry.account_code = 'CASH_ON_HAND'
        and entry.direction = 'DEBIT'
    ), 0)
  into
    entry_count,
    debit_total,
    credit_total,
    ar_debit_count,
    ar_debit_total,
    ar_credit_count,
    ar_credit_total,
    fuel_revenue_credit_count,
    fuel_revenue_credit_total,
    interest_debit_count,
    interest_debit_total,
    interest_credit_count,
    interest_credit_total,
    interest_income_credit_count,
    interest_income_credit_total,
    cash_debit_count,
    cash_debit_total
  from public.ledger_entries as entry
  where entry.transaction_id = target_transaction_id;

  if transaction_row.status <> 'POSTED' then
    return null;
  end if;

  if debit_total <> credit_total
     or debit_total <> transaction_row.amount_paise
  then
    raise exception 'ledger transaction is not balanced'
      using errcode = '23514';
  end if;

  if transaction_row.transaction_type = 'FUEL_CREDIT'
     and (
       entry_count <> 2
       or ar_debit_count <> 1
       or ar_debit_total <> transaction_row.amount_paise
       or fuel_revenue_credit_count <> 1
       or fuel_revenue_credit_total <> transaction_row.amount_paise
     )
  then
    raise exception 'fuel-credit ledger shape is invalid'
      using errcode = '23514';
  elsif transaction_row.transaction_type = 'INTEREST_CHARGE'
     and (
       entry_count <> 2
       or interest_debit_count <> 1
       or interest_debit_total <> transaction_row.amount_paise
       or interest_income_credit_count <> 1
       or interest_income_credit_total <> transaction_row.amount_paise
     )
  then
    raise exception 'interest-charge ledger shape is invalid'
      using errcode = '23514';
  elsif transaction_row.transaction_type = 'CUSTOMER_REPAYMENT' then
    select repayment.*
    into repayment_row
    from public.customer_repayments as repayment
    where repayment.transaction_id = target_transaction_id;

    if not found then
      raise exception 'repayment ledger has no business detail'
        using errcode = '23514';
    end if;

    select
      coalesce(sum(allocation.amount_paise), 0),
      coalesce(sum(allocation.amount_paise) filter (
        where allocation.component = 'PRINCIPAL'
      ), 0),
      coalesce(sum(allocation.amount_paise) filter (
        where allocation.component = 'INTEREST'
      ), 0)
    into
      allocation_total,
      principal_allocation_total,
      interest_allocation_total
    from public.repayment_allocations as allocation
    where allocation.repayment_id = repayment_row.id;

    expected_entry_count :=
      1
      + case when principal_allocation_total > 0 then 1 else 0 end
      + case when interest_allocation_total > 0 then 1 else 0 end;

    if repayment_row.total_amount_paise <> transaction_row.amount_paise
       or allocation_total <> transaction_row.amount_paise
       or entry_count <> expected_entry_count
       or cash_debit_count <> 1
       or cash_debit_total <> transaction_row.amount_paise
       or ar_credit_count
         <> (
           case when principal_allocation_total > 0 then 1 else 0 end
         )
       or ar_credit_total <> principal_allocation_total
       or interest_credit_count
         <> (
           case when interest_allocation_total > 0 then 1 else 0 end
         )
       or interest_credit_total <> interest_allocation_total
    then
      raise exception 'repayment ledger shape is invalid'
        using errcode = '23514';
    end if;
  end if;

  return null;
end;
$$;

revoke all on function app_private.assert_repayment_allocations_balanced()
  from public, anon, authenticated;

create trigger customer_repayments_reject_update_delete
before update or delete on public.customer_repayments
for each row execute function app_private.reject_financial_mutation();

create trigger repayment_allocations_reject_update_delete
before update or delete on public.repayment_allocations
for each row execute function app_private.reject_financial_mutation();

create constraint trigger customer_repayments_require_allocations
after insert or update on public.customer_repayments
deferrable initially deferred
for each row execute function
  app_private.assert_repayment_allocations_balanced();

create constraint trigger repayment_allocations_require_repayment_total
after insert or update or delete on public.repayment_allocations
deferrable initially deferred
for each row execute function
  app_private.assert_repayment_allocations_balanced();

alter table public.customer_repayments enable row level security;
alter table public.customer_repayments force row level security;
alter table public.repayment_allocations enable row level security;
alter table public.repayment_allocations force row level security;

revoke all on table public.customer_repayments
  from public, anon, authenticated, service_role;
revoke all on table public.repayment_allocations
  from public, anon, authenticated, service_role;

comment on table public.customer_repayments is
  'Immutable cash repayments posted to one customer credit account.';
comment on table public.repayment_allocations is
  'Immutable positive principal or interest components of one repayment.';

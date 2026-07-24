create type public.ledger_transaction_type as enum (
  'FUEL_CREDIT'
);

create type public.ledger_transaction_status as enum (
  'POSTED'
);

create type public.ledger_account_code as enum (
  'CUSTOMER_ACCOUNTS_RECEIVABLE',
  'FUEL_SALES_REVENUE'
);

create type public.ledger_entry_direction as enum (
  'DEBIT',
  'CREDIT'
);

create type public.idempotency_operation as enum (
  'FUEL_CREDIT_POSTING'
);

create type public.idempotency_status as enum (
  'IN_PROGRESS',
  'COMPLETED'
);

alter table public.credit_accounts
  add constraint credit_accounts_id_customer_organization_unique
  unique (id, customer_id, organization_id);

create table public.fuel_products (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations (id),
  station_id uuid,
  product_code text not null,
  display_name text not null,
  is_active boolean not null default true,
  currency_code text not null default 'INR',
  created_by uuid not null references auth.users (id),
  updated_by uuid not null references auth.users (id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint fuel_products_station_tenant_fk
    foreign key (station_id, organization_id)
    references public.stations (id, organization_id),
  constraint fuel_products_code_format
    check (product_code ~ '^[A-Z][A-Z0-9_-]{0,31}$'),
  constraint fuel_products_display_name_not_blank
    check (btrim(display_name) <> ''),
  constraint fuel_products_currency_code_check
    check (currency_code = 'INR'),
  constraint fuel_products_scope_code_unique
    unique nulls not distinct (organization_id, station_id, product_code),
  constraint fuel_products_id_organization_unique
    unique (id, organization_id)
);

create table public.ledger_transactions (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations (id),
  station_id uuid not null,
  credit_account_id uuid not null,
  customer_id uuid not null,
  transaction_type public.ledger_transaction_type not null,
  status public.ledger_transaction_status not null,
  amount_paise bigint not null,
  currency_code text not null default 'INR',
  occurred_at timestamptz not null default now(),
  created_by uuid not null references auth.users (id),
  created_at timestamptz not null default now(),
  constraint ledger_transactions_station_tenant_fk
    foreign key (station_id, organization_id)
    references public.stations (id, organization_id),
  constraint ledger_transactions_account_customer_tenant_fk
    foreign key (credit_account_id, customer_id, organization_id)
    references public.credit_accounts (id, customer_id, organization_id),
  constraint ledger_transactions_amount_positive
    check (amount_paise > 0),
  constraint ledger_transactions_currency_code_check
    check (currency_code = 'INR'),
  constraint ledger_transactions_id_organization_unique
    unique (id, organization_id),
  constraint ledger_transactions_id_organization_currency_unique
    unique (id, organization_id, currency_code),
  constraint ledger_transactions_business_identity_unique
    unique (
      id,
      organization_id,
      station_id,
      credit_account_id,
      customer_id,
      currency_code
    )
);

create table public.ledger_entries (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations (id),
  transaction_id uuid not null,
  account_code public.ledger_account_code not null,
  direction public.ledger_entry_direction not null,
  amount_paise bigint not null,
  currency_code text not null default 'INR',
  created_at timestamptz not null default now(),
  constraint ledger_entries_transaction_tenant_currency_fk
    foreign key (transaction_id, organization_id, currency_code)
    references public.ledger_transactions (id, organization_id, currency_code),
  constraint ledger_entries_amount_positive
    check (amount_paise > 0),
  constraint ledger_entries_currency_code_check
    check (currency_code = 'INR')
);

create table public.fuel_credit_sales (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations (id),
  station_id uuid not null,
  transaction_id uuid not null,
  credit_account_id uuid not null,
  customer_id uuid not null,
  fuel_product_id uuid not null,
  amount_paise bigint not null,
  currency_code text not null default 'INR',
  source_reference text,
  created_by uuid not null references auth.users (id),
  created_at timestamptz not null default now(),
  constraint fuel_credit_sales_transaction_identity_fk
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
  constraint fuel_credit_sales_product_tenant_fk
    foreign key (fuel_product_id, organization_id)
    references public.fuel_products (id, organization_id),
  constraint fuel_credit_sales_amount_positive
    check (amount_paise > 0),
  constraint fuel_credit_sales_currency_code_check
    check (currency_code = 'INR'),
  constraint fuel_credit_sales_source_reference_format
    check (
      source_reference is null
      or source_reference ~ '^[A-Za-z0-9][A-Za-z0-9._:/-]{0,99}$'
    ),
  constraint fuel_credit_sales_transaction_unique
    unique (transaction_id),
  constraint fuel_credit_sales_id_organization_unique
    unique (id, organization_id)
);

create table public.idempotency_keys (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations (id),
  station_id uuid not null,
  credit_account_id uuid not null,
  fuel_product_id uuid not null,
  operation public.idempotency_operation not null,
  idempotency_key uuid not null,
  request_fingerprint text not null,
  amount_paise bigint not null,
  status public.idempotency_status not null default 'IN_PROGRESS',
  response_transaction_id uuid,
  response_sale_id uuid,
  response_outstanding_principal_paise bigint,
  response_available_credit_paise bigint,
  response_posted_at timestamptz,
  created_by uuid not null references auth.users (id),
  created_at timestamptz not null default now(),
  completed_at timestamptz,
  constraint idempotency_keys_station_tenant_fk
    foreign key (station_id, organization_id)
    references public.stations (id, organization_id),
  constraint idempotency_keys_account_tenant_fk
    foreign key (credit_account_id, organization_id)
    references public.credit_accounts (id, organization_id),
  constraint idempotency_keys_product_tenant_fk
    foreign key (fuel_product_id, organization_id)
    references public.fuel_products (id, organization_id),
  constraint idempotency_keys_transaction_tenant_fk
    foreign key (response_transaction_id, organization_id)
    references public.ledger_transactions (id, organization_id),
  constraint idempotency_keys_sale_tenant_fk
    foreign key (response_sale_id, organization_id)
    references public.fuel_credit_sales (id, organization_id),
  constraint idempotency_keys_fingerprint_format
    check (request_fingerprint ~ '^[0-9a-f]{64}$'),
  constraint idempotency_keys_amount_positive
    check (amount_paise > 0),
  constraint idempotency_keys_completion_shape
    check (
      (
        status = 'IN_PROGRESS'
        and response_transaction_id is null
        and response_sale_id is null
        and response_outstanding_principal_paise is null
        and response_available_credit_paise is null
        and response_posted_at is null
        and completed_at is null
      )
      or (
        status = 'COMPLETED'
        and response_transaction_id is not null
        and response_sale_id is not null
        and response_outstanding_principal_paise is not null
        and response_available_credit_paise is not null
        and response_posted_at is not null
        and completed_at is not null
      )
    ),
  constraint idempotency_keys_scope_unique
    unique (organization_id, operation, idempotency_key)
);

create index fuel_products_organization_active_idx
  on public.fuel_products (organization_id, is_active, product_code);
create index fuel_products_station_active_idx
  on public.fuel_products (station_id, is_active, product_code)
  where station_id is not null;
create index fuel_products_created_by_idx
  on public.fuel_products (created_by);
create index fuel_products_updated_by_idx
  on public.fuel_products (updated_by);

create index ledger_transactions_organization_occurred_idx
  on public.ledger_transactions (organization_id, occurred_at desc);
create index ledger_transactions_station_occurred_idx
  on public.ledger_transactions (station_id, occurred_at desc);
create index ledger_transactions_account_occurred_idx
  on public.ledger_transactions (credit_account_id, occurred_at desc);
create index ledger_transactions_customer_occurred_idx
  on public.ledger_transactions (customer_id, occurred_at desc);
create index ledger_transactions_created_by_idx
  on public.ledger_transactions (created_by);

create index ledger_entries_transaction_idx
  on public.ledger_entries (transaction_id);
create index ledger_entries_organization_idx
  on public.ledger_entries (organization_id);

create index fuel_credit_sales_organization_created_idx
  on public.fuel_credit_sales (organization_id, created_at desc);
create index fuel_credit_sales_station_created_idx
  on public.fuel_credit_sales (station_id, created_at desc);
create index fuel_credit_sales_account_created_idx
  on public.fuel_credit_sales (credit_account_id, created_at desc);
create index fuel_credit_sales_customer_created_idx
  on public.fuel_credit_sales (customer_id, created_at desc);
create index fuel_credit_sales_product_created_idx
  on public.fuel_credit_sales (fuel_product_id, created_at desc);
create index fuel_credit_sales_created_by_idx
  on public.fuel_credit_sales (created_by);

create index idempotency_keys_station_idx
  on public.idempotency_keys (station_id);
create index idempotency_keys_account_idx
  on public.idempotency_keys (credit_account_id);
create index idempotency_keys_product_idx
  on public.idempotency_keys (fuel_product_id);
create index idempotency_keys_created_by_idx
  on public.idempotency_keys (created_by);
create index idempotency_keys_response_transaction_idx
  on public.idempotency_keys (response_transaction_id)
  where response_transaction_id is not null;
create index idempotency_keys_response_sale_idx
  on public.idempotency_keys (response_sale_id)
  where response_sale_id is not null;

create function app_private.reject_financial_mutation()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  raise exception 'financial records are append-only'
    using errcode = '42501';
end;
$$;

create function app_private.guard_idempotency_mutation()
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

create function app_private.assert_ledger_transaction_balanced()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  target_transaction_id uuid;
  transaction_row public.ledger_transactions%rowtype;
  entry_count bigint;
  debit_total numeric;
  credit_total numeric;
  ar_debit_count bigint;
  ar_debit_total numeric;
  revenue_credit_count bigint;
  revenue_credit_total numeric;
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
      where entry.account_code = 'FUEL_SALES_REVENUE'
        and entry.direction = 'CREDIT'
    )::bigint,
    coalesce(sum(entry.amount_paise) filter (
      where entry.account_code = 'FUEL_SALES_REVENUE'
        and entry.direction = 'CREDIT'
    ), 0)
  into
    entry_count,
    debit_total,
    credit_total,
    ar_debit_count,
    ar_debit_total,
    revenue_credit_count,
    revenue_credit_total
  from public.ledger_entries as entry
  where entry.transaction_id = target_transaction_id;

  if transaction_row.status = 'POSTED'
     and (
       entry_count <> 2
       or debit_total <> credit_total
       or debit_total <> transaction_row.amount_paise
       or ar_debit_count <> 1
       or ar_debit_total <> transaction_row.amount_paise
       or revenue_credit_count <> 1
       or revenue_credit_total <> transaction_row.amount_paise
     )
  then
    raise exception 'ledger transaction is not balanced'
      using errcode = '23514';
  end if;

  return null;
end;
$$;

revoke all on function app_private.reject_financial_mutation()
  from public, anon, authenticated;
revoke all on function app_private.guard_idempotency_mutation()
  from public, anon, authenticated;
revoke all on function app_private.assert_ledger_transaction_balanced()
  from public, anon, authenticated;

create trigger fuel_products_set_updated_at
before update on public.fuel_products
for each row execute function app_private.set_updated_at();

create trigger ledger_transactions_reject_update_delete
before update or delete on public.ledger_transactions
for each row execute function app_private.reject_financial_mutation();

create trigger ledger_entries_reject_update_delete
before update or delete on public.ledger_entries
for each row execute function app_private.reject_financial_mutation();

create trigger fuel_credit_sales_reject_update_delete
before update or delete on public.fuel_credit_sales
for each row execute function app_private.reject_financial_mutation();

create trigger idempotency_keys_guard_update_delete
before update or delete on public.idempotency_keys
for each row execute function app_private.guard_idempotency_mutation();

create constraint trigger ledger_transactions_require_balanced_entries
after insert or update on public.ledger_transactions
deferrable initially deferred
for each row execute function app_private.assert_ledger_transaction_balanced();

create constraint trigger ledger_entries_require_balanced_transaction
after insert or update or delete on public.ledger_entries
deferrable initially deferred
for each row execute function app_private.assert_ledger_transaction_balanced();

alter table public.fuel_products enable row level security;
alter table public.fuel_products force row level security;
alter table public.ledger_transactions enable row level security;
alter table public.ledger_transactions force row level security;
alter table public.ledger_entries enable row level security;
alter table public.ledger_entries force row level security;
alter table public.fuel_credit_sales enable row level security;
alter table public.fuel_credit_sales force row level security;
alter table public.idempotency_keys enable row level security;
alter table public.idempotency_keys force row level security;

revoke all on table public.fuel_products
  from public, anon, authenticated;
revoke all on table public.ledger_transactions
  from public, anon, authenticated;
revoke all on table public.ledger_entries
  from public, anon, authenticated;
revoke all on table public.fuel_credit_sales
  from public, anon, authenticated;
revoke all on table public.idempotency_keys
  from public, anon, authenticated;

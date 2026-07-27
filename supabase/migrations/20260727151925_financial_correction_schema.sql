alter type public.ledger_transaction_type
  add value if not exists 'FINANCIAL_REVERSAL';

create type public.financial_correction_action as enum (
  'REVERSAL_ONLY',
  'REVERSE_AND_REPLACE'
);

create type public.financial_correction_status as enum (
  'PENDING_REVIEW',
  'APPROVED_AND_EXECUTED',
  'REJECTED',
  'CANCELLED'
);

create type public.financial_correction_reason_category as enum (
  'WRONG_AMOUNT',
  'WRONG_FUEL_PRODUCT',
  'WRONG_CUSTOMER_SELECTION',
  'DUPLICATE_ENTRY',
  'WRONG_REPAYMENT_ALLOCATION',
  'WRONG_PAYER_ATTRIBUTION',
  'OPERATIONAL_ERROR',
  'OTHER'
);

create type public.financial_correction_event_type as enum (
  'SUBMITTED',
  'APPROVED_AND_EXECUTED',
  'REVERSAL_EXECUTED',
  'REPLACEMENT_POSTED',
  'REJECTED',
  'CANCELLED'
);

create table public.financial_correction_requests (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations (id),
  station_id uuid not null,
  original_transaction_id uuid not null,
  original_transaction_type public.ledger_transaction_type not null,
  credit_account_id uuid not null,
  customer_id uuid not null,
  currency_code text not null default 'INR',
  action public.financial_correction_action not null,
  reason_category public.financial_correction_reason_category not null,
  explanation text not null,
  requester_id uuid not null references auth.users (id),
  requester_role public.app_role not null,
  submitted_at timestamptz not null default statement_timestamp(),
  status public.financial_correction_status not null default 'PENDING_REVIEW',
  version integer not null default 1,
  correlation_id uuid not null default gen_random_uuid(),
  submission_idempotency_key uuid not null,
  request_fingerprint text not null,
  original_fingerprint text not null,
  replacement_idempotency_key uuid,
  decided_by uuid references auth.users (id),
  decision_reason text,
  decided_at timestamptz,
  reversal_transaction_id uuid,
  replacement_transaction_id uuid,
  updated_at timestamptz not null default statement_timestamp(),
  constraint financial_correction_requests_station_tenant_fk
    foreign key (station_id, organization_id)
    references public.stations (id, organization_id),
  constraint financial_correction_requests_original_identity_fk
    foreign key (
      original_transaction_id,
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
  constraint financial_correction_requests_account_tenant_fk
    foreign key (credit_account_id, customer_id, organization_id)
    references public.credit_accounts (id, customer_id, organization_id),
  constraint financial_correction_requests_reversal_tenant_fk
    foreign key (reversal_transaction_id, organization_id)
    references public.ledger_transactions (id, organization_id),
  constraint financial_correction_requests_replacement_tenant_fk
    foreign key (replacement_transaction_id, organization_id)
    references public.ledger_transactions (id, organization_id),
  constraint financial_correction_requests_supported_type
    check (
      original_transaction_type in (
        'FUEL_CREDIT',
        'CUSTOMER_REPAYMENT',
        'INTEREST_CHARGE'
      )
    ),
  constraint financial_correction_requests_role_check
    check (requester_role in ('OWNER', 'MANAGER')),
  constraint financial_correction_requests_explanation_length
    check (
      char_length(explanation) between 20 and 500
      and explanation = btrim(explanation)
    ),
  constraint financial_correction_requests_version_positive
    check (version > 0),
  constraint financial_correction_requests_currency_code
    check (currency_code = 'INR'),
  constraint financial_correction_requests_fingerprint_format
    check (
      request_fingerprint ~ '^[0-9a-f]{64}$'
      and original_fingerprint ~ '^[0-9a-f]{64}$'
    ),
  constraint financial_correction_requests_wrong_customer_shape
    check (
      reason_category <> 'WRONG_CUSTOMER_SELECTION'
      or action = 'REVERSAL_ONLY'
    ),
  constraint financial_correction_requests_replacement_key_shape
    check (
      (action = 'REVERSAL_ONLY' and replacement_idempotency_key is null)
      or (
        action = 'REVERSE_AND_REPLACE'
        and replacement_idempotency_key is not null
      )
    ),
  constraint financial_correction_requests_terminal_shape
    check (
      (
        status = 'PENDING_REVIEW'
        and decided_by is null
        and decision_reason is null
        and decided_at is null
        and reversal_transaction_id is null
        and replacement_transaction_id is null
      )
      or (
        status = 'APPROVED_AND_EXECUTED'
        and decided_by is not null
        and decided_at is not null
        and reversal_transaction_id is not null
        and (
          (action = 'REVERSAL_ONLY' and replacement_transaction_id is null)
          or (
            action = 'REVERSE_AND_REPLACE'
            and replacement_transaction_id is not null
          )
        )
      )
      or (
        status in ('REJECTED', 'CANCELLED')
        and decided_by is not null
        and decision_reason is not null
        and decided_at is not null
        and reversal_transaction_id is null
        and replacement_transaction_id is null
      )
    ),
  constraint financial_correction_requests_scope_idempotency_unique
    unique (organization_id, submission_idempotency_key),
  constraint financial_correction_requests_id_organization_unique
    unique (id, organization_id)
);

create table public.fuel_credit_correction_proposals (
  request_id uuid primary key,
  organization_id uuid not null,
  station_id uuid not null,
  credit_account_id uuid not null,
  customer_id uuid not null,
  fuel_product_id uuid not null,
  amount_paise bigint not null,
  source_reference text,
  created_at timestamptz not null default statement_timestamp(),
  constraint fuel_credit_correction_proposals_request_tenant_fk
    foreign key (request_id, organization_id)
    references public.financial_correction_requests (id, organization_id),
  constraint fuel_credit_correction_proposals_station_tenant_fk
    foreign key (station_id, organization_id)
    references public.stations (id, organization_id),
  constraint fuel_credit_correction_proposals_account_tenant_fk
    foreign key (credit_account_id, customer_id, organization_id)
    references public.credit_accounts (id, customer_id, organization_id),
  constraint fuel_credit_correction_proposals_product_tenant_fk
    foreign key (fuel_product_id, organization_id)
    references public.fuel_products (id, organization_id),
  constraint fuel_credit_correction_proposals_amount_positive
    check (amount_paise > 0),
  constraint fuel_credit_correction_proposals_source_reference_format
    check (
      source_reference is null
      or (
        char_length(source_reference) between 1 and 120
        and source_reference = btrim(source_reference)
        and source_reference !~ '[[:cntrl:]]'
      )
    )
);

create table public.repayment_correction_proposals (
  request_id uuid primary key,
  organization_id uuid not null,
  station_id uuid not null,
  credit_account_id uuid not null,
  customer_id uuid not null,
  total_amount_paise bigint not null,
  allocation_mode public.repayment_allocation_mode not null,
  principal_allocation_paise bigint not null default 0,
  interest_allocation_paise bigint not null default 0,
  payer_driver_id uuid,
  payment_method public.repayment_payment_method not null default 'CASH',
  source_reference text,
  created_at timestamptz not null default statement_timestamp(),
  constraint repayment_correction_proposals_request_tenant_fk
    foreign key (request_id, organization_id)
    references public.financial_correction_requests (id, organization_id),
  constraint repayment_correction_proposals_station_tenant_fk
    foreign key (station_id, organization_id)
    references public.stations (id, organization_id),
  constraint repayment_correction_proposals_account_tenant_fk
    foreign key (credit_account_id, customer_id, organization_id)
    references public.credit_accounts (id, customer_id, organization_id),
  constraint repayment_correction_proposals_driver_tenant_fk
    foreign key (payer_driver_id, customer_id, organization_id)
    references public.customer_drivers (id, customer_id, organization_id),
  constraint repayment_correction_proposals_total_positive
    check (total_amount_paise > 0),
  constraint repayment_correction_proposals_allocations_nonnegative
    check (
      principal_allocation_paise >= 0
      and interest_allocation_paise >= 0
      and principal_allocation_paise + interest_allocation_paise
        = total_amount_paise
    ),
  constraint repayment_correction_proposals_mode_shape
    check (
      (
        allocation_mode = 'PRINCIPAL_ONLY'
        and principal_allocation_paise = total_amount_paise
        and interest_allocation_paise = 0
      )
      or (
        allocation_mode = 'INTEREST_ONLY'
        and principal_allocation_paise = 0
        and interest_allocation_paise = total_amount_paise
      )
      or (
        allocation_mode = 'SPLIT'
        and principal_allocation_paise > 0
        and interest_allocation_paise > 0
      )
    ),
  constraint repayment_correction_proposals_source_reference_format
    check (
      source_reference is null
      or (
        char_length(source_reference) between 1 and 120
        and source_reference = btrim(source_reference)
        and source_reference !~ '[[:cntrl:]]'
      )
    )
);

create table public.financial_correction_events (
  id uuid primary key default gen_random_uuid(),
  request_id uuid not null,
  organization_id uuid not null,
  event_type public.financial_correction_event_type not null,
  previous_status public.financial_correction_status,
  new_status public.financial_correction_status not null,
  actor_user_id uuid not null references auth.users (id),
  actor_role public.app_role not null,
  reason text,
  correlation_id uuid not null,
  occurred_at timestamptz not null default statement_timestamp(),
  constraint financial_correction_events_request_tenant_fk
    foreign key (request_id, organization_id)
    references public.financial_correction_requests (id, organization_id),
  constraint financial_correction_events_state_shape
    check (
      (event_type = 'SUBMITTED'
        and previous_status is null
        and new_status = 'PENDING_REVIEW')
      or (event_type in (
            'APPROVED_AND_EXECUTED',
            'REVERSAL_EXECUTED',
            'REPLACEMENT_POSTED'
          )
        and previous_status = 'PENDING_REVIEW'
        and new_status = 'APPROVED_AND_EXECUTED')
      or (event_type = 'REJECTED'
        and previous_status = 'PENDING_REVIEW'
        and new_status = 'REJECTED')
      or (event_type = 'CANCELLED'
        and previous_status = 'PENDING_REVIEW'
        and new_status = 'CANCELLED')
    ),
  constraint financial_correction_events_reason_format
    check (
      reason is null
      or (
        char_length(reason) between 1 and 500
        and reason = btrim(reason)
        and reason !~ '[[:cntrl:]]'
      )
    )
);

create table public.financial_reversals (
  id uuid primary key default gen_random_uuid(),
  request_id uuid not null,
  organization_id uuid not null,
  station_id uuid not null,
  credit_account_id uuid not null,
  customer_id uuid not null,
  original_transaction_id uuid not null,
  reversal_transaction_id uuid not null,
  replacement_transaction_id uuid,
  currency_code text not null default 'INR',
  original_business_date date not null,
  reversal_business_date date not null,
  original_amount_paise bigint not null,
  reversal_amount_paise bigint not null,
  executed_by uuid not null references auth.users (id),
  correlation_id uuid not null,
  executed_at timestamptz not null default statement_timestamp(),
  constraint financial_reversals_request_tenant_fk
    foreign key (request_id, organization_id)
    references public.financial_correction_requests (id, organization_id),
  constraint financial_reversals_station_tenant_fk
    foreign key (station_id, organization_id)
    references public.stations (id, organization_id),
  constraint financial_reversals_account_tenant_fk
    foreign key (credit_account_id, customer_id, organization_id)
    references public.credit_accounts (id, customer_id, organization_id),
  constraint financial_reversals_original_identity_fk
    foreign key (
      original_transaction_id,
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
  constraint financial_reversals_reversal_identity_fk
    foreign key (
      reversal_transaction_id,
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
  constraint financial_reversals_replacement_tenant_fk
    foreign key (replacement_transaction_id, organization_id)
    references public.ledger_transactions (id, organization_id),
  constraint financial_reversals_amounts_exact
    check (
      original_amount_paise > 0
      and original_amount_paise = reversal_amount_paise
    ),
  constraint financial_reversals_business_date_order
    check (reversal_business_date >= original_business_date),
  constraint financial_reversals_currency_code
    check (currency_code = 'INR'),
  constraint financial_reversals_request_unique unique (request_id),
  constraint financial_reversals_original_unique
    unique (original_transaction_id),
  constraint financial_reversals_reversal_unique
    unique (reversal_transaction_id),
  constraint financial_reversals_replacement_unique
    unique (replacement_transaction_id),
  constraint financial_reversals_id_organization_unique
    unique (id, organization_id)
);

create index financial_correction_requests_station_status_idx
  on public.financial_correction_requests (station_id, status, submitted_at);
create index financial_correction_requests_account_idx
  on public.financial_correction_requests (credit_account_id, submitted_at);
create index financial_correction_requests_requester_idx
  on public.financial_correction_requests (requester_id);
create index financial_correction_requests_decided_by_idx
  on public.financial_correction_requests (decided_by);
create index financial_correction_requests_reversal_idx
  on public.financial_correction_requests (reversal_transaction_id);
create index financial_correction_requests_replacement_idx
  on public.financial_correction_requests (replacement_transaction_id);
create unique index financial_correction_requests_one_pending_original_idx
  on public.financial_correction_requests (original_transaction_id)
  where status = 'PENDING_REVIEW';
create index fuel_credit_correction_proposals_station_idx
  on public.fuel_credit_correction_proposals (station_id);
create index fuel_credit_correction_proposals_account_idx
  on public.fuel_credit_correction_proposals (credit_account_id);
create index fuel_credit_correction_proposals_product_idx
  on public.fuel_credit_correction_proposals (fuel_product_id);
create index repayment_correction_proposals_station_idx
  on public.repayment_correction_proposals (station_id);
create index repayment_correction_proposals_account_idx
  on public.repayment_correction_proposals (credit_account_id);
create index repayment_correction_proposals_driver_idx
  on public.repayment_correction_proposals (payer_driver_id);
create index financial_correction_events_request_time_idx
  on public.financial_correction_events (request_id, occurred_at, id);
create index financial_correction_events_actor_idx
  on public.financial_correction_events (actor_user_id);
create index financial_reversals_account_date_idx
  on public.financial_reversals (
    credit_account_id,
    reversal_business_date,
    executed_at
  );
create index financial_reversals_station_idx
  on public.financial_reversals (station_id);
create index financial_reversals_executed_by_idx
  on public.financial_reversals (executed_by);

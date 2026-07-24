alter type public.ledger_transaction_type
  add value 'CUSTOMER_REPAYMENT';

alter type public.ledger_transaction_type
  add value 'INTEREST_CHARGE';

alter type public.ledger_account_code
  add value 'CUSTOMER_INTEREST_RECEIVABLE';

alter type public.ledger_account_code
  add value 'INTEREST_INCOME';

alter type public.ledger_account_code
  add value 'CASH_ON_HAND';

alter type public.idempotency_operation
  add value 'CUSTOMER_REPAYMENT';

create type public.repayment_allocation_mode as enum (
  'PRINCIPAL_ONLY',
  'INTEREST_ONLY',
  'SPLIT'
);

create type public.repayment_allocation_component as enum (
  'PRINCIPAL',
  'INTEREST'
);

create type public.repayment_payment_method as enum (
  'CASH'
);

create type public.repayment_payer_type as enum (
  'CUSTOMER',
  'DRIVER'
);

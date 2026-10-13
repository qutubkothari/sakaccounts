-- Owner-scoped Web Push endpoints. Financial records are never sent to the push provider.
create table sakaccounts.push_subscriptions (
  id uuid primary key default gen_random_uuid(),
  owner_id uuid not null references auth.users(id) on delete cascade,
  endpoint text not null unique,
  subscription jsonb not null,
  last_fingerprint text,
  last_sent_date date,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check (endpoint = subscription->>'endpoint')
);

alter table sakaccounts.push_subscriptions enable row level security;
create policy push_subscription_owner on sakaccounts.push_subscriptions
for all to authenticated
using (sakaccounts.can_manage(owner_id))
with check (sakaccounts.can_manage(owner_id));
grant select, insert, delete on sakaccounts.push_subscriptions to authenticated;
grant update(subscription, updated_at) on sakaccounts.push_subscriptions to authenticated;

notify pgrst,'reload schema';

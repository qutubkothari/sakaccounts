create or replace function sakaccounts.reject_duplicate_split_allocations(p_allocations jsonb)
returns void language plpgsql immutable as $$
begin
 if exists (
  select 1 from jsonb_array_elements(p_allocations) as x(value)
  group by x.value->>'allocation_id' having count(*)>1
 ) then raise exception 'Duplicate split allocation in one payment'; end if;
end $$;

-- The settlement RPC is already deployed. Add a database trigger as a final guard
-- so even a malformed or retried request cannot allocate more than its source.
create or replace function sakaccounts.guard_settlement_allocation()
returns trigger language plpgsql security definer set search_path=sakaccounts,pg_temp as $$
declare v_limit bigint; v_used bigint; begin
 select amount_minor into v_limit from sakaccounts.entry_allocations where id=new.allocation_id for update;
 select coalesce(sum(amount_minor),0) into v_used from sakaccounts.settlement_allocations where allocation_id=new.allocation_id;
 if v_limit is null or v_used+new.amount_minor>v_limit then raise exception 'Split allocation overpaid'; end if;
 return new;
end $$;
create trigger settlement_allocation_guard before insert on sakaccounts.settlement_allocations
for each row execute function sakaccounts.guard_settlement_allocation();

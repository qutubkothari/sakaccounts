alter table sakaccounts.owner_preferences
  add column expense_categories text[] not null default '{}'
  check (array_length(expense_categories, 1) is null or array_length(expense_categories, 1) <= 200);

notify pgrst, 'reload schema';

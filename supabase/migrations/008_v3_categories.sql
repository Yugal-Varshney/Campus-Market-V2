-- 008_v3_categories.sql — Campus Market V3: categories become a table.
--
-- WHAT THIS CHANGES:
--   ADDITIVE: new table `categories` seeded with EXACTLY the four values V2 already uses
--     (books, notes, electronics, stationary); admin RPCs; a guard trigger.
--   DESTRUCTIVE-LOOKING (no row is modified): DROPS the CHECK constraint on items.category
--     (category in (...four values...)) and REPLACES it with a FOREIGN KEY items.category -> categories.slug.
--   The PRE-FLIGHT GATE below runs FIRST: if any existing items.category has no matching category the
--   migration ABORTS and lists the offending values. It never rewrites listing categories.
-- Categories are never deleted by the app: admins disable them. A disabled category stays on existing
-- listings (they remain visible) but cannot be chosen for new listings or when changing a category.
-- SECURITY DEFINER protections: same rules as 006 (search_path = '', admin role re-checked inside,
-- EXECUTE only for authenticated, audit row in the same transaction, slug is immutable).
-- Idempotent; one transaction. Requires 006.
-- Known limitation: direct SQL edits of `categories` are not auto-audited (only RPC changes are).

begin;

-- ───────────────────────── PRE-FLIGHT GATE ─────────────────────────
do $$
declare bad text; n integer;
begin
  if to_regprocedure('public.v3_staff_guard(boolean,boolean)') is null or to_regprocedure('public.audit_write(text,text,text,text,text,jsonb,text)') is null then
    raise exception 'MIGRATION 008 ABORTED - nothing was changed. Run 005 and 006 first.';
  end if;
  if to_regclass('public.categories') is null then
    select string_agg(format('%L (%s listing%s)', category, cnt, case when cnt = 1 then '' else 's' end), ', ' order by category) into bad
      from (select category, count(*) as cnt from public.items
             where category not in ('books','notes','electronics','stationary') group by category) x;
  else
    select string_agg(format('%L (%s listing%s)', category, cnt, case when cnt = 1 then '' else 's' end), ', ' order by category) into bad
      from (select category, count(*) as cnt from public.items
             where category not in (select slug from public.categories) group by category) x;
  end if;
  if bad is not null then
    raise exception 'MIGRATION 008 ABORTED - nothing was changed. Existing items.category values have no matching category: %', bad
      using hint = 'No data was rewritten. Decide how to handle these listings, then run this file again.';
  end if;
  select count(*) into n from pg_constraint
   where conrelid = 'public.items'::regclass and contype = 'c' and pg_get_constraintdef(oid) ~ '^CHECK \(\(category = ANY';
  if n > 1 or (n = 0 and not exists (select 1 from pg_constraint where conname = 'items_category_fkey')) then
    raise exception 'MIGRATION 008 ABORTED - nothing was changed. Could not identify the items.category CHECK constraint (found % matching).', n
      using hint = 'Run 004_v3_preflight_audit.sql and send me the constraint list.';
  end if;
end $$;

-- ───────────────────────── categories ─────────────────────────
create table if not exists public.categories (
  id          bigint generated always as identity primary key,
  name        text not null,
  slug        text not null unique,
  description text not null default '',
  is_active   boolean not null default true,
  sort_order  integer not null default 0,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now(),
  constraint categories_slug_format check (slug ~ '^[a-z0-9-]{2,40}$'),
  constraint categories_name_len check (char_length(btrim(name)) between 2 and 40),
  constraint categories_description_len check (char_length(description) <= 200)
);
create unique index if not exists categories_name_lower on public.categories (lower(name));

-- Seed = the exact values already used by V2 (display names are the plain labels the V2 UI shows).
insert into public.categories (name, slug, sort_order) values
  ('Books', 'books', 1), ('Notes', 'notes', 2), ('Electronics', 'electronics', 3), ('Stationary', 'stationary', 4)
on conflict (slug) do nothing;

create or replace function public.categories_touch() returns trigger
language plpgsql set search_path = '' as $$
begin new.updated_at := now(); return new; end $$;
drop trigger if exists categories_touch_trg on public.categories;
create trigger categories_touch_trg before update on public.categories for each row execute function public.categories_touch();

alter table public.categories enable row level security;
revoke all on public.categories from public, anon, authenticated, service_role;
grant select on public.categories to authenticated;                 -- writes only through the admin RPCs below
drop policy if exists "categories readable" on public.categories;
create policy "categories readable" on public.categories for select to authenticated using (true);

-- ───────────────────────── items.category: CHECK -> FOREIGN KEY ─────────────────────────
do $$
declare c record;
begin
  if not exists (select 1 from pg_constraint where conname = 'items_category_fkey') then
    for c in select conname from pg_constraint
              where conrelid = 'public.items'::regclass and contype = 'c' and pg_get_constraintdef(oid) ~ '^CHECK \(\(category = ANY' loop
      execute format('alter table public.items drop constraint %I', c.conname);
    end loop;
    alter table public.items add constraint items_category_fkey
      foreign key (category) references public.categories (slug) on update restrict on delete restrict;
  end if;
end $$;

-- new listings / category changes must use an ACTIVE category (existing listings keep theirs)
create or replace function public.items_v3_category_guard() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  if tg_op = 'INSERT' or new.category is distinct from old.category then
    if not exists (select 1 from public.categories c where c.slug = new.category and c.is_active) then
      raise exception 'CATEGORY_UNAVAILABLE: this category is not available.' using errcode = '23514';
    end if;
  end if;
  return new;
end $$;
drop trigger if exists items_v3_category_guard_trg on public.items;
create trigger items_v3_category_guard_trg before insert or update of category on public.items
  for each row execute function public.items_v3_category_guard();

-- ───────────────────────── admin RPCs ─────────────────────────
create or replace function public.admin_create_category(p_name text, p_slug text, p_description text default '')
returns bigint language plpgsql security definer set search_path = '' as $$
declare v_id bigint; v_slug text := lower(btrim(coalesce(p_slug, ''))); v_name text := btrim(coalesce(p_name, ''));
begin
  perform public.v3_staff_guard(true);
  if char_length(v_name) < 2 or char_length(v_name) > 40 then raise exception 'Category name must be 2-40 characters.' using errcode = '22023'; end if;
  if v_slug !~ '^[a-z0-9-]{2,40}$' then raise exception 'Slug must be 2-40 characters: a-z, 0-9 and "-".' using errcode = '22023'; end if;
  if char_length(coalesce(p_description, '')) > 200 then raise exception 'Description is limited to 200 characters.' using errcode = '22023'; end if;
  begin
    insert into public.categories (name, slug, description, sort_order)
    values (v_name, v_slug, coalesce(p_description, ''), coalesce((select max(sort_order) from public.categories), 0) + 1)
    returning id into v_id;
  exception when unique_violation then
    raise exception 'A category with this name or slug already exists.' using errcode = '23505';
  end;
  perform public.audit_write('CATEGORY_CREATED', 'admin', 'category', v_slug, null,
          jsonb_build_object('name', v_name, 'slug', v_slug), 'rpc');
  return v_id;
end $$;

create or replace function public.admin_update_category(p_id bigint, p_name text, p_description text, p_sort_order integer)
returns bigint language plpgsql security definer set search_path = '' as $$
declare old record; v_name text := btrim(coalesce(p_name, ''));
begin
  perform public.v3_staff_guard(true);
  select * into old from public.categories where id = p_id for update;
  if not found then raise exception 'Category not found.' using errcode = 'P0002'; end if;
  if char_length(v_name) < 2 or char_length(v_name) > 40 then raise exception 'Category name must be 2-40 characters.' using errcode = '22023'; end if;
  if char_length(coalesce(p_description, '')) > 200 then raise exception 'Description is limited to 200 characters.' using errcode = '22023'; end if;
  begin
    update public.categories set name = v_name, description = coalesce(p_description, ''), sort_order = coalesce(p_sort_order, old.sort_order)
     where id = p_id;                                          -- slug is deliberately NOT updatable
  exception when unique_violation then
    raise exception 'A category with this name already exists.' using errcode = '23505';
  end;
  perform public.audit_write('CATEGORY_UPDATED', 'admin', 'category', old.slug, null,
          jsonb_build_object('old_name', old.name, 'new_name', v_name, 'old_sort', old.sort_order, 'new_sort', coalesce(p_sort_order, old.sort_order)), 'rpc');
  return p_id;
end $$;

create or replace function public.admin_set_category_active(p_id bigint, p_active boolean, p_reason text)
returns bigint language plpgsql security definer set search_path = '' as $$
declare old record; v_reason text;
begin
  perform public.v3_staff_guard(true);
  v_reason := public.v3_clean_reason(p_reason);
  select * into old from public.categories where id = p_id for update;
  if not found then raise exception 'Category not found.' using errcode = 'P0002'; end if;
  if old.is_active = p_active then raise exception 'The category is already in that state.' using errcode = '22023'; end if;
  if not p_active and not exists (select 1 from public.categories c where c.id <> p_id and c.is_active) then
    raise exception 'At least one category must stay active.' using errcode = '23514';
  end if;
  update public.categories set is_active = p_active where id = p_id;
  perform public.audit_write(case when p_active then 'CATEGORY_ENABLED' else 'CATEGORY_DISABLED' end, 'admin', 'category', old.slug, v_reason,
          jsonb_build_object('listings_using_it', (select count(*) from public.items i where i.category = old.slug)), 'rpc');
  return p_id;
end $$;

-- ───────────────────────── EXECUTE privileges ─────────────────────────
revoke all on function public.items_v3_category_guard() from public, anon, authenticated, service_role;
revoke all on function public.categories_touch()        from public, anon, authenticated, service_role;
revoke all on function public.admin_create_category(text, text, text), public.admin_update_category(bigint, text, text, integer),
  public.admin_set_category_active(bigint, boolean, text) from public, anon;
grant execute on function public.admin_create_category(text, text, text), public.admin_update_category(bigint, text, text, integer),
  public.admin_set_category_active(bigint, boolean, text) to authenticated;

commit;

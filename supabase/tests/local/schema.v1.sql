-- Campus Market: run this ONCE in Supabase -> SQL Editor -> New query -> Run.

-- Only real-looking college domains may register (.edu, .edu.xx, .ac.xx)
create or replace function public.check_college_email() returns trigger
language plpgsql as $$
begin
  if new.email !~* '@[^@[:space:]]+\.(edu(\.[a-z]{2})?|ac\.[a-z]{2})$' then
    raise exception 'Use your college email (.edu or .ac.xx).';
  end if;
  return new;
end $$;
drop trigger if exists college_email_only on auth.users;
create trigger college_email_only before insert on auth.users
  for each row execute function public.check_college_email();

create table public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  display_name text not null,
  email text not null
);
create or replace function public.handle_new_user() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  insert into public.profiles (id, display_name, email)
  values (new.id, coalesce(new.raw_user_meta_data->>'display_name', 'Student'), new.email);
  return new;
end $$;
create trigger on_auth_user_created after insert on auth.users
  for each row execute function public.handle_new_user();

create table public.items (
  id bigint generated always as identity primary key,
  seller_id uuid references auth.users(id) on delete set null,
  seller_name text not null,
  title text not null,
  description text not null default '',
  category text not null check (category in ('books','notes','electronics','stationary')),
  listing_type text not null check (listing_type in ('sell','rent')),
  price numeric not null check (price > 0 and price <= 100000),
  condition_label text not null default 'good',
  image_url text,
  campus_location text not null default 'Main Campus',
  status text not null default 'active' check (status in ('active','sold','rented')),
  created_at timestamptz not null default now(),
  check (status <> 'sold' or listing_type = 'sell'),
  check (status <> 'rented' or listing_type = 'rent')
);

-- Phone/email live here so they are NOT public; only revealed by get_contact()
create table public.item_private (
  item_id bigint primary key references public.items(id) on delete cascade,
  contact_email text not null default '',
  contact_phone text not null default ''
);

create table public.wishlists (
  user_id uuid not null default auth.uid() references auth.users(id) on delete cascade,
  item_id bigint not null references public.items(id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (user_id, item_id)
);

create table public.conversations (
  id bigint generated always as identity primary key,
  item_id bigint not null references public.items(id) on delete cascade,
  buyer_id uuid not null references auth.users(id) on delete cascade,
  seller_id uuid not null references auth.users(id) on delete cascade,
  buyer_name text not null,
  created_at timestamptz not null default now(),
  unique (item_id, buyer_id)
);

create table public.messages (
  id bigint generated always as identity primary key,
  conversation_id bigint not null references public.conversations(id) on delete cascade,
  sender_id uuid not null default auth.uid() references auth.users(id) on delete cascade,
  body text not null check (length(trim(body)) > 0),
  created_at timestamptz not null default now()
);

alter table public.profiles enable row level security;
alter table public.items enable row level security;
alter table public.item_private enable row level security;
alter table public.wishlists enable row level security;
alter table public.conversations enable row level security;
alter table public.messages enable row level security;

create policy "own profile" on public.profiles for select to authenticated using (id = auth.uid());

create policy "signed-in can browse" on public.items for select to authenticated using (true);
create policy "sellers post" on public.items for insert to authenticated with check (seller_id = auth.uid());
create policy "sellers update own" on public.items for update to authenticated
  using (seller_id = auth.uid()) with check (seller_id = auth.uid());

create policy "seller manages contact" on public.item_private for all to authenticated
  using (exists (select 1 from public.items i where i.id = item_id and i.seller_id = auth.uid()))
  with check (exists (select 1 from public.items i where i.id = item_id and i.seller_id = auth.uid()));

create policy "own wishlist" on public.wishlists for all to authenticated
  using (user_id = auth.uid()) with check (user_id = auth.uid());

create policy "see my chats" on public.conversations for select to authenticated
  using (auth.uid() in (buyer_id, seller_id));
create policy "buyer starts chat" on public.conversations for insert to authenticated
  with check (buyer_id = auth.uid() and buyer_id <> seller_id);

create policy "read my messages" on public.messages for select to authenticated
  using (exists (select 1 from public.conversations c where c.id = conversation_id and auth.uid() in (c.buyer_id, c.seller_id)));
create policy "send in my chats" on public.messages for insert to authenticated
  with check (sender_id = auth.uid() and exists (select 1 from public.conversations c where c.id = conversation_id and auth.uid() in (c.buyer_id, c.seller_id)));

create or replace function public.get_contact(p_item_id bigint)
returns table (name text, email text, phone text)
language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'Sign in first.'; end if;
  if not exists (select 1 from items where id = p_item_id) then raise exception 'Listing not found.'; end if;
  if not exists (select 1 from items where id = p_item_id and status = 'active') then
    raise exception 'This item is no longer available.';
  end if;
  return query select i.seller_name, coalesce(p.contact_email, ''), coalesce(p.contact_phone, '')
    from items i left join item_private p on p.item_id = i.id where i.id = p_item_id;
end $$;

-- Photo storage
insert into storage.buckets (id, name, public) values ('item-images', 'item-images', true)
  on conflict (id) do nothing;
create policy "anyone views photos" on storage.objects for select using (bucket_id = 'item-images');
create policy "students upload photos" on storage.objects for insert to authenticated
  with check (bucket_id = 'item-images');

-- Demo listings (photos come from the /uploads folder in the project)
insert into public.items (seller_name,title,description,category,listing_type,price,condition_label,image_url,campus_location,status,created_at) values
('Sarah M.','Organic Chemistry Vol. 2 (Maitland Jones)','5th edition, decent shape. Some pencil margin notes in chapters 4-9, all pages intact. Great for OChem II this semester.','books','sell',450,'good','textbook-chemistry.jpg','North Campus Library','active',now()-interval '2 hours'),
('Alex P.','Engineering Drafting Kit in Case','Full compass and divider set with spare leads in a hard case. Rent it for the week of your engineering drawing submission.','stationary','rent',80,'like-new','drafting-kit.jpg','Workshop Block','active',now()-interval '5 hours'),
('James K.','Intro to Macroeconomics - Midterm Bundle','Complete handwritten notes for weeks 1-7 with highlighter-marked key graphs, plus two past midterm papers with solutions.','notes','sell',120,'good','notes-bundle.jpg','Student Union','active',now()-interval '1 day'),
('Jordan L.','Scientific Calculator (Black)','Works perfectly, fresh batteries. Approved for engineering and stats exams. Small scratch on the back cover.','electronics','sell',850,'good','calculator.jpg','Engineering Hall','sold',now()-interval '1 day'),
('Riley W.','Noise Cancelling Headphones - Finals Week','Over-ear noise cancelling headphones, perfect for library deep-focus sessions. Rent for a week or the whole finals stretch.','electronics','rent',150,'like-new','headphones.jpg','Central Library Desk','rented',now()-interval '2 days'),
('Priya D.','Standard White Lab Coat - Size Medium','Required for chem and bio labs. Washed and pressed, fits true to size.','stationary','sell',220,'like-new','lab-coat.jpg','Science Block B','active',now()-interval '3 days');
insert into public.item_private (item_id, contact_email, contact_phone)
select id, lower(split_part(seller_name,' ',1)) || '@demo.college.edu', '+91 98765 0000' || id from public.items where seller_id is null;

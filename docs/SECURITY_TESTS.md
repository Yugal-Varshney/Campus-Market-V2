# Security test plan (run against YOUR Supabase project)

I could not reach your live Supabase project, so RLS / storage / trigger behaviour is **unverified until you run these**.
Run `001`→`002`→…→`009` first (V3: see `docs/V3_MIGRATION_RUNBOOK.md`). Use **SQL Editor** for sections A–C (it simulates a signed-in user), then the manual steps in D.

## A. Impersonating users in the SQL Editor
Create two test accounts through the app (A and B), copy their ids from `select id, email from public.profiles;`, then:

```sql
begin;
set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"<USER_A_ID>","role":"authenticated"}', true);
-- ...statements below...
rollback;   -- always roll back so test data is not kept
```

## B. Expected results (each of these MUST fail or return 0 rows)
| Test | Statement (as user A) | Expected |
|---|---|---|
| Edit B's listing | `update public.items set title='hacked' where seller_id='<B>';` | `UPDATE 0` |
| Change B's status | `update public.items set status='sold' where seller_id='<B>';` | `UPDATE 0` |
| Delete B's listing | `delete from public.items where seller_id='<B>';` | `DELETE 0` |
| Reassign ownership | `update public.items set seller_id='<B>' where seller_id='<A>';` | silently ignored by trigger (seller_id unchanged) |
| Spoof seller name | insert an item with `seller_name='Someone Else'` | stored name = A's profile name |
| Bump listing | `update public.items set created_at = now() + interval '1 year' where seller_id='<A>';` | `created_at` unchanged |
| Foreign image URL | insert item with `image_url='https://evil.example/x.jpg'` | `Invalid image location.` |
| Sold a rental | `update public.items set status='sold' where listing_type='rent' and seller_id='<A>';` | check-constraint error |
| Edit B's wishlist | `insert into public.wishlists(user_id,item_id) values ('<B>', 1);` | RLS violation |
| Read B's wishlist | `select * from public.wishlists where user_id='<B>';` | 0 rows |
| Fake conversation | `insert into public.conversations(item_id,buyer_id,seller_id,buyer_name) values (<item_of_B>,'<A>','<C>','x');` | succeeds but `seller_id` is forced to B (trigger) |
| Chat on own listing | same insert on A's own item | `You cannot start a chat on your own listing.` |
| Read B↔C chat | `select * from public.conversations/messages` | only rows where A participates |
| Message into others' chat | `insert into public.messages(conversation_id,sender_id,body) values (<B_C_conv>,'<A>','hi');` | RLS violation |
| Delete listing that has chats | `delete from public.items where id=<item_with_conversation>;` (as the owner) | `This listing has conversations and cannot be deleted…` and the conversation + messages remain |
| Role escalation | `update public.profiles set role='admin' where id='<A>';` | `permission denied` |
| Edit profile | `update public.profiles set display_name='x' where id='<B>';` | `permission denied` |
| Private contact table | `select * from public.item_private;` | only A's own rows |
| Bad email change | `update auth.users set email='x@gmail.com' where id='<A>';` (SQL Editor, not as A) | `Use your college email…` |

## C. get_contact()
- As **anon** (`set local role anon;`): `select * from public.get_contact(1);` → `permission denied`.
- As A on a sold/rented item → `This item is no longer available.`
- As A calling it 41 times in an hour → `RATE_LIMIT: too many "contact_lookup" actions (limit 40 per 60 minutes)…` (migration 005/009; the app shows a friendlier version of this text)

## E. V3 behaviour (migrations 005–009) — every block ends in `rollback`
Use a throwaway test account A and a listing id `<B_ITEM>` owned by someone else (B).

```sql
-- E1 rate limit: the 41st contact lookup in an hour must fail
begin;
set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"<USER_A_ID>","role":"authenticated"}', true);
do $$ begin for i in 1..41 loop perform public.get_contact(<B_ITEM>); end loop; end $$;   -- expect: RATE_LIMIT: too many "contact_lookup" actions (limit 40 per 60 minutes)
rollback;

-- E2 suspended account cannot use the contact function (runs the update as postgres, then switches role)
begin;
update public.profiles set account_status = 'suspended', suspended_until = now() + interval '1 day' where id = '<USER_A_ID>';
set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"<USER_A_ID>","role":"authenticated"}', true);
select * from public.get_contact(<B_ITEM>);   -- expect: ACCOUNT_SUSPENDED: your account is suspended until ...
rollback;

-- E3 hidden listing: invisible to others, locked for its owner
begin;
update public.items set moderation_status = 'hidden' where id = <B_ITEM>;
set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"<USER_A_ID>","role":"authenticated"}', true);
select count(*) from public.items where id = <B_ITEM>;          -- expect 0
select * from public.get_contact(<B_ITEM>);                     -- expect: Listing not found.
rollback;

-- E4 audit tables are append-only
begin;
update public.audit_logs set action = action;                   -- expect: Table audit_logs is append-only: UPDATE is not allowed.
rollback;

-- E5 reserved display names
select public.is_display_name_reserved('Admin');                -- expect true
select public.is_display_name_reserved('Priya Sharma');         -- expect false
```

| Test (as student A) | Expected |
|---|---|
| `select public.staff_hide_listing(<B_ITEM>, 'test');` | any error; must not succeed |
| `select public.admin_set_role('<USER_A_ID>', 'admin', 'test');` | any error; must not succeed |
| `insert into public.reports (reporter_id, listing_id, reason) values ('<A>', <B_ITEM>, 'scam');` | succeeds once; the same insert again fails (one open report per reporter and target) |
| `update public.reports set status = 'resolved';` | `permission denied` |
| `select * from public.reports;` | only A's own reports |
| report a listing A owns | `You cannot report yourself or your own listing.` |

## D. Manual (app + Storage)
1. Sign-up with a non-college address (`@gmail.com`) → rejected by the app **and** by the DB trigger (try the Supabase Auth API directly with curl to confirm).
2. Upload a `.svg`, a `.html` renamed to `.jpg`, and a >5 MB image through the sell form → all rejected. Direct upload via the JS client of an SVG → rejected by the bucket's MIME limit.
3. With A's session, upload to `<B_ID>/x.jpg` via the storage API → `new row violates row-level security policy`.
4. Delete a listing → its image disappears from the `item-images` bucket.
5. Signed out: open `/marketplace`, `/sell`, `/wishlist`, `/messages`, `/profile` → redirected to `/login`.
6. Two browsers, user A and B: send a message from A → appears in B within ~1 s **without** a refresh.
7. Mark a sale listing "sold" and a rental "rented"; confirm the opposite status is refused.
8. Resize to 375 px / 768 px / 1280 px; keyboard-tab through nav, filters, sell form (focus ring must be visible).

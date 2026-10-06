# Security test plan (run against YOUR Supabase project)

I could not reach your live Supabase project, so RLS / storage / trigger behaviour is **unverified until you run these**.
Run `001`→`002`→`003` first. Use **SQL Editor** for sections A–C (it simulates a signed-in user), then the manual steps in D.

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
- As A calling it 41 times in an hour → `Too many contact lookups.`

## D. Manual (app + Storage)
1. Sign-up with a non-college address (`@gmail.com`) → rejected by the app **and** by the DB trigger (try the Supabase Auth API directly with curl to confirm).
2. Upload a `.svg`, a `.html` renamed to `.jpg`, and a >5 MB image through the sell form → all rejected. Direct upload via the JS client of an SVG → rejected by the bucket's MIME limit.
3. With A's session, upload to `<B_ID>/x.jpg` via the storage API → `new row violates row-level security policy`.
4. Delete a listing → its image disappears from the `item-images` bucket.
5. Signed out: open `/marketplace`, `/sell`, `/wishlist`, `/messages`, `/profile` → redirected to `/login`.
6. Two browsers, user A and B: send a message from A → appears in B within ~1 s **without** a refresh.
7. Mark a sale listing "sold" and a rental "rented"; confirm the opposite status is refused.
8. Resize to 375 px / 768 px / 1280 px; keyboard-tab through nav, filters, sell form (focus ring must be visible).

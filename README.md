# IIPS Market — V2

A student-only campus marketplace: buy, sell and rent books, notes, electronics and stationery inside your college. V2 migrates the original V1 (HTML/CSS/vanilla JS + Supabase) to a professional full-stack architecture **without changing the database, visual identity or features**.

## Features
College-email registration + confirmation · login / logout / password reset · browse (login required) · search, category and price filters, sorting, pagination (20 per page, all in the database) · sell **or rent** listings with photos · edit, delete, mark **sold / rented** · wishlist · seller contact (private) · buyer↔seller chat with **Realtime** · profile with my listings.

## Tech stack
Next.js 15 (App Router) · React 19 · TypeScript (strict) · Supabase (PostgreSQL, Auth, Storage, Realtime, RLS) · Vercel. No UI library; the original CSS is kept in `app/globals.css`.

## Architecture
```
Browser ── React components (client only where interactive)
   │          └─ Realtime subscription (chat) — anon key + user session, RLS-filtered
Next.js server ── Server Components (queries) · Server Actions (mutations) · middleware (session + route guard)
   │          └─ Supabase server client = the *user's* JWT, so RLS applies to everything
Supabase ── PostgreSQL (RLS + guard triggers) · Auth · Storage (item-images) · Realtime
```
```
app/            routes (marketplace, sell, wishlist, messages, profile, auth callback)
components/     UI (marketplace/, product/, forms/, messages/)
lib/            supabase/ auth/ listings/ messages/ validation/  + moderation/ risk/ ai/ (future seams)
types/          database.ts (schema types) + domain types
supabase/       schema.v1.sql (original) + migrations/ 001 audit · 002 security · 003 schema/functional
tests/          validation tests (npm test)     docs/  security test plan
```
Every database table keeps its V1 name: `profiles, items, item_private, wishlists, conversations, messages`. Seller contact lives in `item_private` and is only returned by the `get_contact()` RPC to signed-in users.

## Security model
- **RLS is on and never disabled.** The Next.js app never uses the service-role key (it isn't even read). Only `NEXT_PUBLIC_SUPABASE_URL`/`ANON_KEY` reach the browser.
- Identity is set **by the database**, not the client: triggers force `seller_id`, `seller_name`, `buyer_id`, `seller_id` of conversations, `buyer_name`, `contact_email`, `created_at`.
- A listing that has conversations **cannot be deleted** (a database trigger refuses, for every role). Sellers mark it sold/rented instead, so chats and messages are never destroyed as a side effect.
- Both migrations 002 and 003 start with a **pre-flight gate** that aborts, changing nothing, if an unexpected storage write policy exists (002) or if `profiles` is writable / RLS is off on `profiles`, `messages`, `conversations` (003).
- Listing rules enforced in the DB: sold/rented status vs listing type, title/description/condition/phone/price checks, image URL must be in the owner's own storage folder.
- Storage: own-folder uploads only, 5 MB, JPG/PNG/WebP only; the server also checks file signatures; no overwrite.
- Roles `student | moderator | admin` exist on `profiles.role`; users have **no write privilege on `profiles`**, so nobody can promote themselves. Promote in the SQL Editor: `update public.profiles set role='moderator' where email='…';`
- College email: format check in the app **and** a DB trigger on `auth.users` (sign-up **and** email change). It proves format, not membership — add real domains to `public.allowed_email_domains` when ready; while that table is empty any `.edu` / `.ac.xx` address is accepted.

## Local setup
1. `npm install`
2. Copy `.env.example` → `.env.local` and fill in your Supabase URL + anon key.
3. **Run the migrations yourself** in Supabase → SQL Editor, in order: `001_initial_review.sql` (read-only audit — read the output!), `002_security_fixes.sql`, `003_functional_schema_changes.sql`. They are additive and re-runnable; nothing is dropped or rewritten.
4. Supabase → Authentication → URL Configuration: add `http://localhost:3000/auth/callback` and your Vercel URL `/auth/callback` to **Redirect URLs**.
5. Demo listings: bare image filenames in `items.image_url` resolve to `public/uploads/`.
6. `npm run dev` → http://localhost:3000

### Environment variables
| Name | Purpose |
|---|---|
| `NEXT_PUBLIC_SUPABASE_URL` / `NEXT_PUBLIC_SUPABASE_ANON_KEY` | public Supabase config |
| `NEXT_PUBLIC_SITE_URL` | base URL for email links |
| `REQUIRE_LOGIN_TO_BROWSE` | `true` (default) keeps the marketplace students-only |
| `SUPABASE_SERVICE_ROLE_KEY` | not used; never prefix with `NEXT_PUBLIC_` |

### Commands
`npm run dev` · `npm run build` · `npm start` · `npm run typecheck` · `npm test`

## Deployment (Vercel)
Import the repo, set the env vars above (Production + Preview), deploy. `next.config.ts` allows images from your Supabase Storage host automatically. Uploads are capped at 4 MB (Vercel's request limit); the browser resizes photos first.

## Testing
Automated: `npm test` (validation, redirects, query parsing). Database/RLS/storage behaviour must be verified on your project — follow `docs/SECURITY_TESTS.md`.

## Roadmap
V3/V4: AI moderation · fraud detection · risk scoring · admin/moderator dashboard · reports. Hooks reserved at `lib/moderation`, `lib/risk`, `lib/ai`; none are implemented in V2.

-- Phase 3 live checks — READ ONLY (select statements only). Run in Supabase → SQL Editor.
-- Paste each result block back to me; none of these change any data.

-- 1. Allow-list rows and format problems (a leading dot or upper case would lock students out)
select domain, note, created_at,
       case when domain <> lower(btrim(domain)) then 'FIX: use lower case, no spaces'
            when domain like '.%'               then 'FIX: remove the leading dot'
            when domain like '%@%'              then 'FIX: domain only, no @'
            else 'ok' end as format_check
from public.allowed_email_domains
order by domain;

-- 2. Existing accounts versus the allow-list (existing users are not removed; this is informational)
select p.email, p.role, p.account_status,
       case when not exists (select 1 from public.allowed_email_domains) then 'allow-list is empty'
            when exists (select 1 from public.allowed_email_domains d
                         where lower(split_part(p.email, '@', 2)) = d.domain
                            or lower(split_part(p.email, '@', 2)) like '%.' || d.domain) then 'allowed'
            else 'NOT ON ALLOW-LIST' end as allow_status
from public.profiles p
order by p.email;

-- 3. Email confirmation state of existing accounts
select count(*)                                              as accounts,
       count(*) filter (where email_confirmed_at is not null) as confirmed,
       count(*) filter (where email_confirmed_at is null)     as unconfirmed
from auth.users;

-- 4. Staff accounts (0 admins is expected until you create the first one)
select role, count(*) as accounts from public.profiles group by role order by role;

-- 5. Rate-limit rules currently in force
select action, window_seconds, max_count from public.rate_limit_rules order by action, window_seconds;

-- 6. Photo bucket settings (expected: public = true, 5242880 bytes, jpeg/png/webp)
select id, public, file_size_limit, allowed_mime_types from storage.buckets where id = 'item-images';

-- 7. Listings by moderation and marketplace state
select moderation_status, status, count(*) as listings
from public.items group by moderation_status, status order by moderation_status, status;

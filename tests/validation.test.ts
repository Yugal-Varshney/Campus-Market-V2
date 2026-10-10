// Run with: npm test   (plain assertions, no test framework needed)
import { validateListing, sniffImageType, validateImageMeta } from '../lib/validation/listing';
import { isCollegeEmail, safeNext, validateRegistration, parseOtpType } from '../lib/validation/auth';
import { parseListingQuery } from '../lib/listings/search-params';
import { resolveImageUrl } from '../lib/listings/mappers';
import { friendlyDbError, knownDbError } from '../lib/errors';
import { statusInfo } from '../lib/format';

const ok = { title: 'Chem book', description: '', category: 'books', listingType: 'sell', price: 250, condition: 'good', phone: '+91 98765 43210' };
let failed = 0;
const t = (name: string, cond: boolean) => { if (!cond) failed++; console.log(cond ? 'PASS' : 'FAIL', name); };

t('valid listing accepted', !!validateListing(ok).value);
t('short title rejected', !!validateListing({ ...ok, title: 'ab' }).error);
t('price 0 rejected', !!validateListing({ ...ok, price: 0 }).error);
t('price > 100000 rejected', !!validateListing({ ...ok, price: 100001 }).error);
t('bad category rejected', !!validateListing({ ...ok, category: 'cars' }).error);
t('bad listing type rejected', !!validateListing({ ...ok, listingType: 'gift' }).error);
t('bad condition rejected', !!validateListing({ ...ok, condition: 'broken' }).error);
t('bad phone rejected', !!validateListing({ ...ok, phone: 'abc' }).error);
t('empty phone allowed', !!validateListing({ ...ok, phone: '' }).value);
t('long description rejected', !!validateListing({ ...ok, description: 'x'.repeat(1001) }).error);
t('png signature detected', sniffImageType(new Uint8Array([0x89, 0x50, 0x4e, 0x47, 0, 0, 0, 0, 0, 0, 0, 0])) === 'image/png');
t('html disguised as image rejected', sniffImageType(new TextEncoder().encode('<script>alert(1)</script>')) === null);
t('svg mime rejected', !!validateImageMeta({ type: 'image/svg+xml', size: 10 }));
t('oversized image rejected', !!validateImageMeta({ type: 'image/png', size: 5 * 1024 * 1024 }));
t('.edu accepted', isCollegeEmail('a@mit.edu'));
t('.ac.in accepted', isCollegeEmail('a@iips.ac.in'));
t('.edu.in accepted', isCollegeEmail('a@x.edu.in'));
t('gmail rejected', !isCollegeEmail('a@gmail.com'));
t('mit.edu.evil.com rejected', !isCollegeEmail('a@mit.edu.evil.com'));
t('short password rejected', !!validateRegistration({ name: 'A', email: 'a@mit.edu', password: '123' }));
t('open redirect //evil blocked', safeNext('//evil.com') === '/marketplace');
t('absolute redirect blocked', safeNext('https://evil.com') === '/marketplace');
t('relative redirect allowed', safeNext('/sell') === '/sell');
t('tab-smuggled redirect blocked', safeNext('/\t/evil.com') === '/marketplace');
t('newline-smuggled redirect blocked', safeNext('/\n/evil.com') === '/marketplace');
t('space in redirect blocked', safeNext('/ /evil.com') === '/marketplace');
t('null byte in redirect blocked', safeNext('/\u0000x') === '/marketplace');
t('redirect keeps encoded query', safeNext('/sell?x=1&y=a%20b') === '/sell?x=1&y=a%20b');
t('redirect over 2000 chars blocked', safeNext('/' + 'a'.repeat(2001)) === '/marketplace');
const q = parseListingQuery({ category: 'books,hax,notes', maxPrice: 'abc', sort: 'drop table', page: '-3', q: '  chem  ' });
t('query params sanitised', q.categories.join() === 'books,notes' && q.maxPrice === null && q.sort === 'newest' && q.page === 1 && q.q === 'chem');
t('demo image filename resolves to /uploads', resolveImageUrl('calculator.jpg') === '/uploads/calculator.jpg' && resolveImageUrl('../uploads/calculator.jpg') === '/uploads/calculator.jpg');
t('absolute image URL untouched', resolveImageUrl('https://x.co/a.jpg') === 'https://x.co/a.jpg');

// ---- V3 database error mapping (migrations 005-009) ----
t('rate limit message is friendly', /5 per 60 minutes/.test(friendlyDbError('RATE_LIMIT: too many "listing_create" actions (limit 5 per 60 minutes). Please try again later.', 'x')));
t('rate limit hides internal action name', !/listing_create/.test(friendlyDbError('RATE_LIMIT: too many "listing_create" actions (limit 5 per 60 minutes). Please try again later.', 'x')));
t('rate limit without numbers still friendly', friendlyDbError('RATE_LIMIT: odd', 'x') !== 'x');
t('suspension message keeps the end date', /2026-10-12 10:00 UTC/.test(friendlyDbError('ACCOUNT_SUSPENDED: your account is suspended until 2026-10-12 10:00 UTC. You can browse but not post, message or report.', 'x')));
t('ban message mapped', friendlyDbError('ACCOUNT_BANNED: your account has been banned.', 'x') === 'Your account has been banned.');
t('hidden listing message mapped', /hidden by a moderator/.test(friendlyDbError('LISTING_HIDDEN: this listing was hidden by a moderator and cannot be changed.', 'x')));
t('open report delete message mapped', /open report/.test(friendlyDbError('LISTING_REPORTED: this listing has an open report and cannot be deleted. Mark it sold.', 'x')));
t('reserved name message mapped', /reserved/.test(friendlyDbError('RESERVED_NAME: that display name is reserved. Please choose another.', 'x')));
t('unknown database error falls back', friendlyDbError('duplicate key value violates unique constraint "items_pkey"', 'generic') === 'generic');
t('RLS error text is not shown to users', knownDbError('new row violates row-level security policy for table "items"') === null);
t('missing error falls back', friendlyDbError(undefined, 'generic') === 'generic');

// ---- email link types (token-hash flow) ----
t('signup link type accepted', parseOtpType('signup') === 'signup');
t('recovery link type accepted', parseOtpType('recovery') === 'recovery');
t('email_change link type accepted', parseOtpType('email_change') === 'email_change');
t('unknown link type rejected', parseOtpType('magiclink') === null);
t('missing link type rejected', parseOtpType(null) === null);
t('non-string link type rejected', parseOtpType(['recovery']) === null);

// ---- listing status labels ----
t('inactive listing shows UNAVAILABLE', statusInfo({ status: 'inactive', listingType: 'sell' }).label === 'UNAVAILABLE');
t('inactive listing counts as done', statusInfo({ status: 'inactive', listingType: 'rent' }).done === true);
t('active rent listing still FOR RENT', statusInfo({ status: 'active', listingType: 'rent' }).label === 'FOR RENT');

if (failed) { console.error(`\n${failed} test(s) failed`); process.exit(1); }
console.log('\nAll tests passed');

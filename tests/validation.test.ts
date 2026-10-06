// Run with: npm test   (plain assertions, no test framework needed)
import { validateListing, sniffImageType, validateImageMeta } from '../lib/validation/listing';
import { isCollegeEmail, safeNext, validateRegistration } from '../lib/validation/auth';
import { parseListingQuery } from '../lib/listings/search-params';
import { resolveImageUrl } from '../lib/listings/mappers';

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
const q = parseListingQuery({ category: 'books,hax,notes', maxPrice: 'abc', sort: 'drop table', page: '-3', q: '  chem  ' });
t('query params sanitised', q.categories.join() === 'books,notes' && q.maxPrice === null && q.sort === 'newest' && q.page === 1 && q.q === 'chem');
t('demo image filename resolves to /uploads', resolveImageUrl('calculator.jpg') === '/uploads/calculator.jpg' && resolveImageUrl('../uploads/calculator.jpg') === '/uploads/calculator.jpg');
t('absolute image URL untouched', resolveImageUrl('https://x.co/a.jpg') === 'https://x.co/a.jpg');

if (failed) { console.error(`\n${failed} test(s) failed`); process.exit(1); }
console.log('\nAll tests passed');

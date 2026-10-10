import type { Metadata } from 'next';
import Link from 'next/link';
import { Suspense } from 'react';
import { getCurrentUser } from '@/lib/auth/session';
import { getListings, getWishlistIds } from '@/lib/listings/queries';
import { parseListingQuery } from '@/lib/listings/search-params';
import type { Listing, Paginated } from '@/types';
import Filters from '@/components/marketplace/Filters';
import SortSelect from '@/components/marketplace/SortSelect';
import ProductGrid from '@/components/marketplace/ProductGrid';
import Pagination from '@/components/marketplace/Pagination';

export const metadata: Metadata = { title: 'Marketplace' };

type SP = Promise<Record<string, string | string[] | undefined>>;

export default async function MarketplacePage({ searchParams }: { searchParams: SP }) {
  const sp = await searchParams;
  const query = parseListingQuery(sp);
  const user = await getCurrentUser();

  let result: Paginated<Listing> | null = null;
  try {
    result = await getListings(query);
  } catch {
    result = null;
  }
  const wishlistIds = user ? await getWishlistIds(user.id) : [];
  const flat = (k: string) => (Array.isArray(sp[k]) ? (sp[k] as string[])[0] : (sp[k] as string | undefined));
  const keep = { q: flat('q'), category: flat('category'), minPrice: flat('minPrice'), maxPrice: flat('maxPrice'), sort: flat('sort') };

  return (
    <div className="browse-grid">
      <Suspense fallback={<aside className="browse-sidebar" />}><Filters /></Suspense>
      <section className="browse-main">
        {/* The navbar search box is hidden below 768px, so phones get their own. Filters are carried over. */}
        <form className="mobile-search" action="/marketplace" role="search">
          {keep.category && <input type="hidden" name="category" value={keep.category} />}
          {keep.minPrice && <input type="hidden" name="minPrice" value={keep.minPrice} />}
          {keep.maxPrice && <input type="hidden" name="maxPrice" value={keep.maxPrice} />}
          {keep.sort && <input type="hidden" name="sort" value={keep.sort} />}
          <input type="search" name="q" className="search-input" defaultValue={keep.q ?? ''} placeholder="Search books, notes, electronics..." aria-label="Search listings" maxLength={100} />
          <button type="submit" className="btn btn-dark btn-sm">SEARCH</button>
        </form>
        <header className="listings-header">
          <div className="listings-header-left">
            <h1 className="font-display">{query.q ? `RESULTS FOR “${query.q.toUpperCase()}”` : 'LATEST LISTINGS'}</h1>
            <span className="item-count-badge" role="status">{result ? `${result.total} ${result.total === 1 ? 'ITEM' : 'ITEMS'} FOUND` : '—'}</span>
          </div>
          <Suspense fallback={null}><SortSelect /></Suspense>
        </header>

        {!result ? (
          <div className="empty-state solid" role="alert">
            <h2 className="font-display">The board didn&apos;t load</h2>
            <p>Unable to load listings. Please refresh the page.</p>
          </div>
        ) : result.items.length === 0 ? (
          <div className="empty-state">
            <h2 className="font-display">Nothing on the board yet</h2>
            <p>No listings found. Try a different search or clear your filters.</p>
            <Link href="/marketplace" className="btn btn-outline">Clear Filters</Link>
          </div>
        ) : (
          <>
            <ProductGrid items={result.items} wishlistIds={wishlistIds} />
            <Pagination page={result.page} total={result.total} pageSize={result.pageSize} params={keep} />
          </>
        )}
      </section>
    </div>
  );
}

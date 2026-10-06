import type { Metadata } from 'next';
import Link from 'next/link';
import { getCurrentUser } from '@/lib/auth/session';
import { getWishlist } from '@/lib/listings/queries';
import ProductGrid from '@/components/marketplace/ProductGrid';
import type { WishlistItem } from '@/types';

export const metadata: Metadata = { title: 'My wishlist' };

export default async function WishlistPage() {
  const user = await getCurrentUser();
  if (!user) return <div className="empty-state solid" role="alert"><h2 className="font-display">Sign in</h2><p>You need to sign in to continue.</p></div>;

  let items: WishlistItem[] | null = null;
  try { items = await getWishlist(user.id); } catch { items = null; }

  return (
    <div className="messages-shell">
      <header className="listings-header" style={{ marginBottom: '2rem' }}>
        <div className="listings-header-left">
          <h1 className="font-display">MY WISHLIST</h1>
          <span className="item-count-badge" role="status">{items ? `${items.length} SAVED` : '—'}</span>
        </div>
      </header>
      {!items ? (
        <div className="empty-state solid" role="alert"><h2 className="font-display">Couldn&apos;t load</h2><p>Unable to load your wishlist.</p></div>
      ) : items.length === 0 ? (
        <div className="empty-state" style={{ padding: '4rem 1rem' }}>
          <h2 className="font-display">NOTHING SAVED YET</h2>
          <p>Tap the heart on any listing to keep it here for later.</p>
          <Link href="/marketplace" className="btn btn-dark">Browse the Board</Link>
        </div>
      ) : (
        <ProductGrid items={items.map((w) => w.listing)} wishlistIds={items.map((w) => w.itemId)} cols={4} />
      )}
    </div>
  );
}

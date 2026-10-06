import type { Metadata } from 'next';
import Link from 'next/link';
import { getCurrentRole, getCurrentUser } from '@/lib/auth/session';
import { getMyListings } from '@/lib/listings/queries';
import ProductGrid from '@/components/marketplace/ProductGrid';

export const metadata: Metadata = { title: 'My profile' };

export default async function ProfilePage() {
  const user = await getCurrentUser();
  if (!user) return null; // middleware redirects signed-out visitors
  const [listings, role] = await Promise.all([getMyListings(user.id), getCurrentRole()]);

  return (
    <div className="messages-shell">
      <header>
        <h1 className="font-display">{user.displayName.toUpperCase()}</h1>
        <p className="sub font-mono">{user.email}{role !== 'student' ? ` · ${role}` : ''}</p>
      </header>
      <section className="my-listings">
        <h2>My listings</h2>
        {listings.length === 0 ? (
          <div className="empty-state"><h2 className="font-display">NOTHING POSTED YET</h2><p>Your listings show up here.</p><Link href="/sell" className="btn btn-dark">Sell an item</Link></div>
        ) : (
          <ProductGrid items={listings} wishlistIds={[]} cols={4} />
        )}
      </section>
    </div>
  );
}

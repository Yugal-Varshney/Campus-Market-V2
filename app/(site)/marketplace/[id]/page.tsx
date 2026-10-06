import type { Metadata } from 'next';
import Image from 'next/image';
import Link from 'next/link';
import { notFound } from 'next/navigation';
import { cache } from 'react';
import { getCurrentUser } from '@/lib/auth/session';
import { countConversations, getListing, getWishlistIds } from '@/lib/listings/queries';
import { categoryLabel, conditionLabel } from '@/lib/constants';
import { formatPrice, statusInfo, timeAgo } from '@/lib/format';
import SellerPanel from '@/components/product/SellerPanel';

const load = cache(async (raw: string) => getListing(/^\d+$/.test(raw) ? Number(raw) : -1));

export async function generateMetadata({ params }: { params: Promise<{ id: string }> }): Promise<Metadata> {
  const item = await load((await params).id).catch(() => null);
  return { title: item ? item.title : 'Listing not found' };
}

export default async function ItemPage({ params }: { params: Promise<{ id: string }> }) {
  const { id } = await params;
  const item = await load(id);
  if (!item) notFound();
  const user = await getCurrentUser();
  const wishlisted = user ? (await getWishlistIds(user.id)).includes(item.id) : false;
  const st = statusInfo(item);
  const isOwner = !!user && item.sellerId === user.id;
  const hasConversations = isOwner ? (await countConversations(item.id)) > 0 : false;

  return (
    <div className="detail-shell">
      <nav className="breadcrumb" aria-label="Breadcrumb">
        <Link href="/marketplace">Marketplace</Link><span className="sep">/</span>
        <Link href={`/marketplace?category=${item.category}`}>{categoryLabel(item.category)}</Link>
      </nav>
      <div className="detail-grid">
        <div className="detail-media">
          <div className="item-media">
            {item.imageUrl ? <Image src={item.imageUrl} alt={item.title} width={800} height={1000} priority sizes="(min-width:1024px) 50vw, 100vw" /> : <div className="item-media-empty">No photo yet</div>}
          </div>
          <span className={`item-type-badge ${st.cls}`}>{st.label}</span>
        </div>
        <div className="detail-info">
          <p className="detail-meta">{categoryLabel(item.category)} · {item.listingType === 'rent' ? 'For rent' : 'For sale'}</p>
          <h1 className="font-display detail-title">{item.title}</h1>
          <div className="detail-price-row">
            <span className="detail-price">{formatPrice(item.price)}</span>
            {item.listingType === 'rent' && <span className="detail-price-unit">per week</span>}
          </div>
          <div className="stat-grid">
            <div className="stat-box"><p className="stat-label">Condition</p><p className="stat-value">{conditionLabel(item.condition)}</p></div>
            <div className="stat-box"><p className="stat-label">Seller</p><p className="stat-value">{item.sellerName}</p></div>
          </div>
          {item.description && <p className="detail-description">{item.description}</p>}
          {st.done && <div className="status-banner" role="status">This item has been {item.status}.</div>}
          <SellerPanel item={item} isOwner={isOwner} wishlisted={wishlisted} hasConversations={hasConversations} />
          <p className="detail-posted">Posted {timeAgo(item.createdAt)}</p>
        </div>
      </div>
    </div>
  );
}

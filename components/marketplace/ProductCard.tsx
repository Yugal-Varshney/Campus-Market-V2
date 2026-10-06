import Image from 'next/image';
import Link from 'next/link';
import { categoryLabel } from '@/lib/constants';
import { formatPrice, statusInfo } from '@/lib/format';
import type { Product } from '@/types';
import WishlistButton from './WishlistButton';

export default function ProductCard({ item, wishlisted, index = 0 }: { item: Product; wishlisted: boolean; index?: number }) {
  const st = statusInfo(item);
  return (
    <article className={`item-card${st.done ? ' is-done' : ''}`} style={{ animationDelay: `${Math.min(index, 8) * 50}ms` }}>
      <div className="item-media-wrap">
        <Link href={`/marketplace/${item.id}`} aria-label={item.title}>
          <div className="item-media">
            {item.imageUrl ? (
              <Image src={item.imageUrl} alt={item.title} width={600} height={750} sizes="(min-width:1280px) 25vw, (min-width:640px) 50vw, 100vw" />
            ) : (
              <div className="item-media-empty">No photo yet</div>
            )}
          </div>
        </Link>
        <span className={`item-type-badge ${st.cls}`}>{st.label}</span>
        <WishlistButton itemId={item.id} initial={wishlisted} />
      </div>
      <div className="item-info">
        <div className="item-info-main">
          <p className="item-category-label">{categoryLabel(item.category)}</p>
          <h3><Link href={`/marketplace/${item.id}`} className="item-title-link">{item.title}</Link></h3>
          <p className="item-seller-line">Listed by: <span>{item.sellerName}</span></p>
        </div>
        <div className="item-price-block">
          <span className="item-price">{formatPrice(item.price)}</span>
          {item.listingType === 'rent' && <span className="item-price-unit">per week</span>}
        </div>
      </div>
    </article>
  );
}

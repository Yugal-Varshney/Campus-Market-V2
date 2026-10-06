import type { Product } from '@/types';
import ProductCard from './ProductCard';

export default function ProductGrid({ items, wishlistIds, cols = 3 }: { items: Product[]; wishlistIds: number[]; cols?: 3 | 4 }) {
  const saved = new Set(wishlistIds);
  return (
    <div className={`item-grid cols-${cols}`}>
      {items.map((item, i) => (
        <ProductCard key={item.id} item={item} wishlisted={saved.has(item.id)} index={i} />
      ))}
    </div>
  );
}

export function GridSkeleton({ count = 6, cols = 3 }: { count?: number; cols?: 3 | 4 }) {
  return (
    <div className={`item-grid cols-${cols}`} aria-busy="true" aria-label="Loading listings">
      {Array.from({ length: count }, (_, i) => (
        <div key={i} className="skeleton-pulse">
          <div className="item-media skeleton" />
          <div className="skeleton" style={{ marginTop: '1rem', height: '1rem', width: '66%' }} />
          <div className="skeleton" style={{ marginTop: '0.5rem', height: '0.75rem', width: '33%' }} />
        </div>
      ))}
    </div>
  );
}

import type { Database } from '@/types/database';
import type { Listing } from '@/types';

type ItemRow = Database['public']['Tables']['items']['Row'];

export const ITEM_COLUMNS =
  'id, seller_id, seller_name, title, description, category, listing_type, price, condition_label, image_url, campus_location, status, created_at';

/** Demo rows store a bare filename ("calculator.jpg"); those live in /public/uploads. */
export function resolveImageUrl(url: string | null): string | null {
  if (!url) return null;
  if (/^https?:\/\//i.test(url)) return url;
  return '/uploads/' + url.replace(/^\/?(\.\.\/)?(uploads\/)?/, '');
}

export function toListing(r: ItemRow): Listing {
  return {
    id: r.id,
    sellerId: r.seller_id,
    sellerName: r.seller_name,
    title: r.title,
    description: r.description,
    category: r.category,
    listingType: r.listing_type,
    price: Number(r.price),
    condition: r.condition_label,
    imageUrl: resolveImageUrl(r.image_url),
    campusLocation: r.campus_location,
    status: r.status,
    createdAt: r.created_at,
  };
}

import type { Listing } from '@/types';

export function formatPrice(price: number | string): string {
  return '₹' + Number(price).toLocaleString('en-IN', { minimumFractionDigits: 0, maximumFractionDigits: 2 });
}

export function timeAgo(iso: string, now: number = Date.now()): string {
  const seconds = Math.max(1, Math.floor((now - new Date(iso).getTime()) / 1000));
  if (seconds < 60) return 'just now';
  const minutes = Math.floor(seconds / 60);
  if (minutes < 60) return `${minutes} min ago`;
  const hours = Math.floor(minutes / 60);
  if (hours < 24) return `${hours} hr ago`;
  const days = Math.floor(hours / 24);
  return days === 1 ? '1 day ago' : `${days} days ago`;
}

/** Label + CSS class for a listing's state (same classes as V1). */
export function statusInfo(item: Pick<Listing, 'status' | 'listingType'>) {
  if (item.status === 'sold') return { label: 'SOLD', cls: 'sold', done: true };
  if (item.status === 'rented') return { label: 'RENTED', cls: 'rented-out', done: true };
  // 'inactive' is set by the database (migration 006); there is no screen that sets it yet.
  if (item.status === 'inactive') return { label: 'UNAVAILABLE', cls: 'sold', done: true };
  if (item.listingType === 'rent') return { label: 'FOR RENT', cls: 'rent', done: false };
  return { label: 'FOR SALE', cls: 'sell', done: false };
}

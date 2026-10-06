'use client';

import { useState, useTransition } from 'react';
import { toggleWishlist } from '@/lib/listings/actions';

export default function WishlistButton({ itemId, initial, className = 'wishlist-btn' }: { itemId: number; initial: boolean; className?: string }) {
  const [saved, setSaved] = useState(initial);
  const [, start] = useTransition();

  const onClick = () => {
    const next = !saved;
    setSaved(next); // optimistic
    start(async () => {
      const res = await toggleWishlist(itemId, next);
      if (res.error) setSaved(!next);
    });
  };

  return (
    <button type="button" className={`${className}${saved ? ' active' : ''}`} onClick={onClick} aria-pressed={saved}
      aria-label={saved ? 'Remove from wishlist' : 'Save to wishlist'}>
      <svg width="20" height="20" viewBox="0 0 24 24" fill={saved ? 'currentColor' : 'none'} stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round" aria-hidden="true">
        <path d="M19 14c1.49-1.46 3-3.21 3-5.5A5.5 5.5 0 0 0 16.5 3c-1.76 0-3 .5-4.5 2-1.5-1.5-2.74-2-4.5-2A5.5 5.5 0 0 0 2 8.5c0 2.29 1.51 4.04 3 5.5l7 7Z" />
      </svg>
    </button>
  );
}

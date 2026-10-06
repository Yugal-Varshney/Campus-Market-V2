'use client';

import Link from 'next/link';
import { useRouter } from 'next/navigation';
import { useState, useTransition } from 'react';
import { deleteListing, revealContact, setListingStatus } from '@/lib/listings/actions';
import { startConversation } from '@/lib/messages/actions';
import type { Listing, SellerContact } from '@/types';
import WishlistButton from '@/components/marketplace/WishlistButton';

/** Owner controls or buyer actions. These checks are UX only — RLS enforces them in the database. */
export default function SellerPanel({ item, isOwner, wishlisted, hasConversations = false }: { item: Listing; isOwner: boolean; wishlisted: boolean; hasConversations?: boolean }) {
  const router = useRouter();
  const [pending, start] = useTransition();
  const [contact, setContact] = useState<SellerContact | null>(null);
  const [error, setError] = useState('');
  const done = item.status !== 'active';
  const doneStatus = item.listingType === 'rent' ? 'rented' : 'sold';

  const run = (fn: () => Promise<{ error?: string } | void>) => {
    setError('');
    start(async () => {
      const res = await fn();
      if (res && res.error) setError(res.error);
      else router.refresh();
    });
  };

  if (isOwner) {
    return (
      <div className="owner-panel">
        <p className="eyebrow">You&apos;re the seller</p>
        <p className="owner-hint">
          {done ? `This listing is marked ${item.status}. Buyers can still see it but can't contact you.` : `Once it's ${doneStatus}, mark it so buyers know.`}
        </p>
        {hasConversations && (
          <p className="owner-hint">This listing has conversations, so it can&apos;t be deleted. Mark it as sold or rented instead — your chats stay intact.</p>
        )}
        <div className="owner-actions">
          {done ? (
            <button type="button" className="btn btn-outline" disabled={pending} onClick={() => run(() => setListingStatus(item.id, 'active'))}>MARK AVAILABLE AGAIN</button>
          ) : (
            <>
              <button type="button" className="btn btn-dark" disabled={pending} onClick={() => run(() => setListingStatus(item.id, doneStatus))}>
                {item.listingType === 'rent' ? 'MARK AS RENTED OUT' : 'MARK AS SOLD'}
              </button>
              <Link href={`/sell/${item.id}/edit`} className="btn btn-outline">EDIT</Link>
            </>
          )}
          {!hasConversations && (
            <button type="button" className="btn btn-outline" disabled={pending}
              onClick={() => window.confirm('Delete this listing permanently?') && run(() => deleteListing(item.id))}>DELETE</button>
          )}
        </div>
        {error && <p className="error-box" role="alert">{error}</p>}
      </div>
    );
  }

  return (
    <>
      {contact && (
        <div className="contact-card">
          <p className="eyebrow">Seller contact</p>
          <p className="contact-line"><span>Name</span><strong>{contact.name}</strong></p>
          <p className="contact-line"><span>Email</span><a href={`mailto:${contact.email}`}>{contact.email}</a></p>
          {contact.phone && <p className="contact-line"><span>Phone</span><a href={`tel:${contact.phone.replace(/[^\d+]/g, '')}`}>{contact.phone}</a></p>}
          <p className="contact-note">Meet on campus and check the item before paying.</p>
        </div>
      )}
      {error && <p className="error-box" role="alert">{error}</p>}
      <div className="detail-actions">
        {!done && !contact && (
          <button type="button" className="btn btn-primary" disabled={pending}
            onClick={() => { setError(''); start(async () => { const r = await revealContact(item.id); r.contact ? setContact(r.contact) : setError(r.error ?? 'Unavailable.'); }); }}>
            CONTACT SELLER
          </button>
        )}
        {!done && item.sellerId && (
          <button type="button" className="btn btn-outline" disabled={pending}
            onClick={() => { setError(''); start(async () => { const r = await startConversation(item.id); r.conversationId ? router.push(`/messages?c=${r.conversationId}`) : setError(r.error ?? 'Could not start a chat.'); }); }}>
            CHAT
          </button>
        )}
        <WishlistButton itemId={item.id} initial={wishlisted} className="detail-wishlist-btn" />
      </div>
    </>
  );
}

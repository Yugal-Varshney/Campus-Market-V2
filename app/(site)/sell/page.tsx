import type { Metadata } from 'next';
import ListingForm from '@/components/forms/ListingForm';
import { createListing } from '@/lib/listings/actions';

export const metadata: Metadata = { title: 'Sell or rent an item' };

export default function SellPage() {
  return (
    <div className="sell-shell">
      <h1 className="font-display">PIN A LISTING</h1>
      <p className="lead">Books, notes, electronics, stationary — post it for your campus in under a minute.</p>
      <ListingForm action={createListing} submitLabel="POST LISTING" />
    </div>
  );
}

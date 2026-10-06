import type { Metadata } from 'next';
import { notFound } from 'next/navigation';
import ListingForm from '@/components/forms/ListingForm';
import { getCurrentUser } from '@/lib/auth/session';
import { updateListing } from '@/lib/listings/actions';
import { getListing } from '@/lib/listings/queries';
import { createClient } from '@/lib/supabase/server';

export const metadata: Metadata = { title: 'Edit listing' };

export default async function EditPage({ params }: { params: Promise<{ id: string }> }) {
  const { id: raw } = await params;
  const id = /^\d+$/.test(raw) ? Number(raw) : -1;
  const [user, item] = await Promise.all([getCurrentUser(), getListing(id)]);
  if (!user || !item || item.sellerId !== user.id) notFound(); // RLS enforces ownership on save too
  const supabase = await createClient();
  const { data: priv } = await supabase.from('item_private').select('contact_phone').eq('item_id', id).maybeSingle();

  return (
    <div className="sell-shell">
      <h1 className="font-display">EDIT LISTING</h1>
      <ListingForm
        action={updateListing.bind(null, id)}
        submitLabel="SAVE CHANGES"
        initial={{ title: item.title, description: item.description, category: item.category, listingType: item.listingType,
          price: item.price, condition: item.condition, phone: priv?.contact_phone ?? '', imageUrl: item.imageUrl }}
      />
    </div>
  );
}

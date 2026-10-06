'use server';

import { redirect } from 'next/navigation';
import { revalidatePath } from 'next/cache';
import { createClient } from '@/lib/supabase/server';
import { getCurrentUser } from '@/lib/auth/session';
import { moderateListing } from '@/lib/moderation';
import { validateListing } from '@/lib/validation/listing';
import { removeImage, storagePathFromUrl, uploadListingImage } from './storage';
import { getSellerContact } from './queries';
import type { ActionState, ListingStatus, SellerContact } from '@/types';

const str = (fd: FormData, k: string) => (typeof fd.get(k) === 'string' ? (fd.get(k) as string) : '');

function readListing(fd: FormData) {
  return validateListing({
    title: str(fd, 'title'),
    description: str(fd, 'description'),
    category: str(fd, 'category'),
    listingType: str(fd, 'listingType'),
    price: Number(str(fd, 'price')),
    condition: str(fd, 'condition'),
    phone: str(fd, 'phone'),
  });
}
const photo = (fd: FormData): File | null => {
  const f = fd.get('photo');
  return f instanceof File && f.size > 0 ? f : null;
};

export async function createListing(_: ActionState, fd: FormData): Promise<ActionState> {
  const user = await getCurrentUser();
  if (!user) return { error: 'You need to sign in to continue.' };

  const { value, error } = readListing(fd);
  if (!value) return { error };
  const file = photo(fd);
  if (!file) return { error: 'Add a photo — real photos get far more replies.' };

  const verdict = await moderateListing(value);
  if (verdict.decision === 'reject') return { error: 'This listing cannot be posted.' };

  const up = await uploadListingImage(user.id, file);
  if (!up.url) return { error: up.error };

  const supabase = await createClient();
  // seller_id / seller_name / status / created_at are forced by the DB trigger, not by this payload.
  const { data: item, error: insertErr } = await supabase
    .from('items')
    .insert({
      title: value.title,
      description: value.description,
      category: value.category,
      listing_type: value.listingType,
      price: value.price,
      condition_label: value.condition,
      image_url: up.url,
    })
    .select('id')
    .single();
  if (insertErr || !item) {
    await removeImage(up.path ?? null);
    return { error: 'Could not post your listing. Please check the fields and try again.' };
  }

  const { error: privErr } = await supabase
    .from('item_private')
    .insert({ item_id: item.id, contact_phone: value.phone });
  if (privErr) {
    await supabase.from('items').delete().eq('id', item.id);
    await removeImage(up.path ?? null);
    return { error: 'Could not save your contact details. Please try again.' };
  }

  revalidatePath('/marketplace');
  redirect(`/marketplace/${item.id}`);
}

export async function updateListing(id: number, _: ActionState, fd: FormData): Promise<ActionState> {
  const user = await getCurrentUser();
  if (!user) return { error: 'You need to sign in to continue.' };
  const { value, error } = readListing(fd);
  if (!value) return { error };

  const supabase = await createClient();
  const { data: current } = await supabase.from('items').select('image_url, status, seller_id').eq('id', id).maybeSingle();
  if (!current || current.seller_id !== user.id) return { error: 'Listing not found.' };
  if (current.status !== 'active') return { error: 'Mark the item available again before editing it.' };

  let imageUrl: string | undefined;
  let newPath: string | undefined;
  const file = photo(fd);
  if (file) {
    const up = await uploadListingImage(user.id, file);
    if (!up.url) return { error: up.error };
    imageUrl = up.url;
    newPath = up.path;
  }

  const { error: upErr } = await supabase
    .from('items')
    .update({
      title: value.title,
      description: value.description,
      category: value.category,
      listing_type: value.listingType,
      price: value.price,
      condition_label: value.condition,
      ...(imageUrl ? { image_url: imageUrl } : {}),
    })
    .eq('id', id)
    .eq('seller_id', user.id);
  if (upErr) {
    await removeImage(newPath ?? null);
    return { error: 'Could not save your changes.' };
  }
  await supabase.from('item_private').update({ contact_phone: value.phone }).eq('item_id', id);
  if (imageUrl) await removeImage(storagePathFromUrl(current.image_url, user.id));

  revalidatePath('/marketplace');
  redirect(`/marketplace/${id}`);
}

/** Status changes are enforced by RLS + CHECK constraints; this just reports the outcome. */
export async function setListingStatus(id: number, status: ListingStatus): Promise<ActionState> {
  const user = await getCurrentUser();
  if (!user) return { error: 'You need to sign in to continue.' };
  const supabase = await createClient();
  const { data, error } = await supabase.from('items').update({ status }).eq('id', id).select('id');
  if (error) return { error: 'That status is not allowed for this listing.' };
  if (!data?.length) return { error: 'Only the seller can change this listing.' };
  revalidatePath('/marketplace');
  revalidatePath(`/marketplace/${id}`);
  return { success: 'Listing updated.' };
}

export async function deleteListing(id: number): Promise<ActionState> {
  const user = await getCurrentUser();
  if (!user) return { error: 'You need to sign in to continue.' };
  const supabase = await createClient();
  const { data: row } = await supabase.from('items').select('image_url').eq('id', id).eq('seller_id', user.id).maybeSingle();
  if (!row) return { error: 'Listing not found.' };
  const { data, error } = await supabase.from('items').delete().eq('id', id).select('id');
  // The database refuses to delete a listing that has conversations (restrict_violation 23001).
  if (error?.code === '23001' || /conversations/i.test(error?.message ?? ''))
    return { error: "This listing has conversations, so it can't be deleted. Mark it as sold or rented instead — your chats stay intact." };
  if (error || !data?.length) return { error: 'Could not delete this listing.' };
  await removeImage(storagePathFromUrl(row.image_url, user.id));
  revalidatePath('/marketplace');
  redirect('/marketplace');
}

export async function toggleWishlist(itemId: number, saved: boolean): Promise<ActionState> {
  const user = await getCurrentUser();
  if (!user) return { error: 'You need to sign in to continue.' };
  const supabase = await createClient();
  const { error } = saved
    ? await supabase.from('wishlists').upsert({ user_id: user.id, item_id: itemId }, { onConflict: 'user_id,item_id', ignoreDuplicates: true })
    : await supabase.from('wishlists').delete().eq('item_id', itemId).eq('user_id', user.id);
  if (error) return { error: 'Could not update your wishlist.' };
  revalidatePath('/wishlist');
  return {};
}

export async function revealContact(itemId: number): Promise<{ contact?: SellerContact; error?: string }> {
  const user = await getCurrentUser();
  if (!user) return { error: 'You need to sign in to continue.' };
  const res = await getSellerContact(itemId);
  return 'error' in res ? { error: res.error } : { contact: res };
}

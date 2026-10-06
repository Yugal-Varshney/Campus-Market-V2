import { ALLOWED_IMAGE_TYPES, CATEGORIES, CONDITIONS, MAX_IMAGE_BYTES, MAX_PRICE } from '@/lib/constants';
import type { Category, Condition, ListingType } from '@/types';

export interface ListingInput {
  title: string;
  description: string;
  category: string;
  listingType: string;
  price: number;
  condition: string;
  phone: string;
}
export interface ValidListing {
  title: string;
  description: string;
  category: Category;
  listingType: ListingType;
  price: number;
  condition: Condition;
  phone: string;
}

export const PHONE_RE = /^[0-9+()\s-]{7,20}$/;

/** Shared by the form (UX) and the server action (enforcement). The DB re-checks too. */
export function validateListing(i: ListingInput): { value?: ValidListing; error?: string } {
  const title = i.title.trim();
  const description = i.description.trim();
  const phone = i.phone.trim();
  if (title.length < 3) return { error: 'Give your listing a clear title (at least 3 characters).' };
  if (title.length > 120) return { error: 'Title must be 120 characters or fewer.' };
  if (description.length > 1000) return { error: 'Description must be 1000 characters or fewer.' };
  if (!Number.isFinite(i.price) || i.price <= 0) return { error: 'Price must be greater than ₹0.' };
  if (i.price > MAX_PRICE) return { error: 'That price looks too high for a campus listing.' };
  if (!CATEGORIES.some((c) => c.value === i.category)) return { error: 'Pick a valid category.' };
  if (i.listingType !== 'sell' && i.listingType !== 'rent')
    return { error: 'Choose whether the item is for sale or for rent.' };
  if (!CONDITIONS.some((c) => c.value === i.condition)) return { error: 'Pick a valid condition.' };
  if (phone && !PHONE_RE.test(phone)) return { error: 'Enter a valid phone number (digits, spaces, + and - only).' };
  return {
    value: {
      title,
      description,
      category: i.category as Category,
      listingType: i.listingType,
      price: Math.round(i.price * 100) / 100,
      condition: i.condition as Condition,
      phone,
    },
  };
}

export function validateImageMeta(file: { type: string; size: number }): string | null {
  if (!(ALLOWED_IMAGE_TYPES as readonly string[]).includes(file.type)) return 'Please pick a JPG, PNG, or WebP image.';
  if (file.size > MAX_IMAGE_BYTES) return `Image must be under ${MAX_IMAGE_BYTES / 1024 / 1024} MB.`;
  return null;
}

/** Server-side: check the real file signature rather than trusting the declared MIME type. */
export function sniffImageType(bytes: Uint8Array): 'image/jpeg' | 'image/png' | 'image/webp' | null {
  if (bytes[0] === 0xff && bytes[1] === 0xd8 && bytes[2] === 0xff) return 'image/jpeg';
  if (bytes[0] === 0x89 && bytes[1] === 0x50 && bytes[2] === 0x4e && bytes[3] === 0x47) return 'image/png';
  if (
    bytes[0] === 0x52 && bytes[1] === 0x49 && bytes[2] === 0x46 && bytes[3] === 0x46 &&
    bytes[8] === 0x57 && bytes[9] === 0x45 && bytes[10] === 0x42 && bytes[11] === 0x50
  ) return 'image/webp';
  return null;
}

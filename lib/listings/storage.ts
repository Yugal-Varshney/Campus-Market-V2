import 'server-only';
import { IMAGE_BUCKET } from '@/lib/constants';
import { createClient } from '@/lib/supabase/server';
import { sniffImageType, validateImageMeta } from '@/lib/validation/listing';

const EXT = { 'image/jpeg': 'jpg', 'image/png': 'png', 'image/webp': 'webp' } as const;

/** Validates the real file contents, then uploads to <user-id>/<timestamp>-<random>.<ext>. */
export async function uploadListingImage(
  userId: string,
  file: File,
): Promise<{ url?: string; path?: string; error?: string }> {
  const meta = validateImageMeta(file);
  if (meta) return { error: meta };
  const bytes = new Uint8Array(await file.arrayBuffer());
  const type = sniffImageType(bytes);
  if (!type) return { error: 'That file does not look like a real JPG, PNG, or WebP image.' };

  const path = `${userId}/${Date.now()}-${crypto.randomUUID().slice(0, 8)}.${EXT[type]}`;
  const supabase = await createClient();
  const { error } = await supabase.storage.from(IMAGE_BUCKET).upload(path, bytes, {
    contentType: type,
    upsert: false,
    cacheControl: '31536000',
  });
  if (error) return { error: 'Photo upload failed. Please try again.' };
  const { data } = supabase.storage.from(IMAGE_BUCKET).getPublicUrl(path);
  return { url: data.publicUrl, path };
}

/** Extract "<uid>/<file>" from one of our public URLs; null for demo/foreign images. */
export function storagePathFromUrl(url: string | null, userId: string): string | null {
  if (!url) return null;
  const marker = `/storage/v1/object/public/${IMAGE_BUCKET}/`;
  const i = url.indexOf(marker);
  if (i === -1) return null;
  const path = decodeURIComponent(url.slice(i + marker.length));
  return path.startsWith(userId + '/') && !path.includes('..') ? path : null;
}

export async function removeImage(path: string | null) {
  if (!path) return;
  const supabase = await createClient();
  await supabase.storage.from(IMAGE_BUCKET).remove([path]); // storage RLS: own folder only
}

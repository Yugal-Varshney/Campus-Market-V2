import { cache } from 'react';
import { createClient } from '@/lib/supabase/server';
import type { Role, User } from '@/types';

/** The verified signed-in user (validated with Supabase Auth), or null. Cached per request. */
export const getCurrentUser = cache(async (): Promise<User | null> => {
  const supabase = await createClient();
  const { data: { user } } = await supabase.auth.getUser();
  if (!user || !user.email) return null;
  const meta = user.user_metadata as { display_name?: string } | null;
  return {
    id: user.id,
    email: user.email,
    displayName: (meta?.display_name || user.email.split('@')[0]).slice(0, 60),
  };
});

export const getCurrentRole = cache(async (): Promise<Role> => {
  const user = await getCurrentUser();
  if (!user) return 'student';
  const supabase = await createClient();
  const { data } = await supabase.from('profiles').select('role').eq('id', user.id).maybeSingle();
  return data?.role ?? 'student';
});

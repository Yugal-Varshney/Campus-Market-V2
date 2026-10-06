'use server';

import { headers } from 'next/headers';
import { redirect } from 'next/navigation';
import { createClient } from '@/lib/supabase/server';
import { safeNext, validateRegistration, isCollegeEmail } from '@/lib/validation/auth';
import { MIN_PASSWORD_LENGTH } from '@/lib/constants';
import type { ActionState } from '@/types';

async function siteUrl(): Promise<string> {
  if (process.env.NEXT_PUBLIC_SITE_URL) return process.env.NEXT_PUBLIC_SITE_URL.replace(/\/$/, '');
  const h = await headers();
  const host = h.get('x-forwarded-host') ?? h.get('host');
  return `${h.get('x-forwarded-proto') ?? 'https'}://${host}`;
}

const str = (fd: FormData, k: string) => (typeof fd.get(k) === 'string' ? (fd.get(k) as string) : '');

export async function login(_: ActionState, fd: FormData): Promise<ActionState> {
  const email = str(fd, 'email').trim();
  const password = str(fd, 'password');
  if (!email || !password) return { error: 'Enter your email and password.' };

  const supabase = await createClient();
  const { error } = await supabase.auth.signInWithPassword({ email, password });
  if (error) {
    if (/not confirmed/i.test(error.message)) return { error: 'Confirm your email first — check your inbox for the link.' };
    return { error: 'Wrong email or password.' };
  }
  redirect(safeNext(str(fd, 'next')));
}

export async function register(_: ActionState, fd: FormData): Promise<ActionState> {
  const name = str(fd, 'name');
  const email = str(fd, 'email').trim();
  const password = str(fd, 'password');
  const problem = validateRegistration({ name, email, password });
  if (problem) return { error: problem };

  const supabase = await createClient();
  const { error } = await supabase.auth.signUp({
    email,
    password,
    options: {
      data: { display_name: name.trim() },
      emailRedirectTo: `${await siteUrl()}/auth/callback?next=/marketplace`,
    },
  });
  if (error) {
    // The DB trigger on auth.users enforces the college rules even if this check is bypassed.
    if (/college|approved|\.edu/i.test(error.message)) return { error: error.message };
    if (/already/i.test(error.message)) return { error: 'An account with this email already exists. Try signing in.' };
    return { error: 'Could not create your account. Please try again.' };
  }
  return { success: 'We sent a confirmation link to your college email. Click it, then sign in.' };
}

export async function logout() {
  const supabase = await createClient();
  await supabase.auth.signOut();
  redirect('/login');
}

export async function requestPasswordReset(_: ActionState, fd: FormData): Promise<ActionState> {
  const email = str(fd, 'email').trim();
  if (!isCollegeEmail(email)) return { error: 'Enter your college email above first.' };
  const supabase = await createClient();
  await supabase.auth.resetPasswordForEmail(email, {
    redirectTo: `${await siteUrl()}/auth/callback?next=/reset-password`,
  });
  // Same message whether or not the account exists (no account enumeration).
  return { success: 'If that account exists, a reset link is on its way to your inbox.' };
}

export async function updatePassword(_: ActionState, fd: FormData): Promise<ActionState> {
  const password = str(fd, 'password');
  if (password.length < MIN_PASSWORD_LENGTH) return { error: `Password must be at least ${MIN_PASSWORD_LENGTH} characters.` };
  if (password.length > 72) return { error: 'Password must be 72 characters or fewer.' };
  const supabase = await createClient();
  const { data: { user } } = await supabase.auth.getUser();
  if (!user) return { error: 'This reset link has expired. Request a new one from the sign-in page.' };
  const { error } = await supabase.auth.updateUser({ password });
  if (error) return { error: 'Could not update your password. Try a different one.' };
  redirect('/marketplace');
}

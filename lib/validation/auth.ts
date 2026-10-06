import { MIN_PASSWORD_LENGTH } from '@/lib/constants';

/**
 * Format check only: proves the address LOOKS like a college address, not that the user
 * belongs to a particular college. The database re-checks this (and an optional
 * allowed_email_domains allow-list) in a trigger on auth.users — see supabase/migrations/002.
 */
export const COLLEGE_EMAIL_RE = /@[^@\s]+\.(edu(\.[a-z]{2})?|ac\.[a-z]{2})$/i;

export const isCollegeEmail = (email: string) => COLLEGE_EMAIL_RE.test(email.trim());

export function validateRegistration(input: { name: string; email: string; password: string }): string | null {
  if (!input.name.trim()) return 'Tell us your name so buyers and sellers know who you are.';
  if (input.name.trim().length > 60) return 'Name must be 60 characters or fewer.';
  if (!isCollegeEmail(input.email))
    return 'Use your college email — it must include .edu or .ac. (e.g. alex@college.edu or alex@iitb.ac.in).';
  if (input.password.length < MIN_PASSWORD_LENGTH) return `Password must be at least ${MIN_PASSWORD_LENGTH} characters.`;
  if (input.password.length > 72) return 'Password must be 72 characters or fewer.';
  return null;
}

/** Only allow same-site relative redirects (prevents open-redirect via ?next=). */
export function safeNext(next: unknown, fallback = '/marketplace'): string {
  if (typeof next !== 'string' || !next.startsWith('/') || next.startsWith('//') || next.includes('\\')) return fallback;
  return next;
}

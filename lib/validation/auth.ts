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

/**
 * Only allow same-site relative redirects (prevents open-redirect via ?next=).
 * Rejects control characters and whitespace as well: browsers silently strip tabs and newlines
 * from URLs, so "/\t/evil.com" could otherwise be read as "//evil.com".
 */
export function safeNext(next: unknown, fallback = '/marketplace'): string {
  if (typeof next !== 'string' || next.length > 2000) return fallback;
  if (!next.startsWith('/') || next.startsWith('//')) return fallback;
  if (/[\\\u0000-\u001f\u007f\s]/.test(next)) return fallback;
  try {
    // Must still resolve to the same origin once a URL parser has had its say.
    if (new URL(next, 'http://campus.invalid').origin !== 'http://campus.invalid') return fallback;
  } catch {
    return fallback;
  }
  return next;
}

/**
 * Email link types the callback accepts for the token-hash flow (works even when the link is opened
 * in a different browser or device than the one that requested it, unlike the PKCE `code` flow).
 */
export const OTP_TYPES = ['signup', 'email', 'recovery', 'email_change'] as const;
export type OtpType = (typeof OTP_TYPES)[number];

export function parseOtpType(value: unknown): OtpType | null {
  return typeof value === 'string' && (OTP_TYPES as readonly string[]).includes(value) ? (value as OtpType) : null;
}

import { NextResponse, type NextRequest } from 'next/server';
import { createClient } from '@/lib/supabase/server';
import { parseOtpType, safeNext } from '@/lib/validation/auth';

/**
 * Email confirmation + password-reset links land here. Two link styles are supported:
 *   1. ?token_hash=...&type=signup|email|recovery|email_change  (token-hash flow; works across devices;
 *      needs the email templates in docs/PHASE3_SUPABASE_RUNBOOK.md)
 *   2. ?code=...                                                (PKCE flow; the Supabase default; must be
 *                                                                opened in the same browser that asked for it)
 * Anything else, or a failed exchange, sends the user to /login?error=link.
 */
export async function GET(request: NextRequest) {
  const { searchParams, origin } = request.nextUrl;
  const next = safeNext(searchParams.get('next'));
  const tokenHash = searchParams.get('token_hash');
  const otpType = parseOtpType(searchParams.get('type'));
  const code = searchParams.get('code');

  const supabase = await createClient();

  if (tokenHash && otpType) {
    const { error } = await supabase.auth.verifyOtp({ type: otpType, token_hash: tokenHash });
    if (!error) return NextResponse.redirect(`${origin}${next}`);
  } else if (code) {
    const { error } = await supabase.auth.exchangeCodeForSession(code);
    if (!error) return NextResponse.redirect(`${origin}${next}`);
  }
  return NextResponse.redirect(`${origin}/login?error=link`);
}

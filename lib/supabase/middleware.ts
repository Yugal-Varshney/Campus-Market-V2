import { createServerClient } from '@supabase/ssr';
import { NextResponse, type NextRequest } from 'next/server';
import type { Database } from '@/types/database';

const ALWAYS_PROTECTED = ['/sell', '/wishlist', '/messages', '/profile'];
const AUTH_PAGES = ['/login', '/register'];

/** Refreshes the auth cookie on every request and redirects based on sign-in state. */
export async function updateSession(request: NextRequest) {
  let response = NextResponse.next({ request });

  const supabase = createServerClient<Database>(
    process.env.NEXT_PUBLIC_SUPABASE_URL!,
    process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY!,
    {
      cookies: {
        getAll: () => request.cookies.getAll(),
        setAll: (toSet) => {
          toSet.forEach(({ name, value }) => request.cookies.set(name, value));
          response = NextResponse.next({ request });
          toSet.forEach(({ name, value, options }) => response.cookies.set(name, value, options));
        },
      },
    },
  );

  // getUser() validates the token with Supabase Auth (getSession() would trust the cookie).
  const { data: { user } } = await supabase.auth.getUser();
  const path = request.nextUrl.pathname;
  const requireLoginToBrowse = process.env.REQUIRE_LOGIN_TO_BROWSE !== 'false';

  const protectedPath =
    ALWAYS_PROTECTED.some((p) => path === p || path.startsWith(p + '/')) ||
    (requireLoginToBrowse && (path === '/marketplace' || path.startsWith('/marketplace/')));

  const redirectTo = (to: string, withNext = false) => {
    const url = request.nextUrl.clone();
    url.pathname = to;
    url.search = '';
    if (withNext) url.searchParams.set('next', path + request.nextUrl.search);
    const redirect = NextResponse.redirect(url);
    response.cookies.getAll().forEach((c) => redirect.cookies.set(c));
    return redirect;
  };

  if (!user && protectedPath) return redirectTo('/login', true);
  if (user && AUTH_PAGES.includes(path)) return redirectTo('/marketplace');
  return response;
}

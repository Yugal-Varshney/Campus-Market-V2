import type { Metadata } from 'next';
import LoginForm from '@/components/forms/LoginForm';
import { safeNext } from '@/lib/validation/auth';

export const metadata: Metadata = { title: 'Sign in' };

export default async function LoginPage({ searchParams }: { searchParams: Promise<{ next?: string; error?: string }> }) {
  const sp = await searchParams;
  return (
    <div className="auth-shell">
      <h1 className="font-display">WELCOME BACK</h1>
      <p className="lead">Campus Market is for students only — your college email is your pass.</p>
      <LoginForm next={sp.next ? safeNext(sp.next) : undefined} linkError={sp.error === 'link'} />
    </div>
  );
}

import type { Metadata } from 'next';
import Link from 'next/link';
import ResetPasswordForm from '@/components/forms/ResetPasswordForm';
import { getCurrentUser } from '@/lib/auth/session';

export const metadata: Metadata = { title: 'New password' };

export default async function ResetPasswordPage() {
  const user = await getCurrentUser(); // set by /auth/callback after the emailed link is opened
  return (
    <div className="auth-shell">
      <h1 className="font-display">NEW PASSWORD</h1>
      {user ? (
        <>
          <p className="lead">Choose a new password for {user.email}.</p>
          <ResetPasswordForm />
        </>
      ) : (
        <div className="error-box" role="alert">
          You need to sign in to continue. Open this page from the link in your reset email, or <Link href="/login" style={{ textDecoration: 'underline' }}>request a new one</Link>.
        </div>
      )}
    </div>
  );
}

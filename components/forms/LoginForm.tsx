'use client';

import Link from 'next/link';
import { useActionState } from 'react';
import { login, requestPasswordReset } from '@/lib/auth/actions';
import type { ActionState } from '@/types';

const initial: ActionState = {};

export default function LoginForm({ next, linkError }: { next?: string; linkError?: boolean }) {
  const [state, action, pending] = useActionState(login, initial);
  const [reset, resetAction, resetPending] = useActionState(requestPasswordReset, initial);

  return (
    <>
      {linkError && <p className="error-box" role="alert">That link has expired or was already used. Sign in, or request a new reset link.</p>}
      <form action={action} className="auth-form">
        <input type="hidden" name="next" value={next ?? ''} />
        <div>
          <label className="field-label" htmlFor="login-email">College Email</label>
          <input id="login-email" name="email" type="email" className="field-input" placeholder="alex@college.edu" maxLength={255} autoComplete="email" required />
        </div>
        <div>
          <label className="field-label" htmlFor="login-password">Password</label>
          <input id="login-password" name="password" type="password" className="field-input" placeholder="Your password" maxLength={72} autoComplete="current-password" required />
        </div>
        {state.error && <p className="error-box" role="alert">{state.error}</p>}
        {reset.error && <p className="error-box" role="alert">{reset.error}</p>}
        {reset.success && <p className="success-box" role="status">{reset.success}</p>}
        <button type="submit" className="btn btn-primary" style={{ width: '100%' }} disabled={pending}>{pending ? 'SIGNING IN…' : 'SIGN IN'}</button>
        <button type="submit" formAction={resetAction} formNoValidate className="link-btn" disabled={resetPending}>
          {resetPending ? 'Sending…' : 'Forgot password? (enter your email above)'}
        </button>
      </form>
      <p className="field-hint" style={{ marginTop: '1rem' }}>New here? <Link href="/register" style={{ textDecoration: 'underline' }}>Create an account</Link></p>
    </>
  );
}

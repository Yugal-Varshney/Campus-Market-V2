'use client';

import Link from 'next/link';
import { useActionState } from 'react';
import { register } from '@/lib/auth/actions';
import { MIN_PASSWORD_LENGTH } from '@/lib/constants';
import type { ActionState } from '@/types';

export default function RegisterForm() {
  const [state, action, pending] = useActionState(register, {} as ActionState);

  if (state.success) {
    return (
      <div className="info-box" role="status">
        <h2 className="font-display">CHECK YOUR INBOX</h2>
        <p>{state.success} <Link href="/login" style={{ textDecoration: 'underline' }}>Sign in</Link></p>
      </div>
    );
  }
  return (
    <form action={action} className="auth-form">
      <div>
        <label className="field-label" htmlFor="register-name">Full Name</label>
        <input id="register-name" name="name" type="text" className="field-input" placeholder="Alex Sharma" maxLength={60} autoComplete="name" required />
      </div>
      <div>
        <label className="field-label" htmlFor="register-email">College Email</label>
        <input id="register-email" name="email" type="email" className="field-input" placeholder="alex@college.edu" maxLength={255} autoComplete="email" required aria-describedby="email-hint" />
        <p id="email-hint" className="field-hint">Must end in .edu or .ac.xx (e.g. .ac.in). We email you a confirmation link — it keeps the marketplace student-only.</p>
      </div>
      <div>
        <label className="field-label" htmlFor="register-password">Password</label>
        <input id="register-password" name="password" type="password" className="field-input" placeholder={`At least ${MIN_PASSWORD_LENGTH} characters`} minLength={MIN_PASSWORD_LENGTH} maxLength={72} autoComplete="new-password" required />
      </div>
      {state.error && <p className="error-box" role="alert">{state.error}</p>}
      <button type="submit" className="btn btn-primary" style={{ width: '100%' }} disabled={pending}>{pending ? 'CREATING…' : 'CREATE ACCOUNT'}</button>
      <p className="field-hint">Already registered? <Link href="/login" style={{ textDecoration: 'underline' }}>Sign in</Link></p>
    </form>
  );
}

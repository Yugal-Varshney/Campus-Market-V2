'use client';

import { useActionState } from 'react';
import { updatePassword } from '@/lib/auth/actions';
import { MIN_PASSWORD_LENGTH } from '@/lib/constants';
import type { ActionState } from '@/types';

export default function ResetPasswordForm() {
  const [state, action, pending] = useActionState(updatePassword, {} as ActionState);
  return (
    <form action={action} className="auth-form">
      <div>
        <label className="field-label" htmlFor="reset-password">New Password</label>
        <input id="reset-password" name="password" type="password" className="field-input" placeholder={`At least ${MIN_PASSWORD_LENGTH} characters`} minLength={MIN_PASSWORD_LENGTH} maxLength={72} autoComplete="new-password" required />
      </div>
      {state.error && <p className="error-box" role="alert">{state.error}</p>}
      <button type="submit" className="btn btn-primary" style={{ width: '100%' }} disabled={pending}>{pending ? 'SAVING…' : 'SAVE PASSWORD'}</button>
    </form>
  );
}

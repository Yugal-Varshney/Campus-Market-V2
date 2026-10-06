import type { Metadata } from 'next';
import RegisterForm from '@/components/forms/RegisterForm';

export const metadata: Metadata = { title: 'Join the board' };

export default function RegisterPage() {
  return (
    <div className="auth-shell">
      <h1 className="font-display">JOIN THE BOARD</h1>
      <p className="lead">Campus Market is for students only — your college email is your pass.</p>
      <RegisterForm />
    </div>
  );
}

'use client';

import Link from 'next/link';
import { useEffect, useRef, useState } from 'react';
import { logout } from '@/lib/auth/actions';

export default function UserMenu({ email, name }: { email: string; name: string }) {
  const [open, setOpen] = useState(false);
  const ref = useRef<HTMLDivElement>(null);

  useEffect(() => {
    if (!open) return;
    const onDown = (e: MouseEvent) => !ref.current?.contains(e.target as Node) && setOpen(false);
    const onKey = (e: KeyboardEvent) => e.key === 'Escape' && setOpen(false);
    document.addEventListener('mousedown', onDown);
    document.addEventListener('keydown', onKey);
    return () => {
      document.removeEventListener('mousedown', onDown);
      document.removeEventListener('keydown', onKey);
    };
  }, [open]);

  return (
    <div className={`user-menu${open ? ' open' : ''}`} ref={ref}>
      <button type="button" className="user-avatar" aria-haspopup="menu" aria-expanded={open} aria-label="Account menu" onClick={() => setOpen((o) => !o)}>
        {(name || email).charAt(0)}
      </button>
      <div className="user-dropdown" role="menu">
        <p className="user-dropdown-email">{email}</p>
        <Link href="/profile" className="user-dropdown-item" role="menuitem" onClick={() => setOpen(false)}>My Profile</Link>
        <Link href="/wishlist" className="user-dropdown-item" role="menuitem" onClick={() => setOpen(false)}>My Wishlist</Link>
        <Link href="/messages" className="user-dropdown-item" role="menuitem" onClick={() => setOpen(false)}>Messages</Link>
        <form action={logout}>
          <button type="submit" className="user-dropdown-item danger" role="menuitem" style={{ width: '100%', textAlign: 'left' }}>Sign out</button>
        </form>
      </div>
    </div>
  );
}

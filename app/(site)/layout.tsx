import Navbar from '@/components/Navbar';
import Footer from '@/components/Footer';
import { getCurrentUser } from '@/lib/auth/session';
import Link from 'next/link';

export default async function SiteLayout({ children }: { children: React.ReactNode }) {
  const user = await getCurrentUser();
  return (
    <>
      <Navbar />
      <main id="main">{children}</main>
      <Footer />
      {user && (
        <Link href="/messages" className="chat-dock font-display visible" aria-label="Open messages">CHAT</Link>
      )}
    </>
  );
}

import Link from 'next/link';

export default function NotFound() {
  return (
    <div className="not-found-shell">
      <h1 className="font-display">PAGE NOT FOUND</h1>
      <p>That page isn&apos;t on the board.</p>
      <Link href="/marketplace" className="btn btn-dark">Back to the Board</Link>
    </div>
  );
}

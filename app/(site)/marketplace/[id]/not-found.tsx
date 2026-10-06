import Link from 'next/link';

export default function NotFound() {
  return (
    <div className="not-found-shell">
      <h1 className="font-display">LISTING NOT FOUND</h1>
      <p>Listing not found. It may have been taken off the board.</p>
      <Link href="/marketplace" className="btn btn-dark">Back to the Board</Link>
    </div>
  );
}

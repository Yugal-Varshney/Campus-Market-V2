import { GridSkeleton } from '@/components/marketplace/ProductGrid';

export default function Loading() {
  return (
    <div className="browse-grid">
      <aside className="browse-sidebar" />
      <section className="browse-main">
        <header className="listings-header"><h1 className="font-display">LATEST LISTINGS</h1></header>
        <p className="sr-only" role="status">Loading listings...</p>
        <GridSkeleton />
      </section>
    </div>
  );
}

export default function Loading() {
  return (
    <div className="detail-shell" aria-busy="true">
      <p className="sr-only" role="status">Loading listing...</p>
      <div className="skeleton" style={{ height: '1rem', width: '12rem' }} />
      <div className="detail-grid" style={{ marginTop: '1.5rem' }}>
        <div className="item-media skeleton" />
        <div style={{ display: 'flex', flexDirection: 'column', gap: '1rem' }}>
          <div className="skeleton" style={{ height: '2.5rem', width: '66%' }} />
          <div className="skeleton" style={{ height: '1.5rem', width: '33%' }} />
          <div className="skeleton" style={{ height: '8rem', width: '100%' }} />
        </div>
      </div>
    </div>
  );
}

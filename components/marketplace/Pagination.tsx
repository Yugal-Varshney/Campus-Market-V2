import Link from 'next/link';

export default function Pagination({ page, total, pageSize, params }: { page: number; total: number; pageSize: number; params: Record<string, string | undefined> }) {
  const pages = Math.max(1, Math.ceil(total / pageSize));
  if (pages <= 1) return null;
  const href = (n: number) => {
    const p = new URLSearchParams();
    Object.entries(params).forEach(([k, v]) => v && p.set(k, v));
    if (n > 1) p.set('page', String(n));
    const qs = p.toString();
    return qs ? `/marketplace?${qs}` : '/marketplace';
  };
  return (
    <nav className="pagination" aria-label="Pagination">
      <Link className="btn btn-outline" href={href(page - 1)} aria-disabled={page <= 1} tabIndex={page <= 1 ? -1 : 0}>← Prev</Link>
      <span aria-current="page">Page {page} of {pages}</span>
      <Link className="btn btn-outline" href={href(page + 1)} aria-disabled={page >= pages} tabIndex={page >= pages ? -1 : 0}>Next →</Link>
    </nav>
  );
}

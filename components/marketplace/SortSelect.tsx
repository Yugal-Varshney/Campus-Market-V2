'use client';

import { usePathname, useRouter, useSearchParams } from 'next/navigation';
import { SORTS } from '@/lib/constants';

export default function SortSelect() {
  const router = useRouter();
  const pathname = usePathname();
  const params = useSearchParams();
  return (
    <select className="sort-select" aria-label="Sort listings" value={params.get('sort') ?? 'newest'}
      onChange={(e) => {
        const p = new URLSearchParams(params.toString());
        p.set('sort', e.target.value);
        p.delete('page');
        router.push(`${pathname}?${p.toString()}`);
      }}>
      {SORTS.map((s) => <option key={s.value} value={s.value}>{s.label}</option>)}
    </select>
  );
}

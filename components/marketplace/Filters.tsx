'use client';

import { useEffect, useRef, useState } from 'react';
import { usePathname, useRouter, useSearchParams } from 'next/navigation';
import { CATEGORIES, PRICE_SLIDER_MAX } from '@/lib/constants';
import { formatPrice } from '@/lib/format';

/** Filters live in the URL (?category=&maxPrice=) so results are server-rendered, shareable and paginated. */
export default function Filters() {
  const router = useRouter();
  const pathname = usePathname();
  const params = useSearchParams();

  const selected = (params.get('category') ?? '').split(',').filter(Boolean);
  const urlMax = params.get('maxPrice');
  const [max, setMax] = useState(urlMax ? Math.min(Number(urlMax), PRICE_SLIDER_MAX) : PRICE_SLIDER_MAX);
  const first = useRef(true);

  const push = (mutate: (p: URLSearchParams) => void) => {
    const p = new URLSearchParams(params.toString());
    mutate(p);
    p.delete('page');
    const qs = p.toString();
    router.push(qs ? `${pathname}?${qs}` : pathname);
  };

  // Debounce the slider so dragging doesn't fire a query per pixel.
  useEffect(() => {
    if (first.current) { first.current = false; return; }
    const t = setTimeout(() => push((p) => (max >= PRICE_SLIDER_MAX ? p.delete('maxPrice') : p.set('maxPrice', String(max)))), 400);
    return () => clearTimeout(t);
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [max]);

  useEffect(() => { // keep slider in sync when "Clear filters" resets the URL
    setMax(urlMax ? Math.min(Number(urlMax), PRICE_SLIDER_MAX) : PRICE_SLIDER_MAX);
  }, [urlMax]);

  const toggle = (value: string) =>
    push((p) => {
      const next = selected.includes(value) ? selected.filter((v) => v !== value) : [...selected, value];
      if (next.length) p.set('category', next.join(',')); else p.delete('category');
    });

  return (
    <aside className="browse-sidebar" aria-label="Filters">
      <div className="sidebar-sticky">
        <section>
          <h3 className="filter-section-title">Category</h3>
          <div className="filter-list">
            {CATEGORIES.map((c) => (
              <label key={c.value} className="checkbox-row">
                <input type="checkbox" checked={selected.includes(c.value)} onChange={() => toggle(c.value)} />
                <span>{c.label}</span>
              </label>
            ))}
          </div>
        </section>
        <section>
          <h3 className="filter-section-title"><label htmlFor="price-range">Price Range</label></h3>
          <div className="price-range-wrap">
            <input id="price-range" type="range" min={0} max={PRICE_SLIDER_MAX} step={50} value={max}
              onChange={(e) => setMax(Number(e.target.value))} aria-valuetext={max >= PRICE_SLIDER_MAX ? 'No maximum' : `Up to ${formatPrice(max)}`} />
            <div className="price-range-labels">
              <span>₹0</span>
              <span className="current">{max >= PRICE_SLIDER_MAX ? 'any price' : `up to ${formatPrice(max)}`}</span>
              <span>₹5,000+</span>
            </div>
          </div>
        </section>
      </div>
    </aside>
  );
}

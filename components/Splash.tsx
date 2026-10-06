'use client';

import { useCallback, useEffect, useRef, useState } from 'react';
import { useRouter } from 'next/navigation';

const SHOW_MS = 4500; // keep in sync with --splash-ms in globals.css
const FADE_MS = 450;

/** The V1 4.5-second landing splash, now a React component. Skippable with click/Esc/Enter/Space. */
export default function Splash() {
  const router = useRouter();
  const [running, setRunning] = useState(false);
  const [leaving, setLeaving] = useState(false);
  const left = useRef(false);
  const imgRef = useRef<HTMLImageElement>(null);

  const go = useCallback(() => {
    if (left.current) return;
    left.current = true;
    setLeaving(true);
    setTimeout(() => router.replace('/marketplace'), FADE_MS);
  }, [router]);

  useEffect(() => {
    let timer: ReturnType<typeof setTimeout> | undefined;
    const start = () => {
      setRunning(true);
      timer = setTimeout(go, SHOW_MS);
    };
    const img = imgRef.current;
    const safety = setTimeout(() => !timer && go(), 8000);
    if (img?.complete && img.naturalWidth) start();
    else img?.addEventListener('load', start, { once: true });
    const onKey = (e: KeyboardEvent) => ['Escape', 'Enter', ' '].includes(e.key) && go();
    document.addEventListener('keydown', onKey);
    return () => {
      clearTimeout(timer);
      clearTimeout(safety);
      img?.removeEventListener('load', start);
      document.removeEventListener('keydown', onKey);
    };
  }, [go]);

  return (
    <div className={`splash${running ? ' running' : ''}${leaving ? ' leaving' : ''}`} id="splash">
      {/* eslint-disable-next-line @next/next/no-img-element */}
      <img className="bg" src="/images/cmbg.png" alt="" aria-hidden="true" />
      {/* eslint-disable-next-line @next/next/no-img-element */}
      <img
        ref={imgRef}
        className="fg"
        src="/images/cmbg.png"
        onError={go}
        alt="Campus Market — Buy, Sell, Trade, Connect. Everything you need, right here on campus."
      />
      <button type="button" className="skip" onClick={go}>Skip</button>
      <div className="bar"><i /></div>
    </div>
  );
}

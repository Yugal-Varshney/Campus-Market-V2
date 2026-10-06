'use client';

export default function GlobalError({ reset }: { error: Error; reset: () => void }) {
  return (
    <div className="not-found-shell" role="alert">
      <h1 className="font-display">SOMETHING BROKE</h1>
      <p>Something went wrong on our side. Please try again.</p>
      <button type="button" className="btn btn-dark" onClick={reset}>Try again</button>
    </div>
  );
}

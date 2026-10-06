'use client';

import { useActionState, useRef, useState } from 'react';
import { CATEGORIES, CONDITIONS, MAX_PRICE } from '@/lib/constants';
import { compressImage } from '@/lib/image-compress';
import { validateImageMeta, validateListing } from '@/lib/validation/listing';
import type { ActionState, ListingType } from '@/types';

export interface ListingFormInitial {
  title: string; description: string; category: string; listingType: ListingType;
  price: number; condition: string; phone: string; imageUrl: string | null;
}
type Action = (prev: ActionState, fd: FormData) => Promise<ActionState>;

export default function ListingForm({ action, initial, submitLabel }: { action: Action; initial?: ListingFormInitial; submitLabel: string }) {
  const [state, formAction, pending] = useActionState(action, {} as ActionState);
  const [mode, setMode] = useState<ListingType>(initial?.listingType ?? 'sell');
  const [preview, setPreview] = useState<string | null>(initial?.imageUrl ?? null);
  const [clientError, setClientError] = useState('');
  const fileRef = useRef<HTMLInputElement>(null);
  const editing = !!initial;

  async function onPhoto(e: React.ChangeEvent<HTMLInputElement>) {
    const input = e.currentTarget;
    const original = input.files?.[0];
    if (!original) return;
    const file = await compressImage(original);
    const problem = validateImageMeta(file);
    if (problem) { setClientError(problem); input.value = ''; setPreview(initial?.imageUrl ?? null); return; }
    setClientError('');
    const dt = new DataTransfer();
    dt.items.add(file);
    input.files = dt.files;
    setPreview(URL.createObjectURL(file));
  }

  function onSubmit(e: React.FormEvent<HTMLFormElement>) {
    const fd = new FormData(e.currentTarget);
    const { error } = validateListing({
      title: String(fd.get('title') ?? ''), description: String(fd.get('description') ?? ''),
      category: String(fd.get('category') ?? ''), listingType: mode,
      price: Number(fd.get('price')), condition: String(fd.get('condition') ?? ''), phone: String(fd.get('phone') ?? ''),
    });
    const photo = fd.get('photo');
    const hasPhoto = photo instanceof File && photo.size > 0;
    const msg = error ?? (!editing && !hasPhoto ? 'Add a photo — real photos get far more replies.' : '');
    if (msg) { e.preventDefault(); setClientError(msg); } else setClientError('');
  }

  const error = clientError || state.error;
  return (
    <form action={formAction} onSubmit={onSubmit} className="sell-grid" noValidate>
      <div className="sell-form-col">
        <fieldset style={{ border: 0, padding: 0 }}>
          <legend className="field-label">Is this item for sale or for rent?</legend>
          <input type="hidden" name="listingType" value={mode} />
          <div className="mode-toggle">
            {(['sell', 'rent'] as const).map((m) => (
              <button key={m} type="button" className={`mode-btn${mode === m ? ' active' : ''}`} aria-pressed={mode === m} onClick={() => setMode(m)}>
                {m === 'sell' ? 'FOR SALE' : 'FOR RENT'}
              </button>
            ))}
          </div>
        </fieldset>
        <div>
          <label className="field-label" htmlFor="sell-title">Title</label>
          <input id="sell-title" name="title" className="field-input" defaultValue={initial?.title} placeholder="e.g. Organic Chemistry 3rd Ed — highlighted" minLength={3} maxLength={120} />
        </div>
        <div>
          <label className="field-label" htmlFor="sell-description">Description</label>
          <textarea id="sell-description" name="description" className="field-input" rows={4} maxLength={1000} defaultValue={initial?.description} placeholder="Condition details, what's included, pickup spot on campus…" />
        </div>
        <div className="field-row-2">
          <div>
            <label className="field-label" htmlFor="sell-price">{mode === 'rent' ? 'Price per week' : 'Price'}</label>
            <div className="price-input-wrap">
              <span className="dollar" aria-hidden="true">₹</span>
              <input id="sell-price" name="price" type="number" inputMode="decimal" className="field-input" defaultValue={initial?.price} placeholder="250" min={1} max={MAX_PRICE} step="1" />
            </div>
          </div>
          <div>
            <label className="field-label" htmlFor="sell-condition">Condition</label>
            <select id="sell-condition" name="condition" className="field-input" defaultValue={initial?.condition ?? 'good'}>
              {CONDITIONS.map((c) => <option key={c.value} value={c.value}>{c.label}</option>)}
            </select>
          </div>
        </div>
        <div className="field-row-2">
          <div>
            <label className="field-label" htmlFor="sell-category">Category</label>
            <select id="sell-category" name="category" className="field-input" defaultValue={initial?.category ?? 'books'}>
              {CATEGORIES.map((c) => <option key={c.value} value={c.value}>{c.label}</option>)}
            </select>
          </div>
          <div>
            <label className="field-label" htmlFor="sell-phone">Your phone (optional)</label>
            <input id="sell-phone" name="phone" type="tel" className="field-input" defaultValue={initial?.phone} placeholder="+91 98765 43210" maxLength={20} autoComplete="tel" />
          </div>
        </div>
        <p className="field-hint">Buyers see your college email and this phone number when they tap &quot;Contact Seller&quot;.</p>
        {error && <p className="error-box" role="alert">{error}</p>}
        <button type="submit" className="btn btn-primary" style={{ width: '100%' }} disabled={pending}>{pending ? 'SAVING…' : submitLabel}</button>
      </div>

      <div>
        <label className="field-label" htmlFor="sell-photo">Photo</label>
        <input ref={fileRef} id="sell-photo" name="photo" type="file" accept="image/jpeg,image/png,image/webp" className="sr-only" onChange={onPhoto} />
        {preview ? (
          <div className="photo-preview-wrap">
            {/* eslint-disable-next-line @next/next/no-img-element */}
            <img src={preview} alt="Preview of your listing photo" />
            <button type="button" className="btn btn-outline btn-sm" style={{ margin: '0.5rem' }} onClick={() => fileRef.current?.click()}>Change photo</button>
          </div>
        ) : (
          <button type="button" className="photo-drop" onClick={() => fileRef.current?.click()}>
            <span className="headline">ADD A PHOTO</span>
            <span className="sub">JPG, PNG, WebP · up to 4MB</span>
          </button>
        )}
        <div className="etiquette-box">
          <p className="eyebrow">Board etiquette</p>
          <p>Real photos get 3× more replies. Listings stay on the board until you mark them sold or rented. Meet on campus and verify items before paying.</p>
        </div>
      </div>
    </form>
  );
}

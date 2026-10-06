'use client';

import Link from 'next/link';
import { useEffect, useRef, useState, useTransition } from 'react';
import { createClient } from '@/lib/supabase/client';
import { sendMessage } from '@/lib/messages/actions';
import type { Message } from '@/types';
import MessageBubble from './MessageBubble';

interface Props { conversationId: number; userId: string; title: string; otherParty: string; itemId: number; initialMessages: Message[] }

/** Messages arrive over Supabase Realtime (postgres_changes) — no polling. RLS decides who receives each row. */
export default function ChatWindow({ conversationId, userId, title, otherParty, itemId, initialMessages }: Props) {
  const [messages, setMessages] = useState<Message[]>(initialMessages);
  const [draft, setDraft] = useState('');
  const [error, setError] = useState('');
  const [live, setLive] = useState(true);
  const [pending, start] = useTransition();
  const threadRef = useRef<HTMLDivElement>(null);

  const add = (m: Message) => setMessages((prev) => (prev.some((x) => x.id === m.id) ? prev : [...prev, m]));

  useEffect(() => {
    const supabase = createClient();
    const channel = supabase
      .channel(`chat:${conversationId}`)
      .on('postgres_changes', { event: 'INSERT', schema: 'public', table: 'messages', filter: `conversation_id=eq.${conversationId}` },
        (payload) => {
          const r = payload.new as { id: number; conversation_id: number; sender_id: string; body: string; created_at: string };
          add({ id: r.id, conversationId: r.conversation_id, senderId: r.sender_id, body: r.body, createdAt: r.created_at });
        })
      .subscribe((status) => setLive(status !== 'CHANNEL_ERROR' && status !== 'TIMED_OUT'));
    return () => { supabase.removeChannel(channel); };
  }, [conversationId]);

  useEffect(() => { threadRef.current?.scrollTo({ top: threadRef.current.scrollHeight }); }, [messages.length]);

  const submit = (e: React.FormEvent) => {
    e.preventDefault();
    const body = draft.trim();
    if (!body) return;
    setError('');
    start(async () => {
      const res = await sendMessage(conversationId, body);
      if (res.message) { add(res.message); setDraft(''); } else setError(res.error ?? 'Message could not be sent.');
    });
  };

  return (
    <div className="chat-panel">
      <header className="chat-panel-header">
        <div style={{ minWidth: 0 }}>
          <h2 className="font-display">{title}</h2>
          <p className="subtitle">Chatting with {otherParty}</p>
        </div>
        <Link href={`/marketplace/${itemId}`} className="view-link font-mono">View listing</Link>
      </header>
      <div className="chat-thread" ref={threadRef} role="log" aria-live="polite" aria-label="Messages">
        {messages.length === 0
          ? <p className="chat-empty">Say hi — ask about pickup, condition, or a better price.</p>
          : messages.map((m) => <MessageBubble key={m.id} message={m} mine={m.senderId === userId} />)}
      </div>
      {!live && <p className="field-hint" role="status" style={{ padding: '0 1rem' }}>Live updates are unavailable — refresh to see new messages.</p>}
      {error && <p className="error-box" role="alert">{error}</p>}
      <form className="chat-input-row" onSubmit={submit}>
        <input type="text" value={draft} onChange={(e) => setDraft(e.target.value)} placeholder="Ask about pickup, condition, bargaining…" maxLength={1000} aria-label="Message" />
        <button type="submit" className="btn btn-dark" disabled={pending}>Send</button>
      </form>
    </div>
  );
}

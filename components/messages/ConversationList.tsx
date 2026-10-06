import Link from 'next/link';
import { timeAgo } from '@/lib/format';
import type { Conversation } from '@/types';

export default function ConversationList({ conversations, activeId, userId }: { conversations: Conversation[]; activeId: number | null; userId: string }) {
  return (
    <div className="conversation-list-wrap">
      <div className="conversation-list-header">{conversations.length} {conversations.length === 1 ? 'conversation' : 'conversations'}</div>
      <ul className="conversation-list">
        {conversations.length === 0 && <li><p className="conversation-empty">No chats yet — message a seller from any listing to get started.</p></li>}
        {conversations.map((c) => (
          <li key={c.id}>
            <Link href={`/messages?c=${c.id}`} className={`conversation-item${c.id === activeId ? ' active' : ''}`} aria-current={c.id === activeId ? 'true' : undefined} style={{ display: 'block' }}>
              <p className="title">{c.itemTitle}</p>
              <p className="subtitle">Chatting with {c.buyerId === userId ? c.itemSellerName : c.buyerName}</p>
              <p className="time font-mono" suppressHydrationWarning>{timeAgo(c.createdAt)}</p>
            </Link>
          </li>
        ))}
      </ul>
    </div>
  );
}

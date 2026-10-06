import type { Metadata } from 'next';
import { getCurrentUser } from '@/lib/auth/session';
import { getConversations, getMessages } from '@/lib/messages/queries';
import ChatWindow from '@/components/messages/ChatWindow';
import ConversationList from '@/components/messages/ConversationList';
import ConversationsRefresher from '@/components/messages/ConversationsRefresher';
import type { Conversation } from '@/types';

export const metadata: Metadata = { title: 'Messages' };

export default async function MessagesPage({ searchParams }: { searchParams: Promise<{ c?: string }> }) {
  const user = await getCurrentUser();
  if (!user) return null; // middleware redirects signed-out visitors
  const { c } = await searchParams;

  let conversations: Conversation[] | null = null;
  try { conversations = await getConversations(); } catch { conversations = null; }

  const active = conversations?.find((x) => String(x.id) === c) ?? null; // only conversations RLS returned can match
  const messages = active ? await getMessages(active.id).catch(() => []) : [];

  return (
    <div className="messages-shell">
      <header>
        <h1 className="font-display">MESSAGES</h1>
        <p className="sub font-mono">Buyer ↔ seller chats, on campus only</p>
      </header>
      {!conversations ? (
        <div className="empty-state solid" role="alert"><h2 className="font-display">Couldn&apos;t load</h2><p>Unable to load your conversations.</p></div>
      ) : (
        <div className="messages-grid">
          <ConversationsRefresher />
          <aside className="conversation-panel" aria-label="Conversations">
            <ConversationList conversations={conversations} activeId={active?.id ?? null} userId={user.id} />
          </aside>
          <section className="chat-panel-col">
            {active ? (
              <ChatWindow key={active.id} conversationId={active.id} userId={user.id} itemId={active.itemId} title={active.itemTitle}
                otherParty={active.buyerId === user.id ? active.itemSellerName : active.buyerName} initialMessages={messages} />
            ) : (
              <div className="chat-placeholder">
                <h2 className="font-display">PICK A CONVERSATION</h2>
                <p>Your buyer and seller chats show up here. Message a seller from any listing to start one.</p>
              </div>
            )}
          </section>
        </div>
      )}
    </div>
  );
}

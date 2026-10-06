import { timeAgo } from '@/lib/format';
import type { Message } from '@/types';

export default function MessageBubble({ message, mine }: { message: Message; mine: boolean }) {
  return (
    <div className={`chat-row ${mine ? 'mine' : 'theirs'}`}>
      <div className="chat-bubble">
        <p className="text">{message.body}</p>
        <p className="time font-mono" suppressHydrationWarning>{timeAgo(message.createdAt)}</p>
      </div>
    </div>
  );
}

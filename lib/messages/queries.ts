import 'server-only';
import { createClient } from '@/lib/supabase/server';
import type { Conversation, Message } from '@/types';

export async function getConversations(): Promise<Conversation[]> {
  const supabase = await createClient();
  const { data, error } = await supabase
    .from('conversations')
    .select('id, item_id, buyer_id, seller_id, buyer_name, created_at, items (title, seller_name)')
    .order('created_at', { ascending: false });
  if (error) throw new Error('Unable to load conversations.');
  return (data ?? []).map((c) => {
    const item = c.items as unknown as { title: string; seller_name: string } | null;
    return {
      id: c.id,
      itemId: c.item_id,
      buyerId: c.buyer_id,
      sellerId: c.seller_id,
      buyerName: c.buyer_name,
      createdAt: c.created_at,
      itemTitle: item?.title ?? 'Removed listing',
      itemSellerName: item?.seller_name ?? 'Seller',
    };
  });
}

/** Initial messages for the open chat; later ones arrive over Realtime. RLS limits this to participants. */
export async function getMessages(conversationId: number): Promise<Message[]> {
  const supabase = await createClient();
  const { data, error } = await supabase
    .from('messages')
    .select('id, conversation_id, sender_id, body, created_at')
    .eq('conversation_id', conversationId)
    .order('created_at', { ascending: true })
    .limit(500);
  if (error) throw new Error('Unable to load messages.');
  return (data ?? []).map((m) => ({
    id: m.id, conversationId: m.conversation_id, senderId: m.sender_id, body: m.body, createdAt: m.created_at,
  }));
}

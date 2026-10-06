'use server';

import { createClient } from '@/lib/supabase/server';
import { getCurrentUser } from '@/lib/auth/session';
import type { Message } from '@/types';

/** Find-or-create the buyer's conversation for a listing. The DB trigger sets seller + names. */
export async function startConversation(itemId: number): Promise<{ conversationId?: number; error?: string }> {
  const user = await getCurrentUser();
  if (!user) return { error: 'You need to sign in to continue.' };
  const supabase = await createClient();

  const find = () =>
    supabase.from('conversations').select('id').eq('item_id', itemId).eq('buyer_id', user.id).maybeSingle();

  const existing = await find();
  if (existing.data) return { conversationId: existing.data.id };

  const { data, error } = await supabase.from('conversations').insert({ item_id: itemId }).select('id').single();
  if (data) return { conversationId: data.id };
  if (error?.code === '23505') {
    const again = await find();
    if (again.data) return { conversationId: again.data.id };
  }
  const msg = error?.message ?? '';
  if (/own|yourself/i.test(msg)) return { error: "That's your own listing." };
  if (/no longer available|showcase|not found/i.test(msg)) return { error: msg };
  return { error: 'Could not start a chat. Please try again.' };
}

export async function sendMessage(conversationId: number, body: string): Promise<{ message?: Message; error?: string }> {
  const text = body.trim();
  if (!text) return { error: 'Type a message first.' };
  if (text.length > 1000) return { error: 'Messages can be up to 1000 characters.' };
  const user = await getCurrentUser();
  if (!user) return { error: 'You need to sign in to continue.' };
  const supabase = await createClient();
  // RLS: sender must be the signed-in user AND a participant of the conversation.
  const { data, error } = await supabase
    .from('messages')
    .insert({ conversation_id: conversationId, sender_id: user.id, body: text })
    .select('id, conversation_id, sender_id, body, created_at')
    .single();
  if (error || !data) return { error: 'Message could not be sent.' };
  return { message: { id: data.id, conversationId: data.conversation_id, senderId: data.sender_id, body: data.body, createdAt: data.created_at } };
}

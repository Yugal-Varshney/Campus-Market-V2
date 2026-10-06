'use client';

import { useRouter } from 'next/navigation';
import { useEffect } from 'react';
import { createClient } from '@/lib/supabase/client';

/** Refreshes the server-rendered conversation list when someone starts a chat with you (Realtime). */
export default function ConversationsRefresher() {
  const router = useRouter();
  useEffect(() => {
    const supabase = createClient();
    const channel = supabase
      .channel('conversations')
      .on('postgres_changes', { event: 'INSERT', schema: 'public', table: 'conversations' }, () => router.refresh())
      .subscribe();
    return () => { supabase.removeChannel(channel); };
  }, [router]);
  return null;
}

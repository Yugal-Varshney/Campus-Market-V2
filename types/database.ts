/**
 * Hand-written types mirroring the Supabase schema (supabase/schema.sql + migrations).
 * Regenerate with `npx supabase gen types typescript --project-id <ref>` if you prefer.
 */
export type Json = string | number | boolean | null | { [key: string]: Json | undefined } | Json[];

type Category = 'books' | 'notes' | 'electronics' | 'stationary';
type ListingType = 'sell' | 'rent';
type ListingStatus = 'active' | 'sold' | 'rented';
type Role = 'student' | 'moderator' | 'admin';

export type Database = {
  public: {
    Tables: {
      profiles: {
        Row: { id: string; display_name: string; email: string; role: Role };
        Insert: { id: string; display_name: string; email: string; role?: Role };
        Update: { display_name?: string; email?: string; role?: Role };
        Relationships: [];
      };
      items: {
        Row: {
          id: number;
          seller_id: string | null;
          seller_name: string;
          title: string;
          description: string;
          category: Category;
          listing_type: ListingType;
          price: number;
          condition_label: string;
          image_url: string | null;
          campus_location: string;
          status: ListingStatus;
          created_at: string;
        };
        Insert: {
          seller_id?: string | null;
          seller_name?: string;
          title: string;
          description?: string;
          category: Category;
          listing_type: ListingType;
          price: number;
          condition_label?: string;
          image_url?: string | null;
          campus_location?: string;
          status?: ListingStatus;
        };
        Update: {
          title?: string;
          description?: string;
          category?: Category;
          listing_type?: ListingType;
          price?: number;
          condition_label?: string;
          image_url?: string | null;
          campus_location?: string;
          status?: ListingStatus;
        };
        Relationships: [];
      };
      item_private: {
        Row: { item_id: number; contact_email: string; contact_phone: string };
        Insert: { item_id: number; contact_email?: string; contact_phone?: string };
        Update: { contact_email?: string; contact_phone?: string };
        Relationships: [];
      };
      wishlists: {
        Row: { user_id: string; item_id: number; created_at: string };
        Insert: { user_id?: string; item_id: number };
        Update: never;
        Relationships: [
          { foreignKeyName: 'wishlists_item_id_fkey'; columns: ['item_id']; isOneToOne: false; referencedRelation: 'items'; referencedColumns: ['id'] },
        ];
      };
      conversations: {
        Row: { id: number; item_id: number; buyer_id: string; seller_id: string; buyer_name: string; created_at: string };
        Insert: { item_id: number; buyer_id?: string; seller_id?: string; buyer_name?: string };
        Update: never;
        Relationships: [
          { foreignKeyName: 'conversations_item_id_fkey'; columns: ['item_id']; isOneToOne: false; referencedRelation: 'items'; referencedColumns: ['id'] },
        ];
      };
      messages: {
        Row: { id: number; conversation_id: number; sender_id: string; body: string; created_at: string };
        Insert: { conversation_id: number; sender_id?: string; body: string };
        Update: never;
        Relationships: [];
      };
    };
    Views: { [_ in never]: never };
    Functions: {
      get_contact: {
        Args: { p_item_id: number };
        Returns: { name: string; email: string; phone: string }[];
      };
    };
    Enums: { [_ in never]: never };
    CompositeTypes: { [_ in never]: never };
  };
};

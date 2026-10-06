import type { Database } from './database';

export type Category = Database['public']['Tables']['items']['Row']['category'];
export type ListingType = Database['public']['Tables']['items']['Row']['listing_type'];
export type ListingStatus = Database['public']['Tables']['items']['Row']['status'];
export type Condition = 'new' | 'like-new' | 'good' | 'fair';
export type Role = Database['public']['Tables']['profiles']['Row']['role'];
export type SortKey = 'newest' | 'price-asc' | 'price-desc';

/** The signed-in user as the UI needs it. */
export interface User {
  id: string;
  email: string;
  displayName: string;
}

export type Profile = Database['public']['Tables']['profiles']['Row'];

/** A listing as shown on cards and detail pages (never includes private contact data). */
export interface Listing {
  id: number;
  sellerId: string | null;
  sellerName: string;
  title: string;
  description: string;
  category: Category;
  listingType: ListingType;
  price: number;
  condition: string;
  imageUrl: string | null;
  campusLocation: string;
  status: ListingStatus;
  createdAt: string;
}
export type Product = Listing;

export interface WishlistItem {
  itemId: number;
  createdAt: string;
  listing: Listing;
}

export interface Conversation {
  id: number;
  itemId: number;
  buyerId: string;
  sellerId: string;
  buyerName: string;
  createdAt: string;
  itemTitle: string;
  itemSellerName: string;
}

export interface Message {
  id: number;
  conversationId: number;
  senderId: string;
  body: string;
  createdAt: string;
}

export interface SellerContact {
  name: string;
  email: string;
  phone: string;
}

export interface ListingQuery {
  q: string;
  categories: Category[];
  minPrice: number | null;
  maxPrice: number | null;
  sort: SortKey;
  page: number;
  availableOnly: boolean;
}

export interface Paginated<T> {
  items: T[];
  total: number;
  page: number;
  pageSize: number;
}

/** Result shape for server actions used with useActionState. */
export interface ActionState {
  error?: string;
  success?: string;
  fieldErrors?: Record<string, string>;
}

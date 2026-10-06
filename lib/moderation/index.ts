import type { ValidListing } from '@/lib/validation/listing';

/**
 * Moderation seam for future versions (V3/V4). V2 intentionally contains NO AI and no scoring:
 * this is a typed, pass-through hook so a real service can later be plugged in here without
 * touching the listing actions.
 *
 *   Listing submitted -> validation -> moderateListing() -> publish | hold for human review
 */
export type ModerationDecision = 'allow' | 'review' | 'reject';
export interface ModerationResult {
  decision: ModerationDecision;
  reasons: string[];
}

export async function moderateListing(_listing: ValidListing): Promise<ModerationResult> {
  return { decision: 'allow', reasons: [] };
}

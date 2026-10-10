/**
 * Turns database errors into messages a student can act on.
 *
 * The V3 migrations (005-009) raise exceptions that start with a stable code, for example
 *   RATE_LIMIT: too many "listing_create" actions (limit 5 per 60 minutes). Please try again later.
 *   ACCOUNT_SUSPENDED: your account is suspended until 2026-10-12 10:00 UTC. ...
 *   LISTING_HIDDEN: this listing was hidden by a moderator and cannot be changed.
 * Only these known, database-authored messages are shown to users. Anything else falls back to
 * the caller's generic text so internal error details never leak into the UI.
 *
 * Pure module (no 'server-only' import) so it can be unit-tested with `npm test`.
 */
const KNOWN_CODES = ['ACCOUNT_BANNED', 'ACCOUNT_SUSPENDED', 'LISTING_HIDDEN', 'LISTING_REPORTED', 'RESERVED_NAME'] as const;

const capitalise = (s: string) => (s ? s.charAt(0).toUpperCase() + s.slice(1) : s);

/** Returns a user-facing message for a known V3 error, or null when the error is not one of ours. */
export function knownDbError(message: string | null | undefined): string | null {
  if (!message) return null;
  const msg = message.trim();

  if (/^RATE_LIMIT\b/.test(msg)) {
    const m = msg.match(/limit (\d+) per (\d+) minutes?/i);
    return m
      ? `You've reached the limit for this action (${m[1]} per ${m[2]} minutes). Please try again later.`
      : "You're doing that too often. Please wait a few minutes and try again.";
  }

  for (const code of KNOWN_CODES) {
    if (msg.startsWith(code + ':')) return capitalise(msg.slice(code.length + 1).trim());
  }
  return null;
}

/** Known V3 message if there is one, otherwise the caller's generic fallback. */
export function friendlyDbError(message: string | null | undefined, fallback: string): string {
  return knownDbError(message) ?? fallback;
}

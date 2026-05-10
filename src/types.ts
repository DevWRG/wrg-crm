export interface MasterUser {
  id: number;
  wa_number: string;
  nama_am: string;
  area: string | null;
  role: string;
  aktif: boolean;
}

export type Hashtag = '#PLAN' | '#REPORT' | '#LEADS' | '#UPDATE';

export type AuditStatus =
  | 'SUCCESS'
  | 'FAILED'
  | 'CONFIRM_NEEDED'
  | 'NOT_FOUND'
  | 'IGNORED'
  | 'UNREGISTERED'
  | 'RATE_LIMITED';

export interface InboundMessage {
  /** WA number of the sender, no '+' prefix, e.g. "6281111111111" */
  from: string;
  /** Group ID where the message was posted, or null for DM */
  groupId?: string | null;
  /** Raw text body */
  text: string;
  /** Optional message id for idempotency (not enforced yet) */
  messageId?: string;
  /** Optional ISO timestamp; defaults to now */
  timestamp?: string;
}

export interface OutboundReply {
  /** "group" → reply to the source group; "dm" → reply to sender's DM */
  to: 'group' | 'dm';
  /** Resolved target identifier (group id or wa number) */
  target: string;
  text: string;
}

export interface HandlerResult {
  status: AuditStatus;
  customerCount: number;
  payload: Record<string, unknown>;
  replies: OutboundReply[];
  error?: string;
}

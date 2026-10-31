val past_original : Keeper_librarian_durable_request.t -> (bool, string) result
(** Read-only, blocking original-range relevance check, after strict owner and
    whole-inventory validation. The actual Memory-backed coverage and current
    read frontier must both reach the original end in its typed generation;
    original boundary identities must still match the append-only log. The
    external cursor must have ACKed the original's complete admission frontier.
    A changed position, unrelated generation, pending external preparation,
    unreadable record or missing receipt is never progress evidence.

    [true] says this old range is behind the durable reader, so its refusal
    need not block future selection. It does not certify that every message
    was read: committed coverage's unread holes keep their existing meaning
    and durable ledger. The complete refused original can be settled without
    discarding that evidence. No source capture, Memory effect, ACK repair or
    provider execution is performed. Offload the whole call in Eio. *)

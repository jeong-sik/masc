(** The Keeper side of the Board recipient lookup
    (RFC-at-name-resolves-to-declared-recipient, layer L2c).

    A name written after [@] is declared when a persisted Keeper answers to it.
    That is the question the Board asks when it routes a post to a Keeper
    ({!Keeper_lane_mentions.effective_target_ids}): the Keeper's
    [mention_targets] when it has any, else its own name.  The recipient is the
    name itself in lower case, an alias as well as a Keeper's own name, because
    the router matches a recorded target against those names.  The server
    hands this to {!Board_dispatch.init_jsonl}. *)

val make : base_path:string -> Recipient_lookup.t
(** [make ~base_path] answers for each candidate:

    - A candidate that cannot be a Keeper name ({!Keeper_id.Keeper_name.of_string}:
      a path component of at most 128 bytes) is never used to build an own-name
      file path. It can still be a declared alias, which is found by the scan.
    - A Keeper's own name is declared when that Keeper answers to it. Keeper
      identity is case-folded, including when the persisted filename retains
      uppercase letters on a case-sensitive filesystem. A Keeper whose
      [mention_targets] leave its own name out does not answer to it, so the
      name is looked up among the aliases like any other. A matching own name
      retains priority over alias collisions. The router compares the recorded
      target with each Keeper's effective target list, subject to its separate
      suppression of signals authored by that Keeper. The own-name shortcut
      requires the observed filename spelling and payload name to match
      exactly. The lookup lists persisted names even for the canonical shortcut
      (a listing error fails the lookup), but it does not read unrelated
      settings on that shortcut. When alternate spellings are checked, every
      matching file must be readable before the name can be accepted. The
      metadata read and filename listing are separate observations: concurrent
      replacement can mix them, so this is not an atomic or latest-state
      ownership guarantee.
    - An alias is found by reading every Keeper's settings, once for the write
      and only if a name needs it.  One unreadable setting, or two Keepers
      claiming one alias, fails the lookup.  The detail names the Keeper or the
      alias, and the write is refused.
    - A name the Board cannot hold as an identity (longer than 64 bytes) fails
      the lookup the same way.
    - A Keeper file this build cannot decode as the current schema fails the
      lookup too, whether the name is that Keeper's or a scan reaches it, and so
      do filesystem errors from a read: neither is taken for "no such Keeper".
      Cancellation and other non-filesystem exceptions propagate. *)

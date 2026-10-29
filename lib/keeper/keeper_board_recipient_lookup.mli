(** The Keeper side of the Board recipient lookup
    (RFC-at-name-resolves-to-declared-recipient, layer L2c).

    A name written after [@] is declared when it is a Keeper's own name or one
    of its [mention_targets] aliases, read from the persisted Keeper settings
    under [base_path].  The recipient is that Keeper's name, whichever alias or
    case the author wrote.  The server hands this to
    {!Board_dispatch.init_jsonl}. *)

val make : base_path:string -> Recipient_lookup.t
(** [make ~base_path] answers for each candidate:

    - A name that cannot be a Keeper name ({!Keeper_id.Keeper_name.of_string}:
      a path component of at most 128 bytes) is not declared.  No file name is
      built from it.
    - A Keeper's own name wins over an alias, as in the broadcast path.
    - An alias is found by reading every Keeper's settings, so one unreadable
      setting, or two Keepers claiming one alias, fails the lookup.  The detail
      names the Keeper or the alias, and the write is refused.
    - A Keeper whose name is not a Board identity (longer than 64 bytes) cannot
      be recorded as a target, so it fails the lookup the same way. *)

(** Completed dynamic-tool receipts that the ended vendor turn could not
    receive. The outbox is Keeper-owned, independent of vendor process and
    session identity. It does not authorize executing or replaying tools. *)

type snapshot

val retain :
  base_path:string -> keeper_name:string ->
  Runtime_codex_app_server.undelivered_tool_result -> (unit, string) result

val load : base_path:string -> keeper_name:string -> (snapshot, string) result
val developer_context : snapshot -> string list

val acknowledge : snapshot -> (unit, string) result
(** Remove only the exact loaded receipts after a successful vendor or
    acknowledged host-terminal settlement. Input writes, provider refusals and
    context-overflow retries do not acknowledge delivery. Newer receipts remain
    pending. *)

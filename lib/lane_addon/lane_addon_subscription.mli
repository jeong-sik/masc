(** Subscriptions publish references, never original source bodies or wakeups.
    Read receipts and explicit acknowledgements are distinct from semantic use.
    An unreadable producer phase cannot authorize reading or acknowledgement.
    Cursor bytes and their exact parent are strictly synced before accepting a
    position, including after restart. A post-rename write failure reports
    [acknowledged=false], [published=true], and unconfirmed durability. Retrying
    exactly the current receipt revalidates its output and does not consume the
    next receipt. These guarantees concern process restart, not power loss. *)
type subscription = {keeper_name:string; run_id:string; installation_id:string; output_id:string}
type operation = Inspect | Save | Read | Acknowledge
val json : subscription -> Yojson.Safe.t
val decode : Yojson.Safe.t -> (subscription, string) result
(** Omitted [access] is unauthenticated; caller text cannot grant private ownership. *)
val dispatch : ?access:Lane_addon_sources.access -> config:Workspace.config -> caller:string -> operation:operation ->
  Yojson.Safe.t -> (Yojson.Safe.t, string) result
(** [caller] selects a subscription; only explicit, verified [access] grants
    its private read or update authority. The default is unauthenticated. *)
val observe : config:Workspace.config -> keeper_name:string -> (Yojson.Safe.t, string) result
val render : (Yojson.Safe.t, string) result -> string option
val handle : ?access:Lane_addon_sources.access -> config:Workspace.config -> caller:string -> Yojson.Safe.t -> (Yojson.Safe.t, string) result

module For_testing : sig
  val handle :
    replace_cursor_file:(string -> string -> (unit, Fs_compat.atomic_replace_failure) result) ->
    sync_file:(Unix.file_descr -> unit) -> sync_parent:(Unix.file_descr -> unit) ->
    ?access:Lane_addon_sources.access -> config:Workspace.config -> caller:string -> Yojson.Safe.t -> (Yojson.Safe.t, string) result
  val observe : sync_file:(Unix.file_descr -> unit) -> sync_parent:(Unix.file_descr -> unit) ->
    config:Workspace.config -> keeper_name:string -> (Yojson.Safe.t, string) result
end

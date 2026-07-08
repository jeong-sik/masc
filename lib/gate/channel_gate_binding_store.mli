(** Shared file-backed binding store and audit log for Channel Gate
    connectors. *)

type binding = {
  channel_id : string;
  keeper_name : string;
}

type guild_id_field =
  | Omit
  | Include_empty
  | Include_event_value

type audit_event = {
  timestamp : string;
  action : string;
  guild_id : string option;
  channel_id : string;
  keeper_name : string;
  actor_id : string;
  actor_name : string;
  previous_keeper : string;
}

type t

val create :
  binding_store_path:(unit -> string) ->
  binding_store_read_path:(unit -> string) ->
  binding_audit_path:(unit -> string) ->
  binding_audit_read_path:(unit -> string) ->
  guild_id_field:guild_id_field ->
  t

val read_json_file_result : string -> (Yojson.Safe.t option, string) result
val read_json_file_opt : string -> Yojson.Safe.t option
val normalize_bindings_json : Yojson.Safe.t -> binding list
val read_bindings_result : t -> (binding list, string) result
val read_bindings : t -> binding list
val binding_json : binding -> Yojson.Safe.t
val save_bindings : t -> binding list -> unit
val audit_event_json : t -> audit_event -> Yojson.Safe.t
val append_audit_event : t -> audit_event -> unit
val read_recent_audit : t -> limit:int -> Yojson.Safe.t list

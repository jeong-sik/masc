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

type binding_decode_error =
  | Expected_object
  | Blank_channel_id
  | Non_canonical_channel_id of string
  | Keeper_name_not_string of string
  | Blank_keeper_name of string
  | Non_canonical_keeper_name of {
      channel_id : string;
      keeper_name : string;
    }
  | Duplicate_channel_id of string

type binding_store_error =
  | Binding_store_io_failed of string
  | Binding_store_decode_failed of {
      path : string;
      error : binding_decode_error;
    }

type audit_append_error =
  | Audit_append_failed of Fs_compat.private_jsonl_append_error
  | Audit_io_failed of string

type mutation_error =
  | Mutation_rejected of string
  | Mutation_read_failed of binding_store_error
  | Mutation_write_failed of string
  | Mutation_audit_failed of {
      audit_error : audit_append_error;
      binding_rollback_error : string option;
    }

val create :
  binding_store_path:(unit -> string) ->
  binding_store_read_path:(unit -> string) ->
  binding_audit_path:(unit -> string) ->
  binding_audit_read_path:(unit -> string) ->
  guild_id_field:guild_id_field ->
  t

val read_json_file_result : string -> (Yojson.Safe.t option, string) result
val read_json_file_opt : string -> Yojson.Safe.t option
val normalize_bindings_json :
  Yojson.Safe.t -> (binding list, binding_decode_error) result
val binding_decode_error_to_string : binding_decode_error -> string
val binding_store_error_to_string : binding_store_error -> string
val audit_append_error_to_string : audit_append_error -> string
val mutation_error_to_string : mutation_error -> string
val read_bindings_result : t -> (binding list, binding_store_error) result
val bound_channels_result :
  t -> keeper_name:string -> (string list, binding_store_error) result
val binding_json : binding -> Yojson.Safe.t
val audit_event_json : t -> audit_event -> Yojson.Safe.t
val mutate_bindings :
  t ->
  decide:(binding list -> (binding list * audit_event * 'a, string) result) ->
  ('a, mutation_error) result
val read_recent_audit : t -> limit:int -> Yojson.Safe.t list

(** Shared file-backed binding store and audit log for Channel Gate
    connectors. *)

type binding = {
  channel_id : string;
  keeper_name : string;
}

type guild_id_field =
  | Omit
  | Include_empty

type audit_event = {
  timestamp : string;
  action : string;
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
  | Audit_append_failed_with_cleanup of {
      error : Fs_compat.private_jsonl_append_error;
      cleanup_failure : Fs_compat.private_jsonl_operation_failure;
    }
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

val read_json_file_opt : string -> Yojson.Safe.t option
val normalize_bindings_json :
  Yojson.Safe.t -> (binding list, binding_decode_error) result
val binding_store_error_to_string : binding_store_error -> string
val mutation_error_to_string : mutation_error -> string
val read_bindings_result : t -> (binding list, binding_store_error) result
val bound_channels_result :
  t -> keeper_name:string -> (string list, binding_store_error) result
val find_binding_by_channel_id :
  binding list -> channel_id:string -> binding option
(** [find_binding_by_channel_id bindings ~channel_id] returns the first
    binding whose [channel_id] is equal to [channel_id], or [None] when
    no binding matches.  Compares the ids as given; callers normalize
    beforehand. *)

val binding_json : binding -> Yojson.Safe.t
val audit_event_json : t -> audit_event -> Yojson.Safe.t
val mutate_bindings :
  t ->
  decide:(binding list -> (binding list * audit_event * 'a, string) result) ->
  ('a, mutation_error) result

val bind :
  t ->
  channel_id:string ->
  keeper_name:string ->
  actor_name:string ->
  (unit, mutation_error) result
(** Trim and validate channel and Keeper names, then atomically replace the
    channel's binding and append its audit record. Validation precedes store
    reads; the channel error precedes the Keeper error. The previous owner and
    wall-clock audit timestamp are observed inside the durable transaction.
    Each store retains its own paths and [guild_id_field] serialization. *)

val unbind :
  t ->
  ?expected_keeper_name:string ->
  channel_id:string ->
  actor_name:string ->
  unit ->
  (unit, mutation_error) result
(** Remove an existing binding and append its audit record in one durable
    transaction. [None] permits any current owner; [Some expected] requires
    an exact owner match without normalizing [expected]. Missing or changed
    bindings refuse without writing a binding or audit record. Only the
    channel name is trimmed; actor identity is retained as supplied. *)

val read_recent_audit : t -> limit:int -> Yojson.Safe.t list

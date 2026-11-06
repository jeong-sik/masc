(** The request record paths, the durable read and write of request records
    and the active inventory of [Keeper_msg_async].

    A request record is the file [<request_id>.json] in the [active]
    directory until the request settles and in the [terminal] directory after
    it; [atomic_staging_dir] holds the temporary files of a durable write.
    [canonical_base_path] and [resolve_access_identity] give the canonical base
    path and the checked caller name, and [is_safe_request_id] accepts only
    ids of at most 128 characters made of letters, digits, [_], [-] and [.].
    [load_record] and [load_record_canonical] read one record by id and prefer
    the terminal record when both exist; [load_record_canonical_located] also
    says which directory it came from.
    [persist_entry] writes a record inside the persistence lane of the entry's
    Keeper. A terminal record is published first and the active source is
    removed afterwards, so a crash leaves at least one of the two names.
    [persist_error] says whether a failed write may already have landed.
    [read_durable_active_inventory] lists the records of the active directory
    and [active_inventory_record_error] builds the error of a record that
    cannot be read. [rollback_rejected_record_file_unlocked] removes a record
    file that a refused submission may have left behind.
    [Keeper_msg_async] includes this module. *)
open Keeper_msg_async_types
open Keeper_msg_async_locks
open Keeper_msg_async_state

val request_dir : base_path:string -> string

val active_request_dir : base_path:string -> string

val atomic_staging_dir : base_path:string -> string

val canonical_base_path :
  string -> (string, access_rejection) result

val resolve_access_identity :
  base_path:string ->
  caller:string ->
  (string * string, access_rejection) result

val request_key :
  base_path:string ->
  submitted_by:string ->
  request_id:string -> Request_key.t

val is_safe_request_id : string -> bool

val active_record_path :
  base_path:string -> request_id:string -> string option

val terminal_record_path :
  base_path:string -> request_id:string -> string option

val load_record_at_path :
  base_path:string ->
  request_id:string -> string -> load_result

type record_location =
  | Active_location
  | Terminal_location

type located_load_result =
  | Located of entry * record_location
  | Located_absent
  | Located_unreadable of string
  | Located_rejected of access_rejection

val remove_duplicate_source_unlocked :
  ops:request_ops ->
  entry:entry -> string -> bool

type persist_integrity_error =
  | Unsafe_request_id
  | Invalid_keeper_name of string
  | Terminal_partition_nonterminal
  | Terminal_conflict
  | Terminal_unreadable of string
  | Terminal_access_rejected of access_rejection

type write_failure =
  | Not_published of Keeper_fs.durable_write_error
  | Published_uncertain of Keeper_fs.durable_write_error

type persist_error =
  | Write_failed of write_failure
  | Integrity_failed of persist_integrity_error

val persist_integrity_error_to_string : persist_integrity_error -> string

val persist_error_to_string : persist_error -> string

val save_entry_durable :
  ops:request_ops ->
  string -> entry -> (unit, persist_error) result

val persist_entry_unlocked :
  ops:request_ops ->
  ?source_path:string ->
  entry -> (unit, persist_error) result

val with_entry_persistence_transaction :
  entry ->
  (unit -> ('a, persist_error) result) -> ('a, persist_error) result

val persist_entry :
  ops:request_ops ->
  ?source_path:string ->
  entry -> (unit, persist_error) result

val load_record_canonical_located :
  base_path:string -> request_id:string -> located_load_result

val load_record_canonical :
  base_path:string -> request_id:string -> load_result

val load_record :
  base_path:string -> request_id:string -> load_result

val observe_persist_error :
  operation:string ->
  entry ->
  (unit, persist_error) result -> (unit, persist_error) result

val request_id_of_record_filename : string -> string option

val active_inventory_record_error :
  ?request_id:string ->
  path:string ->
  active_inventory_record_error_kind ->
  active_inventory_record_error

val read_durable_active_inventory :
  base_path:string ->
  (durable_active_inventory,
   active_inventory_store_error)
  result

val rollback_rejected_record_file_unlocked :
  ops:request_ops ->
  ownership_root:string ->
  keeper_name:string ->
  string -> (unit, Keeper_fs.durable_remove_error) result

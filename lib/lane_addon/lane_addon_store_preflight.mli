(** The Lane Add-on records the deploy preflight ([validate-stores]) reads
    beside {!Keeper_durable_store}, with the decoders the runtime applies to
    them.

    A Lane Add-on record the new build cannot decode is refused by its reader
    long after the deploy: a native claim whose cleanup descriptor no longer
    decodes kept its installation [failed] and refused every new start
    (#45106), and old-shape bindings failed a declaration (#44651). Reports
    name every refused file and its store-specific fresh-state requirements.
    Generic records can name individual move scopes; a Librarian original
    requires review of its complete linked bundle.

    The scan only lists directories and reads files. It takes no slot gate or
    store lock, syncs nothing, and creates, moves or writes nothing, so it can
    run while the old server is still serving the same workspace. *)

module Store : sig
  type t =
    | Bindings
    | Native_claims
    | Actions
    | Exact_requests
    | Tool_request_owners

  val all : t list
  (** Every constructor in declaration order. *)
end

(** The runtime reader that refused a record. *)
type decoder =
  | Json  (** The file is not JSON. *)
  | Retained_binding  (** {!Lane_addon_runtime.check_retained_binding} *)
  | Inventory_record  (** {!Lane_addon_runtime.check_inventory_record} *)
  | Native_lease  (** {!Native_addon_lease.inspect} *)
  | Cleanup_descriptor  (** {!Browser_addon_socket.check_retained} *)
  | Action_receipt
      (** {!Lane_addon_action.of_json}, and the receipt's own ids against the
          key it is stored under. *)
  | Exact_record  (** {!Lane_addon_exact.check_retained_record} *)
  | Tool_request_inventory  (** {!Lane_addon_store.tool_request_owner_entry} *)
  | Tool_request_owner  (** {!Lane_addon_tool_request_owner.Published_reader.read} *)
  | Tool_request_payload (** The consumer's current pure payload decoder. *)

type tool_request_reader = scope:string -> request_id:string ->
  (Lane_addon_tool_request_owner.retained option, string) result
type request_body_reader = scope:string -> request_digest:string -> (Yojson.Safe.t, string) result
type tool_request_scope_reader = scope:string ->
  (Lane_addon_tool_request_owner.retained list, string) result
type tool_request_archive_reader = scope:string -> date:string -> request_id:string ->
  (Lane_addon_tool_request_owner.Record.t option, string) result
type history_resolution_reader = scope:string -> request_id:string -> (Yojson.Safe.t option, string) result
type payload_validator = read:tool_request_reader -> read_scope:tool_request_scope_reader -> read_body:request_body_reader ->
  read_archive:tool_request_archive_reader ->
  read_fence:history_resolution_reader -> read_resolution:history_resolution_reader ->
  Lane_addon_tool_request_owner.retained -> (unit, string) result
(** Explicit read-only parent, scope inventory and body ports. Every returned original passes the
    same record identity, canonical body and digest checks as the scanned one.

    {!scan} asks for a new validator once per scan, never once per record. A
    validator may remember what it proved about an owner while that scan runs,
    so the many records one owner has do not each prove it again. *)

val decoder_name : decoder -> string

type refusal =
  { path : string
        (** The refused file; the slot directory when the lease refused a
            native claim. *)
  ; decoder : decoder
  ; detail : string  (** The decoder's own message. *)
  ; delete : string list
        (** What fresh state deletes with the server stopped. For a record it
            is that file. For a native claim it is the slot directory, then the
            binding and observations of the instance the slot names, when that
            could be read and they exist. For a tool request owner it is the
            record's scope directory and, when they exist, the scope's request
            body, history fence and history resolution directories. *)
  }

type report =
  { rows : int  (** Files (installation slots, for native claims) read. *)
  ; refusals : refusal list  (** In path order. *)
  }

val name : Store.t -> string
(** The name the preflight prints, e.g. ["lane-addon bindings"]. *)

val on_refusal : Store.t -> string
(** What the running server does with a record of this store it cannot
    decode. *)

val fresh_state_step : refusal -> string
(** The fresh-state line the preflight prints: stop the server, delete
    [delete], start the new build. *)

val scan : ?validate_tool_request:(unit -> payload_validator) -> Store.t -> base_path:string -> (report, string) result
(** Read every record of the store under [base_path] with this build's
    decoders. A missing store directory is an empty store. [Error] means a
    directory exists and cannot be listed. The scan runs beside a live server
    and takes none of its locks: a record removed before it is read, or while
    it is checked, is absent, since a settle moves an original's record and
    then the body its check reads. *)

module For_testing : sig
  val scan : ?validate_tool_request:(unit -> payload_validator) -> after_read:(string -> unit) ->
    Store.t -> base_path:string -> (report, string) result
  (** The same scan, calling [after_read] with each record's path once its
      bytes are read and before they are decoded, so a test can move a file
      at the point a running server could. *)
end

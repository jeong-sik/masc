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
  | Exact_record
      (** {!Lane_addon_exact.check_retained_record}, with the record's proof
          link, and the record's own ids against the key it is stored under. *)
  | Exact_proof_link
      (** {!Lane_addon_exact.Retained_key.proof_path}: no retained record names
          the proof link. *)
  | Exact_slot_observation
      (** {!Lane_addon_exact_observation.request_id}, the startup sweep's read. *)
  | Tool_request_inventory  (** {!Lane_addon_store.tool_request_owner_entry} *)
  | Tool_request_owner  (** {!Lane_addon_tool_request_owner.Published_reader.read} *)
  | Tool_request_payload (** The consumer's current pure payload decoder. *)
  | History_resolution
      (** The consumer's decoder for one file of a scope's history resolution
          directory. *)
  | Tool_request_exact_reads
      (** The consumer's reads of the original's Exact record and proof link,
          on the files the Exact scan leaves. *)

type tool_request_reader = scope:string -> request_id:string ->
  (Lane_addon_tool_request_owner.retained option, string) result
type request_body_reader = scope:string -> request_digest:string -> (Yojson.Safe.t, string) result
type tool_request_scope_reader = scope:string ->
  (Lane_addon_tool_request_owner.retained list, string) result
type tool_request_archive_reader = scope:string -> date:string -> request_id:string ->
  (Lane_addon_tool_request_owner.Record.t option, string) result
type history_resolution_reader = scope:string -> request_id:string -> (Yojson.Safe.t option, string) result

(** What the record the Exact scan deletes at an original's path showed of
    that original: open, terminal with this final, or nothing, when the record
    is another request's or its shape cannot be read. *)
type deleted_record = Deleted_open | Deleted_terminal of Lane_addon_exact.final | Deleted_unknown

type exact_proof = No_proof | Proof of Yojson.Safe.t | Unreadable_proof of string

(** One original's Exact files as the Exact scan leaves them. *)
type exact_files =
  { record : Yojson.Safe.t option
        (** The record at the original's path, when the Exact scan keeps it. *)
  ; deleted : deleted_record option  (** The record the Exact scan deletes there. *)
  ; proof : exact_proof
        (** The proof link the original's request names, unless the Exact scan
            deletes it with that record. A link no kept record names is read
            here: whether the Exact scan finds it depends on the other records
            of its declaration. *)
  ; store : Lane_addon_store.t
        (** The store the files were read from. A proof decoder compares the
            root each proof names with its root. *)
  }

type exact_reader = declaration_id:string -> Lane_addon_exact.request -> (exact_files, string) result
(** Reads by path, as the Exact scan does, and judges the record with the Exact
    scan's own judgment. [Error] names two store roots: a proof link names
    another root than this scan reads. *)

type payload_verdict =
  | Payload_valid
  | Payload_invalid of string
      (** Fresh state deletes the record's scope: its owner records,
          request bodies, history fences and history resolution records. *)
  | Consumer_stops_on_exact of { detail : string; scopes : string list; paths : string list }
      (** The consumer stops on the Exact files the Exact scan leaves. Fresh
          state deletes every directory the store names by each scope in
          [scopes] (owner records, request bodies, settled originals, history
          fences and resolutions) and each path in [paths], below the store
          root, those that exist. *)
  | Exact_root_differs of string
      (** The scan stops and prints no fresh-state line. *)

type payload_validator = read:tool_request_reader -> read_scope:tool_request_scope_reader -> read_body:request_body_reader ->
  read_archive:tool_request_archive_reader ->
  read_fence:history_resolution_reader -> read_resolution:history_resolution_reader ->
  read_exact:exact_reader -> Lane_addon_tool_request_owner.retained -> payload_verdict
(** Explicit read-only parent, scope inventory, body and Exact ports. Every returned original passes the
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
            could be read and they exist. For a tool request owner or a
            history resolution record it is the scope's directories that
            exist: owner records, request bodies, history fences and history
            resolution records. When the consumer of a tool request owner
            stops on the Exact files the Exact scan leaves, it is the
            directories the store names by every scope of its owner, settled
            originals included, and the paths the consumer check names. For an
            Exact record stored under its own key it is that file, its proof
            link and the slot observation files of its request, those that
            exist. *)
  }

type report =
  { rows : int
        (** Files (installation slots, for native claims) read. The Exact scan
            also counts the slot observation files it reads and the proof
            links it refuses. *)
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

type history_resolution_validator = group:string -> name:string -> Yojson.Safe.t -> (unit, string) result
(** One file of [history-resolutions/<group>/<name>]. *)

val scan : ?validate_tool_request:(unit -> payload_validator) ->
  ?validate_history_resolution:history_resolution_validator ->
  Store.t -> base_path:string -> (report, string) result
(** Read every record of the store under [base_path] with this build's
    decoders. A missing store directory is an empty store. [Error] means a
    directory exists and cannot be listed, or an Exact proof link or slot
    observation names another store root than the one below [base_path] (in
    the Tool owners scan, one an original's consumer check reads); the message
    names both roots. [base_path] is read as given: the server
    resolves its workspace with {!Workspace_root.resolve_current}, so a caller
    resolves it the same way. The scan runs beside a live server and takes
    none of its locks: a record removed before it is read, or while it is
    checked, is absent, since a settle moves an original's record and then the
    body its check reads. *)

module For_testing : sig
  val scan : ?validate_tool_request:(unit -> payload_validator) ->
    ?validate_history_resolution:history_resolution_validator -> after_read:(string -> unit) ->
    Store.t -> base_path:string -> (report, string) result
  (** The same scan, calling [after_read] with each record's path once its
      bytes are read and before they are decoded, so a test can move a file
      at the point a running server could. The Exact scan calls it for every
      file it reads: a record, its proof link and the record again, in that
      order before the next record, each slot observation, and, after the
      declaration's proof links are listed, each record no fresh-state line
      deletes, once more. *)
end

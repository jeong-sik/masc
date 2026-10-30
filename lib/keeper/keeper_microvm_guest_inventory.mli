(** Complete runtime inventory for deciding whether a guest still exists.
    Labels, ownership and running state do not filter this observation. *)

type presence = Keeper_microvm_inventory_json.presence = Present | Absent

type invalid_inventory = Keeper_microvm_inventory_json.invalid_inventory =
  | Invalid_json
  | Expected_array
  | Expected_row_object
  | Duplicate_row_key
  | Invalid_configuration
  | Duplicate_configuration_key
  | Missing_identity
  | Invalid_identity
  | Conflicting_identity
  | Duplicate_guest_name

type unavailable_output = Keeper_microvm_cli_output.unavailable_output =
  | Capture_directory_unavailable
  | Capture_incomplete
  | Capture_failed
  | Capture_limit_exceeded
  | Capture_unreadable
  | Capture_permissions_invalid
  | Capture_length_mismatch
  | Capture_cleanup_failed

type error =
  | Unsupported of Keeper_microvm_backend.t
  | Invalid_guest_name
  | Command_failed of Unix.process_status
  | Invalid_inventory of invalid_inventory
  | Output_unavailable of unavailable_output

type scoping_labels = Keeper_microvm_inventory_json.scoping_labels =
  { component : string
  ; base_path_hash : string
  ; kind : string
  ; keeper : string
  }
(** Actual reported values, not assumptions about this server's scope. *)

type row = Keeper_microvm_inventory_json.row =
  { name : string
  ; scoping_labels : scoping_labels option
  }
(** [None] means missing, incomplete, duplicate, malformed or conflicting
    scoping labels. The guest still exists and must not be selected for deletion
    using this row. [Some] still requires explicit current-base/kind/component
    comparison by the owning sweep; foreign labels grant no authority. *)

type t = Keeper_microvm_inventory_json.t
(** Validated complete unfiltered inventory. This read-only observation is not
    a lifecycle scope or transferable mutation capability. *)

val rows : t -> row list
val presence : guest_name:string -> t -> (presence, error) result
val read_apple : timeout_sec:float -> (t, error) result
(** Actual canonical full Apple listing; validate every identity before label
    projection. Malformed labels never hide a guest from [presence]. *)

val read :
  backend:Keeper_microvm_backend.t -> guest_name:string -> timeout_sec:float ->
  (presence, error) result
(** Run the backend's canonical full, unfiltered listing. Only Apple is
    supported here; other backends explicitly refuse without executing a CLI.
    Every row must have a consistent nonempty identity and names must be unique.
    Require authoritative stdout EOF from the canonical process capture, then
    read its complete owned 0600 file and verify the recorded byte length.
    Bounded previews and fallback execution cannot establish absence.
    A failed call or unreadable inventory never means [Absent]. Cancellation
    propagates. No raw stdout, stderr or JSON values enter returned errors.

    This is an observation, not a transferable mutation capability. The caller
    must own the Keeper lifecycle scope continuously from this read through any
    snapshot mutation; callers cannot supply a prior absence witness. *)

val error_message : error -> string
(** A bounded explanation containing no inventory content or credential bytes. *)

module For_testing : sig
  val inventory_of_apple_json : string -> (t, error) result
  val presence_of_apple_json : guest_name:string -> string -> (presence, error) result
  (** The same complete decoder used after a successful Apple CLI call. *)
end

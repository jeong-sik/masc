(** Shared first-run batch writer. [binary] is the trusted current MASC
    executable supplied by the composition root, never an HTTP input. Native
    stage validation runs in a child, without publishing its catalog globally. *)
type revision
type error = Invalid_selection | Invalid_configuration | Changed_configuration
  | Configuration_unavailable | Validation_failed | Verification_failed of string
  | Write_failed | Rollback_failed | Lock_unavailable
type readiness = Not_probed | Verified
type receipt = { runtime_id:string; runtime_ids:string list; models:string list;
                 readiness:readiness }
val error_message : error -> string
val revision_to_string : revision -> string
val revision_of_string : string -> (revision,error) result
val observe : base_path:string -> (revision,error) result
(** Must run inside an Eio scope, like the server and native setup CLI. *)
val configure : binary:string -> base_path:string -> expected_revision:revision ->
  specs:Runtime_setup_spec.t list -> runtime_ids:string list ->
  default_runtime_id:string -> verify:bool -> unit -> (receipt,error) result
(** The selected default is placed first. Existing provider and unrelated
    settings bytes are retained. Both files are compared again after stage
    validation under the existing runtime writer lock. Publication replaces the
    overlay dependency before runtime.toml; each replacement is atomic, the pair
    is not a filesystem transaction. Reported failures restore prior bytes;
    [Rollback_failed] requires operator inspection. Successful save is not owner
    activation or sandbox readiness. *)
val receipt_json : receipt -> Yojson.Safe.t

module For_testing : sig
  val publish :
    replace:(string -> int -> string -> (unit,Fs_compat.atomic_replace_failure) result) ->
    files:(string * string) list -> (unit,error) result
  (** Fault injection at the filesystem replacement edge; uses the same
      publication/rollback implementation and real original-file snapshots. *)
end

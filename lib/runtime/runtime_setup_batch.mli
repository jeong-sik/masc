(** Shared first-run batch writer. [binary] is the trusted current MASC
    executable supplied by the composition root, never an HTTP input. Native
    stage validation runs in a child, without publishing its catalog globally. *)
type revision
type error = Invalid_selection | Invalid_configuration | Changed_configuration
  | Configuration_unavailable
  | Child_not_started of Process_eio.spawn_refusal
      (** The MASC executable could not be spawned for stage validation or
          verification. *)
  | Validation_failed of { exit : Unix.process_status; stderr : string }
      (** The native stage validator ran and did not exit 0. Carries how it
          ended and what it wrote to stderr. *)
  | Verification_failed of { runtime_id : string; code : string; message : string; detail : string option }
      (** The runtime's own verification report says it is not verified.
          [code], [message] and [detail] are the report's failure, read back
          through {!Runtime_verification.of_json}. *)
  | Verification_unreadable of { runtime_id : string; exit : Unix.process_status; stderr : string; reason : string }
      (** The verification child produced no report this module can read, or
          a verified report with a failing exit. *)
  | Write_failed | Rollback_failed | Lock_unavailable
type readiness = Not_probed | Verified
type receipt = { runtime_id:string; runtime_ids:string list; models:string list;
                 readiness:readiness }
val error_message : error -> string
(** One line: how the step ended and why, never a child's log. *)
val error_detail : error -> string option
(** The stderr of the stage validator or verification child, when one ran and
    wrote something. A diagnostic for the operator's own terminal, not for
    HTTP responses. *)
val revision_to_string : revision -> string
val revision_of_string : string -> (revision,error) result
val observe : base_path:string -> (revision,error) result
val observe_inventory : base_path:string -> (revision * Runtime.config_observation,error) result
(** One paired-file observation supplies both the private runtime text and its
    setup revision, so a menu cannot join stale rows to a newer revision. *)
(** Must run inside an Eio scope, like the server and native setup CLI. *)
val configure : ?pending_credentials:Runtime_setup_credentials.pending list -> binary:string -> base_path:string -> expected_revision:revision ->
  specs:Runtime_setup_spec.t list -> runtime_ids:string list ->
  default_runtime_id:string -> verify:bool -> unit -> (receipt,error) result
(** The selected default is placed first. Existing provider and unrelated
    settings bytes are retained. Both files are compared again after stage
    validation under the existing runtime writer lock. Publication replaces the
    overlay dependency before runtime.toml; each replacement is atomic, the pair
    is not a filesystem transaction. Reported failures restore prior bytes;
    [Rollback_failed] requires operator inspection. Successful save is not owner
    activation or sandbox readiness. Pending credential handles are retained
    immediately after publication in the same cancellation-protected phase,
    before config-lock settlement can interrupt the caller. *)
val receipt_json : receipt -> Yojson.Safe.t

module For_testing : sig
  val publish :
    replace:(string -> int -> string -> (unit,Fs_compat.atomic_replace_failure) result) ->
    files:(string * string) list -> (unit,error) result
  (** Fault injection at the filesystem replacement edge; uses the same
      publication/rollback implementation and real original-file snapshots. *)
end

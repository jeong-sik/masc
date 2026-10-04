(** Shared first-run batch writer. [binary] is the trusted current MASC
    executable supplied by the composition root, never an HTTP input. Native
    stage validation runs in a child, without publishing its catalog globally. *)
type revision
val usage_limit : Runtime_verification.failure -> bool
(** A spent quota or a rate limit: the provider answered for the account and
    declined for its usage. Setup publishes such a runtime unmeasured and
    [masc setup] accepts it; every other failure refuses both. *)
type error = Invalid_selection | Invalid_configuration | Changed_configuration
  | Configuration_unavailable
  | Child_not_started of Process_eio.spawn_refusal
      (** The MASC executable could not be spawned for stage validation or
          verification. *)
  | Validation_failed of { exit : Unix.process_status; stderr : string }
      (** The native stage validator ran and did not exit 0. Carries how it
          ended and what it wrote to stderr. *)
  | Commit_refused of string
      (** The commit that publishes the saved text refused it: the final
          in-process validation disagreed with what the staged child accepted.
          The string is the commit's refusal, several lines at most, carried
          whole by {!error_detail} rather than the one-line summary. *)
  | Verification_failed of { runtime_id : string; code : string; message : string; detail : string option }
      (** The runtime's own verification report says it is not verified, for
          a reason other than a spent quota or a rate limit ({!Usage_limited}).
          [code], [message] and [detail] are the report's failure, read back
          through {!Runtime_verification.of_json}. *)
  | Verification_unreadable of { runtime_id : string; exit : Unix.process_status; stderr : string; reason : string }
      (** The verification child produced no report this module can read, or
          a verified report with a failing exit. *)
  | Write_failed | Rollback_failed | Lock_unavailable
type usage_limited = { runtime_id : string; code : string }
(** A runtime whose provider declined the verification for the account's
    usage: a spent quota or a rate limit. It is published without a
    response and tool measurement; [code] is the report's failure code. *)
type readiness =
  | Not_probed
  | Verified
  | Usage_limited of usage_limited * usage_limited list
  | Partly_checked of { limited : usage_limited list; not_rechecked : string list }
(** [Verified] means every selected runtime answered a real check in this
    save. [Usage_limited] lists the selected runtimes that were published
    unmeasured; every other selected runtime was verified.

    [Partly_checked] is any save that left a selected runtime it did not
    call: one already bound and not first in the chain, or every selected
    runtime already bound. [not_rechecked] names those, in selection order,
    and says nothing about whether they ever passed a check. [limited] lists
    what was called and published unmeasured, and may be empty. A caller
    must not report the save as verified. *)
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
val configure : ?pending_credentials:Runtime_setup_credentials.pending list -> ?default_lane_id:string -> binary:string -> base_path:string -> expected_revision:revision ->
  specs:Runtime_setup_spec.t list -> runtime_ids:string list ->
  default_runtime_id:string -> verify:bool -> unit -> (receipt,error) result
(** The selected concrete default is placed first. [default_lane_id] preserves
    the current declared default lane, replacing only its ordered candidates;
    unrelated lanes and Keeper assignments remain unchanged. The receipt names
    that lane as [runtime_id], with concrete candidates in [runtime_ids].
    Existing provider and unrelated
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

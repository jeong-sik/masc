(** Durable current-owner state between one Keeper and one official subscription
    client session.

    This is not an AGENT_CORE checkpoint. The external client owns its transcript;
    MASC owns the exact claim, observation, recovery, and settlement phase needed
    to avoid silently duplicating an externally admitted turn. *)

type client_kind = Keeper_semantic_execution.official_client_kind =
  | Codex
  | Claude_code
  | Antigravity

type settlement =
  { session_id : string
  ; turn_id : string
  }

(* Why input-capacity recovery remains held for the same client/runtime:
   the minimum bootstrap input was rejected, or observed response/tool
   activity prevented a retry. [Effect_fenced] does not imply a floor
   rejection. [resolve_recovery] explicitly reopens the same identity. *)
type input_rejection_reason = Keeper_internal_error.official_client_input_rejection =
  | Bootstrap_floor_exceeded
  | Effect_fenced

type vendor_session_activity = Keeper_internal_error.vendor_session_activity =
  | No_activity_observed
  | Activity_observed

type recovery_failure =
  | Transient_spawn_failed
  | Owner_stopped_turn
  | Transport_interrupted
  | Protocol_failed
  | Provider_rejected
  | Input_rejected of input_rejection_reason
  | Host_hook_failed
  | State_persistence_failed
  | Process_restarted
  | Vendor_session_full of vendor_session_activity
      (** A Gate continuation resumed its original session and the vendor
          refused it as full; the argument says whether a response or tool
          effect was observed first. Only that
          session may carry the continuation, so the continuation is over:
          {!validate_continuation} refuses it, [Retry_previous] is
          unavailable, and, like every failure other than [Input_rejected],
          the next claim supersedes it with a fresh session. *)

type failure_disposition =
  | Transient
  | Ambiguous
  | Fatal

val failure_disposition : recovery_failure -> failure_disposition

(** Wire label of a failure; the inverse of the decoder used by [of_yojson].
    Projections (dashboard) reuse this instead of restating labels. *)
val recovery_failure_to_string : recovery_failure -> string

type recovery_required =
  { recovery_id : string
  ; previous_settlement : settlement option
  ; observed_session_id : string option
  ; observed_turn_id : string option
  ; owner_epoch : string
  ; failure : recovery_failure
  ; detail : string
  ; required_at : float
  }

type phase =
  | Ready
  | Start of
      { owner_epoch : string
      ; previous_settlement : settlement option
      }
  | Active of
      { owner_epoch : string
      ; session_id : string
      ; previous_settlement : settlement option
      }
  | Turn_inflight of
      { owner_epoch : string
      ; session_id : string
      ; turn_id : string option
      ; previous_settlement : settlement option
      }
  | Recovery_required of recovery_required
  | Settled of settlement

type recovery_resolution =
  | Retry_previous
  | Restart_fresh

type recovery_resolution_application =
  | Applied
  | Replayed

type recovery_commit =
  | Committed
  | Recovery_already_resolved

type recovery_resolution_error =
  | Invalid_resolved_by
  | Invalid_resolved_at
  | Session_missing
  | Session_changed
  | Recovery_id_changed
  | Recovery_not_required
  | Retry_previous_unavailable
  | Resolution_conflict
  | Store_unavailable of string

type recovery_resolution_record =
  { recovery_id : string
  ; failure : recovery_failure
  ; resolution : recovery_resolution
  ; resolved_by : string
  ; resolved_at : float
  }

type transient_release_record =
  { failure : recovery_failure
  ; owner_epoch : string
  ; released_at : float
  }

(** Delivery provenance for canonical context. Replaced configuration is an
    external snapshot available to this vendor turn, not persistent history
    injection. Canonical_source_guard binds the pre-projection source used by
    a client without replacement support; it does not claim all source bytes
    were delivered. Held_by_vendor_session records a resume that sent none of
    the canonical snapshot: the vendor session holds the conversation and the
    system prompt it recorded at its first launch, and MASC sent only its
    composed per-turn context in front of the user prompt
    ({!Keeper_official_client_host.resume_prompt}). Its snapshot hash names the
    canonical history MASC held at that turn, not bytes the model read. No
    receipt asserts that the model understood its contents. *)
type context_delivery =
  | Prepared_start_context
  | Replaced_configuration
  | Canonical_source_guard
  | Held_by_vendor_session

type context_frontier =
  { snapshot_sha256 : string
  ; message_count : int
  ; delivery : context_delivery
  ; acknowledged_turn : settlement option
    (** None during claim/inflight. Only exact vendor settlement records Some. *)
  }

type t =
  { client_kind : client_kind
  ; runtime_id : string
  ; phase : phase
  ; turn_count : int
  ; tool_surface_sha256 : string
  ; context_frontier : context_frontier option
  ; last_recovery_resolution : recovery_resolution_record option
  ; last_transient_release : transient_release_record option
  ; updated_at : float
  }

type context_admission_error = Context_frontier_missing | Canonical_context_changed

(** What a claim under [Canonical_source_guard] did with the stored settlement.
    [Context_restarted] names why the retained vendor conversation could not be
    resumed; the claim then opens a fresh session instead. *)
type context_reconciliation =
  | Context_kept
  | Context_restarted of context_admission_error

type claim_plan =
  { previous_settlement : settlement option
  ; turn_count : int
  ; required_tool_surface_sha256 : string option
  }

type claim_error =
  | Invalid_runtime_id
  | Input_recovery_required of Keeper_internal_error.official_client_recovery
  | Turn_count_exhausted
  | Start_incomplete
  | Active_unsettled
  | Turn_already_inflight

val process_epoch : unit -> string
(** One UUID for the current MASC process. A durable incomplete claim owned by
    another epoch is a restart ambiguity, not an active same-process turn. *)

val path : base_path:string -> keeper_name:string -> (string, string) result

val tool_surface_sha256 :
  native_posture:Runtime_native_tools.posture -> Agent_core.Tool.t list -> string
(** Stable digest of the exact typed dynamic-tool surface, the keeper's
    native-tool posture, and official-client context-message schema. Tool
    order, parameter order, and JSON object field order do not affect the
    digest; tool semantics, posture, and history framing do. A framing or
    posture change therefore starts a fresh provider conversation instead of
    resuming a session that cannot receive the new surface. *)

val load : base_path:string -> keeper_name:string -> (t option, string) result
(** Missing state is [Ok None]. Malformed, retired, or ambiguous state is an
    error and never degrades to a new session. *)

val clear_then :
  base_path:string -> keeper_name:string -> (unit -> 'a) -> ('a, string) result
(** [clear_then ... after_clear] durably removes the current binding, then runs
    [after_clear] before releasing the same claim lock. New claims therefore
    cannot observe an absent binding until the caller's paired durable mutation
    has finished. [after_clear] must not take this claim lock again, and every
    other lock it takes is ordered under this one. Missing state still runs
    [after_clear] without creating the optional session-store directory or its
    sibling lock. A completed callback result survives a lock-release failure;
    that release failure is logged separately. A binding that cannot decode is
    not resumable, so clear warns and removes it under the lock instead of
    wedging the Keeper permanently. *)

module For_testing : sig
  val clear_then_with_release_failure :
    release_failure:File_lock_eio.durable_lock_error ->
    base_path:string ->
    keeper_name:string ->
    (unit -> 'a) ->
    ('a, string) result
end

val commit_if_input_recovery_current :
  base_path:string ->
  keeper_name:string ->
  expected:Keeper_internal_error.official_client_recovery ->
  commit:(unit -> unit) ->
  (recovery_commit, string) result
(** Run [commit] under the durable session lock only while the same runtime,
    recovery id, and typed input-rejection reason are still current.
    [Recovery_already_resolved] means recovery was resolved or replaced before
    the commit. The callback must not suspend or re-enter this session store.
    It runs while the file lock is held. The registry-publication callback used
    by [Keeper_unified_turn_failure] then acquires
    [Keeper_lifecycle_reservation.with_key_lock], establishing the order
    session-store lock before lifecycle-reservation lock. Callers must not hold
    the lifecycle-reservation lock before entering this function. The callback
    stays inside the lock so recovery cannot change between the current-state
    check and its publication. *)

val claim_error_to_string : claim_error -> string
val core_error_of_claim_error : claim_error -> Agent_core.Error.t
(** Preserve an operator-held input rejection as a typed MASC recovery cause.
    Other claim refusals retain the official-client claim configuration error. *)

val plan_claim :
  expected:t option ->
  client_kind:client_kind ->
  runtime_id:string ->
  (claim_plan, claim_error) result
(** Pure claim planning shared by every official-client adapter. The plan is
    the SSOT for fresh versus resumed execution, the next turn ordinal, and
    whether the prepared tool surface must match a settled session. *)

val reconcile_tool_surface : claim_plan -> tool_surface_sha256:string -> claim_plan
(** Fold a moved tool surface into the plan. A settled session whose stored
    digest differs from the prepared one is not resumable and cannot be
    recovered -- [Settled] never becomes [Recovery_required], so no id exists
    for the resolve endpoint. Rather than refusing the turn, the plan becomes
    the fresh-session plan [plan_claim] already produces for a changed
    [client_kind] or [runtime_id]: what the prior session settled against no
    longer describes this execution. Every adapter must apply this before
    [claim], and [claim] applies it again so a caller cannot skip it. *)

val validate_continuation : checkpoint:Keeper_semantic_execution.official_client_checkpoint ->
  expected:t option -> client_kind:client_kind -> runtime_id:string -> tool_surface_sha256:string ->
  (unit, string) result
(** Before model dispatch, bind a Gate resume to the original native session.
    The captured turn must still be current; changing sessions or tools is not. *)

val validate_completed_continuation :
  checkpoint:Keeper_semantic_execution.official_client_checkpoint ->
  expected:t option -> (unit, string) result
(** After transmitted input settles, require a different turn in the captured
    session with the same runtime and tool surface. Admission still requires
    the original turn through [validate_continuation]. *)

val validate_unchanged_context : expected:t option -> snapshot_sha256:string ->
  (unit, context_admission_error) result
val context_admission_error_to_string : context_admission_error -> string

val reconcile_context_frontier :
  claim_plan ->
  expected:t option ->
  context_frontier:context_frontier option ->
  claim_plan * context_reconciliation
(** Fold a moved canonical source into the plan. A resume under
    [Canonical_source_guard] whose stored frontier does not match the prepared
    snapshot becomes the fresh-session plan, as [reconcile_tool_surface] does
    for a moved tool surface: refusing it left the settled session with no
    recovery id and no settled turn to advance its frontier, so every later
    turn was refused the same way (#38328). [claim_with_context_frontier]
    applies it too. A caller bound to the original vendor session must refuse
    on [Context_restarted] rather than proceed. *)

val claim_with_context_frontier :
  context_frontier:context_frontier option ->
  base_path:string ->
  keeper_name:string ->
  expected:t option ->
  client_kind:client_kind ->
  owner_epoch:string ->
  runtime_id:string ->
  tool_surface_sha256:string ->
  updated_at:float ->
  (t, string) result

val claim :
  base_path:string ->
  keeper_name:string ->
  expected:t option ->
  client_kind:client_kind ->
  owner_epoch:string ->
  runtime_id:string ->
  tool_surface_sha256:string ->
  updated_at:float ->
  (t, string) result
(** Claim the next exact turn. A terminal binding may start fresh when its
    declared client kind or runtime id changes. Resuming the same settled
    client/runtime requires an identical tool surface. A same-process Start,
    Active, or Turn_inflight phase rejects a concurrent claim. A completed
    failure observation other than [Input_rejected] may be superseded atomically
    by a fresh-session claim. Same-identity [Input_rejected] remains held for
    explicit recovery resolution. *)

val mark_active :
  base_path:string ->
  keeper_name:string ->
  expected:t ->
  session_id:string ->
  updated_at:float ->
  (t, string) result

val mark_turn_starting :
  base_path:string ->
  keeper_name:string ->
  expected:t ->
  session_id:string ->
  updated_at:float ->
  (t, string) result

val mark_turn_started :
  base_path:string ->
  keeper_name:string ->
  expected:t ->
  session_id:string ->
  turn_id:string ->
  turn_count:int ->
  updated_at:float ->
  (t, string) result

val settle :
  base_path:string ->
  keeper_name:string ->
  expected:t ->
  session_id:string ->
  turn_id:string ->
  updated_at:float ->
  (t, string) result

val require_recovery :
  base_path:string ->
  keeper_name:string ->
  expected:t ->
  failure:recovery_failure ->
  detail:string ->
  required_at:float ->
  (t, string) result
(** Convert the exact incomplete claim into an operator-visible failure
    observation. The next claim may supersede it atomically; an operator may
    still resolve it first to choose the previous settlement or a fresh start. *)

val conclude_resume_session_full :
  base_path:string ->
  keeper_name:string ->
  expected:t ->
  recovery_id:string ->
  updated_at:float ->
  (t, string) result
(** Re-record the exact [Input_rejected Bootstrap_floor_exceeded] recovery of a
    resumed session as [Vendor_session_full No_activity_observed], keeping its
    recovery id and evidence. A caller uses it once the same-session shrink
    retries of a Gate continuation have run out: no smaller input remains, and
    no other session may carry the continuation. Any other phase or failure is
    refused. *)

val release_transient :
  base_path:string ->
  keeper_name:string ->
  expected:t ->
  failure:recovery_failure ->
  released_at:float ->
  (t, string) result
(** Release one exact incomplete claim only when [failure] is classified
    [Transient]. The previous settlement, if any, is restored atomically. *)

val reconcile_process_restart :
  base_path:string ->
  keeper_name:string ->
  expected:t ->
  current_owner_epoch:string ->
  required_at:float ->
  (t, string) result
(** Convert an incomplete claim owned by a different process epoch into an
    explicit ambiguous recovery. Same-epoch claims remain occupied. *)

val resolve_recovery :
  base_path:string ->
  keeper_name:string ->
  expected:t ->
  recovery_id:string ->
  resolution:recovery_resolution ->
  resolved_by:string ->
  resolved_at:float ->
  ((t * recovery_resolution_application), recovery_resolution_error) result
(** Resolve one exact recovery claim with compare-and-swap authority.
    [Retry_previous] restores the last settled session and drops only the turn
    that failed, so the next claim re-attempts the same ordinal against it.
    A [Vendor_session_full] recovery has no [Retry_previous]: the same
    resume would be refused again.
    [Restart_fresh] abandons the conversation, so the ordinal restarts with it
    and the next claim asks for ordinal 1 -- the same reset an automatic
    supersede performs. Repeating the same recovery id and decision returns the
    already committed binding as [Replayed]; a different decision for the same
    recovery id is a conflict. *)
(** Every phase change is a process-safe durable compare-and-swap followed by
    exact read-back. Any incomplete phase blocks a later automatic claim. *)

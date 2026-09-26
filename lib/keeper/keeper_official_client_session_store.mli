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

(** Delivery provenance for canonical context. Prepared_start_context is the
    history a new vendor session was seeded with. Canonical_source_guard binds
    the pre-projection source used by a client without replacement support; it
    does not claim all source bytes were delivered. Held_by_vendor_session records a resume that sent none of
    the canonical snapshot: the vendor session holds the conversation and the
    system prompt it recorded at its first launch, and MASC sent in front of
    the user prompt only the composed per-turn context the session did not
    already hold ({!Keeper_official_client_host.resume_prompt}). Its snapshot hash names the
    canonical history MASC held at that turn, not bytes the model read. No
    receipt asserts that the model understood its contents. *)
type context_delivery =
  | Prepared_start_context
  | Canonical_source_guard
  | Held_by_vendor_session

(** One piece of per-turn context a resume carries in front of its prompt,
    named by what composed it: one typed block of the context carrier, the
    whole carrier when its blocks are not known, the Librarian working state,
    or the historical task reference. *)
type carried_context =
  | Context_block of Prompt_block_id.t
  | Context_carrier
  | Librarian_working_state
  | Historical_task_reference

(** A carried context the vendor session holds, and the sha256 of the exact
    text it was sent. *)
type held_context =
  { context : carried_context
  ; sha256 : string
  }

type context_frontier =
  { snapshot_sha256 : string
  ; message_count : int
  ; delivery : context_delivery
  ; acknowledged_turn : settlement option
    (** None during claim/inflight. Only exact vendor settlement records Some. *)
  ; held_context : held_context list
    (** What of the carried context the vendor session holds once this turn
        is acknowledged: a start holds every context it composed, a resume
        adds what it sent to what the resumed session already held. It is
        read only through {!held_context_for_resume}, so an unacknowledged
        frontier is never taken as held. Empty when nothing is known to be
        held. *)
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
  ?account_home:string -> native_posture:Runtime_native_tools.posture -> Agent_core.Tool.t list -> string
(** Stable digest of the exact typed dynamic-tool surface, the keeper's
    native-tool posture, and official-client context-message schema. Tool
    order, parameter order, and JSON object field order do not affect the
    digest; tool semantics, posture, and history framing do. A framing or
    posture change therefore starts a fresh provider conversation instead of
    resuming a session that cannot receive the new surface. A selected account
    home also enters the digest, so changing it never resumes another home's
    vendor session. *)

val load : base_path:string -> keeper_name:string -> (t option, string) result
(** Missing state is [Ok None]. Malformed, retired, or ambiguous state is an
    error and never degrades to a new session. *)

type stored_binding =
  { keeper_name : string
  ; path : string
  ; decoded : (t, string) result
  }

val stored_bindings : base_path:string -> (stored_binding list, string) result
(** Every binding file under the keepers directory {!path} writes to, decoded
    with {!load}'s decoder, in keeper-name order. Each entry is read the way
    a claim reads it, a linked keeper directory included; a keeper without
    the file is left out, and so is an entry whose name {!path} refuses,
    because this store never writes there. [Ok []] when the keepers
    directory does not exist; [Error] when it exists but cannot be inspected
    or listed. Reads only. The deploy preflight and boot reconcile both read
    the store through this. *)

val move_aside :
  base_path:string -> keeper_name:string -> rejected_path:string -> (unit, string) result
(** Rename the keeper's binding to [rejected_path] while holding the store
    lock every claim and transition takes. The binding is read again under
    the lock; one that decodes now, or is gone, is left alone and the result
    is [Error]. The keeper's next claim finds no binding and starts a new
    vendor session. A rename that completed stays [Ok] even when releasing
    the lock fails; that failure is logged. *)

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

val held_context_for_resume : claim_plan -> expected:t option -> held_context list
(** The carried context the session a claim plan resumes already holds: the
    [held_context] of a frontier acknowledged by exactly that settlement.
    Anything else -- a fresh plan, a frontier the settlement did not
    acknowledge, or no frontier -- is [[]], so a resume that cannot show what
    the session holds re-sends every carried context. *)

val reconcile_context : claim_plan -> expected:t option -> snapshot_sha256:string -> claim_plan
(** Fold an unproven canonical source into the plan, as
    {!reconcile_tool_surface} does for a moved tool surface. A settled session
    resumes only when its acknowledged frontier matches the prepared canonical
    history and system prompt. When it differs, or no frontier was
    acknowledged so nothing shows what the session settled against, the plan
    becomes the fresh-session plan instead of refusing every later turn; what
    lived only in the superseded vendor conversation is not carried over.
    [claim_with_context_frontier] applies this again for
    [Canonical_source_guard]. A Gate continuation, bound to its original
    session, does not use this: it refuses with {!validate_unchanged_context}. *)

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

val settle_holding :
  held_context:held_context list ->
  base_path:string ->
  keeper_name:string ->
  expected:t ->
  session_id:string ->
  turn_id:string ->
  updated_at:float ->
  (t, string) result
(** {!settle}, also replacing the frontier's [held_context] in the same
    durable write. A lane uses it when the turn changed what the vendor
    session holds after the claim was recorded, as when the client compacted
    the conversation and the copies it held are no longer there as sent. *)

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

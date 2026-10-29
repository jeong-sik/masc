(** Runtime adapter for tool-free LLM-owned current Memory OS selection.

    The exact-output flow receives only the immutable Librarian input. No tool
    output or external research is admitted to the persistent Memory OS
    mutation path. One atomic current-snapshot replacement remains the sole
    mutation authority. *)

val messages_for_librarian
  :  Keeper_librarian.input
  -> (Agent_core.Types.message list, string) result

(** Every variable the [librarian] template is rendered with for a Memory
    pass, with the [continuity] range when one is attached: the input's own
    variables and the shared [working_contexts_rule] fragment. *)
val librarian_prompt_variables
  :  ?continuity:Keeper_librarian_continuity.prepared
  -> Keeper_librarian.input
  -> ((string * string) list, string) result

type extraction_error

val extraction_error_to_string : extraction_error -> string

type slot_refusal =
  { slot_id : string
  ; cause : Agent_core.Exact_output.admission_error
  }

(** Render each rejected slot and its typed admission cause once, for the
    exclusion WARN and the all-slots-refused error. *)
val slot_reason_pairs : ?sep:string -> slot_refusal list -> string

type preflight_selection =
  { selected_slots : Runtime_exact_output_registry.selected_slot list
  ; unusable : slot_refusal list
  }

val preflight_slots
  :  requirement:Agent_core.Exact_output.output_requirement
  -> selected_slots:Runtime_exact_output_registry.selected_slot list
  -> messages:Agent_core.Types.message list
  -> (preflight_selection, extraction_error) result
(** The pre-flight over the ladder: the selected slots whose request projected
    and the slots this run is without (id and typed admission cause). The execution
    flow receives only [selected_slots]; a ladder with no projectable slot at
    all is [Exact_request_projection_failed], naming each refusal. An empty
    ladder reports two empty lists -- the caller routes it to the cli lane.
    The execution caller also tries declared CLI slots after all API
    projections are refused, preserving this error if no CLI answer is
    accepted. *)


type served_slot =
  | Api_slot of string
      (** An API slot, named by its exact-output flow candidate id. *)
  | Cli_slot of string
      (** A CLI slot, named by its lane runtime id -- the id a CLI's
          {!Keeper_lane_cli_oneshot.input_capacity} carries. *)
(** The slot whose answer a pass accepted. The two transports name slots from
    separate spaces, so a caller asks which transport answered by
    constructor, not by comparing ids. *)

val served_slot_id : served_slot -> string

type write_scope = Context_only | Context_and_memory | Memory_maintenance
(** The caller names the evidence's purpose. A durable range retains Memory
    processing. [Context_only] never writes Memory, so it never asks for a
    Memory judgment: with [continuity] it asks the [librarian.continuity]
    prompt for the working state alone, and without it the
    [librarian.working_context] prompt for the working contexts alone. Each
    answer is refused if it carries any other field. *)
(* [Memory_maintenance] curates the current Memory snapshot without publishing
   a working-context or continuity snapshot or advancing history cursors. *)

type input_capacity_evidence = No_input_capacity_refusal | Input_capacity_refused
(** Admission partitioning evidence, distinct from the historical range-window
    policy. Only a typed input/context-capacity refusal establishes it; output,
    schema, domain, timeout and ordinary transport failures do not. *)

type message_descent =
  | No_descent_evidence
  | Smaller_input_may_help
  | Invalid_output_blocks_descent
(** Whether reading a smaller original message input may answer the failed
    walk. A safe native context refusal needs no invented character limit.
    Invalid JSON/domain output vetoes descent across the complete walk.
    This policy never grants permission to skip an unread message. *)

type not_committed =
  { input_capacity_evidence : input_capacity_evidence
  ; message_descent : message_descent
      (** Whole-walk policy, independent of measured historical fitting and
          actual exhausted API evidence used to authorize unread records. *)
  ; provider_input_refusals : Keeper_librarian_input_refusal.t list
      (** Named provider input refusals encountered in the walk, including earlier
          slots. Empty for local admission, unknown/opaque CLI failures and
          timeouts. This records the actual causes without granting consumption
          authority or claiming that the selected source is indivisible. *)
  ; detail : string
        (** Diagnostic text for the caller's log, not a classification input. *)
  ; walk_shows_size : bool
        (** Historical range-window adaptation hint, not authoritative evidence
            that the input exceeded capacity. Admission partitioning must use
            [input_capacity_evidence] instead. Message descent uses the separate
            [message_descent] policy, which also recognizes unmeasured native
            context refusals. This historical policy can include:
            a provider that judged the request too large, one that refused it
            for a reason it did not name, a refused output, or a candidate
            whose projection did not fit a slot's declared window.

            Invalid JSON or domain output stops partition traversal, including
            a walk that also encountered a capacity refusal.

            False covers everything else, and a caller reading less only when
            this is true is what keeps an outage from shrinking its reads. An
            HTTP refusal from a provider that took the request and could not
            serve it (quota, overload, server, network), a refusal only an
            operator can lift (authentication, authorization, payment, an
            absent model), and every failure that never reached a provider all
            answer false, as does a pass that recorded no typed cause at all.
            A provider error that is not an HTTP refusal arrives as
            [Completion_failed] with its typed transport error and whether
            the request was sent. A request never sent answers false. A sent
            one answers true only for a named context overflow, an oversized
            response, a deadline on the request's own processing, or an empty
            completion stopped by the context window or the output budget. A
            dropped connection, a DNS failure, a hard quota, an idle stream,
            any other empty completion and every unclassified failure answer
            false.

            The verdict covers every failed visit of the walk, not the last
            one, so the same set of causes answers the same way whatever order
            the slots were tried in. *)
  ; smaller_range_meets_same_failure : bool
        (** Some visit of the walk also failed for a reason a smaller range
            meets the same way: an execution failure whose cause answers false
            above and is not invalid output, or a CLI slot that ran and failed
            without naming its input capacity. A candidate turned away before
            dispatch and a slot this process could not run do not count.

            [walk_shows_size] keeps its own answer; this field adds to it. A
            caller that reads one smaller range once can ignore it. A caller
            that splits recursively on [walk_shows_size] reads it as a veto:
            each part would send the failing slot another request, up to
            2N-1 of them during a quota or an outage. *)
  }

val merge_message_descent : message_descent -> message_descent -> message_descent
(** Invalid output is absorbing; a neutral local settlement report cannot
    erase an earlier size observation or unblock an earlier invalid output. *)

val not_committed_of_failure : detail:string -> Keeper_exact_walk_failure.t -> not_committed
(** The one place whole-walk host evidence becomes a pass report. Both the
    direct Runtime walk and the Add-on original refusal use it, so a given
    observation reads the same on either path. *)

val may_descend_messages : not_committed list -> bool
(** Fold every report for the failed pass. Empty reports and unclassified
    transport failures grant no descent; any invalid-output veto holds even
    alongside a measured CLI limit. This is not an unread-message authorization. *)

type inference_failure = private
  { reports : not_committed list
  ; exhausted_input_refusals : Keeper_librarian_input_refusal.t list option
  }
(** [Some] contains nonempty named input refusals from an actually exhausted
    API-only walk. Every declared candidate reached generation and no CLI tail,
    semantic/domain-invalid output or local terminal interrupted the walk.
    Diagnostic reports alone never establish this skip authority. *)

type working_state_prompt = private
  { run_id : string
  ; resolution : Prompt_registry.prompt_resolution
  ; variables : (string * string) list
  ; rendered_prompt : string
  ; output_schema : Yojson.Safe.t
  }
(** Immutable base prompt and requirement captured by the actual inference
    pass before preflight. CLI transports append their schema instructions.
    This is preparation evidence, not provider-wire or dispatch evidence. *)

type working_state_preparation =
  | Not_prepared
  | Prompt_failed of { run_id : string; variables : (string * string) list; detail : string }
  | Prompt_prepared of working_state_prompt
(** [Not_prepared] means the pass never reached prompt preparation. Failure
    reports retain the actual setup reason; no later prompt lookup fills it. *)

type working_state_outcome =
  | Inferred of { working_state : string; served_by : served_slot }
  | Not_inferred of inference_failure

type working_state_inference =
  { preparation : working_state_preparation
  ; outcome : working_state_outcome
  }

val infer_working_state
  :  ?cli_runner:Keeper_lane_cli_oneshot.runner
  -> base_path:string
  -> keepers_dir:string
  -> keeper_id:string
  -> previous_state:string option
  -> unread_messages:Keeper_librarian_unread.t list
  -> Keeper_librarian.input
  -> working_state_inference
(** Infer a volatile continuation from exactly the supplied conversation.
    Uses the normal exact-output lane and strict working-state answer, but
    writes no Memory, continuity snapshot, queued context or read cursor.
    [Not_inferred] preserves failure reports in callback order. Cancellation
    propagates. The caller owns source selection and any later publication. *)

type memory_step = private
  { run_id : string
  ; source_input : Keeper_librarian.input
  ; prompt_variables : (string * string) list
  ; rendered_prompt : string
  ; absorb_gate : Keeper_librarian_absorb_gate.run_result
  ; new_claims : Keeper_memory_os_types.fact list
  ; dropped : Keeper_memory_os_types.dropped_statement list
  ; absorbed : Keeper_memory_os_types.absorbed_statement list
  ; revisions : Keeper_memory_os_types.revision list
  ; working_state : string
  }
(** A parsed Memory decision after the normal absorption/copy gate. Original
    fact fields, retirement reasons and exact revision/absorption identities
    are retained. The original rendered base prompt and variables preserve the
    host context actually used, without re-rendering later under changed config. This is not a stored snapshot or a consumption receipt.
    It must be composed against its original current facts before it can
    become the current input of another step; a working-state summary is
    never substituted for Memory evidence. *)

type memory_inference =
  | Memory_inferred of { step : memory_step; served_by : served_slot }
  | Memory_not_inferred of inference_failure

val infer_memory_step
  :  ?cli_runner:Keeper_lane_cli_oneshot.runner
  -> base_path:string
  -> keepers_dir:string
  -> keeper_id:string
  -> previous_state:string option
  -> unread_messages:Keeper_librarian_unread.t list
  -> Keeper_librarian.input
  -> memory_inference
(** Judge exactly this input using the Memory prompt, strict Memory/continuity
    answer and the ordinary absorption gate, without publishing Memory,
    continuity, working contexts or range receipts. Inference/failure evidence
    is recorded by the existing lane observer. A gate failure leaves the
    whole step unaccepted. Cancellation propagates. *)

val fit_continuity :
  capacity:Keeper_lane_cli_oneshot.input_capacity -> base_path:string -> keeper_id:string ->
  input_for:(Keeper_librarian_continuity.prepared -> (Keeper_librarian.input, string) result) ->
  Keeper_librarian_continuity.prepared ->
  (Keeper_librarian_continuity.prepared option, string) result
(** Fit the complete rendered CLI prompt to a reported character limit while its
    runtime remains declared in the lane. Each candidate is measured with the
    input [input_for] gives it, so what a Memory pass over that candidate
    carries counts. Returns [None] if no safe source fits. Does not dispatch a
    provider or change Memory receipts. *)

(** Standalone judgment {!run_best_effort} applies to its optional admission
    arguments: an explicit admission batch rides only a standalone
    [Memory_maintenance] pass with no continuity or range binding. Each boolean
    is the presence of the corresponding optional argument. Exposed so tests
    can pin the accepted and rejected combinations. *)
val admission_mode_valid
  :  has_admission:bool
  -> write_scope:write_scope
  -> has_continuity:bool
  -> has_durable_range_id:bool
  -> has_official_range_id:bool
  -> bool

val run_best_effort
  :  ?write_scope:write_scope
  -> ?admission:Keeper_memory_admission_queue.batch
       (** Explicit candidates use a separate strict judgment envelope. Any
           deferred candidate leaves the entire batch pending. This mode is
           valid only with [Memory_maintenance] and no conversation ranges. *)
  -> ?continuity:Keeper_librarian_continuity.prepared
  -> ?on_memory_committed:(unit -> unit)
       (** Synchronous observation at the snapshot commit. Must only update
           caller-owned in-memory state, without I/O, yielding or raising. *)
  -> ?on_cli_input_limit:(Keeper_lane_cli_oneshot.input_capacity -> unit)
       (** The largest typed character limit reported by any refusing CLI slot,
           with that slot's runtime ID, for {!fit_continuity}. Keeping the
           most permissive observed boundary lets at least one measured CLI
           take the fitted input. An API slot's refusal reports none. *)
  -> ?on_not_committed:(not_committed -> unit)
  -> ?on_admission_deferred:(unit -> unit)
       (** Observes a completed, validated admission answer deferring every
           candidate. Not fired for provider, schema, store or dispatch failure.
           This grants no consumption authority. Callback must not raise. *)
  -> ?on_continuity_committed:(served_by:served_slot -> Librarian_continuity_snapshot.t -> unit)
       (** [served_by] is the slot whose answer committed. *)
  -> ?on_context_committed:(Keeper_librarian_context.version -> unit)
       (** The working-context version this pass wrote, observed right after
           that write succeeds. Same constraints as [on_memory_committed]. *)
  -> ?durable_range_id:Keeper_memory_os_current.durable_range_id
  -> ?official_range_id:Keeper_memory_os_current.official_range_id
  -> ?cli_runner:Keeper_lane_cli_oneshot.runner
       (** Injectable effect edge for the cli lane-slot fallback walked after
           catalog exhaustion (RFC cli-runtimes-as-lane-slots); [None] spawns
           the real official client. *)
  -> base_path:string
  -> keepers_dir:string
  -> keeper_id:string
  -> expected_revision:int option
  -> Keeper_librarian.input
  -> unit
(** Execute a Librarian unit already admitted by its producer. The input
    arrives already selected -- a durable range, official-line fragments, or a
    Context-only pass with no messages -- and nothing here trims it.
    [on_memory_committed] runs only after the current Memory OS snapshot write
    succeeds. [durable_range_id] and [official_range_id] are committed through the Memory store's WAL
    sidecar, so a durable consumer can recover a later progress-file failure
    without submitting the completed-turn range again. *)

(** What an accepted answer publishes besides Memory. A continuity pass is
    accepted only with its working state, so the two arrive together. *)
type continuity_answer =
  | Memory_only
  | Continuity of
      { prepared : Keeper_librarian_continuity.prepared
      ; working_state : string
      }

type accepted =
  { selection : Keeper_librarian.selection
  ; continuity_answer : continuity_answer
  ; required_memory_ids : string list
      (** Admission destinations that must survive the locked disposition. *)
  ; explicit_candidate_ids : Keeper_memory_os_current.explicit_candidate_id list
      (** Independently settled candidate identities bound to the disposition. *)
  ; admission_support : string list
      (** Declared candidate support exposed to the absorption judge. *)
  ; admission_recall_bindings : Keeper_memory_os_current.admission_recall_binding list
      (** Original admitted observations bound to their selected current targets. *)
  }

(** Original completed-history [Memory_pass None] preparation. This is separate
    from explicit-candidate admission and grants no publication authority. *)
type durable_policy = {
  facts_max_bytes : int;
  category_cap : int;
  facts_per_category_cap : int;
}
type durable_preparation = {
  source_input : Keeper_librarian.input;
  parsing_now : float;
  policy : durable_policy;
  rule_prompt : Prompt_registry.prompt_resolution;
  prompt : Prompt_registry.prompt_resolution;
  variables : (string * string) list;
  rendered_prompt : string;
  output_schema : Yojson.Safe.t;
}
val prepare_durable : now:float -> Keeper_librarian.input ->
  (durable_preparation, string) result
(** Resolve the original policy and both prompt assets once, on the caller
    fiber. The synchronous Memory pass consumes this same preparation. *)
val validate_durable_preparation : durable_preparation -> (unit, string) result
(** Pure restoration check of the complete captured input, policy, resolutions,
    substitutions, rendered prompt and schema. No environment/prompt lookup. *)
val restore_durable_preparation : source_input:Keeper_librarian.input -> parsing_now:float ->
  policy:durable_policy -> rule_prompt:Prompt_registry.prompt_resolution ->
  prompt:Prompt_registry.prompt_resolution -> output_schema:Yojson.Safe.t ->
  (durable_preparation, string) result
(** Render the substitutions and prompt again from the captured input and the
    retained resolutions, then {!validate_durable_preparation}. No
    environment/prompt lookup. *)
type durable_absorption = {
  observations : Yojson.Safe.t list;
  facts : Keeper_memory_os_types.fact list;
  new_claims : Keeper_memory_os_types.fact list;
  superseding : string list;
  absorbed : Keeper_memory_os_types.absorbed_statement list;
}
type durable_proposal = private {
  accepted : accepted;
  absorption : durable_absorption;
}
type durable_proposal_error =
  | Preparation_invalid of string
  | Proposal_invalid of Keeper_librarian.parse_error
val validate_durable_proposal : durable_preparation -> Yojson.Safe.t ->
  (durable_proposal, durable_proposal_error) result
(** Check the restored original preparation, parse the complete raw Memory
    answer against its original input/time, and prepare the ordinary absorption
    inputs. No provider, gate judgment, locked disposition or source ACK is
    performed. [accepted] retains the normal Memory-only answer, including its
    independent working-context result; explicit-candidate fields stay empty. *)

(** {1 Durable message-floor steps}

    One question of the durable message floor (RFC librarian-durable-message-floor).
    It is the question the Runtime floor asks for the same message: the same
    prompt with the working state so far and the unread messages in its
    continuity slot, answered under the schema that requires a nonblank working
    state. A durable step freezes the policy and prompt resolutions as any
    durable question does, so a restored step renders the bytes it was sent. *)
type durable_step_context = {
  previous_state : string option;
  unread_messages : Keeper_librarian_unread.t list;
}
type durable_step_preparation = {
  context : durable_step_context;
  preparation : durable_preparation;
      (** [preparation.source_input] is the question's input with its working
          context cleared, as the Runtime floor clears it. *)
}
val prepare_durable_step : now:float -> context:durable_step_context -> Keeper_librarian.input ->
  (durable_step_preparation, string) result
(** Resolve the policy and both prompt assets once, on the caller fiber, for one
    floor question. [input] is the question as {!Keeper_librarian_message_floor.Machine}
    asks it. *)
val validate_durable_step_preparation : durable_step_preparation -> (unit, string) result
(** Pure restoration check: the captured input holds no working context, and the
    substitutions, rendered prompt and continuity schema match the input,
    context and retained resolutions. No environment or prompt lookup. *)
val restore_durable_step_preparation : context:durable_step_context ->
  source_input:Keeper_librarian.input -> parsing_now:float -> policy:durable_policy ->
  rule_prompt:Prompt_registry.prompt_resolution -> prompt:Prompt_registry.prompt_resolution ->
  output_schema:Yojson.Safe.t -> (durable_step_preparation, string) result
(** Render the substitutions and prompt again from the captured input, context
    and retained resolutions, then {!validate_durable_step_preparation}. *)
type durable_step_proposal = private {
  proposal : durable_proposal;
      (** The Memory answer as a durable pass reads it, parsed against the
          step's input. *)
  working_state : string;
}
val validate_durable_step_proposal : durable_step_preparation -> Yojson.Safe.t ->
  (durable_step_proposal, durable_proposal_error) result
(** Check the restored preparation, parse the raw Memory answer against the
    step's input at the frozen parsing time, and require a nonblank working
    state. No provider, gate judgment or Memory write. *)
val durable_memory_step : run_id:string -> durable_step_preparation -> durable_step_proposal ->
  absorb_gate:Keeper_librarian_absorb_gate.run_result -> (memory_step, string) result
(** The gated decision a retained step stands for, in the form the ordered
    Memory plan and program take. The caller supplies the gate's judgment of this
    step's proposal. A failed judgment, or a blank [run_id], is an error and no
    decision. *)

(** Shared original explicit-candidate preparation and complete validation.
    These ports perform no provider call or Memory/queue mutation. *)
type admission_policy = {
  facts_max_bytes : int;
  category_cap : int;
  facts_per_category_cap : int;
}
type admission_preparation = {
  policy : admission_policy;
  rule_prompt : Prompt_registry.prompt_resolution;
  prompt : Prompt_registry.prompt_resolution;
  variables : (string * string) list;
  rendered_prompt : string;
  output_schema : Yojson.Safe.t;
}
type admission_proposal = Deferred | Accepted of accepted
val prepare_admission : batch:Keeper_memory_admission_queue.batch ->
  retirement:Keeper_memory_admission_judgment.retirement_evidence ->
  Keeper_librarian.input -> (admission_preparation, string) result
(** Resolve the current template/fragments on the caller fiber; the host
    retains this complete preparation and original substitution bytes before
    dispatch. It is not a grant to a worker. *)
val validate_admission_preparation : batch:Keeper_memory_admission_queue.batch ->
  retirement:Keeper_memory_admission_judgment.retirement_evidence ->
  input:Keeper_librarian.input -> admission_preparation -> (unit, string) result
(** Pure captured-template/input/schema consistency check; never resolves a
    current prompt. *)
val validate_admission_proposal : now:float ->
  batch:Keeper_memory_admission_queue.batch -> input:Keeper_librarian.input ->
  Yojson.Safe.t -> (admission_proposal, Keeper_librarian.parse_error) result

module For_testing : sig
  val cause_input_refusals : Agent_core.Exact_output.execution_error_cause -> Keeper_librarian_input_refusal.t list
  (** Named provider refusals, independently of the wider historical sizing policy. *)
  val cause_shows_size : Agent_core.Exact_output.execution_error_cause -> bool
  (** The size verdict one provider cause gives, so the whole table can be
      asserted cause by cause. A walk reads less when any of its failures
      answers true. *)

  val cli_failure_shows_size : Keeper_lane_cli_oneshot.failure -> bool
  (** The same verdict for one official-client slot's failure. *)

  val disposition_shows_size : Agent_core.Exact_output.candidate_rejection_disposition -> bool
  (** The same verdict for a candidate the flow turned away before dispatch. *)

  val commit_continuity
    : commit:(unit -> (Librarian_continuity_snapshot.t, string) result)
    -> observe:((Librarian_continuity_snapshot.t, string) result -> unit)
    -> unit

  type classified_error

  val classified_error_detail : classified_error -> string
  val classified_error_kind : classified_error -> Keeper_memory_os_current.librarian_failure_kind

  val execute_exact_output_classified
    :  continuity:Keeper_librarian_continuity.prepared option
    -> ?cli_runner:Keeper_lane_cli_oneshot.runner
    -> clock:_ Eio.Time.clock
    -> net:[ `Generic | `Unix ] Eio.Net.ty Eio.Resource.t
    -> base_path:string
    -> keeper_id:string
    -> selected_input:Keeper_librarian.input
    -> messages:Agent_core.Types.message list
    -> unit
    -> ( (accepted * Yojson.Safe.t) * served_slot
       , classified_error )
       result

  val record_failure
    :  keepers_dir:string
    -> keeper_id:string
    -> trace_id:string
    -> kind:Keeper_memory_os_current.librarian_failure_kind
    -> detail:string
    -> unit
end

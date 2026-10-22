module Snapshot = Keeper_repetition_snapshot
module Scope_id = Keeper_execution_scope_id
let ( let* ) = Result.bind

type source_member =
  { post_id : string
  ; admitted_revision : int64
  ; checkpoint_retentions : int
  ; source_sha256 : string
  }

let canonical_sha value =
  match Digestif.SHA256.consistent_of_hex_opt value with
  | Some digest -> String.equal value (Digestif.SHA256.to_hex digest)
  | None -> false

let source_member ~post_id ~admitted_revision ~checkpoint_retentions ~source_sha256 =
  if String.trim post_id = "" then Error "source post_id must not be blank"
  else if admitted_revision < 0L || checkpoint_retentions < 0 then
    Error "source revision and retention count must not be negative"
  else if not (canonical_sha source_sha256) then Error "source hash must be canonical SHA-256"
  else Ok { post_id; admitted_revision; checkpoint_retentions; source_sha256 }

let valid_time value = Float.is_finite value && value >= 0.

type runtime_retry =
  { checkpoint : Keeper_checkpoint_ref.t
  ; assignment_id : string
  ; failed_runtime_id : string
  ; next_runtime_id : string
  ; later_runtime_ids : string list
  ; not_before : float option
  }
let runtime_retry ~not_before ~checkpoint ~assignment_id ~failed_runtime_id ~next_runtime_id ~later_runtime_ids =
  if List.exists (fun value -> String.trim value = "")
      (assignment_id :: failed_runtime_id :: next_runtime_id :: later_runtime_ids)
  then Error "runtime retry identities must be nonblank"
  else match not_before with
    | Some value when not (valid_time value) ->
      Error "runtime retry not_before must be a finite nonnegative time"
    | _ -> Ok {checkpoint; assignment_id; failed_runtime_id; next_runtime_id; later_runtime_ids; not_before}

let equal_runtime_retry left right =
  (* not_before is scheduling metadata, not part of the continuation's
     identity: the store's idempotent defer check compares a freshly rebuilt
     continuation (carrying a new backoff) against the persisted one, and the
     two must still match. *)
  Keeper_checkpoint_ref.equal left.checkpoint right.checkpoint
  && left.assignment_id = right.assignment_id
  && left.failed_runtime_id = right.failed_runtime_id
  && left.next_runtime_id = right.next_runtime_id
  && left.later_runtime_ids = right.later_runtime_ids

type gate_obligation =
  { approval_id : string; tool_name : string; input_hash : string }
let gate_obligation ~approval_id ~tool_name ~input_hash =
  if String.trim approval_id = "" || String.trim tool_name = "" then Error "Gate identity is blank"
  else if not (canonical_sha input_hash) then Error "Gate input hash is invalid"
  else Ok {approval_id; tool_name; input_hash}
type runtime_suffix = { assignment_id:string; failed_runtime_id:string; next_runtime_id:string; later_runtime_ids:string list }
let runtime_suffix ~assignment_id ~failed_runtime_id ~next_runtime_id ~later_runtime_ids =
  if List.exists (fun value -> String.trim value = "") (assignment_id :: failed_runtime_id :: next_runtime_id :: later_runtime_ids)
  then Error "runtime suffix identities are blank" else Ok {assignment_id; failed_runtime_id; next_runtime_id; later_runtime_ids}
type official_client_kind = Codex | Claude_code | Antigravity | Muse
let official_client_kind_to_string = function
  | Codex -> "codex" | Claude_code -> "claude_code" | Antigravity -> "antigravity" | Muse -> "muse"
let official_client_kind_of_string = function
  | "codex" -> Some Codex | "claude_code" -> Some Claude_code | "antigravity" -> Some Antigravity
  | "muse" -> Some Muse | _ -> None
type official_client_checkpoint =
  { client_kind : official_client_kind; runtime_id : string; session_id : string;
    turn_id : string; tool_surface_sha256 : string; frame : Keeper_repetition_snapshot.t }
type gate_checkpoint = Agent_core of Keeper_checkpoint_ref.t | Official_client of official_client_checkpoint
type gate_wait =
  { checkpoint : gate_checkpoint; obligations : gate_obligation list; runtime_retry : runtime_retry option }
let gate_wait ~checkpoint ~obligations =
  if obligations = [] then Error "Gate waiting requires an obligation"
  else if List.length (List.sort_uniq String.compare (List.map (fun row -> row.approval_id) obligations))
          <> List.length obligations then Error "duplicate Gate obligation"
  else Ok {checkpoint=Agent_core checkpoint; obligations; runtime_retry=None}
let validate_official_client_checkpoint (checkpoint : official_client_checkpoint) =
  if List.exists (fun value -> String.trim value = "")
      [checkpoint.runtime_id; checkpoint.session_id; checkpoint.turn_id]
     || not (canonical_sha checkpoint.tool_surface_sha256)
  then Error "invalid official-client Gate session identity"
  else match Snapshot.active checkpoint.frame with
    | None -> Error "official-client Gate has no original execution scope"
    | Some _ -> Ok ()
let official_client_gate_wait ~(checkpoint : official_client_checkpoint) ~obligations =
  let* () = validate_official_client_checkpoint checkpoint in
  if obligations = [] || List.length (List.sort_uniq String.compare
      (List.map (fun row -> row.approval_id) obligations)) <> List.length obligations
  then Error "invalid official-client Gate obligations"
  else Ok {checkpoint=Official_client checkpoint; obligations; runtime_retry=None}
let gate_checkpoint_owns checkpoint scope = match checkpoint with
  | Agent_core _ -> true
  | Official_client checkpoint -> (match Snapshot.active checkpoint.frame with Some active -> Keeper_execution_scope_id.equal scope active | None -> false)
let equal_gate_checkpoint left right = match left, right with
  | Agent_core left, Agent_core right -> Keeper_checkpoint_ref.equal left right
  | Official_client left, Official_client right ->
    left.client_kind = right.client_kind && left.runtime_id = right.runtime_id
    && left.session_id = right.session_id && left.turn_id = right.turn_id
    && left.tool_surface_sha256 = right.tool_surface_sha256 && Snapshot.equal left.frame right.frame
  | Agent_core _, Official_client _ | Official_client _, Agent_core _ -> false
let gate_wait_with_runtime_retry ~checkpoint ~obligations ~(runtime_retry : runtime_retry) =
  match gate_wait ~checkpoint ~obligations with
  | Error _ as error -> error
  | Ok waiting ->
    if Keeper_checkpoint_ref.equal checkpoint runtime_retry.checkpoint
    then Ok {waiting with runtime_retry=Some runtime_retry}
    else Error "Gate and runtime continuation must share their exact checkpoint"
type gate_preparation =
  | Prepared_agent_core of { reference : Keeper_checkpoint_ref.t; canonical_checkpoint_bytes : string }
  | Prepared_official_client of official_client_checkpoint
let preparation_checkpoint = function
  | Prepared_agent_core {reference; _} -> Agent_core reference
  | Prepared_official_client checkpoint -> Official_client checkpoint
type gate_binding = { approval_ids:string list; obligations:gate_obligation list; runtime_suffix:runtime_suffix option; unconfirmed_wait:gate_wait option; preparation:gate_preparation }
let gate_binding ~(preparation : gate_preparation) ~approval_ids ~obligations ~runtime_suffix =
  let* () = match preparation with
    | Prepared_agent_core {reference;canonical_checkpoint_bytes} ->
      let* observed = Keeper_checkpoint_ref.create ~trace_id:reference.trace_id ~turn_count:reference.turn_count
        ~canonical_checkpoint_bytes |> Result.map_error (fun _ -> "invalid Gate preparation reference") in
      let* () = if Keeper_checkpoint_ref.equal reference observed then Ok () else Error "Gate preparation bytes changed" in
      let* checkpoint = Agent_core.Checkpoint.of_string canonical_checkpoint_bytes
        |> Result.map_error (fun _ -> "invalid canonical Gate preparation checkpoint") in
      if checkpoint.session_id = Keeper_id.Trace_id.to_string reference.trace_id
         && checkpoint.turn_count = reference.turn_count then Ok ()
      else Error "Gate preparation embedded checkpoint identity changed"
    | Prepared_official_client checkpoint -> validate_official_client_checkpoint checkpoint in
  if approval_ids = [] || List.exists (fun id -> String.trim id = "") approval_ids
     || List.sort_uniq String.compare approval_ids <> List.sort String.compare approval_ids
     || not (List.for_all (fun (row : gate_obligation) -> List.mem row.approval_id approval_ids) obligations)
  then Error "invalid unresolved Gate identities"
  else Ok {approval_ids; obligations; runtime_suffix; unconfirmed_wait=None; preparation}
type gate_decision = Gate_approved | Gate_denied of string
type gate_resolution = { obligation : gate_obligation; decision : gate_decision }
type gate_wait_state = { waiting : gate_wait; resolution : gate_resolution option }
let equal_gate_wait (left : gate_wait) (right : gate_wait) = equal_gate_checkpoint left.checkpoint right.checkpoint
  && left.obligations = right.obligations
  && Option.equal equal_runtime_retry left.runtime_retry right.runtime_retry
let gate_binding_with_wait ~binding ~(waiting : gate_wait) =
  let ids = List.map (fun (row : gate_obligation) -> row.approval_id) waiting.obligations |> List.sort String.compare in
  let same_runtime = match binding.runtime_suffix, waiting.runtime_retry with
    | None, None -> true
    | Some suffix, Some retry -> suffix.assignment_id = retry.assignment_id
      && suffix.failed_runtime_id = retry.failed_runtime_id && suffix.next_runtime_id = retry.next_runtime_id
      && suffix.later_runtime_ids = retry.later_runtime_ids
    | Some _, None | None, Some _ -> false in
  let same_preparation = equal_gate_checkpoint (preparation_checkpoint binding.preparation) waiting.checkpoint in
  if not same_runtime || not same_preparation || ids <> List.sort String.compare binding.approval_ids
     || not (List.for_all (fun prior -> List.mem prior waiting.obligations) binding.obligations)
  then Error "unconfirmed Gate source does not preserve original obligations"
  else Ok {binding with unconfirmed_wait=Some waiting}

type input_wait =
  { checkpoint : Keeper_checkpoint_ref.t
  ; pending : Agent_core.Agent_input_request.pending }
let input_wait ~checkpoint ~pending =
  let* pending = Agent_core.Agent_input_request.pending_of_json
    (Agent_core.Agent_input_request.pending_to_json pending) in
  let* _ = Keeper_chat_operation.canonical_json (Agent_core.Agent_input_request.pending_to_json pending)
    |> Result.map_error (function
      | Keeper_chat_operation.Duplicate_object_key key -> "duplicate pending request key: " ^ key
      | Keeper_chat_operation.Non_finite_float -> "pending request contains a non-finite number") in
  Ok {checkpoint;pending}
let equal_input_wait left right = Keeper_checkpoint_ref.equal left.checkpoint right.checkpoint
  && Yojson.Safe.equal (Agent_core.Agent_input_request.pending_to_json left.pending)
       (Agent_core.Agent_input_request.pending_to_json right.pending)

type input_response_destination = Canonical_input | Operation_input
type input_response_intent =
  { waiting : input_wait
  ; source : Keeper_checkpoint_ref.t
  ; candidate : Keeper_checkpoint_ref.t
  ; response : Agent_core.Hooks.elicitation_response
  ; destination : input_response_destination }
let canonical_input_response = function
  | Agent_core.Hooks.Answer answer ->
    Keeper_chat_operation.canonical_json answer
    |> Result.map (fun answer -> Agent_core.Hooks.Answer answer)
    |> Result.map_error (function
      | Keeper_chat_operation.Duplicate_object_key key -> "duplicate response key: " ^ key
      | Keeper_chat_operation.Non_finite_float -> "response contains a non-finite number")
  | Agent_core.Hooks.Declined -> Ok Agent_core.Hooks.Declined
  | Agent_core.Hooks.Timeout -> Ok Agent_core.Hooks.Timeout
let input_response_intent ~(waiting : input_wait) ~source ~candidate ~response ~destination =
  if not (Keeper_id.Trace_id.equal waiting.checkpoint.trace_id source.Keeper_checkpoint_ref.trace_id
      && Keeper_id.Trace_id.equal source.trace_id candidate.Keeper_checkpoint_ref.trace_id)
     || source.turn_count < waiting.checkpoint.turn_count
     || candidate.turn_count <> source.turn_count
     || Keeper_checkpoint_ref.equal source candidate
     || Keeper_checkpoint_ref.equal waiting.checkpoint candidate
  then Error "input response intent changed trace, turn or consumed checkpoint identity"
  else
    let* response = canonical_input_response response in
    Ok {waiting;source;candidate;response;destination}
let same_input_response_payload left right =
  equal_input_wait left.waiting right.waiting
  && Keeper_checkpoint_ref.equal left.source right.source
  && Keeper_checkpoint_ref.equal left.candidate right.candidate
  && (match left.response,right.response with
      | Agent_core.Hooks.Answer left,Agent_core.Hooks.Answer right -> Yojson.Safe.equal left right
      | Declined,Declined | Timeout,Timeout -> true
      | (Answer _ | Declined | Timeout),(Answer _ | Declined | Timeout) -> false)

let equal_input_response_intent left right =
  same_input_response_payload left right && left.destination = right.destination
let continues_input_response_intent ~previous ~next =
  same_input_response_payload previous next &&
  match previous.destination,next.destination with
  | Canonical_input,(Canonical_input | Operation_input) | Operation_input,Operation_input -> true
  | Operation_input,Canonical_input -> false

type input_branch =
  { origin : input_wait
  ; checkpoint : Keeper_checkpoint_ref.t }

type terminal = Completed | Cancelled | Failed of string
type recovery_origin =
  | Unconfirmed_sources
  | Confirmed_undispatched
  | Checkpointed of Keeper_checkpoint_ref.t
  | Official_checkpointed of official_client_checkpoint
  | Interrupted_execution
  | Runtime_retry of runtime_retry
  | Gate_wait of gate_wait_state
  | Gate_binding of gate_binding
  | Input_wait of input_wait
type recovery = { origin : recovery_origin; diagnostic : string }
type phase =
  | Preparing
  | Ready
  | Running
  | Resuming_runtime_retry of runtime_retry
  | Resuming_gate of gate_wait * gate_resolution
  | Recovering of recovery
  | Suspended of Keeper_checkpoint_ref.t
  | Settled of terminal

type t =
  { id : Keeper_execution_scope_id.t
  ; revision : int64
  ; input : Yojson.Safe.t option
  ; input_sha256 : string
  ; gate_obligations : gate_obligation list
  ; sources : source_member list
  ; current_sources : source_member list
  ; frame : Snapshot.t
  ; phase : phase
  ; native_call : Keeper_native_call.state
  ; input_response_intent : input_response_intent option
  ; input_branch : input_branch option
  ; canonical_input_origin : input_wait option
  ; created_at : float
  ; updated_at : float
  }
type error =
  | Invalid_record of string
  | Invalid_transition of string
  | Native_call_unsettled
  | Revision_exhausted
type action =
  | Confirm_sources
  | Begin_execution
  | Resume_checkpoint of Keeper_checkpoint_ref.t
  | Resume_official_checkpoint of official_client_checkpoint
  | Require_reconciliation of string
  | Suspend of Keeper_checkpoint_ref.t
  | Suspend_official_checkpoint of official_client_checkpoint
  | Suspend_runtime_retry of runtime_retry
  | Resume_runtime_retry of runtime_retry
  | Update_runtime_retry_wait of { observed : runtime_retry; replacement : runtime_retry }
  | Suspend_gate_reconciliation of gate_binding * string
  | Suspend_gate of gate_wait
  | Suspend_input of input_wait
  | Prepare_input_response of input_response_intent
  | Resolve_input of { observed : input_wait; checkpoint : Keeper_checkpoint_ref.t }
  | Resolve_input_branch of { observed : input_wait; checkpoint : Keeper_checkpoint_ref.t }
  | Advance_input_branch of
      { observed : Keeper_checkpoint_ref.t; checkpoint : Keeper_checkpoint_ref.t }
  | Reconcile_gate_binding of gate_binding * gate_wait
  | Resolve_gate of gate_resolution
  | Resume_gate of gate_wait * gate_resolution
  | Discharge_gate of gate_obligation
  | Settle of terminal

let error_to_string = function
  | Invalid_record detail -> "invalid semantic execution: " ^ detail
  | Invalid_transition detail -> "invalid semantic execution transition: " ^ detail
  | Native_call_unsettled ->
    "native call has no settled disposition that allows this change"
  | Revision_exhausted -> "semantic execution revision exhausted"

let phase_name = function
  | Preparing -> "preparing" | Ready -> "ready" | Running | Resuming_runtime_retry _ | Resuming_gate _ -> "running"
  | Recovering _ -> "recovering" | Suspended _ -> "suspended" | Settled _ -> "settled"
let is_terminal execution = match execution.phase with
  | Settled _ -> true
  | Preparing | Ready | Running | Resuming_runtime_retry _ | Resuming_gate _ | Recovering _ | Suspended _ -> false
let scope execution = execution.id
(* A direct operation's session directory is its trace directory directly
   under the session root, and its native call, cooperative checkpoint, Gate
   and runtime retry read their references from there. *)
let gate_checkpoint_references = function Agent_core reference -> [reference] | Official_client _ -> []
let gate_wait_retained (waiting : gate_wait) =
  gate_checkpoint_references waiting.checkpoint
  @ (match waiting.runtime_retry with Some retry -> [retry.checkpoint] | None -> [])
let gate_binding_retained (binding : gate_binding) =
  (match binding.preparation with
   | Prepared_agent_core {reference; _} -> [reference]
   | Prepared_official_client _ -> [])
  @ (match binding.unconfirmed_wait with Some waiting -> gate_wait_retained waiting | None -> [])
let phase_checkpoints execution = match execution.phase with
  | Preparing | Ready | Running | Settled _ -> []
  | Resuming_runtime_retry retry -> [retry.checkpoint]
  | Resuming_gate (waiting, _) -> gate_wait_retained waiting
  | Suspended reference -> [reference]
  | Recovering {origin; _} ->
    (match origin with
     | Unconfirmed_sources | Confirmed_undispatched | Official_checkpointed _ | Interrupted_execution -> []
     | Checkpointed reference -> [reference]
     | Runtime_retry retry -> [retry.checkpoint]
     | Gate_wait {waiting; _} -> gate_wait_retained waiting
     | Gate_binding binding -> gate_binding_retained binding
     | Input_wait waiting -> [waiting.checkpoint])
let branch_checkpoints execution = match execution.input_branch with
  | None -> [] | Some branch -> [branch.origin.checkpoint;branch.checkpoint]
let checkpoint_references execution =
  Keeper_native_call.checkpoint_references execution.native_call @ phase_checkpoints execution
  @ branch_checkpoints execution
  @ (match execution.canonical_input_origin with None -> [] | Some origin -> [origin.checkpoint])
  @ (match execution.input_response_intent with
     | None -> [] | Some intent -> [intent.source;intent.candidate])
let continuation_checkpoints execution =
  let native = match execution.native_call with
    | Keeper_native_call.No_native_call -> []
    | Active call | Terminal_unacknowledged (call,_) -> [call.checkpoint] in
  native @ phase_checkpoints execution
  @ (match execution.input_branch with None -> [] | Some branch -> [branch.checkpoint])
(* Approval ids an unsettled execution may still read from the Gate store: a
   wait observes its obligations, a binding observes its approval ids, and a
   resuming wait still carries the obligation it resumed with, and an
   obligation stays on the execution until its evidence is discharged. *)
let gate_approval_ids execution =
  let of_obligations = List.map (fun (obligation : gate_obligation) -> obligation.approval_id) in
  let of_wait (waiting : gate_wait) = of_obligations waiting.obligations in
  of_obligations execution.gate_obligations @
  match execution.phase with
  | Preparing | Ready | Running | Resuming_runtime_retry _ | Suspended _ | Settled _ -> []
  | Resuming_gate (waiting, _) -> of_wait waiting
  | Recovering {origin; _} ->
    (match origin with
     | Unconfirmed_sources | Confirmed_undispatched | Checkpointed _ | Official_checkpointed _
     | Interrupted_execution | Runtime_retry _ | Input_wait _ -> []
     | Gate_wait {waiting; _} -> of_wait waiting
     | Gate_binding binding ->
       binding.approval_ids @ of_obligations binding.obligations
       @ (match binding.unconfirmed_wait with Some waiting -> of_wait waiting | None -> []))
let valid_terminal = function Failed detail -> String.trim detail <> "" | Completed | Cancelled -> true

let validate_sources sources =
  let rec loop seen = function
    | [] -> Ok ()
    | source :: rest ->
      let identity = source.post_id in
      if List.mem identity seen then Error (Invalid_record "duplicate selected source")
      else loop (identity :: seen) rest
  in loop [] sources

let canonical_input input =
  let* payload = Keeper_chat_operation.canonical_json input
    |> Result.map_error (function
         | Keeper_chat_operation.Duplicate_object_key key -> "duplicate input key: " ^ key
         | Keeper_chat_operation.Non_finite_float -> "input contains a non-finite number") in
  let* digest = Keeper_chat_operation.execution_digest payload in
  Ok (payload, digest)

let create ~id ~input ~sources ~now =
  if not (valid_time now) then Error (Invalid_record "invalid admission time")
  else
    let* () = validate_sources sources in
    let* input, input_sha256 = canonical_input input |> Result.map_error (fun detail -> Invalid_record detail) in
    let* frame = Snapshot.admit Snapshot.empty (Snapshot.Fresh id)
      |> Result.map_error (fun error -> Invalid_record (Snapshot.error_to_string error)) in
    Ok { id; revision = 0L; input = Some input; input_sha256; gate_obligations=[]; sources; current_sources = sources; frame; phase = Preparing; native_call = Keeper_native_call.No_native_call; input_response_intent=None; input_branch=None; canonical_input_origin=None; created_at = now; updated_at = now }

let same_admission left right =
  Scope_id.equal left.id right.id && left.sources = right.sources
  && String.equal left.input_sha256 right.input_sha256

let recovery_origin = function
  | Preparing -> Some Unconfirmed_sources
  | Ready -> Some Confirmed_undispatched
  | Running | Resuming_runtime_retry _ | Resuming_gate _ -> Some Interrupted_execution
  | Suspended checkpoint -> Some (Checkpointed checkpoint)
  | Recovering recovery -> Some recovery.origin
  | Settled _ -> None

let validate_native_call ~id ~input_sha256 ~phase native_call =
  let open Keeper_native_call in
  match native_call with
  | No_native_call -> Ok ()
  | Active call | Terminal_unacknowledged (call, _) ->
    if Option.is_none (Scope_id.direct_operation_id id) then Error "native call requires a direct operation"
    else if call.operation_digest <> input_sha256 then Error "native call operation digest changed"
    else match phase, native_call with
      | (Preparing | Ready | Suspended _), _ -> Error "native call has no running or terminal execution"
      | (Recovering _ | Settled _), Active _ -> Error "inactive execution retains an active native call"
      | Recovering {origin=Input_wait _;_}, Terminal_unacknowledged _ ->
        Error "accepted input wait retains an unacknowledged native call"
      | (Running | Resuming_runtime_retry _ | Resuming_gate _), _ -> Ok ()
      | Recovering {origin=(Unconfirmed_sources | Confirmed_undispatched | Checkpointed _
          | Official_checkpointed _ | Interrupted_execution | Runtime_retry _ | Gate_wait _ | Gate_binding _);_},
          (No_native_call | Terminal_unacknowledged _) -> Ok ()
      | Recovering {origin=Input_wait _;_},No_native_call -> Ok ()
      | Settled _,(No_native_call | Terminal_unacknowledged _) -> Ok ()

let validate_input_branch ~id ~revision ~phase ~native_call ~intent = function
  | None -> Ok ()
  | Some (branch : input_branch) ->
    let same_trace reference = Keeper_id.Trace_id.equal
      branch.origin.checkpoint.trace_id reference.Keeper_checkpoint_ref.trace_id in
    let current_reference reference = same_trace reference
      && reference.Keeper_checkpoint_ref.turn_count >= branch.checkpoint.turn_count in
    let admitted_reference reference = same_trace reference
      && reference.Keeper_checkpoint_ref.turn_count >= branch.origin.checkpoint.turn_count in
    let* () = if Option.is_some (Scope_id.direct_operation_id id) && revision >= 5L
        && same_trace branch.checkpoint
        && branch.checkpoint.turn_count >= branch.origin.checkpoint.turn_count
        && not (Keeper_checkpoint_ref.equal branch.origin.checkpoint branch.checkpoint)
      then Ok () else Error "input branch lost its direct origin or current reference" in
    let* () = match native_call with
      | Keeper_native_call.No_native_call -> Ok ()
      | Active call | Terminal_unacknowledged (call,_) ->
        if same_trace call.seed_checkpoint && current_reference call.checkpoint then Ok ()
        else Error "input branch and native checkpoint disagree" in
    let* () = match phase with
      | Running | Recovering {origin=Interrupted_execution;_} -> Ok ()
      | Resuming_runtime_retry retry ->
        if admitted_reference retry.checkpoint then Ok ()
        else Error "input branch runtime admission changed trace or regressed"
      | Suspended checkpoint
      | Recovering {origin=(Checkpointed checkpoint | Runtime_retry {checkpoint;_});_} ->
        if current_reference checkpoint then Ok ()
        else Error "input branch continuation changed trace or regressed"
      | Recovering {origin=Input_wait waiting;_} ->
        if Keeper_checkpoint_ref.equal waiting.checkpoint branch.checkpoint then Ok ()
        else Error "input branch wait is not its current input head"
      | Resuming_gate (waiting,_) ->
        (match waiting.checkpoint with
         | Agent_core checkpoint when admitted_reference checkpoint -> Ok ()
         | Agent_core _ | Official_client _ -> Error "input branch lost its admitted Agent Core Gate continuation")
      | Recovering {origin=Gate_wait {waiting;_};_} ->
        (match waiting.checkpoint with
         | Agent_core checkpoint when current_reference checkpoint -> Ok ()
         | Agent_core _ | Official_client _ -> Error "input branch lost its Agent Core Gate continuation")
      | Recovering {origin=Gate_binding binding;_} ->
        (match binding.preparation with
         | Prepared_agent_core {reference;_} when current_reference reference -> Ok ()
         | Prepared_agent_core _ | Prepared_official_client _ -> Error "input branch lost its Agent Core Gate binding")
      | Preparing | Ready | Settled _
      | Recovering {origin=(Unconfirmed_sources | Confirmed_undispatched | Official_checkpointed _);_} ->
        Error "input branch has no active Agent Core execution" in
    match intent with
    | None -> Ok ()
    | Some intent ->
      if intent.destination = Operation_input
          && Keeper_checkpoint_ref.equal intent.waiting.checkpoint branch.checkpoint then Ok ()
      else Error "input branch response intent names another input head"

let validate_canonical_input_origin current = match current.canonical_input_origin with
  | None -> Ok ()
  | Some origin ->
    let active=match current.phase with
      | Settled _ | Preparing | Ready -> false
      | Running | Resuming_runtime_retry _ | Resuming_gate _ | Suspended _ | Recovering _ -> true in
    if active && current.revision>=4L && Option.is_some (Scope_id.direct_operation_id current.id)
        && Option.is_none current.input_branch
        && List.for_all (fun reference ->
          Keeper_id.Trace_id.equal origin.checkpoint.trace_id reference.Keeper_checkpoint_ref.trace_id
          && reference.turn_count>=origin.checkpoint.turn_count) (continuation_checkpoints current)
    then Ok () else Error "canonical input response lost its original direct lineage"

let detach_canonical_input ~now ~input_checkpoint current =
  let invalid detail=Error (Invalid_transition detail) in
  let* origin=match current.canonical_input_origin,current.input_branch with
    | Some origin,None when Keeper_id.Trace_id.equal origin.checkpoint.trace_id input_checkpoint.Keeper_checkpoint_ref.trace_id -> Ok origin
    | (Some _ | None),(Some _ | None) -> invalid "execution has no canonical response lineage for this input" in
  let* checkpoint=match current.phase with
    | Suspended checkpoint
    | Recovering {origin=(Checkpointed checkpoint | Input_wait {checkpoint;_} | Runtime_retry {checkpoint;_});_}
    | Resuming_runtime_retry {checkpoint;_} -> Ok checkpoint
    | Recovering {origin=Gate_wait {waiting;_};_} | Resuming_gate (waiting,_) ->
      (match waiting.checkpoint with Agent_core checkpoint -> Ok checkpoint
       | Official_client _ -> invalid "canonical response has no Agent Core Gate checkpoint")
    | Recovering {origin=Gate_binding binding;_} ->
      (match binding.preparation with Prepared_agent_core {reference;_} -> Ok reference
       | Prepared_official_client _ -> invalid "canonical response has no Agent Core Gate preparation")
    | Running | Recovering {origin=Interrupted_execution;_} ->
      (match current.native_call with
       | Keeper_native_call.No_native_call -> Ok input_checkpoint
       | Active call | Terminal_unacknowledged (call,_) -> Ok call.checkpoint)
    | Preparing | Ready | Settled _
    | Recovering {origin=(Unconfirmed_sources | Confirmed_undispatched | Official_checkpointed _);_} ->
      invalid "canonical response has no detachable original continuation" in
  let* ()=if current.revision=Int64.max_int then Error Revision_exhausted
    else if valid_time now then Ok () else invalid "invalid canonical response detach time" in
  let branch={origin;checkpoint} in
  let* input_response_intent=match current.input_response_intent with
    | None -> Ok None
    | Some previous ->
      let intent={previous with destination=Operation_input} in
      if continues_input_response_intent ~previous ~next:intent then Ok (Some intent)
      else invalid "detachment changed the original prepared response" in
  let next={current with revision=Int64.succ current.revision;canonical_input_origin=None;
    input_branch=Some branch;input_response_intent;updated_at=now} in
  let* ()=validate_input_branch ~id:next.id ~revision:next.revision ~phase:next.phase
      ~native_call:next.native_call ~intent:next.input_response_intent next.input_branch
    |> Result.map_error (fun detail -> Invalid_transition detail) in
  Ok next

let checkpoint_input_branch ~now ~(observed:Keeper_checkpoint_ref.t)
    ~(checkpoint:Keeper_checkpoint_ref.t) (current:t) =
  let invalid detail = Error (Invalid_transition detail) in
  let* branch=match current.input_branch with
    | Some branch when Keeper_checkpoint_ref.equal branch.checkpoint observed -> Ok branch
    | Some _ | None -> invalid "host checkpoint lost its operation branch predecessor" in
  let* ()=if valid_time now && Keeper_id.Trace_id.equal observed.trace_id checkpoint.trace_id
      && checkpoint.turn_count=observed.turn_count then Ok ()
    else invalid "host branch checkpoint changed trace or turn" in
  let* ()=match current.phase with
    | Running | Resuming_runtime_retry _ | Resuming_gate _ -> Ok ()
    | Preparing | Ready | Recovering _ | Suspended _ | Settled _ ->
      invalid "host branch checkpoint requires a running operation" in
  let* ()=match current.native_call with
    | Keeper_native_call.No_native_call -> Ok ()
    | Active call when Keeper_checkpoint_ref.equal call.checkpoint checkpoint
        && Keeper_checkpoint_ref.equal observed checkpoint -> Ok ()
    | Terminal_unacknowledged (call,{Agent_core.Agent.recovery=Retire;_})
        when call.checkpoint.turn_count=checkpoint.turn_count -> Ok ()
    | Active _
    | Terminal_unacknowledged (_, {Agent_core.Agent.recovery=
        (Retire | Operator_repair_required Effect_outcome_unknown);_}) -> Error Native_call_unsettled in
  if Keeper_checkpoint_ref.equal observed checkpoint then Ok current
  else if current.revision=Int64.max_int then Error Revision_exhausted
  else
    let next={current with revision=Int64.succ current.revision;
      input_branch=Some {branch with checkpoint};updated_at=now} in
    let* ()=validate_input_branch ~id:next.id ~revision:next.revision ~phase:next.phase
        ~native_call:next.native_call ~intent:next.input_response_intent next.input_branch
      |> Result.map_error (fun detail -> Invalid_transition detail) in
    Ok next

let update_native_call ~now ~expected ~replacement current =
  let open Keeper_native_call in
  let invalid detail = Error (Invalid_transition detail) in
  if not (valid_time now) then invalid "invalid native call update time"
  else if not (equal_state expected current.native_call) then invalid "native call source changed"
  else
    let* () = validate_native_call ~id:current.id ~input_sha256:current.input_sha256
        ~phase:current.phase replacement |> Result.map_error (fun detail -> Invalid_transition detail) in
    let* () = match current.phase with
      | Running | Resuming_runtime_retry _ | Resuming_gate _ -> Ok ()
      | Preparing | Ready | Suspended _ | Recovering _ | Settled _ -> invalid "native call update requires running execution" in
    let* () = match expected, replacement with
      | No_native_call, Active _ -> Ok ()
      | Terminal_unacknowledged (_, disposition), (Active _ | No_native_call) ->
        (match disposition.Agent_core.Agent.recovery with
         | Agent_core.Agent.Retire -> Ok ()
         | Agent_core.Agent.Operator_repair_required Agent_core.Agent.Effect_outcome_unknown ->
           invalid "native call transition is not admitted")
      | Active before, Active after ->
        let* advanced = advance before ~observed:before.checkpoint ~checkpoint:after.checkpoint
          |> Result.map_error (fun detail -> Invalid_transition detail) in
        if equal advanced after then Ok () else invalid "native call identity changed"
      | Active before, Terminal_unacknowledged (after, _) when equal before after -> Ok ()
      | _, _ when equal_state expected replacement -> Ok ()
      | (No_native_call | Active _ | Terminal_unacknowledged _), _ -> invalid "native call transition is not admitted" in
    let* () = validate_input_branch ~id:current.id ~revision:current.revision
        ~phase:current.phase ~native_call:replacement ~intent:current.input_response_intent current.input_branch
      |> Result.map_error (fun detail -> Invalid_transition detail) in
    if equal_state expected replacement then Ok current
    else if current.revision = Int64.max_int then Error Revision_exhausted
    else
      let next={current with native_call=replacement; revision=Int64.succ current.revision; updated_at=now} in
      let* ()=validate_canonical_input_origin next |> Result.map_error (fun detail -> Invalid_transition detail) in
      Ok next

let retain_repetition_frame ~now candidate current =
  let invalid detail = Error (Invalid_transition detail) in
  let* () = if valid_time now then Ok () else invalid "invalid frame observation time" in
  let* () = match current.phase with
    | Settled _ -> invalid "terminal execution cannot acquire observations"
    | Preparing | Ready | Running | Resuming_runtime_retry _ | Resuming_gate _
    | Recovering _ | Suspended _ -> Ok () in
  let* () = match Snapshot.active candidate with
    | Some scope when Scope_id.equal scope current.id -> Ok ()
    | Some _ | None -> invalid "frame does not own the original active scope" in
  let* frame = Snapshot.restore_scope ~scope:current.id ~source:candidate ~target:Snapshot.empty
    |> Result.map_error (fun error -> Invalid_transition (Snapshot.error_to_string error)) in
  let observations frame = Snapshot.observations frame ~scope:current.id
    |> Result.map_error (fun error -> Invalid_transition (Snapshot.error_to_string error)) in
  let* before = observations current.frame in
  let* after = observations frame in
  let rec prefix before after = match before,after with
    | [],_ -> true
    | expected::before,actual::after -> expected=actual && prefix before after
    | _::_,[] -> false in
  let* () = if prefix (List.rev before) (List.rev after) then Ok ()
    else invalid "original repetition observations regressed or changed" in
  if Snapshot.equal current.frame frame then Ok current
  else
    let* () = match current.phase with
      | Running | Resuming_runtime_retry _ | Resuming_gate _ -> Ok ()
      | Preparing | Ready | Recovering _ | Suspended _ | Settled _ ->
        invalid "only an executing original scope may add observations" in
    if current.revision=Int64.max_int then Error Revision_exhausted
    else Ok {current with frame; revision=Int64.succ current.revision; updated_at=now}

let apply ~now action current =
  if not (valid_time now) then Error (Invalid_transition "invalid transition time")
  else
    let unchanged phase = Ok phase in
    let reject () = Error (Invalid_transition ("action is not admitted in " ^ phase_name current.phase)) in
    let* phase = match action with
      | Confirm_sources ->
          (match current.phase with
           | Preparing -> unchanged Ready
           | Ready | Running | Resuming_runtime_retry _ | Resuming_gate _ | Recovering _ | Suspended _ | Settled _ -> reject ())
      | Begin_execution ->
          (match current.phase with
           | Ready -> unchanged Running
           | Preparing | Running | Resuming_runtime_retry _ | Resuming_gate _ | Recovering _ | Suspended _ | Settled _ -> reject ())
      | Resume_official_checkpoint checkpoint ->
          (match current.phase with
           | Recovering recovery ->
             (match recovery.origin with
              | Official_checkpointed expected ->
                if equal_gate_checkpoint (Official_client expected) (Official_client checkpoint)
                then unchanged Running else reject ()
              | Unconfirmed_sources | Confirmed_undispatched | Checkpointed _
              | Interrupted_execution | Runtime_retry _ | Gate_wait _ | Gate_binding _ | Input_wait _ -> reject ())
           | Preparing | Ready | Running | Resuming_runtime_retry _ | Resuming_gate _
           | Suspended _ | Settled _ -> reject ())
      | Resume_checkpoint checkpoint ->
          let resume expected =
            if Keeper_checkpoint_ref.equal expected checkpoint then unchanged Running
            else reject () in
          (* The accepted checkpoint owns continuation, even after attention ACK. *)
          (match current.phase with
           | Suspended expected -> resume expected
           | Recovering recovery ->
               (match recovery.origin with
                | Checkpointed expected -> resume expected
                | Official_checkpointed _ | Unconfirmed_sources | Confirmed_undispatched | Interrupted_execution | Runtime_retry _ | Gate_wait _ | Gate_binding _ | Input_wait _ -> reject ())
           | Preparing | Ready | Running | Resuming_runtime_retry _ | Resuming_gate _ | Settled _ -> reject ())
      | Suspend_official_checkpoint checkpoint ->
          (match current.phase, validate_official_client_checkpoint checkpoint with
           | (Running | Resuming_runtime_retry _ | Resuming_gate _), Ok ()
             when gate_checkpoint_owns (Official_client checkpoint) (scope current) ->
               unchanged (Recovering { origin = Official_checkpointed checkpoint;
                 diagnostic = "official client retained unfinished direct conversation" })
           | (Preparing | Ready | Running | Resuming_runtime_retry _ | Resuming_gate _
             | Recovering _ | Suspended _ | Settled _), (Ok () | Error _) -> reject ())
      | Suspend checkpoint ->
          (match current.phase with
           | Running | Resuming_runtime_retry _ | Resuming_gate _ -> unchanged (Suspended checkpoint)
           | Preparing | Ready | Recovering _ | Suspended _ | Settled _ -> reject ())
      | Suspend_runtime_retry retry ->
          (match current.phase with
           | Running | Resuming_runtime_retry _ | Resuming_gate _ -> unchanged (Recovering {origin = Runtime_retry retry;
               diagnostic = "checkpointed runtime retry awaits its frozen continuation"})
           | Preparing | Ready | Recovering _ | Suspended _ | Settled _ -> reject ())
      | Update_runtime_retry_wait { observed; replacement } ->
          (match current.phase with
           | Recovering {origin = Runtime_retry expected; diagnostic} ->
             if expected = observed
                && Keeper_checkpoint_ref.equal expected.checkpoint replacement.checkpoint
             then unchanged (Recovering {origin = Runtime_retry replacement; diagnostic})
             else reject ()
           | Recovering {origin = (Checkpointed _ | Official_checkpointed _ | Unconfirmed_sources
               | Confirmed_undispatched | Interrupted_execution | Gate_wait _ | Gate_binding _ | Input_wait _); _}
           | Preparing | Ready | Running | Resuming_runtime_retry _ | Resuming_gate _ | Suspended _ | Settled _ -> reject ())
      | Resume_runtime_retry observed ->
          (match current.phase with
           | Recovering {origin = Runtime_retry expected; _} ->
             if equal_runtime_retry expected observed then unchanged (Resuming_runtime_retry expected) else reject ()
           | Recovering {origin = (Checkpointed _ | Official_checkpointed _ | Unconfirmed_sources
               | Confirmed_undispatched | Interrupted_execution | Gate_wait _ | Gate_binding _ | Input_wait _); _}
           | Preparing | Ready | Running | Resuming_runtime_retry _ | Resuming_gate _ | Suspended _ | Settled _ -> reject ())
      | Suspend_gate_reconciliation (binding, diagnostic) ->
          (match current.phase with
           | Running | Resuming_runtime_retry _ | Resuming_gate _ ->
             if String.trim diagnostic <> ""
                && gate_checkpoint_owns (preparation_checkpoint binding.preparation) (scope current)
                && Option.fold ~none:true
                     ~some:(fun (waiting : gate_wait) -> gate_checkpoint_owns waiting.checkpoint (scope current)) binding.unconfirmed_wait
                && List.for_all (fun prior -> List.mem prior binding.obligations) current.gate_obligations
             then unchanged (Recovering {origin=Gate_binding binding; diagnostic})
             else reject ()
           | Preparing | Ready | Recovering _ | Suspended _ | Settled _ -> reject ())
      | Reconcile_gate_binding (binding, waiting) ->
          (match current.phase with
           | Recovering {origin=Gate_binding expected; _} ->
             (match gate_binding_with_wait ~binding ~waiting with
              | Ok _ when expected = binding
                  && Option.fold ~none:true
                    ~some:(equal_gate_wait waiting) binding.unconfirmed_wait
                  && gate_checkpoint_owns waiting.checkpoint (scope current) ->
                unchanged (Recovering {origin=Gate_wait {waiting; resolution=None};
                  diagnostic="original exact Gate source is durably retained"})
              | Ok _ | Error _ -> reject ())
           | Recovering {origin=(Unconfirmed_sources | Confirmed_undispatched | Checkpointed _ | Official_checkpointed _
               | Interrupted_execution | Runtime_retry _ | Gate_wait _ | Input_wait _); _}
           | Preparing | Ready | Running | Resuming_runtime_retry _ | Resuming_gate _
           | Suspended _ | Settled _ -> reject ())
      | Prepare_input_response intent ->
          let* () = match current.native_call with
            | Keeper_native_call.No_native_call -> Ok ()
            | Active _ | Terminal_unacknowledged _ -> Error Native_call_unsettled in
          (match current.phase with
           | Recovering {origin=Input_wait waiting;_}
               when equal_input_wait waiting intent.waiting
                 && Option.is_some (Scope_id.direct_operation_id current.id)
                 && Option.fold ~none:true ~some:(fun branch ->
                   Keeper_checkpoint_ref.equal branch.checkpoint waiting.checkpoint) current.input_branch
                 && (Option.is_none current.input_branch || intent.destination = Operation_input)
                 && Option.fold ~none:true ~some:(fun previous -> continues_input_response_intent ~previous ~next:intent) current.input_response_intent ->
             unchanged current.phase
           | Recovering {origin=(Input_wait _ | Unconfirmed_sources | Confirmed_undispatched
               | Checkpointed _ | Official_checkpointed _ | Interrupted_execution
               | Runtime_retry _ | Gate_wait _ | Gate_binding _);_}
           | Preparing | Ready | Running | Resuming_runtime_retry _ | Resuming_gate _
           | Suspended _ | Settled _ -> reject ())
      | Resolve_input {observed;checkpoint} ->
          (match current.phase with
           | Recovering {origin=Input_wait expected;_}
               when equal_input_wait observed expected
                 && Option.is_none current.input_branch
                 && Keeper_id.Trace_id.equal checkpoint.trace_id observed.checkpoint.trace_id
                 && checkpoint.turn_count >= observed.checkpoint.turn_count
                 && not (Keeper_checkpoint_ref.equal checkpoint observed.checkpoint)
                 && Option.fold ~none:true
                      ~some:(fun intent -> intent.destination = Canonical_input
                        && Keeper_checkpoint_ref.equal intent.candidate checkpoint) current.input_response_intent ->
             unchanged (Suspended checkpoint)
           | Recovering {origin=(Input_wait _ | Unconfirmed_sources | Confirmed_undispatched
               | Checkpointed _ | Official_checkpointed _ | Interrupted_execution
               | Runtime_retry _ | Gate_wait _ | Gate_binding _);_}
           | Preparing | Ready | Running | Resuming_runtime_retry _ | Resuming_gate _
           | Suspended _ | Settled _ -> reject ())
      | Resolve_input_branch {observed;checkpoint} ->
          (match current.phase,current.native_call,current.input_response_intent with
           | Recovering {origin=Input_wait expected;_},Keeper_native_call.No_native_call,Some intent
               when equal_input_wait observed expected && equal_input_wait observed intent.waiting
                 && intent.destination = Operation_input
                 && Keeper_checkpoint_ref.equal checkpoint intent.candidate
                 && Option.is_some (Scope_id.direct_operation_id current.id)
                 && Option.fold ~none:true ~some:(fun branch ->
                   Keeper_checkpoint_ref.equal branch.checkpoint observed.checkpoint) current.input_branch ->
             unchanged (Suspended checkpoint)
           | (Preparing | Ready | Running | Resuming_runtime_retry _ | Resuming_gate _
             | Suspended _ | Settled _
             | Recovering {origin=(Input_wait _ | Unconfirmed_sources | Confirmed_undispatched
                 | Checkpointed _ | Official_checkpointed _ | Interrupted_execution
                 | Runtime_retry _ | Gate_wait _ | Gate_binding _);_}),
               (Keeper_native_call.No_native_call | Active _ | Terminal_unacknowledged _),(Some _ | None) -> reject ())
      | Advance_input_branch {observed;checkpoint} ->
          (match current.input_branch,current.native_call,current.phase with
           | Some branch,Keeper_native_call.Active call,(Running | Resuming_runtime_retry _ | Resuming_gate _)
               when Keeper_checkpoint_ref.equal branch.checkpoint observed
                 && Keeper_checkpoint_ref.equal call.checkpoint checkpoint
                 && Keeper_id.Trace_id.equal observed.trace_id checkpoint.trace_id
                 && checkpoint.turn_count >= observed.turn_count -> unchanged current.phase
           | (Some _ | None),(Keeper_native_call.No_native_call | Active _ | Terminal_unacknowledged _),
               (Preparing | Ready | Running | Resuming_runtime_retry _ | Resuming_gate _
                 | Suspended _ | Recovering _ | Settled _) -> reject ())
      | Suspend_input waiting ->
          (match current.phase with
           | Running | Resuming_runtime_retry _ | Resuming_gate _ ->
             if current.gate_obligations = [] then
               unchanged (Recovering {origin=Input_wait waiting;
                 diagnostic="original execution awaits its canonical input response"})
             else reject ()
           | Preparing | Ready | Recovering _ | Suspended _ | Settled _ -> reject ())
      | Suspend_gate waiting ->
          (match current.phase with
           | Running | Resuming_runtime_retry _ | Resuming_gate _ ->
             if gate_checkpoint_owns waiting.checkpoint (scope current)
                && List.for_all (fun prior -> List.mem prior waiting.obligations) current.gate_obligations
             then unchanged (Recovering {origin=Gate_wait {waiting; resolution=None}; diagnostic="waiting for durable Gate resolution"})
             else reject ()
           | Recovering {origin=Gate_wait state; _} when equal_gate_wait state.waiting waiting ->
             unchanged (Recovering {origin=Gate_wait {waiting; resolution=None}; diagnostic="Gate admission requires reconciliation"})
           | Recovering {origin=(Gate_binding _ | Input_wait _ | Gate_wait _ | Runtime_retry _ | Checkpointed _ | Official_checkpointed _ | Unconfirmed_sources
               | Confirmed_undispatched | Interrupted_execution); _}
           | Preparing | Ready | Suspended _ | Settled _ -> reject ())
      | Resolve_gate resolution ->
          (match current.phase with
           | Recovering {origin=Gate_wait state; _} ->
             let valid_decision = match resolution.decision with Gate_approved -> true
               | Gate_denied detail -> String.trim detail <> "" in
             if not valid_decision || not (List.mem resolution.obligation state.waiting.obligations) then reject ()
             else (match state.resolution with
               | Some current when current <> resolution -> reject ()
               | Some _ | None -> unchanged (Recovering {origin=Gate_wait {state with resolution=Some resolution};
                   diagnostic="durable Gate resolution is ready for the original operation"}))
           | Recovering {origin=(Gate_binding _ | Input_wait _ | Runtime_retry _ | Checkpointed _ | Official_checkpointed _ | Unconfirmed_sources
               | Confirmed_undispatched | Interrupted_execution); _}
           | Preparing | Ready | Running | Resuming_runtime_retry _ | Resuming_gate _ | Suspended _ | Settled _ -> reject ())
      | Resume_gate (waiting, resolution) ->
          (match current.phase with
           | Recovering {origin=Gate_wait state; _} ->
             if equal_gate_wait waiting state.waiting && state.resolution = Some resolution
             then unchanged (Resuming_gate (waiting, resolution)) else reject ()
           | Recovering {origin=(Gate_binding _ | Input_wait _ | Runtime_retry _ | Checkpointed _ | Official_checkpointed _ | Unconfirmed_sources
               | Confirmed_undispatched | Interrupted_execution); _}
           | Preparing | Ready | Running | Resuming_runtime_retry _ | Resuming_gate _ | Suspended _ | Settled _ -> reject ())
      | Discharge_gate obligation ->
          (match current.phase with
           | Resuming_gate (waiting, selected) ->
             if selected.obligation = obligation && List.mem obligation waiting.obligations
             then unchanged current.phase else reject ()
           | Running | Resuming_runtime_retry _ ->
             if List.mem obligation current.gate_obligations then unchanged current.phase else reject ()
           | Preparing | Ready | Recovering _ | Suspended _ | Settled _ -> reject ())
      | Require_reconciliation diagnostic ->
          if String.trim diagnostic = "" then reject ()
          else (match recovery_origin current.phase with
            | Some origin -> unchanged (Recovering {origin; diagnostic})
            | None -> reject ())
      | Settle terminal ->
          if not (valid_terminal terminal) then reject ()
          else (match terminal with
            | Completed ->
                (match current.phase with
                 | Running | Resuming_runtime_retry _ | Resuming_gate _ ->
                   if current.gate_obligations = [] then unchanged (Settled terminal) else reject ()
                 | Preparing | Ready | Recovering _ | Suspended _ | Settled _ -> reject ())
            | Cancelled | Failed _ ->
                (match current.phase with
                 | Preparing | Ready | Running | Resuming_runtime_retry _ | Resuming_gate _ | Recovering _ | Suspended _ -> unchanged (Settled terminal)
                 | Settled _ -> reject ())) in
    let* native_call = match current.native_call with
      | Keeper_native_call.No_native_call -> Ok Keeper_native_call.No_native_call
      | Keeper_native_call.Active _ ->
        (match action with
         | Settle (Completed | Cancelled | Failed _) ->
           Error Native_call_unsettled
         | Confirm_sources | Begin_execution | Resume_checkpoint _ | Resume_official_checkpoint _
         | Require_reconciliation _ | Suspend _ | Suspend_official_checkpoint _
         | Suspend_runtime_retry _ | Resume_runtime_retry _ | Update_runtime_retry_wait _
         | Suspend_gate_reconciliation _ | Suspend_gate _ | Suspend_input _ | Prepare_input_response _ | Resolve_input _ | Resolve_input_branch _ | Advance_input_branch _ | Reconcile_gate_binding _
         | Resolve_gate _ | Resume_gate _ | Discharge_gate _ ->
           if phase <> current.phase then
             Error Native_call_unsettled
           else Ok current.native_call)
      | Keeper_native_call.Terminal_unacknowledged (_, disposition) ->
        (match disposition.Agent_core.Agent.recovery with
         | Agent_core.Agent.Retire ->
           (match action with
            | Suspend _ | Suspend_official_checkpoint _ | Suspend_runtime_retry _
            | Suspend_gate _ | Suspend_input _ | Suspend_gate_reconciliation _ ->
              (* Retirement commits together with the accepted continuation. *)
              Ok Keeper_native_call.No_native_call
            | Confirm_sources | Begin_execution | Resume_checkpoint _ | Resume_official_checkpoint _
            | Require_reconciliation _ | Resume_runtime_retry _ | Update_runtime_retry_wait _
            | Prepare_input_response _ | Resolve_input _ | Resolve_input_branch _ | Advance_input_branch _ | Reconcile_gate_binding _ | Resolve_gate _ | Resume_gate _ | Discharge_gate _
            | Settle (Completed | Cancelled | Failed _) -> Ok current.native_call)
         | Agent_core.Agent.Operator_repair_required Agent_core.Agent.Effect_outcome_unknown ->
           (match action with
            | Settle Completed ->
              (* An unknown effect cannot complete. *)
              Error Native_call_unsettled
            | Suspend _ | Suspend_official_checkpoint _ | Suspend_runtime_retry _
            | Suspend_gate _ | Suspend_input _ | Suspend_gate_reconciliation _ ->
              (* An unknown effect cannot resume through another continuation. *)
              Error Native_call_unsettled
            | Confirm_sources | Begin_execution | Resume_checkpoint _ | Resume_official_checkpoint _
            | Require_reconciliation _ | Resume_runtime_retry _ | Update_runtime_retry_wait _
            | Prepare_input_response _ | Resolve_input _ | Resolve_input_branch _ | Advance_input_branch _ | Reconcile_gate_binding _ | Resolve_gate _ | Resume_gate _ | Discharge_gate _
            | Settle (Cancelled | Failed _) -> Ok current.native_call)) in
    let gate_obligations = match action with
      | Suspend_gate_reconciliation (binding, _) -> binding.obligations
      | Suspend_gate waiting | Reconcile_gate_binding (_, waiting) -> waiting.obligations
      | Discharge_gate obligation -> List.filter (fun current -> current <> obligation) current.gate_obligations
      | Settle _ -> []
      | Confirm_sources | Begin_execution | Resume_checkpoint _
      | Resume_official_checkpoint _ | Suspend_official_checkpoint _
      | Require_reconciliation _ | Suspend _ | Suspend_input _ | Prepare_input_response _ | Resolve_input _ | Resolve_input_branch _ | Advance_input_branch _ | Suspend_runtime_retry _
      | Resume_runtime_retry _ | Update_runtime_retry_wait _ | Resolve_gate _ | Resume_gate _ -> current.gate_obligations in
    let input_response_intent = match action with
      | Prepare_input_response intent -> Some intent
      | Resolve_input _ | Resolve_input_branch _ | Settle _ -> None
      | Confirm_sources | Begin_execution | Resume_checkpoint _ | Resume_official_checkpoint _
      | Require_reconciliation _ | Suspend _ | Suspend_official_checkpoint _
      | Suspend_runtime_retry _ | Resume_runtime_retry _ | Update_runtime_retry_wait _
      | Suspend_gate_reconciliation _ | Suspend_gate _ | Suspend_input _ | Reconcile_gate_binding _
      | Advance_input_branch _ | Resolve_gate _ | Resume_gate _ | Discharge_gate _ -> current.input_response_intent in
    let input_branch = match action with
      | Resolve_input_branch {observed;checkpoint} ->
        let origin = match current.input_branch with None -> observed | Some branch -> branch.origin in
        Some {origin;checkpoint}
      | Advance_input_branch {checkpoint;_} ->
        Option.map (fun branch -> {branch with checkpoint}) current.input_branch
      | Settle _ -> None
      | Confirm_sources | Begin_execution | Resume_checkpoint _ | Resume_official_checkpoint _
      | Require_reconciliation _ | Suspend _ | Suspend_official_checkpoint _
      | Suspend_runtime_retry _ | Resume_runtime_retry _ | Update_runtime_retry_wait _
      | Suspend_gate_reconciliation _ | Suspend_gate _ | Suspend_input _ | Prepare_input_response _
      | Resolve_input _ | Reconcile_gate_binding _ | Resolve_gate _ | Resume_gate _ | Discharge_gate _ -> current.input_branch in
    let canonical_input_origin=match action with
      | Resolve_input {observed;_} -> Some (match current.canonical_input_origin with Some origin -> origin | None -> observed)
      | Resolve_input_branch _ | Settle _ -> None
      | Confirm_sources | Begin_execution | Resume_checkpoint _ | Resume_official_checkpoint _
      | Require_reconciliation _ | Suspend _ | Suspend_official_checkpoint _
      | Suspend_runtime_retry _ | Resume_runtime_retry _ | Update_runtime_retry_wait _
      | Suspend_gate_reconciliation _ | Suspend_gate _ | Suspend_input _ | Prepare_input_response _
      | Advance_input_branch _ | Reconcile_gate_binding _ | Resolve_gate _ | Resume_gate _ | Discharge_gate _ -> current.canonical_input_origin in
    let* () = validate_input_branch ~id:current.id ~revision:(if current.revision = Int64.max_int then current.revision else Int64.succ current.revision)
        ~phase ~native_call ~intent:input_response_intent input_branch
      |> Result.map_error (fun detail -> Invalid_transition detail) in
    if phase = current.phase && gate_obligations = current.gate_obligations
       && Keeper_native_call.equal_state native_call current.native_call
       && Option.equal equal_input_response_intent input_response_intent current.input_response_intent
       && input_branch = current.input_branch
       && Option.equal equal_input_wait canonical_input_origin current.canonical_input_origin
    then Ok current
    else if current.revision = Int64.max_int then Error Revision_exhausted
    else
      let input = match phase with
        | Settled _ -> None
        | Preparing | Ready | Running | Resuming_runtime_retry _ | Resuming_gate _ | Suspended _ | Recovering _ -> current.input in
      let next={ current with revision = Int64.succ current.revision; phase; input; gate_obligations; native_call; input_response_intent; input_branch; canonical_input_origin; updated_at = now } in
      let* ()=validate_canonical_input_origin next |> Result.map_error (fun detail -> Invalid_transition detail) in
      Ok next

let source_to_json source =
  `Assoc [ "post_id", `String source.post_id
         ; "admitted_revision", `Intlit (Int64.to_string source.admitted_revision)
         ; "checkpoint_retentions", `Int source.checkpoint_retentions
         ; "source_sha256", `String source.source_sha256 ]
let terminal_json = function
  | Completed -> `Assoc ["kind", `String "completed"]
  | Cancelled -> `Assoc ["kind", `String "cancelled"]
  | Failed detail -> `Assoc ["kind", `String "failed"; "detail", `String detail]
let checkpoint_json checkpoint =
  `Assoc [ "trace_id", `String (Keeper_id.Trace_id.to_string checkpoint.Keeper_checkpoint_ref.trace_id)
         ; "turn_count", `Int checkpoint.turn_count
         ; "sha256", `String checkpoint.sha256 ]
let runtime_retry_json (retry : runtime_retry) =
  `Assoc [ "kind", `String "runtime_retry"
             ; "checkpoint", checkpoint_json retry.checkpoint
             ; "assignment_id", `String retry.assignment_id
             ; "failed_runtime_id", `String retry.failed_runtime_id
             ; "next_runtime_id", `String retry.next_runtime_id
             ; "later_runtime_ids", `List (List.map (fun id -> `String id) retry.later_runtime_ids)
             ; "not_before", (match retry.not_before with None -> `Null | Some value -> `Float value) ]
let gate_obligation_json value = `Assoc ["approval_id", `String value.approval_id;
  "tool_name", `String value.tool_name; "input_hash", `String value.input_hash]
let runtime_suffix_json (suffix : runtime_suffix) = `Assoc [
  "assignment_id", `String suffix.assignment_id; "failed_runtime_id", `String suffix.failed_runtime_id;
  "next_runtime_id", `String suffix.next_runtime_id;
  "later_runtime_ids", `List (List.map (fun id -> `String id) suffix.later_runtime_ids)]
let official_client_checkpoint_json value = `Assoc [
  "client_kind", `String (official_client_kind_to_string value.client_kind);
  "runtime_id", `String value.runtime_id; "session_id", `String value.session_id;
  "turn_id", `String value.turn_id; "tool_surface_sha256", `String value.tool_surface_sha256;
  "frame", Snapshot.to_json value.frame]
let gate_wait_json (value : gate_wait) = `Assoc ([(match value.checkpoint with
  | Agent_core checkpoint -> "checkpoint", checkpoint_json checkpoint
  | Official_client checkpoint -> "official_client", official_client_checkpoint_json checkpoint);
  "obligations", `List (List.map gate_obligation_json value.obligations)] @
  (match value.runtime_retry with None -> [] | Some retry -> ["runtime_retry", runtime_retry_json retry]))
let gate_binding_json binding = `Assoc ([
  "approval_ids", `List (List.map (fun id -> `String id) binding.approval_ids);
  "obligations", `List (List.map gate_obligation_json binding.obligations);
  "runtime_suffix", Option.fold ~none:`Null ~some:runtime_suffix_json binding.runtime_suffix;
  "preparation", `Assoc (match binding.preparation with
    | Prepared_agent_core {reference;canonical_checkpoint_bytes} ->
      ["checkpoint", checkpoint_json reference;"canonical_checkpoint_bytes",`String canonical_checkpoint_bytes]
    | Prepared_official_client checkpoint -> ["official_client", official_client_checkpoint_json checkpoint])] @
  (match binding.unconfirmed_wait with None -> [] | Some waiting -> ["unconfirmed_wait", gate_wait_json waiting]))
let gate_resolution_json value = `Assoc ["obligation", gate_obligation_json value.obligation;
  "decision", (match value.decision with Gate_approved -> `Assoc ["kind", `String "approved"]
    | Gate_denied detail -> `Assoc ["kind", `String "denied"; "detail", `String detail])]
let recovery_origin_json = function
  | Official_checkpointed checkpoint -> `Assoc ["kind", `String "official_checkpointed";
      "official_client", official_client_checkpoint_json checkpoint]
  | Gate_binding binding -> `Assoc ["kind", `String "gate_binding"; "binding", gate_binding_json binding]
  | Input_wait waiting -> `Assoc ["kind",`String "input_wait";
      "checkpoint",checkpoint_json waiting.checkpoint;
      "pending",Agent_core.Agent_input_request.pending_to_json waiting.pending]
  | Unconfirmed_sources -> `Assoc ["kind", `String "unconfirmed_sources"]
  | Confirmed_undispatched -> `Assoc ["kind", `String "confirmed_undispatched"]
  | Interrupted_execution -> `Assoc ["kind", `String "interrupted_execution"]
  | Gate_wait state -> `Assoc ["kind", `String "gate_wait"; "waiting", gate_wait_json state.waiting;
      "resolution", Option.fold ~none:`Null ~some:gate_resolution_json state.resolution]
  | Runtime_retry retry ->
      runtime_retry_json retry
  | Checkpointed checkpoint ->
      `Assoc ["kind", `String "checkpointed"; "checkpoint", checkpoint_json checkpoint]
let phase_json = function
  | Preparing -> `Assoc ["kind", `String "preparing"]
  | Ready -> `Assoc ["kind", `String "ready"]
  | Running -> `Assoc ["kind", `String "running"]
  | Resuming_runtime_retry retry -> `Assoc ["kind", `String "resuming_runtime_retry";
      "origin", recovery_origin_json (Runtime_retry retry)]
  | Resuming_gate (waiting, resolution) -> `Assoc ["kind", `String "resuming_gate";
      "waiting", gate_wait_json waiting; "resolution", gate_resolution_json resolution]
  | Recovering recovery ->
      `Assoc ["kind", `String "recovering"; "origin", recovery_origin_json recovery.origin;
              "detail", `String recovery.diagnostic]
  | Suspended checkpoint ->
      `Assoc ["kind", `String "suspended"; "checkpoint", checkpoint_json checkpoint]
  | Settled terminal -> `Assoc ["kind", `String "settled"; "terminal", terminal_json terminal]

let input_response_intent_json (intent : input_response_intent) =
  `Assoc ["waiting",recovery_origin_json (Input_wait intent.waiting);
    "source",checkpoint_json intent.source;"candidate",checkpoint_json intent.candidate;
    "destination",`String (match intent.destination with Canonical_input -> "canonical_input" | Operation_input -> "operation_input");
    "response",(match intent.response with
      | Agent_core.Hooks.Answer value -> `Assoc ["kind",`String "answer";"value",value]
      | Agent_core.Hooks.Declined -> `Assoc ["kind",`String "declined"]
      | Agent_core.Hooks.Timeout -> `Assoc ["kind",`String "timeout"])]

let to_json execution =
  `Assoc ([ "schema", `String "masc.keeper_semantic_execution.v1"
         ; "id", Scope_id.to_json execution.id
         ; "revision", `Intlit (Int64.to_string execution.revision)
         ; "input", (match execution.input with None -> `Null | Some payload -> `Assoc ["payload", payload])
         ; "input_sha256", `String execution.input_sha256
         ; "sources", `List (List.map source_to_json execution.sources)
         ; "current_sources", `List (List.map source_to_json execution.current_sources)
         ; "frame", Snapshot.to_json execution.frame
         ; "phase", phase_json execution.phase
         ; "created_at", `Float execution.created_at
         ; "updated_at", `Float execution.updated_at ]
          @ (match execution.native_call with Keeper_native_call.No_native_call -> []
             | Keeper_native_call.Active _ | Keeper_native_call.Terminal_unacknowledged _ ->
               ["native_call", Keeper_native_call.state_to_json execution.native_call])
          @ (match execution.input_response_intent with None -> []
             | Some intent -> ["input_response_intent",input_response_intent_json intent])
          @ (match execution.canonical_input_origin with None -> []
             | Some origin -> ["canonical_input_origin",recovery_origin_json (Input_wait origin)])
          @ (match execution.input_branch with None -> []
             | Some branch -> ["input_branch",`Assoc ["origin",recovery_origin_json (Input_wait branch.origin);
                 "checkpoint",checkpoint_json branch.checkpoint]])
          @ (if execution.gate_obligations = [] then []
             else ["gate_obligations", `List (List.map gate_obligation_json execution.gate_obligations)]))

let exact names = function
  | `Assoc fields when List.sort String.compare (List.map fst fields) = List.sort String.compare names -> Ok fields
  | _ -> Error "missing, duplicate, or unexpected fields"
let field name fields = List.assoc name fields
let string name fields = match field name fields with `String value -> Ok value | _ -> Error (name ^ " must be a string")
let int64 name fields = match field name fields with
  | `Int n -> Ok (Int64.of_int n)
  | `Intlit value -> (match Int64.of_string_opt value with Some n -> Ok n | None -> Error (name ^ " exceeds int64"))
  | _ -> Error (name ^ " must be an integer")
let int name fields =
  let* n = int64 name fields in
  if n < 0L || n > Int64.of_int max_int then Error (name ^ " is out of range") else Ok (Int64.to_int n)
let time name fields =
  let value = match field name fields with `Float n -> Some n | `Int n -> Some (Float.of_int n) | _ -> None in
  match value with Some n when valid_time n -> Ok n | _ -> Error (name ^ " must be a finite nonnegative time")
let rec decode_list decode = function
  | [] -> Ok []
  | first :: rest -> let* first = decode first in let* rest = decode_list decode rest in Ok (first :: rest)
let source_of_json json =
  let* fields = exact ["post_id"; "admitted_revision"; "checkpoint_retentions"; "source_sha256"] json in
  let* post_id = string "post_id" fields in
  let* admitted_revision = int64 "admitted_revision" fields in
  let* checkpoint_retentions = int "checkpoint_retentions" fields in
  let* source_sha256 = string "source_sha256" fields in
  source_member ~post_id ~admitted_revision ~checkpoint_retentions ~source_sha256
let terminal_of_json json =
  let names = match json with `Assoc fields when List.mem_assoc "detail" fields -> ["kind";"detail"] | _ -> ["kind"] in
  let* fields = exact names json in
  let* kind = string "kind" fields in
  match kind, names with
  | "completed", ["kind"] -> Ok Completed
  | "cancelled", ["kind"] -> Ok Cancelled
  | "failed", ["kind";"detail"] ->
      let* detail = string "detail" fields in
      if String.trim detail = "" then Error "failure detail must not be blank" else Ok (Failed detail)
  | _ -> Error "invalid terminal state"
let checkpoint_of_json json =
  let* checkpoint = exact ["trace_id";"turn_count";"sha256"] json in
  let* trace_id = string "trace_id" checkpoint in
  let* trace_id = Keeper_id.Trace_id.of_string trace_id in
  let* turn_count = int "turn_count" checkpoint in
  let* sha256 = string "sha256" checkpoint in
  Keeper_checkpoint_ref.of_persisted ~trace_id ~turn_count ~sha256
  |> Result.map_error (fun _ -> "invalid checkpoint identity")
let kind_of_json json =
  match json with
  | `Assoc fields -> (match List.assoc_opt "kind" fields with
      | Some (`String kind) -> Ok kind | _ -> Error "kind missing")
  | _ -> Error "expected an object"
let gate_obligation_of_json json =
  let* fields = exact ["approval_id";"tool_name";"input_hash"] json in
  let* approval_id = string "approval_id" fields in
  let* tool_name = string "tool_name" fields in
  let* input_hash = string "input_hash" fields in
  gate_obligation ~approval_id ~tool_name ~input_hash
let runtime_retry_of_json json =
      let names = match json with
        | `Assoc fields when List.mem_assoc "not_before" fields ->
          ["kind"; "checkpoint"; "assignment_id"; "failed_runtime_id";
           "next_runtime_id"; "later_runtime_ids"; "not_before"]
        | _ -> ["kind"; "checkpoint"; "assignment_id"; "failed_runtime_id";
                "next_runtime_id"; "later_runtime_ids"] in
      let* fields = exact names json in
      let* kind = string "kind" fields in
      let* () = if kind = "runtime_retry" then Ok () else Error "invalid frozen runtime retry kind" in
      let* checkpoint = checkpoint_of_json (field "checkpoint" fields) in
      let* assignment_id = string "assignment_id" fields in
      let* failed_runtime_id = string "failed_runtime_id" fields in
      let* next_runtime_id = string "next_runtime_id" fields in
      let* later_runtime_ids = match field "later_runtime_ids" fields with
        | `List values ->
          List.fold_right (fun value result -> let* ids = result in match value with
            | `String id -> Ok (id :: ids) | _ -> Error "runtime suffix identity must be a string") values (Ok [])
        | _ -> Error "runtime suffix must be a list" in
      (* Records persisted before [not_before] existed simply lack the field;
         they decode to [None] and stay immediately claimable, exactly the
         behaviour they had when written. *)
      let* not_before = match List.assoc_opt "not_before" fields with
        | None | Some `Null -> Ok None
        | Some (`Float _ | `Int _) -> let* value = time "not_before" fields in Ok (Some value)
        | Some _ -> Error "not_before must be a finite nonnegative time" in
      runtime_retry ~not_before ~checkpoint ~assignment_id ~failed_runtime_id ~next_runtime_id ~later_runtime_ids
let agent_core_gate_wait_of_json json =
  let json = match json with
    | `Assoc fields when not (List.mem_assoc "runtime_retry" fields) -> `Assoc (("runtime_retry", `Null) :: fields)
    | json -> json in
  let* fields = exact ["checkpoint";"obligations";"runtime_retry"] json in
  let* checkpoint = checkpoint_of_json (field "checkpoint" fields) in
  let* obligations = match field "obligations" fields with
    | `List rows -> decode_list gate_obligation_of_json rows
    | _ -> Error "Gate obligations must be a list" in
  match field "runtime_retry" fields with
  | `Null -> gate_wait ~checkpoint ~obligations
  | json -> let* runtime_retry = runtime_retry_of_json json in
      gate_wait_with_runtime_retry ~checkpoint ~obligations ~runtime_retry
let official_client_checkpoint_of_json json =
    let* native = exact ["client_kind"; "runtime_id"; "session_id"; "turn_id"; "tool_surface_sha256"; "frame"] json in
    let* kind = string "client_kind" native in
    let* client_kind = Option.to_result ~none:"invalid official-client kind"
      (official_client_kind_of_string kind) in
    let* runtime_id = string "runtime_id" native in
    let* session_id = string "session_id" native in
    let* turn_id = string "turn_id" native in
    let* tool_surface_sha256 = string "tool_surface_sha256" native in
    let* frame = Snapshot.of_json (field "frame" native) |> Result.map_error Snapshot.error_to_string in
    let checkpoint = {client_kind; runtime_id; session_id; turn_id; tool_surface_sha256; frame} in
    let* () = validate_official_client_checkpoint checkpoint in
    Ok checkpoint
let gate_wait_of_json json = match json with
  | `Assoc fields when List.mem_assoc "official_client" fields ->
    let* fields = exact ["official_client"; "obligations"] json in
    let* checkpoint = official_client_checkpoint_of_json (field "official_client" fields) in
    let* obligations = match field "obligations" fields with
      | `List rows -> decode_list gate_obligation_of_json rows | _ -> Error "Gate obligations must be a list" in
    official_client_gate_wait ~checkpoint ~obligations
  | _ -> agent_core_gate_wait_of_json json
let gate_resolution_of_json json =
  let* fields = exact ["obligation";"decision"] json in
  let* obligation = gate_obligation_of_json (field "obligation" fields) in
  let* decision = match field "decision" fields with
    | `Assoc [("kind", `String "approved")] -> Ok Gate_approved
    | (`Assoc fields as json) ->
      let* _ = exact ["kind";"detail"] json in
      let* kind = string "kind" fields in
      let* detail = string "detail" fields in
      if kind = "denied" && String.trim detail <> "" then Ok (Gate_denied detail)
      else Error "invalid Gate decision"
    | _ -> Error "invalid Gate decision" in
  Ok {obligation; decision}
let runtime_suffix_of_json json =
  let* fields = exact ["assignment_id";"failed_runtime_id";"next_runtime_id";"later_runtime_ids"] json in
  let* assignment_id = string "assignment_id" fields in
  let* failed_runtime_id = string "failed_runtime_id" fields in
  let* next_runtime_id = string "next_runtime_id" fields in
  let* later_runtime_ids = match field "later_runtime_ids" fields with
    | `List rows -> decode_list (function `String value -> Ok value | _ -> Error "runtime id must be a string") rows
    | _ -> Error "runtime suffix must be a list" in
  runtime_suffix ~assignment_id ~failed_runtime_id ~next_runtime_id ~later_runtime_ids
let gate_binding_of_json json =
  let names = ["approval_ids";"obligations";"runtime_suffix";"preparation"] @
    (match json with `Assoc fields -> List.filter (fun name -> List.mem_assoc name fields)
      ["unconfirmed_wait"] | _ -> []) in
  let* fields = exact names json in
  let* approval_ids = match field "approval_ids" fields with
    | `List rows -> decode_list (function `String value -> Ok value | _ -> Error "approval id must be a string") rows
    | _ -> Error "approval ids must be a list" in
  let* obligations = match field "obligations" fields with
    | `List rows -> decode_list gate_obligation_of_json rows | _ -> Error "obligations must be a list" in
  let* runtime_suffix = match field "runtime_suffix" fields with
    | `Null -> Ok None | json -> runtime_suffix_of_json json |> Result.map Option.some in
  let json = field "preparation" fields in
  let source_name = match json with `Assoc fields when List.mem_assoc "official_client" fields -> "official_client"
    | _ -> "checkpoint" in
  let* values = exact ([source_name] @
    if source_name = "checkpoint" then ["canonical_checkpoint_bytes"] else []) json in
  let* preparation = if source_name = "official_client" then
      official_client_checkpoint_of_json (field source_name values) |> Result.map (fun checkpoint -> Prepared_official_client checkpoint)
    else
      let* reference = checkpoint_of_json (field source_name values) in
      let* canonical_checkpoint_bytes = string "canonical_checkpoint_bytes" values in
      Ok (Prepared_agent_core {reference;canonical_checkpoint_bytes}) in
  let* binding = gate_binding ~preparation ~approval_ids ~obligations ~runtime_suffix in
  match List.assoc_opt "unconfirmed_wait" fields with
  | None -> Ok binding
  | Some json -> let* waiting = gate_wait_of_json json in gate_binding_with_wait ~binding ~waiting
let recovery_origin_of_json json =
  let* kind = kind_of_json json in
  let kind_only origin = let* _ = exact ["kind"] json in Ok origin in
  match kind with
  | "unconfirmed_sources" -> kind_only Unconfirmed_sources
  | "confirmed_undispatched" -> kind_only Confirmed_undispatched
  | "interrupted_execution" -> kind_only Interrupted_execution
  | "gate_wait" ->
      let* fields = exact ["kind";"waiting";"resolution"] json in
      let* waiting = gate_wait_of_json (field "waiting" fields) in
      let* resolution = match field "resolution" fields with
        | `Null -> Ok None
        | json -> gate_resolution_of_json json |> Result.map Option.some in
      if Option.fold ~none:true ~some:(fun r -> List.mem r.obligation waiting.obligations) resolution
      then Ok (Gate_wait {waiting; resolution}) else Error "Gate resolution is not an obligation"
  | "input_wait" ->
      let* fields = exact ["kind";"checkpoint";"pending"] json in
      let* checkpoint = checkpoint_of_json (field "checkpoint" fields) in
      let* pending = Agent_core.Agent_input_request.pending_of_json (field "pending" fields) in
      input_wait ~checkpoint ~pending |> Result.map (fun waiting -> Input_wait waiting)
  | "gate_binding" ->
      let* fields = exact ["kind";"binding"] json in
      gate_binding_of_json (field "binding" fields) |> Result.map (fun binding -> Gate_binding binding)
  | "runtime_retry" ->
      runtime_retry_of_json json
      |> Result.map (fun retry -> Runtime_retry retry)
  | "official_checkpointed" ->
      let* fields = exact ["kind";"official_client"] json in
      official_client_checkpoint_of_json (field "official_client" fields)
      |> Result.map (fun checkpoint -> Official_checkpointed checkpoint)
  | "checkpointed" ->
      let* fields = exact ["kind";"checkpoint"] json in
      checkpoint_of_json (field "checkpoint" fields) |> Result.map (fun checkpoint -> Checkpointed checkpoint)
  | _ -> Error "unknown recovery origin"
let phase_of_json json =
  let* kind = match json with
    | `Assoc fields -> (match List.assoc_opt "kind" fields with Some (`String kind) -> Ok kind | _ -> Error "phase kind missing")
    | _ -> Error "phase must be an object" in
  let kind_only phase = let* _ = exact ["kind"] json in Ok phase in
  match kind with
  | "preparing" -> kind_only Preparing
  | "ready" -> kind_only Ready
  | "running" -> kind_only Running
  | "resuming_gate" ->
      let* fields = exact ["kind";"waiting";"resolution"] json in
      let* waiting = gate_wait_of_json (field "waiting" fields) in
      let* resolution = gate_resolution_of_json (field "resolution" fields) in
      if List.mem resolution.obligation waiting.obligations then Ok (Resuming_gate (waiting, resolution))
      else Error "resumed Gate resolution is not an obligation"
  | "resuming_runtime_retry" ->
      let* fields = exact ["kind";"origin"] json in
      let* origin = recovery_origin_of_json (field "origin" fields) in
      (match origin with
       | Runtime_retry retry -> Ok (Resuming_runtime_retry retry)
       | Checkpointed _ | Official_checkpointed _ | Unconfirmed_sources | Confirmed_undispatched | Interrupted_execution | Gate_wait _ | Gate_binding _ | Input_wait _ ->
         Error "resuming runtime requires its frozen continuation")
  | "recovering" ->
      let* fields = exact ["kind";"origin";"detail"] json in
      let* diagnostic = string "detail" fields in
      let* origin = recovery_origin_of_json (field "origin" fields) in
      if String.trim diagnostic = "" then Error "recovery detail is blank"
      else Ok (Recovering {origin; diagnostic})
  | "suspended" ->
      let* fields = exact ["kind";"checkpoint"] json in
      checkpoint_of_json (field "checkpoint" fields)
      |> Result.map (fun reference -> Suspended reference)
  | "settled" ->
      let* fields = exact ["kind";"terminal"] json in
      terminal_of_json (field "terminal" fields) |> Result.map (fun terminal -> Settled terminal)
  | _ -> Error "unknown execution phase"

let input_response_intent_of_json json =
  let* fields = exact ["waiting";"source";"candidate";"response";"destination"] json in
  let* origin = recovery_origin_of_json (field "waiting" fields) in
  let* waiting = match origin with
    | Input_wait waiting -> Ok waiting
    | Unconfirmed_sources | Confirmed_undispatched | Checkpointed _ | Official_checkpointed _
    | Interrupted_execution | Runtime_retry _ | Gate_wait _ | Gate_binding _ -> Error "response intent has no original input wait" in
  let* source = checkpoint_of_json (field "source" fields) in
  let* candidate = checkpoint_of_json (field "candidate" fields) in
  let response_json = field "response" fields in
  let* kind = kind_of_json response_json in
  let* response = match kind with
    | "answer" ->
      let* fields = exact ["kind";"value"] response_json in
      Ok (Agent_core.Hooks.Answer (field "value" fields))
    | "declined" -> let* _ = exact ["kind"] response_json in Ok Agent_core.Hooks.Declined
    | "timeout" -> let* _ = exact ["kind"] response_json in Ok Agent_core.Hooks.Timeout
    | _ -> Error "unknown input response kind" in
  let* destination = match field "destination" fields with
    | `String "canonical_input" -> Ok Canonical_input
    | `String "operation_input" -> Ok Operation_input
    | _ -> Error "unknown input response destination" in
  input_response_intent ~waiting ~source ~candidate ~response ~destination

let input_branch_of_json json =
  let* fields = exact ["origin";"checkpoint"] json in
  let* origin = recovery_origin_of_json (field "origin" fields) in
  let* origin = match origin with
    | Input_wait waiting -> Ok waiting
    | Unconfirmed_sources | Confirmed_undispatched | Checkpointed _ | Official_checkpointed _
    | Interrupted_execution | Runtime_retry _ | Gate_wait _ | Gate_binding _ -> Error "input branch has no original full wait" in
  let* checkpoint = checkpoint_of_json (field "checkpoint" fields) in
  Ok {origin;checkpoint}

let of_json json =
  let decode () =
    let* canonical_input_origin,json=match json with
      | `Assoc fields ->
        (match List.assoc_opt "canonical_input_origin" fields with
         | None -> Ok (None,json)
         | Some value ->
           let* origin=recovery_origin_of_json value in
           let* waiting=match origin with Input_wait waiting -> Ok waiting
             | Unconfirmed_sources | Confirmed_undispatched | Checkpointed _ | Official_checkpointed _
             | Interrupted_execution | Runtime_retry _ | Gate_wait _ | Gate_binding _ -> Error "canonical input origin has no full wait" in
           Ok (Some waiting,`Assoc (List.remove_assoc "canonical_input_origin" fields)))
      | _ -> Ok (None,json) in
    let* input_branch, json = match json with
      | `Assoc fields ->
        (match List.assoc_opt "input_branch" fields with
         | None -> Ok (None,json)
         | Some value -> let* branch = input_branch_of_json value in
           Ok (Some branch,`Assoc (List.remove_assoc "input_branch" fields)))
      | _ -> Ok (None,json) in
    let* input_response_intent, json = match json with
      | `Assoc fields ->
        (match List.assoc_opt "input_response_intent" fields with
         | None -> Ok (None,json)
         | Some value -> let* intent = input_response_intent_of_json value in
           Ok (Some intent,`Assoc (List.remove_assoc "input_response_intent" fields)))
      | _ -> Ok (None,json) in
    let native_call_json, json = match json with
      | `Assoc fields ->
        (match List.assoc_opt "native_call" fields with
         | None -> `Null, json
         | Some value -> value, `Assoc (List.remove_assoc "native_call" fields))
      | _ -> `Null, json in
    let* native_call = Keeper_native_call.state_of_json native_call_json in
    let json = match json with
      | `Assoc fields when not (List.mem_assoc "gate_obligations" fields) ->
        `Assoc (("gate_obligations", `List []) :: fields)
      | json -> json in
    let* fields = exact ["schema";"id";"revision";"input";"input_sha256";"gate_obligations";"sources";"current_sources";"frame";"phase";"created_at";"updated_at"] json in
    let* gate_obligations = match field "gate_obligations" fields with
      | `List rows -> decode_list gate_obligation_of_json rows
      | _ -> Error "Gate obligations must be a list" in
    let* schema = string "schema" fields in
    let* () = if schema = "masc.keeper_semantic_execution.v1" then Ok () else Error "unsupported execution schema" in
    let* id = Scope_id.of_json (field "id" fields) in
    let* revision = int64 "revision" fields in
    let* () = if revision < 0L then Error "negative execution revision" else Ok () in
    let* sources = match field "sources" fields with `List rows -> decode_list source_of_json rows | _ -> Error "sources must be a list" in
    let* () = validate_sources sources |> Result.map_error error_to_string in
    let* current_sources = match field "current_sources" fields with
      | `List rows -> decode_list source_of_json rows | _ -> Error "current_sources must be a list" in
    let* () =
      if List.length sources = List.length current_sources
         && List.for_all2 (fun initial current ->
              initial.post_id = current.post_id
              && current.admitted_revision >= initial.admitted_revision
              && current.checkpoint_retentions >= initial.checkpoint_retentions) sources current_sources
      then Ok () else Error "current source projections do not preserve original admissions" in
    let* frame = Snapshot.of_json (field "frame" fields) |> Result.map_error Snapshot.error_to_string in
    let expected = id in
    let* () = match Snapshot.active frame, Snapshot.scope_ids frame with
      | Some active, [only] when Scope_id.equal active expected && Scope_id.equal only expected -> Ok ()
      | _ -> Error "execution frame must contain only its admitted scope" in
    let* phase = phase_of_json (field "phase" fields) in
    let* () = match phase with
      | Recovering {origin=Gate_binding binding; _} ->
        if gate_obligations = binding.obligations
           && gate_checkpoint_owns (preparation_checkpoint binding.preparation) expected
           && Option.fold ~none:true ~some:(fun (waiting : gate_wait) -> gate_checkpoint_owns waiting.checkpoint expected) binding.unconfirmed_wait
        then Ok () else Error "Gate binding lost prior obligations or source ownership"
      | Recovering {origin=Gate_wait state; _} ->
        if gate_checkpoint_owns state.waiting.checkpoint expected && gate_obligations = state.waiting.obligations then Ok ()
        else Error "Gate wait lost its owned obligations"
      | Resuming_gate (waiting, _) ->
        if gate_checkpoint_owns waiting.checkpoint expected && List.for_all (fun obligation -> List.mem obligation waiting.obligations) gate_obligations then Ok ()
        else Error "resumed Gate obligations changed identity"
      | Recovering { origin = Official_checkpointed checkpoint; _ } ->
        if gate_checkpoint_owns (Official_client checkpoint) expected then Ok ()
        else Error "official continuation changed execution scope"
      | Preparing | Ready | Running | Resuming_runtime_retry _ | Suspended _ | Settled _
      | Recovering {origin=(Runtime_retry _ | Checkpointed _ | Interrupted_execution
          | Unconfirmed_sources | Confirmed_undispatched); _} -> Ok ()
      | Recovering {origin=Input_wait _;_} ->
        if gate_obligations=[] then Ok () else Error "input wait retains unresolved Gate obligations" in
    let* () = match input_response_intent with
      | None -> Ok ()
      | Some intent ->
        (match phase,native_call with
         | Recovering {origin=Input_wait waiting;_},Keeper_native_call.No_native_call
             when equal_input_wait waiting intent.waiting && Option.is_some (Scope_id.direct_operation_id id)
               (* Minimum wait revision is three; preparing adds one transition. *)
               && revision >= 4L -> Ok ()
         | (Preparing | Ready | Running | Resuming_runtime_retry _ | Resuming_gate _ | Suspended _ | Settled _
           | Recovering {origin=(Input_wait _ | Unconfirmed_sources | Confirmed_undispatched | Checkpointed _
               | Official_checkpointed _ | Interrupted_execution | Runtime_retry _ | Gate_wait _ | Gate_binding _);_}),
             (Keeper_native_call.No_native_call | Active _ | Terminal_unacknowledged _) ->
           Error "response intent lost its original direct input wait") in
    let* input_sha256 = string "input_sha256" fields in
    let* () = if canonical_sha input_sha256 then Ok () else Error "invalid admitted input digest" in
    let* () = validate_native_call ~id ~input_sha256 ~phase native_call in
    let* () = validate_input_branch ~id ~revision ~phase ~native_call ~intent:input_response_intent input_branch in
    let* input = match field "input" fields with
      | `Null -> Ok None
      | value ->
          let* wrapper = exact ["payload"] value in
          let* payload, digest = canonical_input (field "payload" wrapper) in
          if String.equal digest input_sha256 then Ok (Some payload)
          else Error "admitted input digest does not match payload" in
    let* () = match phase, input with
      | Settled _, None -> Ok ()
      | (Preparing | Ready | Running | Resuming_runtime_retry _ | Resuming_gate _ | Suspended _ | Recovering _), Some _ -> Ok ()
      | Settled _, Some _ -> Error "settled execution retains an input body"
      | (Preparing | Ready | Running | Resuming_runtime_retry _ | Resuming_gate _ | Suspended _ | Recovering _), None ->
          Error "outstanding execution has no admitted input" in
    let* observations = Snapshot.observations frame ~scope:expected
      |> Result.map_error Snapshot.error_to_string in
    let coherent = match phase with
      | Preparing -> observations = []
      | Ready -> revision >= 1L && observations = []
      | Running -> revision >= 2L
      | Resuming_runtime_retry _ | Resuming_gate _ -> revision >= 4L
      | Suspended _ -> revision >= 3L
      | Recovering recovery ->
          (match recovery.origin with
           | Unconfirmed_sources | Confirmed_undispatched -> revision >= 1L && observations = []
           | Checkpointed _ | Official_checkpointed _ | Interrupted_execution -> revision >= 2L
           | Runtime_retry _ | Gate_wait _ | Gate_binding _ | Input_wait _ -> revision >= 3L)
      | Settled _ -> revision >= 1L in
    let* () = if coherent then Ok ()
      else Error "execution phase, revision and initial frame are incoherent" in
    let* created_at = time "created_at" fields in
    let* updated_at = time "updated_at" fields in
    let execution={ id; revision; input; input_sha256; gate_obligations; sources; current_sources; frame; phase; native_call; input_response_intent; input_branch; canonical_input_origin; created_at; updated_at } in
    let* ()=validate_canonical_input_origin execution in
    Ok execution
  in decode () |> Result.map_error (fun detail -> Invalid_record detail)

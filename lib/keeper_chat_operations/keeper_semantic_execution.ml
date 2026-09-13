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

type source_projection = 
  { original : source_member
  ; observed : source_member
  ; bound_scope : Keeper_execution_scope_id.t
  }
let source_projection ~original ~observed ~bound_scope =
  if not (String.equal original.post_id observed.post_id) then
    Error "source projection changed the admitted source identity"
  else Ok { original; observed; bound_scope }

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
type session_scope = Session_scope of string list
let session_scope components =
  if List.exists (fun component -> component = "" || component = "." || component = ".."
      || String.contains component '/' || String.contains component '\\'
      || String.contains component '\000') components
  then Error "invalid relative session scope"
  else Ok (Session_scope components)
let session_scope_components (Session_scope components) = components
type official_client_kind = Codex | Claude_code | Antigravity
type official_client_checkpoint =
  { client_kind : official_client_kind; runtime_id : string; session_id : string;
    turn_id : string; tool_surface_sha256 : string; frame : Keeper_repetition_snapshot.t }
type gate_checkpoint = Agent_core of Keeper_checkpoint_ref.t | Official_client of official_client_checkpoint
type gate_wait =
  { checkpoint : gate_checkpoint; session_scope : session_scope; obligations : gate_obligation list; runtime_retry : runtime_retry option }
let gate_wait ~checkpoint ~session_scope ~obligations =
  if obligations = [] then Error "Gate waiting requires an obligation"
  else if List.length (List.sort_uniq String.compare (List.map (fun row -> row.approval_id) obligations))
          <> List.length obligations then Error "duplicate Gate obligation"
  else Ok {checkpoint=Agent_core checkpoint; session_scope; obligations; runtime_retry=None}
let official_client_gate_wait ~(checkpoint : official_client_checkpoint) ~session_scope ~obligations =
  if List.exists (fun value -> String.trim value = "")
      [checkpoint.runtime_id; checkpoint.session_id; checkpoint.turn_id]
     || not (canonical_sha checkpoint.tool_surface_sha256)
  then Error "invalid official-client Gate session identity"
  else if obligations = [] || List.length (List.sort_uniq String.compare
      (List.map (fun row -> row.approval_id) obligations)) <> List.length obligations
  then Error "invalid official-client Gate obligations"
  else match Snapshot.active checkpoint.frame with
    | None -> Error "official-client Gate has no original execution scope"
    | Some _ -> Ok {checkpoint=Official_client checkpoint; session_scope; obligations; runtime_retry=None}
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
let gate_wait_with_runtime_retry ~checkpoint ~session_scope ~obligations ~(runtime_retry : runtime_retry) =
  match gate_wait ~checkpoint ~session_scope ~obligations with
  | Error _ as error -> error
  | Ok waiting ->
    if Keeper_checkpoint_ref.equal checkpoint runtime_retry.checkpoint
    then Ok {waiting with runtime_retry=Some runtime_retry}
    else Error "Gate and runtime continuation must share their exact checkpoint"
type gate_binding = { approval_ids:string list; obligations:gate_obligation list; runtime_suffix:runtime_suffix option; unconfirmed_wait:gate_wait option }
let gate_binding ~approval_ids ~obligations ~runtime_suffix =
  if approval_ids = [] || List.exists (fun id -> String.trim id = "") approval_ids
     || List.sort_uniq String.compare approval_ids <> List.sort String.compare approval_ids
     || not (List.for_all (fun (row : gate_obligation) -> List.mem row.approval_id approval_ids) obligations)
  then Error "invalid unresolved Gate identities"
  else Ok {approval_ids; obligations; runtime_suffix; unconfirmed_wait=None}
type gate_decision = Gate_approved | Gate_denied of string
type gate_resolution = { obligation : gate_obligation; decision : gate_decision }
type gate_wait_state = { waiting : gate_wait; resolution : gate_resolution option }
let equal_gate_wait left right = equal_gate_checkpoint left.checkpoint right.checkpoint
  && left.session_scope = right.session_scope && left.obligations = right.obligations
  && Option.equal equal_runtime_retry left.runtime_retry right.runtime_retry
let gate_binding_with_wait ~binding ~(waiting : gate_wait) =
  let ids = List.map (fun (row : gate_obligation) -> row.approval_id) waiting.obligations |> List.sort String.compare in
  let same_runtime = match binding.runtime_suffix, waiting.runtime_retry with
    | None, None -> true
    | Some suffix, Some retry -> suffix.assignment_id = retry.assignment_id
      && suffix.failed_runtime_id = retry.failed_runtime_id && suffix.next_runtime_id = retry.next_runtime_id
      && suffix.later_runtime_ids = retry.later_runtime_ids
    | Some _, None | None, Some _ -> false in
  if not same_runtime || ids <> List.sort String.compare binding.approval_ids
     || not (List.for_all (fun prior -> List.mem prior waiting.obligations) binding.obligations)
  then Error "unconfirmed Gate source does not preserve original obligations"
  else Ok {binding with unconfirmed_wait=Some waiting}

type terminal = Completed | Cancelled | Failed of string
type recovery_origin =
  | Unconfirmed_sources
  | Confirmed_undispatched
  | Checkpointed of Keeper_checkpoint_ref.t
  | Interrupted_execution
  | Runtime_retry of runtime_retry
  | Gate_wait of gate_wait_state
  | Gate_binding of gate_binding
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
  ; created_at : float
  ; updated_at : float
  }
type error = Invalid_record of string | Invalid_transition of string | Revision_exhausted
type action =
  | Confirm_sources
  | Begin_execution
  | Recheck_sources of source_projection list
  | Resume_checkpoint of Keeper_checkpoint_ref.t
  | Record_observation of Snapshot.observation
  | Require_reconciliation of string
  | Suspend of Keeper_checkpoint_ref.t
  | Suspend_runtime_retry of runtime_retry
  | Resume_runtime_retry of runtime_retry
  | Suspend_gate_reconciliation of gate_binding * string
  | Suspend_gate of gate_wait
  | Reconcile_gate_binding of gate_binding * gate_wait
  | Resolve_gate of gate_resolution
  | Resume_gate of gate_wait * gate_resolution
  | Discharge_gate of gate_obligation
  | Settle of terminal

let error_to_string = function
  | Invalid_record detail -> "invalid semantic execution: " ^ detail
  | Invalid_transition detail -> "invalid semantic execution transition: " ^ detail
  | Revision_exhausted -> "semantic execution revision exhausted"

let phase_name = function
  | Preparing -> "preparing" | Ready -> "ready" | Running | Resuming_runtime_retry _ | Resuming_gate _ -> "running"
  | Recovering _ -> "recovering" | Suspended _ -> "suspended" | Settled _ -> "settled"
let is_terminal execution = match execution.phase with
  | Settled _ -> true
  | Preparing | Ready | Running | Resuming_runtime_retry _ | Resuming_gate _ | Recovering _ | Suspended _ -> false
let scope execution = execution.id
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
    Ok { id; revision = 0L; input = Some input; input_sha256; gate_obligations=[]; sources; current_sources = sources; frame; phase = Preparing; created_at = now; updated_at = now }

let same_admission left right =
  Scope_id.equal left.id right.id && left.sources = right.sources
  && String.equal left.input_sha256 right.input_sha256

let projected_sources current projections =
  let rec loop originals previous projections =
    match originals, previous, projections with
    | [], [], [] -> Ok []
    | original :: originals, previous :: previous_tail, projection :: projections
      when projection.original = original
           && String.equal projection.observed.post_id original.post_id
           && Scope_id.equal projection.bound_scope (scope current)
           && projection.observed.admitted_revision >= previous.admitted_revision
           && projection.observed.checkpoint_retentions >= previous.checkpoint_retentions ->
        let* rest = loop originals previous_tail projections in
        Ok (projection.observed :: rest)
    | _ -> Error (Invalid_transition "source recheck must preserve each original admission and its exact bound scope")
  in
  loop current.sources current.current_sources projections

let recovery_origin = function
  | Preparing -> Some Unconfirmed_sources
  | Ready -> Some Confirmed_undispatched
  | Running | Resuming_runtime_retry _ | Resuming_gate _ -> Some Interrupted_execution
  | Suspended checkpoint -> Some (Checkpointed checkpoint)
  | Recovering recovery -> Some recovery.origin
  | Settled _ -> None

let apply ~now action current =
  if not (valid_time now) then Error (Invalid_transition "invalid transition time")
  else
    let unchanged phase = Ok (phase, current.frame, current.current_sources) in
    let reject () = Error (Invalid_transition ("action is not admitted in " ^ phase_name current.phase)) in
    let* phase, frame, current_sources = match action with
      | Confirm_sources ->
          (match current.phase with
           | Preparing -> unchanged Ready
           | Ready | Running | Resuming_runtime_retry _ | Resuming_gate _ | Recovering _ | Suspended _ | Settled _ -> reject ())
      | Begin_execution ->
          (match current.phase with
           | Ready -> unchanged Running
           | Preparing | Running | Resuming_runtime_retry _ | Resuming_gate _ | Recovering _ | Suspended _ | Settled _ -> reject ())
      | Recheck_sources projections ->
          let recheck phase =
            let* sources = projected_sources current projections in
            Ok (phase, current.frame, sources) in
          (match current.phase with
           | Preparing -> recheck Preparing
           | Ready -> recheck Ready
           | Recovering recovery ->
               (match recovery.origin with
                | Unconfirmed_sources -> recheck Preparing
                | Confirmed_undispatched -> recheck Ready
                | Checkpointed _ | Interrupted_execution | Runtime_retry _ | Gate_wait _ | Gate_binding _ -> reject ())
           | Running | Resuming_runtime_retry _ | Resuming_gate _ | Suspended _ | Settled _ -> reject ())
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
                | Unconfirmed_sources | Confirmed_undispatched | Interrupted_execution | Runtime_retry _ | Gate_wait _ | Gate_binding _ -> reject ())
           | Preparing | Ready | Running | Resuming_runtime_retry _ | Resuming_gate _ | Settled _ -> reject ())
      | Record_observation observation ->
          (match current.phase with
           | Running | Resuming_runtime_retry _ | Resuming_gate _ ->
               Snapshot.record current.frame ~scope:(scope current) observation
               |> Result.map (fun frame -> current.phase, frame, current.current_sources)
               |> Result.map_error (fun error -> Invalid_record (Snapshot.error_to_string error))
           | Preparing | Ready | Recovering _ | Suspended _ | Settled _ -> reject ())
      | Suspend checkpoint ->
          (match current.phase with
           | Running -> unchanged (Suspended checkpoint)
           | Resuming_runtime_retry _ | Resuming_gate _ -> reject ()
           | Preparing | Ready | Recovering _ | Suspended _ | Settled _ -> reject ())
      | Suspend_runtime_retry retry ->
          (match current.phase with
           | Running | Resuming_runtime_retry _ | Resuming_gate _ -> unchanged (Recovering {origin = Runtime_retry retry;
               diagnostic = "checkpointed runtime retry awaits its frozen continuation"})
           | Preparing | Ready | Recovering _ | Suspended _ | Settled _ -> reject ())
      | Resume_runtime_retry observed ->
          (match current.phase with
           | Recovering {origin = Runtime_retry expected; _} ->
             if equal_runtime_retry expected observed then unchanged (Resuming_runtime_retry expected) else reject ()
           | Recovering {origin = (Checkpointed _ | Unconfirmed_sources
               | Confirmed_undispatched | Interrupted_execution | Gate_wait _ | Gate_binding _); _}
           | Preparing | Ready | Running | Resuming_runtime_retry _ | Resuming_gate _ | Suspended _ | Settled _ -> reject ())
      | Suspend_gate_reconciliation (binding, diagnostic) ->
          (match current.phase with
           | Running | Resuming_runtime_retry _ | Resuming_gate _ ->
             if String.trim diagnostic <> ""
                && Option.fold ~none:true
                     ~some:(fun waiting -> gate_checkpoint_owns waiting.checkpoint (scope current)) binding.unconfirmed_wait
                && List.for_all (fun prior -> List.mem prior binding.obligations) current.gate_obligations
             then unchanged (Recovering {origin=Gate_binding binding; diagnostic})
             else reject ()
           | Preparing | Ready | Recovering _ | Suspended _ | Settled _ -> reject ())
      | Reconcile_gate_binding (binding, waiting) ->
          (match current.phase with
           | Recovering {origin=Gate_binding expected; _} ->
             (match binding.unconfirmed_wait with
              | Some candidate when expected = binding && equal_gate_wait waiting candidate
                  && gate_checkpoint_owns waiting.checkpoint (scope current) ->
                unchanged (Recovering {origin=Gate_wait {waiting; resolution=None};
                  diagnostic="original exact Gate source is durably retained"})
              | Some _ | None -> reject ())
           | Recovering {origin=(Unconfirmed_sources | Confirmed_undispatched | Checkpointed _
               | Interrupted_execution | Runtime_retry _ | Gate_wait _); _}
           | Preparing | Ready | Running | Resuming_runtime_retry _ | Resuming_gate _
           | Suspended _ | Settled _ -> reject ())
      | Suspend_gate waiting ->
          (match current.phase with
           | Running | Resuming_runtime_retry _ | Resuming_gate _ ->
             if gate_checkpoint_owns waiting.checkpoint (scope current)
                && List.for_all (fun prior -> List.mem prior waiting.obligations) current.gate_obligations
             then unchanged (Recovering {origin=Gate_wait {waiting; resolution=None}; diagnostic="waiting for durable Gate resolution"})
             else reject ()
           | Recovering {origin=Gate_wait state; _} when equal_gate_wait state.waiting waiting ->
             unchanged (Recovering {origin=Gate_wait {waiting; resolution=None}; diagnostic="Gate admission requires reconciliation"})
           | Recovering {origin=(Gate_binding _ | Gate_wait _ | Runtime_retry _ | Checkpointed _ | Unconfirmed_sources
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
           | Recovering {origin=(Gate_binding _ | Runtime_retry _ | Checkpointed _ | Unconfirmed_sources
               | Confirmed_undispatched | Interrupted_execution); _}
           | Preparing | Ready | Running | Resuming_runtime_retry _ | Resuming_gate _ | Suspended _ | Settled _ -> reject ())
      | Resume_gate (waiting, resolution) ->
          (match current.phase with
           | Recovering {origin=Gate_wait state; _} ->
             if equal_gate_wait waiting state.waiting && state.resolution = Some resolution
             then unchanged (Resuming_gate (waiting, resolution)) else reject ()
           | Recovering {origin=(Gate_binding _ | Runtime_retry _ | Checkpointed _ | Unconfirmed_sources
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
    let gate_obligations = match action with
      | Suspend_gate_reconciliation (binding, _) -> binding.obligations
      | Suspend_gate waiting | Reconcile_gate_binding (_, waiting) -> waiting.obligations
      | Discharge_gate obligation -> List.filter (fun current -> current <> obligation) current.gate_obligations
      | Settle _ -> []
      | Confirm_sources | Begin_execution | Recheck_sources _ | Resume_checkpoint _
      | Record_observation _ | Require_reconciliation _ | Suspend _ | Suspend_runtime_retry _
      | Resume_runtime_retry _ | Resolve_gate _ | Resume_gate _ -> current.gate_obligations in
    if phase = current.phase && Snapshot.equal frame current.frame && current_sources = current.current_sources
       && gate_obligations = current.gate_obligations
    then Ok current
    else if current.revision = Int64.max_int then Error Revision_exhausted
    else
      let input = match phase with
        | Settled _ -> None
        | Preparing | Ready | Running | Resuming_runtime_retry _ | Resuming_gate _ | Suspended _ | Recovering _ -> current.input in
      Ok { current with revision = Int64.succ current.revision; phase; frame; current_sources; input; gate_obligations; updated_at = now }

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
  "client_kind", `String (match value.client_kind with Codex -> "codex" | Claude_code -> "claude_code" | Antigravity -> "antigravity");
  "runtime_id", `String value.runtime_id; "session_id", `String value.session_id;
  "turn_id", `String value.turn_id; "tool_surface_sha256", `String value.tool_surface_sha256;
  "frame", Snapshot.to_json value.frame]
let gate_wait_json value = `Assoc ([(match value.checkpoint with
  | Agent_core checkpoint -> "checkpoint", checkpoint_json checkpoint
  | Official_client checkpoint -> "official_client", official_client_checkpoint_json checkpoint);
  "session_scope", `List (List.map (fun value -> `String value) (session_scope_components value.session_scope));
  "obligations", `List (List.map gate_obligation_json value.obligations)] @
  (match value.runtime_retry with None -> [] | Some retry -> ["runtime_retry", runtime_retry_json retry]))
let gate_binding_json binding = `Assoc ([
  "approval_ids", `List (List.map (fun id -> `String id) binding.approval_ids);
  "obligations", `List (List.map gate_obligation_json binding.obligations);
  "runtime_suffix", Option.fold ~none:`Null ~some:runtime_suffix_json binding.runtime_suffix] @
  (match binding.unconfirmed_wait with None -> [] | Some waiting -> ["unconfirmed_wait", gate_wait_json waiting]))
let gate_resolution_json value = `Assoc ["obligation", gate_obligation_json value.obligation;
  "decision", (match value.decision with Gate_approved -> `Assoc ["kind", `String "approved"]
    | Gate_denied detail -> `Assoc ["kind", `String "denied"; "detail", `String detail])]
let recovery_origin_json = function
  | Gate_binding binding -> `Assoc ["kind", `String "gate_binding"; "binding", gate_binding_json binding]
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
  let* fields = exact ["checkpoint";"session_scope";"obligations";"runtime_retry"] json in
  let* checkpoint = checkpoint_of_json (field "checkpoint" fields) in
  let* obligations = match field "obligations" fields with
    | `List rows -> decode_list gate_obligation_of_json rows
    | _ -> Error "Gate obligations must be a list" in
  let* session_scope = match field "session_scope" fields with
    | `List rows ->
      let* components = decode_list (function `String value -> Ok value | _ -> Error "invalid session component") rows in
      session_scope components
    | _ -> Error "Gate session scope must be a list" in
  match field "runtime_retry" fields with
  | `Null -> gate_wait ~checkpoint ~session_scope ~obligations
  | json -> let* runtime_retry = runtime_retry_of_json json in
      gate_wait_with_runtime_retry ~checkpoint ~session_scope ~obligations ~runtime_retry
let gate_wait_of_json json = match json with
  | `Assoc fields when List.mem_assoc "official_client" fields ->
    let* fields = exact ["official_client"; "session_scope"; "obligations"] json in
    let* native = exact ["client_kind"; "runtime_id"; "session_id"; "turn_id"; "tool_surface_sha256"; "frame"] (field "official_client" fields) in
    let* kind = string "client_kind" native in
    let* client_kind = match kind with "codex" -> Ok Codex | "claude_code" -> Ok Claude_code
      | "antigravity" -> Ok Antigravity | _ -> Error "invalid official-client kind" in
    let* runtime_id = string "runtime_id" native in
    let* session_id = string "session_id" native in
    let* turn_id = string "turn_id" native in
    let* tool_surface_sha256 = string "tool_surface_sha256" native in
    let* frame = Snapshot.of_json (field "frame" native) |> Result.map_error Snapshot.error_to_string in
    let* components = match field "session_scope" fields with
      | `List rows -> decode_list (function `String value -> Ok value | _ -> Error "invalid session component") rows
      | _ -> Error "Gate session scope must be a list" in
    let* session_scope = session_scope components in
    let* obligations = match field "obligations" fields with
      | `List rows -> decode_list gate_obligation_of_json rows | _ -> Error "Gate obligations must be a list" in
    official_client_gate_wait ~checkpoint:{client_kind; runtime_id; session_id; turn_id; tool_surface_sha256; frame}
      ~session_scope ~obligations
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
  let names = match json with `Assoc fields when List.mem_assoc "unconfirmed_wait" fields ->
    ["approval_ids";"obligations";"runtime_suffix";"unconfirmed_wait"]
    | _ -> ["approval_ids";"obligations";"runtime_suffix"] in
  let* fields = exact names json in
  let* approval_ids = match field "approval_ids" fields with
    | `List rows -> decode_list (function `String value -> Ok value | _ -> Error "approval id must be a string") rows
    | _ -> Error "approval ids must be a list" in
  let* obligations = match field "obligations" fields with
    | `List rows -> decode_list gate_obligation_of_json rows | _ -> Error "obligations must be a list" in
  let* runtime_suffix = match field "runtime_suffix" fields with
    | `Null -> Ok None | json -> runtime_suffix_of_json json |> Result.map Option.some in
  let* binding = gate_binding ~approval_ids ~obligations ~runtime_suffix in
  match List.assoc_opt "unconfirmed_wait" fields with
  | None -> Ok binding
  | Some json -> let* waiting = gate_wait_of_json json in gate_binding_with_wait ~binding ~waiting
let recovery_origin_of_json json =
  let* kind = kind_of_json json in
  match kind with
  | "unconfirmed_sources" | "confirmed_undispatched" | "interrupted_execution" ->
      let* _ = exact ["kind"] json in
      Ok (if kind = "unconfirmed_sources" then Unconfirmed_sources
          else if kind = "confirmed_undispatched" then Confirmed_undispatched
          else Interrupted_execution)
  | "gate_wait" ->
      let* fields = exact ["kind";"waiting";"resolution"] json in
      let* waiting = gate_wait_of_json (field "waiting" fields) in
      let* resolution = match field "resolution" fields with
        | `Null -> Ok None
        | json -> gate_resolution_of_json json |> Result.map Option.some in
      if Option.fold ~none:true ~some:(fun r -> List.mem r.obligation waiting.obligations) resolution
      then Ok (Gate_wait {waiting; resolution}) else Error "Gate resolution is not an obligation"
  | "gate_binding" ->
      let* fields = exact ["kind";"binding"] json in
      gate_binding_of_json (field "binding" fields) |> Result.map (fun binding -> Gate_binding binding)
  | "runtime_retry" ->
      runtime_retry_of_json json
      |> Result.map (fun retry -> Runtime_retry retry)
  | "checkpointed" ->
      let* fields = exact ["kind";"checkpoint"] json in
      checkpoint_of_json (field "checkpoint" fields) |> Result.map (fun checkpoint -> Checkpointed checkpoint)
  | _ -> Error "unknown recovery origin"
let phase_of_json json =
  let* kind = match json with
    | `Assoc fields -> (match List.assoc_opt "kind" fields with Some (`String kind) -> Ok kind | _ -> Error "phase kind missing")
    | _ -> Error "phase must be an object" in
  match kind with
  | "preparing" | "ready" | "running" ->
      let* _ = exact ["kind"] json in
      Ok (if kind = "preparing" then Preparing else if kind = "ready" then Ready else Running)
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
       | Checkpointed _ | Unconfirmed_sources | Confirmed_undispatched | Interrupted_execution | Gate_wait _ | Gate_binding _ ->
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

let of_json json =
  let decode () =
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
           && Option.fold ~none:true ~some:(fun waiting -> gate_checkpoint_owns waiting.checkpoint expected) binding.unconfirmed_wait
        then Ok () else Error "Gate binding lost prior obligations or source ownership"
      | Recovering {origin=Gate_wait state; _} ->
        if gate_checkpoint_owns state.waiting.checkpoint expected && gate_obligations = state.waiting.obligations then Ok ()
        else Error "Gate wait lost its owned obligations"
      | Resuming_gate (waiting, _) ->
        if gate_checkpoint_owns waiting.checkpoint expected && List.for_all (fun obligation -> List.mem obligation waiting.obligations) gate_obligations then Ok ()
        else Error "resumed Gate obligations changed identity"
      | Preparing | Ready | Running | Resuming_runtime_retry _ | Suspended _ | Settled _
      | Recovering {origin=(Runtime_retry _ | Checkpointed _ | Interrupted_execution
          | Unconfirmed_sources | Confirmed_undispatched); _} -> Ok () in
    let* input_sha256 = string "input_sha256" fields in
    let* () = if canonical_sha input_sha256 then Ok () else Error "invalid admitted input digest" in
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
           | Checkpointed _ | Interrupted_execution -> revision >= 2L
           | Runtime_retry _ | Gate_wait _ | Gate_binding _ -> revision >= 3L)
      | Settled _ -> revision >= 1L in
    let* () = if coherent then Ok ()
      else Error "execution phase, revision and initial frame are incoherent" in
    let* created_at = time "created_at" fields in
    let* updated_at = time "updated_at" fields in
    Ok { id; revision; input; input_sha256; gate_obligations; sources; current_sources; frame; phase; created_at; updated_at }
  in decode () |> Result.map_error (fun detail -> Invalid_record detail)

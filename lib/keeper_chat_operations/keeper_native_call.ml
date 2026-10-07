module Ref = Keeper_checkpoint_ref
module Agent = Agent_core.Agent
let ( let* ) = Result.bind

type api = New_input of { seed_message_count : int } | Continue_from_checkpoint
type t =
  { call_id : string
  ; runtime_id : string
  ; operation_digest : string
  ; api : api
  ; seed_checkpoint : Ref.t
  ; checkpoint : Ref.t
  ; locator : Agent.execution_locator
  }
type state =
  | No_native_call
  | Active of t
  | Terminal_unacknowledged of t * Agent.execution_terminal_disposition
type change =
  | Bind of {observed:state; call:t}
  | Checkpoint of {call_id:string; observed:Ref.t; checkpoint:Ref.t}
  | Terminal of {call_id:string; disposition:Agent.execution_terminal_disposition}
  | Acknowledge of string

let valid_component value = match Uuidm.of_string value with
  | Some uuid -> String.equal (Uuidm.to_string uuid) value
  | None -> false

let valid_digest value = String.length value = 64
  && String.for_all (function '0' .. '9' | 'a' .. 'f' -> true | _ -> false) value

let create ~call_id ~runtime_id ~operation_digest ~api ~seed_checkpoint ~locator =
  let* () = if valid_component call_id then Ok () else Error "invalid native call directory identity" in
  let* () = if String.trim runtime_id <> "" then Ok () else Error "native call runtime is empty" in
  let* () = if valid_digest operation_digest then Ok () else Error "invalid native operation digest" in
  let* () = match api with
    | New_input {seed_message_count} when seed_message_count < 0 -> Error "negative native seed length"
    | New_input _ | Continue_from_checkpoint -> Ok () in
  Ok {call_id; runtime_id; operation_digest; api; seed_checkpoint;
      checkpoint=seed_checkpoint; locator}

let advance call ~observed ~checkpoint =
  if not (Ref.equal call.checkpoint observed) then Error "native checkpoint source changed"
  else if call.seed_checkpoint.trace_id <> checkpoint.Ref.trace_id then Error "native checkpoint trace changed"
  else if checkpoint.turn_count < observed.turn_count then Error "native checkpoint regressed"
  else Ok {call with checkpoint}

let equal left right =
  left.call_id = right.call_id && left.runtime_id = right.runtime_id
  && left.operation_digest = right.operation_digest && left.api = right.api
  && Ref.equal left.seed_checkpoint right.seed_checkpoint
  && Ref.equal left.checkpoint right.checkpoint
  && Yojson.Safe.equal (Agent.execution_locator_to_yojson left.locator)
      (Agent.execution_locator_to_yojson right.locator)

let equal_state left right = match left, right with
  | No_native_call, No_native_call -> true
  | Active left, Active right -> equal left right
  | Terminal_unacknowledged (left, ld), Terminal_unacknowledged (right, rd) -> equal left right && ld = rd
  | (No_native_call | Active _ | Terminal_unacknowledged _), _ -> false

let transition state change = match state, change with
  | No_native_call, Bind {observed=No_native_call; call} -> Ok (Active call)
  | Active current, Bind {observed; call} when equal_state state observed && equal current call -> Ok state
  | Terminal_unacknowledged (previous, {Agent.recovery=Agent.Retire; _}), Bind {observed; call}
    when equal_state state observed && previous.call_id <> call.call_id
      && not (Yojson.Safe.equal (Agent.execution_locator_to_yojson previous.locator)
        (Agent.execution_locator_to_yojson call.locator)) -> Ok (Active call)
  | Active call, Checkpoint {call_id; observed; checkpoint} when call.call_id = call_id ->
    advance call ~observed ~checkpoint |> Result.map (fun call -> Active call)
  | Active call, Terminal {call_id; disposition} when call.call_id = call_id ->
    Ok (Terminal_unacknowledged (call, disposition))
  | Terminal_unacknowledged (call, current), Terminal {call_id; disposition}
    when call.call_id = call_id && current = disposition -> Ok state
  | Terminal_unacknowledged (call, {Agent.recovery=Agent.Retire; _}), Acknowledge call_id
    when call.call_id = call_id -> Ok No_native_call
  | (No_native_call | Active _ | Terminal_unacknowledged _),
    (Bind _ | Checkpoint _ | Terminal _ | Acknowledge _) -> Error "native call transition or identity is not admitted"

let checkpoint_references = function
  | No_native_call -> []
  | Active call | Terminal_unacknowledged (call, _) -> [call.seed_checkpoint; call.checkpoint]

let checkpoint_json (value : Ref.t) = `Assoc [
  "trace_id", `String (Keeper_id.Trace_id.to_string value.trace_id);
  "turn_count", `Int value.turn_count; "sha256", `String value.sha256]

let call_json call = `Assoc [
  "call_id", `String call.call_id; "runtime_id", `String call.runtime_id;
  "operation_digest", `String call.operation_digest;
  "api", (match call.api with
    | New_input {seed_message_count} -> `Assoc ["kind", `String "new_input"; "seed_message_count", `Int seed_message_count]
    | Continue_from_checkpoint -> `Assoc ["kind", `String "continue_from_checkpoint"]);
  "seed_checkpoint", checkpoint_json call.seed_checkpoint;
  "checkpoint", checkpoint_json call.checkpoint;
  "locator", Agent.execution_locator_to_yojson call.locator]

let state_to_json = function
  | No_native_call -> `Null
  | Active call -> `Assoc ["kind", `String "active"; "call", call_json call]
  | Terminal_unacknowledged (call, disposition) -> `Assoc [
      "kind", `String "terminal_unacknowledged"; "call", call_json call;
      "outcome", `String (match disposition.Agent.outcome with
        | Agent.Terminal_succeeded -> "succeeded" | Agent.Terminal_failed -> "failed"
        | Agent.Terminal_cancelled -> "cancelled");
      "recovery", `String (match disposition.Agent.recovery with
        | Agent.Retire -> "retire"
        | Agent.Operator_repair_required Agent.Effect_outcome_unknown -> "effect_outcome_unknown")]

let exact keys = function
  | `Assoc fields when List.sort String.compare (List.map fst fields) = List.sort String.compare keys -> Ok fields
  | _ -> Error "native call object fields do not match its schema"
let field key fields = List.assoc key fields
let string key fields = match field key fields with `String value -> Ok value | _ -> Error ("native call " ^ key ^ " must be a string")
let int key fields = match field key fields with `Int value -> Ok value | _ -> Error ("native call " ^ key ^ " must be an integer")
let checkpoint_of_json json =
  let* fields = exact ["trace_id"; "turn_count"; "sha256"] json in
  let* trace = string "trace_id" fields in
  let* trace_id = Keeper_id.Trace_id.of_string trace in
  let* turn_count = int "turn_count" fields in
  let* sha256 = string "sha256" fields in
  Ref.of_persisted ~trace_id ~turn_count ~sha256 |> Result.map_error (fun _ -> "invalid native checkpoint reference")
let api_of_json json = match json with
  | `Assoc [("kind", `String "continue_from_checkpoint")] -> Ok Continue_from_checkpoint
  | _ ->
    let* fields = exact ["kind"; "seed_message_count"] json in
    let* kind = string "kind" fields in
    let* seed_message_count = int "seed_message_count" fields in
    if kind = "new_input" && seed_message_count >= 0 then Ok (New_input {seed_message_count})
    else Error "invalid native API mode"
let call_of_json json =
  let* fields = exact ["call_id"; "runtime_id"; "operation_digest"; "api"; "seed_checkpoint"; "checkpoint"; "locator"] json in
  let* call_id = string "call_id" fields in
  let* runtime_id = string "runtime_id" fields in
  let* operation_digest = string "operation_digest" fields in
  let* api = api_of_json (field "api" fields) in
  let* seed_checkpoint = checkpoint_of_json (field "seed_checkpoint" fields) in
  let* checkpoint = checkpoint_of_json (field "checkpoint" fields) in
  let* locator = Agent.execution_locator_of_yojson (field "locator" fields) in
  let* call = create ~call_id ~runtime_id ~operation_digest ~api ~seed_checkpoint ~locator in
  advance call ~observed:seed_checkpoint ~checkpoint
let state_of_json = function
  | `Null -> Ok No_native_call
  | `Assoc fields as json ->
    (match List.assoc_opt "kind" fields with
     | Some (`String "active") ->
       let* fields = exact ["kind"; "call"] json in
       call_of_json (field "call" fields) |> Result.map (fun call -> Active call)
     | Some (`String "terminal_unacknowledged") ->
       let* fields = exact ["kind"; "call"; "outcome"; "recovery"] json in
       let* call = call_of_json (field "call" fields) in
       let* outcome = match field "outcome" fields with
         | `String "succeeded" -> Ok Agent.Terminal_succeeded
         | `String "failed" -> Ok Agent.Terminal_failed
         | `String "cancelled" -> Ok Agent.Terminal_cancelled
         | _ -> Error "unknown native terminal outcome" in
       let* recovery = match field "recovery" fields with
         | `String "retire" -> Ok Agent.Retire
         | `String "effect_outcome_unknown" -> Ok (Agent.Operator_repair_required Agent.Effect_outcome_unknown)
         | _ -> Error "unknown native recovery disposition" in
       Ok (Terminal_unacknowledged (call, {Agent.outcome; recovery}))
     | Some _ | None -> Error "unknown native call state")
  | _ -> Error "native call state must be an object or null"

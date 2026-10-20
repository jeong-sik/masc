type failure =
  { attempt : int
  ; runtime_id : string
  ; dispatch : Runtime_attempt_dispatch.t
  ; failure : Keeper_request_failure.t
  ; api_candidate_fault : Llm_provider.Candidate_fault.t option
  }

type terminal =
  | Terminal_not_observed
  | Candidate_terminal of
      { runtime_id : string
      ; attempt : int
      ; failure : Keeper_request_failure.t
      }

type t = { failures : failure list; terminal : terminal }

let empty = {failures=[];terminal=Terminal_not_observed}

let observe_failure ~runtime_id ~attempt ~dispatch error =
  let api_candidate_fault = match error with
    | Agent_core.Error.Api api -> Some (Llm_provider.Candidate_fault.of_api_error api)
    | Agent_core.Error.Provider _ | Agent_core.Error.Agent _ | Agent_core.Error.Mcp _
    | Agent_core.Error.Config _ | Agent_core.Error.Serialization _ | Agent_core.Error.Io _
    | Agent_core.Error.Orchestration _ | Agent_core.Error.Internal _
    | Agent_core.Error.Internal_carried _ -> None in
  {attempt;runtime_id;dispatch;failure=Keeper_request_failure.of_core_error error;
   api_candidate_fault}

let observe_terminal ~runtime_id ~attempt error =
  Candidate_terminal {runtime_id;attempt;failure=Keeper_request_failure.of_core_error error}

module Fault = Llm_provider.Candidate_fault

let binding_to_string = function
  | Fault.Credential -> "credential"
  | Fault.Account_access -> "account_access"
  | Fault.Account -> "account"
  | Fault.Model_absent -> "model_absent"
  | Fault.Rate_limit -> "rate_limit"
  | Fault.Capacity -> "capacity"
  | Fault.Server -> "server"
  | Fault.Window -> "window"
  | Fault.Body_limit -> "body_limit"
  | Fault.Admission -> "admission"
  | Fault.Deadline -> "deadline"
  | Fault.Output_dialect -> "output_dialect"
  | Fault.Refusal_unread -> "refusal_unread"

let binding_of_string = function
  | "credential" -> Some Fault.Credential
  | "account_access" -> Some Fault.Account_access
  | "account" -> Some Fault.Account
  | "model_absent" -> Some Fault.Model_absent
  | "rate_limit" -> Some Fault.Rate_limit
  | "capacity" -> Some Fault.Capacity
  | "server" -> Some Fault.Server
  | "window" -> Some Fault.Window
  | "body_limit" -> Some Fault.Body_limit
  | "admission" -> Some Fault.Admission
  | "deadline" -> Some Fault.Deadline
  | "output_dialect" -> Some Fault.Output_dialect
  | "refusal_unread" -> Some Fault.Refusal_unread
  | _ -> None

let fault_to_json = function
  | Fault.Binding fact -> `Assoc ["kind",`String "binding";"fact",`String (binding_to_string fact)]
  | Fault.Unattributed -> `Assoc ["kind",`String "unattributed"]
  | Fault.Unknown_after_dispatch -> `Assoc ["kind",`String "unknown_after_dispatch"]

let failure_to_json (value : failure) =
  `Assoc ["attempt",`Int value.attempt;"runtime_id",`String value.runtime_id;
    "dispatch",`String (Runtime_attempt_dispatch.to_string value.dispatch);
    "failure",Keeper_request_failure.to_yojson value.failure;
    "api_candidate_fault",(match value.api_candidate_fault with
      | Some fault -> fault_to_json fault | None -> `Null)]

let terminal_to_json = function
  | Terminal_not_observed -> `Assoc ["kind",`String "not_observed"]
  | Candidate_terminal {runtime_id;attempt;failure} ->
    `Assoc ["kind",`String "candidate";"runtime_id",`String runtime_id;
      "attempt",`Int attempt;"failure",Keeper_request_failure.to_yojson failure]

let to_yojson {failures;terminal} =
  `Assoc ["failures",`List (List.map failure_to_json failures);"terminal",terminal_to_json terminal]

let ( let* ) = Result.bind

let object_fields = function
  | `Assoc fields -> Ok fields
  | `Bool _ | `Float _ | `Int _ | `Intlit _ | `List _ | `Null | `String _ ->
    Error "runtime walk evidence must be an object"

let exact_fields expected fields =
  if List.equal String.equal (List.sort String.compare expected)
      (List.sort String.compare (List.map fst fields))
  then Ok () else Error "runtime walk evidence fields are missing, extra or duplicated"

let string_field key fields = match List.assoc_opt key fields with
  | Some (`String value) -> Ok value
  | Some (`Assoc _ | `Bool _ | `Float _ | `Int _ | `Intlit _ | `List _ | `Null) | None ->
    Error ("runtime walk evidence field must be a string: "^key)

let ordinal fields = match List.assoc_opt "attempt" fields with
  | Some (`Int attempt) when attempt >= 0 -> Ok attempt
  | Some (`Assoc _ | `Bool _ | `Float _ | `Int _ | `Intlit _ | `List _ | `Null | `String _) | None ->
    Error "runtime walk attempt must be a nonnegative integer"

let fault_of_json json =
  let* fields=object_fields json in
  let* kind=string_field "kind" fields in
  match kind with
  | "binding" ->
    let* ()=exact_fields ["kind";"fact"] fields in
    let* fact=string_field "fact" fields in
    (match binding_of_string fact with
     | Some fact -> Ok (Fault.Binding fact)
     | None -> Error "unknown runtime walk candidate binding fact")
  | "unattributed" ->
    let* ()=exact_fields ["kind"] fields in Ok Fault.Unattributed
  | "unknown_after_dispatch" ->
    let* ()=exact_fields ["kind"] fields in Ok Fault.Unknown_after_dispatch
  | _ -> Error "unknown runtime walk candidate fault kind"

let failure_of_json json =
  let* fields=object_fields json in
  let* ()=exact_fields ["attempt";"runtime_id";"dispatch";"failure";"api_candidate_fault"] fields in
  let* attempt=ordinal fields in
  let* runtime_id=string_field "runtime_id" fields in
  let* dispatch=string_field "dispatch" fields in
  let* dispatch=match dispatch with
    | "dispatched" -> Ok Runtime_attempt_dispatch.Dispatched
    | "rejected_before_dispatch" -> Ok Runtime_attempt_dispatch.Rejected_before_dispatch
    | _ -> Error "unknown runtime walk dispatch" in
  let* failure=Keeper_request_failure.of_yojson (List.assoc "failure" fields) in
  let* api_candidate_fault=match List.assoc "api_candidate_fault" fields with
    | `Null -> Ok None
    | (`Assoc _ | `Bool _ | `Float _ | `Int _ | `Intlit _ | `List _ | `String _) as json ->
      Result.map Option.some (fault_of_json json) in
  Ok {attempt;runtime_id;dispatch;failure;api_candidate_fault}

let terminal_of_json json =
  let* fields=object_fields json in
  let* kind=string_field "kind" fields in
  match kind with
  | "not_observed" ->
    let* ()=exact_fields ["kind"] fields in Ok Terminal_not_observed
  | "candidate" ->
    let* ()=exact_fields ["kind";"runtime_id";"attempt";"failure"] fields in
    let* runtime_id=string_field "runtime_id" fields in
    let* attempt=ordinal fields in
    let* failure=Keeper_request_failure.of_yojson (List.assoc "failure" fields) in
    Ok (Candidate_terminal {runtime_id;attempt;failure})
  | _ -> Error "unknown runtime walk terminal kind"

let of_yojson json =
  let* fields=object_fields json in
  let* ()=exact_fields ["failures";"terminal"] fields in
  let* failures=match List.assoc "failures" fields with
    | `List values ->
      let rec read acc = function
        | [] -> Ok (List.rev acc)
        | value::rest -> let* value=failure_of_json value in read (value::acc) rest in
      read [] values
    | `Assoc _ | `Bool _ | `Float _ | `Int _ | `Intlit _ | `Null | `String _ ->
      Error "runtime walk failures must be a list" in
  let* terminal=terminal_of_json (List.assoc "terminal" fields) in
  Ok {failures;terminal}

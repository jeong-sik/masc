module Types = Sse_event_t
module Json = Sse_event_j

let dashboard_observation_changed_payload_to_json payload =
  Yojson.Safe.from_string
    (Json.string_of_dashboard_observation_changed_payload payload)
;;

let dashboard_observation_changed_payload_of_json json =
  match
    Json.dashboard_observation_changed_payload_of_string
      (Yojson.Safe.to_string json)
  with
  | payload ->
      let nonempty value = not (String.equal (String.trim value) "") in
      let valid_scope = match payload.scope with
        | `Workspace -> true
        | `Keeper keeper -> nonempty keeper
        | `Operation { keeper_name; operation_id } ->
            nonempty keeper_name && nonempty operation_id
      in
      if valid_scope
      then Ok payload
      else Error "observation scope identifiers must be non-empty"
  | exception (Atdgen_runtime.Oj_run.Error detail | Yojson.Json_error detail) ->
      Error detail
;;

(** Encode the typed [agent_failed] payload independently from its delivery
    envelope. *)
let agent_failed_payload
      ~(agent_name : string)
      ~(task_id : string)
      ~(elapsed_s : float)
      ~(error : string)
      ~(error_domain : string)
      ~(error_code : string)
      ~(error_retryable : bool)
      ~(error_detail : Yojson.Safe.t)
  : Yojson.Safe.t
  =
  let p : Sse_event_t.agent_failed_payload =
    { agent_name
    ; task_id
    ; elapsed_s
    ; error
    ; error_domain
    ; error_code
    ; error_retryable
    ; error_detail
    }
  in
  Yojson.Safe.from_string (Sse_event_j.string_of_agent_failed_payload p)
;;

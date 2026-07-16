module History = Keeper_compaction_eligible_history
module Plan = Keeper_compaction_eligible_plan

type complete_fn = Keeper_provider_subcall.complete_fn

type structured_response_error =
  | Missing_text
  | Invalid_json of string

type candidate_failure_reason =
  | Runtime_missing
  | Schema_rejected of string
  | Transport_failed of Llm_provider.Http_client.http_error
  | Structured_response_rejected of structured_response_error
  | Plan_rejected of Plan.decode_error

type candidate_failure =
  { runtime_id : string
  ; reason : candidate_failure_reason
  }

type success =
  { plan : Plan.t
  ; selected_runtime_id : string
  ; failed_candidates : candidate_failure list
  }

type error =
  | Assignment_missing of string
  | Candidates_exhausted of
      { assignment_id : string
      ; failures : candidate_failure list
      }

type candidate =
  { runtime_id : string
  ; runtime : Runtime.t option
  }

let provider_for_plan (provider : Llm_provider.Provider_config.t) =
  { provider with
    tool_choice = None
  ; disable_parallel_tool_use = true
  ; response_format = Agent_sdk.Types.JsonSchema Plan.output_schema
  ; output_schema = Some Plan.output_schema
  }
;;

let messages_for_plan source =
  let message role text = Agent_sdk.Types.text_message role text in
  [ message
      Agent_sdk.Types.System
      "Judge every supplied eligible unit exactly once. Preserve facts or \
       replace/remove content only according to your semantic judgment. Return \
       only JSON conforming to the supplied response schema."
  ; message
      Agent_sdk.Types.User
      (Yojson.Safe.to_string (Plan.input_json source))
  ]
;;

let structured_json (response : Agent_sdk.Types.api_response) =
  let text = Agent_sdk.Types.visible_text_of_response response in
  if String.equal text ""
  then Error Missing_text
  else
    try Ok (Yojson.Safe.from_string text) with
    | Yojson.Json_error detail -> Error (Invalid_json detail)
;;

let complete_provider ?override ~sw ~net ?clock ~config ~messages () =
  match override with
  | Some complete -> complete ~sw ~net ?clock ~config ~messages ()
  | None ->
    Llm_provider.Complete.complete
      ~sw
      ~net
      ?clock
      ~config
      ~messages
      ~tools:[]
      ()
;;

let candidates assignment_id =
  match Runtime.resolve_assignment assignment_id with
  | `Missing -> Error (Assignment_missing assignment_id)
  | `Single_runtime runtime ->
    Ok [ { runtime_id = runtime.Runtime.id; runtime = Some runtime } ]
  | `Lane lane ->
    Ok
      (Runtime_lane.ordered_candidates lane
       |> List.map (fun runtime_id ->
         { runtime_id; runtime = Runtime.get_runtime_by_id runtime_id }))
;;

let attempt
    ?complete
    ~sw
    ~net
    ?clock
    ~source
    ({ runtime_id = _; runtime } : candidate)
  =
  match runtime with
  | None -> Error Runtime_missing
  | Some runtime ->
    let provider = provider_for_plan runtime.Runtime.provider_config in
    (match Llm_provider.Provider_config.validate_output_schema_request provider with
     | Error detail -> Error (Schema_rejected detail)
     | Ok () ->
       (match
          complete_provider
            ?override:complete
            ~sw
            ~net
            ?clock
            ~config:provider
            ~messages:(messages_for_plan source)
            ()
        with
        | Error error -> Error (Transport_failed error)
        | Ok response ->
          (match structured_json response with
           | Error error -> Error (Structured_response_rejected error)
           | Ok json ->
             (match Plan.decode ~source json with
              | Error error -> Error (Plan_rejected error)
              | Ok plan -> Ok plan))))
;;

let failure_label = function
  | Runtime_missing -> "runtime_missing"
  | Schema_rejected _ -> "schema_rejected"
  | Transport_failed _ -> "transport_failed"
  | Structured_response_rejected _ -> "structured_response_rejected"
  | Plan_rejected _ -> "plan_rejected"
;;

let run
    ?complete
    ~sw
    ~net
    ?clock
    ~keeper_name
    ~assignment_id
    ~source
    ()
  =
  match candidates assignment_id with
  | Error error -> Error error
  | Ok candidates ->
    let rec loop failures = function
      | [] ->
        Error
          (Candidates_exhausted
             { assignment_id; failures = List.rev failures })
      | ({ runtime_id; _ } as candidate) :: rest ->
        (match attempt ?complete ~sw ~net ?clock ~source candidate with
         | Ok plan ->
           Ok
             { plan
             ; selected_runtime_id = runtime_id
             ; failed_candidates = List.rev failures
             }
         | Error reason ->
           Log.Keeper.warn
             ~keeper_name
             "eligible compaction plan candidate rejected assignment=%s \
              runtime=%s reason=%s"
             assignment_id
             runtime_id
             (failure_label reason);
           loop ({ runtime_id; reason } :: failures) rest)
    in
    loop [] candidates
;;

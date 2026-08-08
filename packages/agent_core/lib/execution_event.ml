open Result_syntax

module type ID = Execution_id.S

module Event_id = Execution_id.Make (struct
    let value = "execution-event-"
  end)

module Run_id = Execution_id.Make (struct
    let value = "execution-run-"
  end)

module Node_id = Execution_id.Make (struct
    let value = "execution-node-"
  end)

module Correlation_id = Execution_id.Correlation

type output_block_kind =
  | Text_block
  | Thinking_block
  | Reasoning_details_block
  | Redacted_thinking_block
  | Image_block
  | Document_block
  | Audio_block
[@@deriving show]

let equal_output_block_kind left right = left = right

type content_block_classification =
  | Output_content of output_block_kind
  | Tool_use_content
  | Tool_result_content
[@@deriving show]

let classify_content_block (block : Llm_provider.Types.content_block) =
  let open Llm_provider.Types in
  match block with
  | Text _ -> Output_content Text_block
  | Thinking _ -> Output_content Thinking_block
  | ReasoningDetails _ -> Output_content Reasoning_details_block
  | RedactedThinking _ -> Output_content Redacted_thinking_block
  | ToolUse _ -> Tool_use_content
  | ToolResult _ -> Tool_result_content
  | Image _ -> Output_content Image_block
  | Document _ -> Output_content Document_block
  | Audio _ -> Output_content Audio_block
;;

type node_kind =
  | Agent_run of { agent_name : string }
  | Agent_turn of { ordinal : int }
  | Provider_attempt of
      { ordinal : int
      ; target : Binding_identity.Redacted_snapshot.t
      }
  | Output_block of
      { ordinal : int
      ; block_kind : output_block_kind
      }
  | Tool_invocation of
      { provider_tool_use_id : string option
      ; tool_name : string
      ; schedule : Tool_contract.schedule
      ; completion : Tool_contract.completion
      }
  | Tool_attempt

let pp_node_kind formatter = function
  | Agent_run { agent_name } ->
    Format.fprintf formatter "Agent_run {agent_name=%S}" agent_name
  | Agent_turn { ordinal } -> Format.fprintf formatter "Agent_turn {ordinal=%d}" ordinal
  | Provider_attempt { ordinal; target } ->
    Format.fprintf
      formatter
      "Provider_attempt {ordinal=%d; target=%a}"
      ordinal
      Binding_identity.Redacted_snapshot.pp
      target
  | Output_block { ordinal; block_kind } ->
    Format.fprintf
      formatter
      "Output_block {ordinal=%d; block_kind=%a}"
      ordinal
      pp_output_block_kind
      block_kind
  | Tool_invocation { provider_tool_use_id; tool_name; schedule; completion } ->
    Format.fprintf
      formatter
      "Tool_invocation {provider_tool_use_id=%a; tool_name=%S; \
       schedule={planned_index=%d; batch_index=%d; batch_size=%d; execution_mode=%a}; \
       completion=%a}"
      (Format.pp_print_option Format.pp_print_string)
      provider_tool_use_id
      tool_name
      schedule.planned_index
      schedule.batch_index
      schedule.batch_size
      Tool_contract.pp_execution_mode
      schedule.execution_mode
      Tool_contract.pp_completion
      completion
  | Tool_attempt -> Format.pp_print_string formatter "Tool_attempt"
;;

let show_node_kind kind = Format.asprintf "%a" pp_node_kind kind

type node =
  { node_id : Node_id.t
  ; run_id : Run_id.t
  ; parent_node_id : Node_id.t option
  ; kind : node_kind
  }

let node_id node = node.node_id
let node_run_id node = node.run_id
let parent_node_id node = node.parent_node_id
let node_kind node = node.kind

let validate_non_blank field value =
  if String.equal (String.trim value) ""
  then Error (field ^ " must contain non-whitespace text")
  else Ok ()
;;

let validate_json = Execution_json.validate

let validate_node_kind = function
  | Agent_run { agent_name } -> validate_non_blank "agent_name" agent_name
  | Agent_turn { ordinal } ->
    if ordinal < 0 then Error "agent turn ordinal must be non-negative" else Ok ()
  | Provider_attempt { ordinal; _ } ->
    if ordinal < 0 then Error "provider attempt ordinal must be non-negative" else Ok ()
  | Output_block { ordinal; _ } ->
    if ordinal < 0 then Error "output block ordinal must be non-negative" else Ok ()
  | Tool_invocation { provider_tool_use_id = _; tool_name; schedule; completion } ->
    let* () = validate_non_blank "tool_name" tool_name in
    Execution_tool_schedule.validate_completion_message ~completion schedule
  | Tool_attempt -> Ok ()
;;

let provider_attempt ~ordinal binding =
  let kind =
    Provider_attempt { ordinal; target = Binding_identity.redacted_snapshot binding }
  in
  let+ () = validate_node_kind kind in
  kind
;;

let make_node ~node_id ~run_id ~parent_node_id ~kind =
  let* () = validate_node_kind kind in
  Ok { node_id; run_id; parent_node_id; kind }
;;

let equal_node_kind left right =
  match left, right with
  | Agent_run left, Agent_run right -> String.equal left.agent_name right.agent_name
  | Agent_turn left, Agent_turn right -> left.ordinal = right.ordinal
  | Provider_attempt left, Provider_attempt right ->
    left.ordinal = right.ordinal
    && Binding_identity.Redacted_snapshot.equal left.target right.target
  | Output_block left, Output_block right ->
    left.ordinal = right.ordinal
    && equal_output_block_kind left.block_kind right.block_kind
  | Tool_invocation left, Tool_invocation right ->
    Option.equal String.equal left.provider_tool_use_id right.provider_tool_use_id
    && String.equal left.tool_name right.tool_name
    && Execution_tool_schedule.equal left.schedule right.schedule
    && left.completion = right.completion
  | Tool_attempt, Tool_attempt -> true
  | ( ( Agent_run _
      | Agent_turn _
      | Provider_attempt _
      | Output_block _
      | Tool_invocation _
      | Tool_attempt )
    , _ ) -> false
;;

let equal_node left right =
  Node_id.equal left.node_id right.node_id
  && Run_id.equal left.run_id right.run_id
  && Option.equal Node_id.equal left.parent_node_id right.parent_node_id
  && equal_node_kind left.kind right.kind
;;

let pp_node formatter node =
  Format.fprintf
    formatter
    "{node_id=%s; run_id=%s; parent_node_id=%a; kind=%a}"
    (Node_id.to_string node.node_id)
    (Run_id.to_string node.run_id)
    (Format.pp_print_option Node_id.pp)
    node.parent_node_id
    pp_node_kind
    node.kind
;;

let show_node node = Format.asprintf "%a" pp_node node

type node_update =
  | Provider_event of Yojson.Safe.t
  | Provider_response_snapshot of Llm_provider.Types.api_response
  | Output_delta of Yojson.Safe.t
  | Output_snapshot of Llm_provider.Types.content_block
  | Tool_input_delta of Yojson.Safe.t
  | Tool_input_snapshot of Llm_provider.Types.content_block
  | Tool_progress of Yojson.Safe.t
  | Tool_result of Llm_provider.Types.content_block
[@@deriving show]

type failure_kind =
  | Provider_failure
  | Tool_failure
  | Hook_failure
  | Observer_failure
  | Persistence_failure
  | Protocol_failure
  | Internal_failure
[@@deriving show]

let equal_failure_kind left right = left = right

type failure =
  { kind : failure_kind
  ; detail : string
  ; data : Yojson.Safe.t option
  }
[@@deriving show]

type terminal =
  | Succeeded
  | Failed of failure
  | Cancelled of
      { reason : string option
      ; data : Yojson.Safe.t option
      }
[@@deriving show]

type payload =
  | Node_opened of node
  | Node_updated of
      { node_id : Node_id.t
      ; update : node_update
      }
  | Node_closed of
      { node_id : Node_id.t
      ; terminal : terminal
      }
[@@deriving show]

module External_source = Execution_cause.External_source
module Cause = Execution_cause.Make (Event_id)
module Response_snapshot = Execution_provider_response_snapshot

type cause = Cause.t =
  | Internal_event of Event_id.t
  | External_event of
      { source : External_source.t
      ; event_id : string
      }
[@@deriving show]

type t =
  { event_id : Event_id.t
  ; run_id : Run_id.t
  ; correlation_id : Correlation_id.t
  ; seq : int
  ; parent_event_id : Event_id.t option
  ; envelope : Event_envelope.t
  ; causes : cause list
  ; payload : payload
  }

let durable_content_to_yojson block =
  try Ok (Checkpoint_codec.checkpoint_content_block_to_json block) with
  | exn ->
    Llm_provider.Reserved_exn.reraise_if_reserved exn;
    Error ("durable content snapshot encoding failed: " ^ Printexc.to_string exn)
;;

let durable_content_of_yojson json =
  let decoded =
    try
      Checkpoint_codec.content_block_of_json_strict json
      |> Result.map_error Error.to_string
    with
    | exn ->
      Llm_provider.Reserved_exn.reraise_if_reserved exn;
      Error ("durable content snapshot decoding failed: " ^ Printexc.to_string exn)
  in
  let* block = decoded in
  let* canonical = durable_content_to_yojson block in
  if Yojson.Safe.equal json canonical
  then Ok block
  else Error "durable content snapshot is not in canonical closed form"
;;

let validate_content_block block =
  let open Llm_provider.Types in
  let* json = durable_content_to_yojson block in
  let* () = validate_json ~context:"canonical content snapshot" json in
  let* decoded = durable_content_of_yojson json in
  if block = decoded
  then (
    match block with
    | ToolUse { id = _; name; _ } -> validate_non_blank "tool-use name" name
    | ToolResult { tool_use_id = _; _ } -> Ok ()
    | Text _
    | Thinking _
    | ReasoningDetails _
    | RedactedThinking _
    | Image _
    | Document _
    | Audio _ -> Ok ())
  else Error "canonical content snapshot is not losslessly durable"
;;

let validate_node_update update =
  match update with
  | Provider_response_snapshot value -> Response_snapshot.validate value
  | Provider_event value -> validate_json ~context:"provider event" value
  | Output_delta value -> validate_json ~context:"output delta" value
  | Tool_input_delta value -> validate_json ~context:"tool input delta" value
  | Tool_progress value -> validate_json ~context:"tool progress" value
  | Output_snapshot block | Tool_input_snapshot block | Tool_result block ->
    validate_content_block block
;;

let validate_failure failure =
  if String.equal (String.trim failure.detail) ""
  then Error "failure detail must contain non-whitespace text"
  else (
    match failure.data with
    | None -> Ok ()
    | Some data -> validate_json ~context:"failure data" data)
;;

let validate_terminal_value = function
  | Succeeded -> Ok ()
  | Failed failure -> validate_failure failure
  | Cancelled { reason; data } ->
    let* () =
      match reason with
      | None -> Ok ()
      | Some reason when String.equal (String.trim reason) "" ->
        Error "cancelled reason must contain non-whitespace text"
      | Some _ -> Ok ()
    in
    let* () =
      match reason, data with
      | None, None -> Error "cancelled terminal requires reason or data"
      | (None | Some _), Some data -> validate_json ~context:"cancelled data" data
      | Some _, None -> Ok ()
    in
    Ok ()
;;

type validated_terminal = Validated_terminal of terminal

let validate_terminal terminal =
  let+ () = validate_terminal_value terminal in
  Validated_terminal terminal
;;

let validate_payload_value = function
  | Node_opened _ -> Ok ()
  | Node_updated { update; _ } -> validate_node_update update
  | Node_closed { terminal; _ } -> validate_terminal_value terminal
;;

type validated_payload = Validated_payload of payload

let validate_payload payload =
  let+ () = validate_payload_value payload in
  Validated_payload payload
;;

let close_payload ~node_id (Validated_terminal terminal) =
  Validated_payload (Node_closed { node_id; terminal })
;;

let payload_run_id = function
  | Node_opened node -> Some node.run_id
  | Node_updated _ | Node_closed _ -> None
;;

let make_validated ?(causes = []) ~envelope (Validated_payload payload) =
  let* event_id = Event_id.of_string envelope.Event_envelope.event_id in
  let* envelope_run_id = Run_id.of_string envelope.run_id in
  let* correlation_id = Correlation_id.of_string envelope.correlation_id in
  let* parent_event_id =
    match envelope.parent_event_id with
    | None -> Ok None
    | Some value ->
      let+ event_id = Event_id.of_string value in
      Some event_id
  in
  let* () =
    match envelope.caused_by with
    | None -> Ok ()
    | Some _ ->
      Error "execution event envelope caused_by must be null; use the typed cause field"
  in
  let* () = Cause.validate_all causes in
  let* () =
    if
      Execution_json.is_finite_number envelope.event_time
      && Execution_json.is_finite_number envelope.observed_at
    then Ok ()
    else Error "event timestamps must be finite"
  in
  let* seq =
    match envelope.seq with
    | Some seq when seq > 0 -> Ok seq
    | Some _ -> Error "event seq must be positive"
    | None -> Error "event seq is required"
  in
  let* () =
    match payload_run_id payload with
    | None -> Ok ()
    | Some payload_run_id when Run_id.equal payload_run_id envelope_run_id -> Ok ()
    | Some _ -> Error "opened node run_id must match event envelope run_id"
  in
  Ok
    { event_id
    ; run_id = envelope_run_id
    ; correlation_id
    ; seq
    ; parent_event_id
    ; envelope
    ; causes
    ; payload
    }
;;

let make ?(causes = []) ~envelope payload =
  let* payload = validate_payload payload in
  make_validated ~causes ~envelope payload
;;

let envelope event = event.envelope
let event_id event = event.event_id
let run_id event = event.run_id
let correlation_id event = event.correlation_id
let seq event = event.seq
let parent_event_id event = event.parent_event_id
let causes event = event.causes
let payload event = event.payload

let equal_update left right =
  match left, right with
  | Provider_event left, Provider_event right
  | Output_delta left, Output_delta right
  | Tool_input_delta left, Tool_input_delta right
  | Tool_progress left, Tool_progress right -> Yojson.Safe.equal left right
  | Output_snapshot left, Output_snapshot right
  | Tool_input_snapshot left, Tool_input_snapshot right
  | Tool_result left, Tool_result right -> left = right
  | Provider_response_snapshot left, Provider_response_snapshot right -> left = right
  | ( ( Provider_event _
      | Provider_response_snapshot _
      | Output_delta _
      | Output_snapshot _
      | Tool_input_delta _
      | Tool_input_snapshot _
      | Tool_progress _
      | Tool_result _ )
    , _ ) -> false
;;

let equal_failure left right =
  equal_failure_kind left.kind right.kind
  && String.equal left.detail right.detail
  && Option.equal Yojson.Safe.equal left.data right.data
;;

let equal_terminal left right =
  match left, right with
  | Succeeded, Succeeded -> true
  | Failed left, Failed right -> equal_failure left right
  | Cancelled left, Cancelled right ->
    Option.equal String.equal left.reason right.reason
    && Option.equal Yojson.Safe.equal left.data right.data
  | (Succeeded | Failed _ | Cancelled _), _ -> false
;;

let equal_payload left right =
  match left, right with
  | Node_opened left, Node_opened right -> equal_node left right
  | Node_updated left, Node_updated right ->
    Node_id.equal left.node_id right.node_id && equal_update left.update right.update
  | Node_closed left, Node_closed right ->
    Node_id.equal left.node_id right.node_id
    && equal_terminal left.terminal right.terminal
  | (Node_opened _ | Node_updated _ | Node_closed _), _ -> false
;;

let equal left right =
  Yojson.Safe.equal
    (Event_envelope.to_json left.envelope)
    (Event_envelope.to_json right.envelope)
  && List.equal Cause.equal left.causes right.causes
  && equal_payload left.payload right.payload
;;

let object_fields = Execution_json.object_fields
let field = Execution_json.field
let string_field = Execution_json.string_field
let int_field = Execution_json.int_field
let option_string_field = Execution_json.option_string_field
let option_json = Execution_json.option_json

let output_block_kind_to_string = function
  | Text_block -> "text"
  | Thinking_block -> "thinking"
  | Reasoning_details_block -> "reasoning_details"
  | Redacted_thinking_block -> "redacted_thinking"
  | Image_block -> "image"
  | Document_block -> "document"
  | Audio_block -> "audio"
;;

let output_block_kind_of_string = function
  | "text" -> Ok Text_block
  | "thinking" -> Ok Thinking_block
  | "reasoning_details" -> Ok Reasoning_details_block
  | "redacted_thinking" -> Ok Redacted_thinking_block
  | "image" -> Ok Image_block
  | "document" -> Ok Document_block
  | "audio" -> Ok Audio_block
  | value -> Error ("unknown output block kind: " ^ value)
;;

let schedule_to_yojson = Execution_tool_schedule.to_yojson
let schedule_of_yojson = Execution_tool_schedule.of_yojson

let node_kind_to_yojson_unchecked = function
  | Agent_run { agent_name } ->
    `Assoc [ "type", `String "agent_run"; "agent_name", `String agent_name ]
  | Agent_turn { ordinal } ->
    `Assoc [ "type", `String "agent_turn"; "ordinal", `Int ordinal ]
  | Provider_attempt { ordinal; target } ->
    `Assoc
      [ "type", `String "provider_attempt"
      ; "ordinal", `Int ordinal
      ; "target", Binding_identity.Redacted_snapshot.to_yojson target
      ]
  | Output_block { ordinal; block_kind } ->
    `Assoc
      [ "type", `String "output_block"
      ; "ordinal", `Int ordinal
      ; "block_kind", `String (output_block_kind_to_string block_kind)
      ]
  | Tool_invocation { provider_tool_use_id; tool_name; schedule; completion } ->
    `Assoc
      [ "type", `String "tool_invocation"
      ; ( "provider_tool_use_id"
        , option_json (Option.map (fun v -> `String v) provider_tool_use_id) )
      ; "tool_name", `String tool_name
      ; "schedule", schedule_to_yojson schedule
      ; "completion", Tool_contract.completion_to_yojson completion
      ]
  | Tool_attempt -> `Assoc [ "type", `String "tool_attempt" ]
;;

let node_kind_to_yojson kind =
  let+ () = validate_node_kind kind in
  node_kind_to_yojson_unchecked kind
;;

let node_kind_of_yojson json =
  let* header =
    object_fields
      ~context:"node kind"
      ~required:[ "type" ]
      ~optional:
        [ "agent_name"
        ; "ordinal"
        ; "target"
        ; "block_kind"
        ; "provider_tool_use_id"
        ; "tool_name"
        ; "schedule"
        ; "completion"
        ]
      json
  in
  let* kind = string_field "type" header in
  let decode ~required ~optional construct =
    let* fields =
      object_fields
        ~context:(kind ^ " node kind")
        ~required:("type" :: required)
        ~optional
        json
    in
    construct fields
  in
  let* value =
    match kind with
    | "agent_run" ->
      decode ~required:[ "agent_name" ] ~optional:[] (fun fields ->
        let+ agent_name = string_field "agent_name" fields in
        Agent_run { agent_name })
    | "agent_turn" ->
      decode ~required:[ "ordinal" ] ~optional:[] (fun fields ->
        let+ ordinal = int_field "ordinal" fields in
        Agent_turn { ordinal })
    | "provider_attempt" ->
      decode ~required:[ "ordinal"; "target" ] ~optional:[] (fun fields ->
        let* ordinal = int_field "ordinal" fields in
        let* target_json = field "target" fields in
        let+ target = Binding_identity.Redacted_snapshot.of_yojson target_json in
        Provider_attempt { ordinal; target })
    | "output_block" ->
      decode ~required:[ "ordinal"; "block_kind" ] ~optional:[] (fun fields ->
        let* ordinal = int_field "ordinal" fields in
        let* block_kind_string = string_field "block_kind" fields in
        let+ block_kind = output_block_kind_of_string block_kind_string in
        Output_block { ordinal; block_kind })
    | "tool_invocation" ->
      decode
        ~required:[ "provider_tool_use_id"; "tool_name"; "schedule"; "completion" ]
        ~optional:[]
        (fun fields ->
           let* provider_tool_use_id =
             option_string_field "provider_tool_use_id" fields
           in
           let* tool_name = string_field "tool_name" fields in
           let* schedule_json = field "schedule" fields in
           let* schedule = schedule_of_yojson schedule_json in
           let* completion_json = field "completion" fields in
           let+ completion = Tool_contract.completion_of_yojson completion_json in
           Tool_invocation { provider_tool_use_id; tool_name; schedule; completion })
    | "tool_attempt" -> decode ~required:[] ~optional:[] (fun _ -> Ok Tool_attempt)
    | value -> Error ("unknown node kind: " ^ value)
  in
  let* () = validate_node_kind value in
  Ok value
;;

let node_to_yojson node =
  `Assoc
    [ "node_id", `String (Node_id.to_string node.node_id)
    ; "run_id", `String (Run_id.to_string node.run_id)
    ; ( "parent_node_id"
      , option_json
          (Option.map
             (fun value -> `String (Node_id.to_string value))
             node.parent_node_id) )
    ; "kind", node_kind_to_yojson_unchecked node.kind
    ]
;;

let node_of_yojson json =
  let* fields =
    object_fields
      ~context:"execution node"
      ~required:[ "node_id"; "run_id"; "parent_node_id"; "kind" ]
      ~optional:[]
      json
  in
  let* node_id_string = string_field "node_id" fields in
  let* node_id = Node_id.of_string node_id_string in
  let* run_id_string = string_field "run_id" fields in
  let* run_id = Run_id.of_string run_id_string in
  let* parent_node_id_string = option_string_field "parent_node_id" fields in
  let* parent_node_id =
    match parent_node_id_string with
    | None -> Ok None
    | Some value ->
      let+ value = Node_id.of_string value in
      Some value
  in
  let* kind_json = field "kind" fields in
  let* kind = node_kind_of_yojson kind_json in
  make_node ~node_id ~run_id ~parent_node_id ~kind
;;

let node_update_json kind value = `Assoc [ "type", `String kind; "value", value ]

let node_update_to_yojson_unchecked update =
  match update with
  | Provider_response_snapshot value ->
    node_update_json "provider_response_snapshot" (Response_snapshot.to_yojson value)
  | Provider_event value -> node_update_json "provider_event" value
  | Output_delta value -> node_update_json "output_delta" value
  | Output_snapshot value ->
    node_update_json
      "output_snapshot"
      (Checkpoint_codec.checkpoint_content_block_to_json value)
  | Tool_input_delta value -> node_update_json "tool_input_delta" value
  | Tool_input_snapshot value ->
    node_update_json
      "tool_input_snapshot"
      (Checkpoint_codec.checkpoint_content_block_to_json value)
  | Tool_progress value -> node_update_json "tool_progress" value
  | Tool_result value ->
    node_update_json
      "tool_result"
      (Checkpoint_codec.checkpoint_content_block_to_json value)
;;

let node_update_to_yojson update =
  let+ () = validate_node_update update in
  node_update_to_yojson_unchecked update
;;

let node_update_of_yojson json =
  let* fields =
    object_fields ~context:"node update" ~required:[ "type"; "value" ] ~optional:[] json
  in
  let* kind = string_field "type" fields in
  let* value = field "value" fields in
  let* update =
    match kind with
    | "provider_event" -> Ok (Provider_event value)
    | "provider_response_snapshot" ->
      let+ value = Response_snapshot.of_yojson value in
      Provider_response_snapshot value
    | "output_delta" -> Ok (Output_delta value)
    | "output_snapshot" ->
      let+ block = durable_content_of_yojson value in
      Output_snapshot block
    | "tool_input_delta" -> Ok (Tool_input_delta value)
    | "tool_input_snapshot" ->
      let+ block = durable_content_of_yojson value in
      Tool_input_snapshot block
    | "tool_progress" -> Ok (Tool_progress value)
    | "tool_result" ->
      let+ block = durable_content_of_yojson value in
      Tool_result block
    | value -> Error ("unknown node update: " ^ value)
  in
  let+ () = validate_node_update update in
  update
;;

let failure_kind_to_string = function
  | Provider_failure -> "provider"
  | Tool_failure -> "tool"
  | Hook_failure -> "hook"
  | Observer_failure -> "observer"
  | Persistence_failure -> "persistence"
  | Protocol_failure -> "protocol"
  | Internal_failure -> "internal"
;;

let failure_kind_of_string = function
  | "provider" -> Ok Provider_failure
  | "tool" -> Ok Tool_failure
  | "hook" -> Ok Hook_failure
  | "observer" -> Ok Observer_failure
  | "persistence" -> Ok Persistence_failure
  | "protocol" -> Ok Protocol_failure
  | "internal" -> Ok Internal_failure
  | value -> Error ("unknown failure kind: " ^ value)
;;

let failure_to_yojson failure =
  `Assoc
    [ "kind", `String (failure_kind_to_string failure.kind)
    ; "detail", `String failure.detail
    ; "data", option_json failure.data
    ]
;;

let failure_of_yojson json =
  let* fields =
    object_fields
      ~context:"execution failure"
      ~required:[ "kind"; "detail"; "data" ]
      ~optional:[]
      json
  in
  let* kind_string = string_field "kind" fields in
  let* kind = failure_kind_of_string kind_string in
  let* detail = string_field "detail" fields in
  let* data_json = field "data" fields in
  let data =
    match data_json with
    | `Null -> None
    | value -> Some value
  in
  Ok { kind; detail; data }
;;

let terminal_to_yojson_unchecked = function
  | Succeeded -> `Assoc [ "type", `String "succeeded" ]
  | Failed failure ->
    `Assoc [ "type", `String "failed"; "failure", failure_to_yojson failure ]
  | Cancelled { reason; data } ->
    `Assoc
      [ "type", `String "cancelled"
      ; "reason", option_json (Option.map (fun value -> `String value) reason)
      ; "data", option_json data
      ]
;;

let terminal_to_yojson terminal =
  let+ _validated = validate_terminal terminal in
  terminal_to_yojson_unchecked terminal
;;

let terminal_of_yojson json =
  let* header =
    object_fields
      ~context:"terminal"
      ~required:[ "type" ]
      ~optional:[ "failure"; "reason"; "data" ]
      json
  in
  let* kind = string_field "type" header in
  let* terminal =
    match kind with
    | "succeeded" ->
      let* _ =
        object_fields ~context:"succeeded terminal" ~required:[ "type" ] ~optional:[] json
      in
      Ok Succeeded
    | "failed" ->
      let* fields =
        object_fields
          ~context:"failed terminal"
          ~required:[ "type"; "failure" ]
          ~optional:[]
          json
      in
      let* failure_json = field "failure" fields in
      let+ failure = failure_of_yojson failure_json in
      Failed failure
    | "cancelled" ->
      let* fields =
        object_fields
          ~context:"cancelled terminal"
          ~required:[ "type"; "reason"; "data" ]
          ~optional:[]
          json
      in
      let* reason = option_string_field "reason" fields in
      let* data_json = field "data" fields in
      let data =
        match data_json with
        | `Null -> None
        | value -> Some value
      in
      Ok (Cancelled { reason; data })
    | value -> Error ("unknown terminal: " ^ value)
  in
  let+ _validated = validate_terminal terminal in
  terminal
;;

let payload_to_yojson = function
  | Node_opened node ->
    `Assoc [ "type", `String "node_opened"; "node", node_to_yojson node ]
  | Node_updated { node_id; update } ->
    `Assoc
      [ "type", `String "node_updated"
      ; "node_id", `String (Node_id.to_string node_id)
      ; "update", node_update_to_yojson_unchecked update
      ]
  | Node_closed { node_id; terminal } ->
    `Assoc
      [ "type", `String "node_closed"
      ; "node_id", `String (Node_id.to_string node_id)
      ; "terminal", terminal_to_yojson_unchecked terminal
      ]
;;

let payload_of_yojson json =
  let* header =
    object_fields
      ~context:"execution payload"
      ~required:[ "type" ]
      ~optional:[ "node"; "node_id"; "update"; "terminal" ]
      json
  in
  let* kind = string_field "type" header in
  match kind with
  | "node_opened" ->
    let* fields =
      object_fields
        ~context:"node_opened payload"
        ~required:[ "type"; "node" ]
        ~optional:[]
        json
    in
    let* node_json = field "node" fields in
    let+ node = node_of_yojson node_json in
    Node_opened node
  | "node_updated" ->
    let* fields =
      object_fields
        ~context:"node_updated payload"
        ~required:[ "type"; "node_id"; "update" ]
        ~optional:[]
        json
    in
    let* node_id_string = string_field "node_id" fields in
    let* node_id = Node_id.of_string node_id_string in
    let* update_json = field "update" fields in
    let+ update = node_update_of_yojson update_json in
    Node_updated { node_id; update }
  | "node_closed" ->
    let* fields =
      object_fields
        ~context:"node_closed payload"
        ~required:[ "type"; "node_id"; "terminal" ]
        ~optional:[]
        json
    in
    let* node_id_string = string_field "node_id" fields in
    let* node_id = Node_id.of_string node_id_string in
    let* terminal_json = field "terminal" fields in
    let+ terminal = terminal_of_yojson terminal_json in
    Node_closed { node_id; terminal }
  | value -> Error ("unknown execution payload: " ^ value)
;;

let schema_version_current = 3

let to_yojson event =
  `Assoc
    [ "schema_version", `Int schema_version_current
    ; "envelope", Event_envelope.to_json event.envelope
    ; "causes", `List (List.map Cause.to_yojson event.causes)
    ; "payload", payload_to_yojson event.payload
    ]
;;

let of_yojson json =
  let* fields =
    object_fields
      ~context:"execution event"
      ~required:[ "schema_version"; "envelope"; "causes"; "payload" ]
      ~optional:[]
      json
  in
  let* schema_version = int_field "schema_version" fields in
  if schema_version <> schema_version_current
  then
    Error (Printf.sprintf "unsupported execution event schema_version: %d" schema_version)
  else
    let* envelope_json = field "envelope" fields in
    let* _ =
      object_fields
        ~context:"execution event envelope"
        ~required:
          [ "event_id"
          ; "correlation_id"
          ; "run_id"
          ; "event_time"
          ; "observed_at"
          ; "seq"
          ; "parent_event_id"
          ; "caused_by"
          ; "source_clock"
          ]
        ~optional:[]
        envelope_json
    in
    let* envelope = Event_envelope.of_json envelope_json in
    let* causes_json = field "causes" fields in
    let* causes =
      match causes_json with
      | `List values ->
        List.fold_left
          (fun result value ->
             let* reverse_causes = result in
             let+ cause = Cause.of_yojson value in
             cause :: reverse_causes)
          (Ok [])
          values
        |> Result.map List.rev
      | _ -> Error "execution event causes must be a JSON array"
    in
    let* payload_json = field "payload" fields in
    let* payload = payload_of_yojson payload_json in
    make ~causes ~envelope payload
;;

let to_json_string event = Yojson.Safe.to_string (to_yojson event)

let of_json_string encoded =
  (* The Util exceptions are unreachable while the of_yojson path stays
     assoc-based; catching them keeps the (t, string) result total if a
     future decoder edit introduces a Yojson.Safe.Util accessor. *)
  try Yojson.Safe.from_string encoded |> of_yojson with
  | Yojson.Json_error detail -> Error ("invalid execution event JSON: " ^ detail)
  | Yojson.Safe.Util.Type_error (detail, _) | Yojson.Safe.Util.Undefined (detail, _) ->
    Error ("invalid execution event JSON: " ^ detail)
;;

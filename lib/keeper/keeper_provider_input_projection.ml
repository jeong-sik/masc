(** See [keeper_provider_input_projection.mli]. *)

open Result.Syntax

type observation =
  { limit_bytes : int
  ; stream : bool
  ; canonical_history_messages : int
  ; current_run_messages : int
  ; body_bytes : int
  ; body_sha256 : string
  ; fits : bool
  }

type inspection =
  { body_bytes : int
  ; body_sha256 : string
  }

type inspection_failure =
  { limit_bytes : int
  ; stream : bool
  ; canonical_history_messages : int
  ; current_run_messages : int
  ; detail : string
  }

type serialized_request_inspector =
  stream:bool ->
  config:Llm_provider.Provider_config.t ->
  messages:Agent_sdk.Types.message list ->
  tools:Yojson.Safe.t list ->
  unit ->
  (inspection, string) result

let prefix_mismatch_to_string = function
  | Keeper_replay_prefix.Prefix_longer_than_messages ->
    "canonical_prefix_longer_than_provider_messages"
  | Keeper_replay_prefix.Prefix_message_mismatch ->
    "canonical_prefix_message_mismatch"
;;

let project_base base_projection messages =
  try Ok (base_projection messages) with
  | exn ->
    Llm_provider.Reserved_exn.reraise_if_reserved exn;
    Error
      (Printf.sprintf
         "keeper provider input base projection raised: %s"
         (Printexc.to_string exn))
;;

let base_block_preserves_position
      (before : Agent_sdk.Types.content_block)
      (after : Agent_sdk.Types.content_block)
  =
  match
    Agent_sdk.Canonical_tool.tool_result_of_block before,
    Agent_sdk.Canonical_tool.tool_result_of_block after
  with
  | Some before, Some after ->
    (* Artifact hydration may replace only the opaque result payload. The
       protocol identity and outcome remain tied to the same call position. *)
    String.equal before.call_id after.call_id
    && before.outcome = after.outcome
    && before.structured_content = after.structured_content
    && before.content_blocks = after.content_blocks
  | None, None -> before = after
  | Some _, None | None, Some _ -> false
;;

let base_message_preserves_position
      (before : Agent_sdk.Types.message)
      (after : Agent_sdk.Types.message)
  =
  before.role = after.role
  && before.name = after.name
  && before.tool_call_id = after.tool_call_id
  && before.metadata = after.metadata
  && List.length before.content = List.length after.content
  && List.for_all2 base_block_preserves_position before.content after.content
;;

let rec first_base_projection_mismatch index before after =
  match before, after with
  | [], [] -> None
  | before :: before_rest, after :: after_rest ->
    if base_message_preserves_position before after
    then first_base_projection_mismatch (index + 1) before_rest after_rest
    else Some index
  | [], _ :: _ | _ :: _, [] -> Some index
;;

let notify observe observation =
  match observe with
  | None -> ()
  | Some observe ->
    (try observe observation with
     | exn ->
       Llm_provider.Reserved_exn.reraise_if_reserved exn;
       Log.Keeper.warn
         "provider input projection observer failed: %s"
         (Printexc.to_string exn))
;;

let inspect_serialized_request ~stream ~config ~messages ~tools () =
  Llm_provider.Complete.inspect_serialized_request
    ~stream
    ~config
    ~messages
    ~tools
    ()
  |> Result.map (fun wire ->
    { body_bytes = wire.body_bytes; body_sha256 = wire.body_sha256 })
  |> Result.map_error Provider_http_error.to_message
;;

let create
      ~(canonical_prefix : Agent_sdk.Types.message list)
      ~(provider_config : Llm_provider.Provider_config.t)
      ~(tools : Agent_sdk.Tool.t list)
      ~stream
      ~base_projection
      ?observe
      ?observe_inspection_failure
      ?(inspect_serialized_request = inspect_serialized_request)
      ()
  : Agent_sdk.Agent.model_input_projection
  =
  let tools = List.map Agent_sdk.Tool.schema_to_json tools in
  fun messages ->
    let* current_run =
      Keeper_replay_prefix.split ~prefix:canonical_prefix messages
      |> Result.map_error (fun mismatch ->
        Printf.sprintf
          "keeper provider input projection cannot locate canonical history: %s"
          (prefix_mismatch_to_string mismatch))
    in
    let* projected_messages = project_base base_projection messages in
    let* () =
      match first_base_projection_mismatch 0 messages projected_messages with
      | None -> Ok ()
      | Some index ->
        Error
          (Printf.sprintf
             "keeper provider input base projection changed message order, protocol \
              identity, or non-artifact content at index %d"
             index)
    in
    match provider_config.max_request_body_bytes with
    | None -> Ok projected_messages
    | Some limit_bytes ->
      (match
         inspect_serialized_request
          ~stream
          ~config:provider_config
          ~messages:projected_messages
          ~tools
          ()
       with
       | Error detail ->
         let failure =
           { limit_bytes
           ; stream
           ; canonical_history_messages = List.length canonical_prefix
           ; current_run_messages = List.length current_run
           ; detail
           }
         in
         Log.Keeper.warn
           "serialized-request diagnostic inspection failed; continuing to OAS \
            canonical admission: %s"
           detail;
         notify observe_inspection_failure failure;
         Ok projected_messages
       | Ok wire ->
         notify
           observe
           { limit_bytes
           ; stream
           ; canonical_history_messages = List.length canonical_prefix
           ; current_run_messages = List.length current_run
           ; body_bytes = wire.body_bytes
           ; body_sha256 = wire.body_sha256
           ; fits = wire.body_bytes <= limit_bytes
           };
         (* Never hide canonical messages from the model. If this exact body is
            over the declared bound, OAS's final admission returns the typed
            Request_body_too_large refusal before HTTP. MASC then owns checkpoint
            compaction and exact source requeue. *)
         Ok projected_messages)
;;

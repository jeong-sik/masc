(** Shared turn logic for sync and streaming paths.

    Contains helper functions shared by the sync and streaming Agent drivers.

    These functions take explicit parameters (not Agent.t) to avoid
    circular module dependency: Agent -> Agent_turn is fine,
    Agent_turn -> Agent is not. *)

open Types

let _log = Log.create ~module_name:"agent_turn" ()

module Deferred_name_set = Set.Make (String)

(* [turn_count] is advanced by the collect stage at the end of a provider
   turn, so before a fresh turn starts it is exactly the zero-based ordinal of
   the turn about to run. Read here only, by the turn frontier resolution. *)
let provider_turn_ordinal (state : agent_state) : int = state.turn_count

(* ── Turn preparation ─────────────────────────────────────────── *)

type turn_request =
  { effective_messages : Llm_provider.Types.message list
  ; tools : Tool_set.t
  ; tools_json : Yojson.Safe.t list option
  ; visible_tool_names : string list
  ; context_message : (message option, Error.t) result
  }

type narrower_turn_request = Error.t -> (turn_request option, Error.t) result

type turn_preparation =
  { tools_json : Yojson.Safe.t list option
  ; request : turn_request
  ; narrower : narrower_turn_request list
  ; visible_tool_names : string list
  }

let prepare_tools ~(tools : Tool_set.t) ?(deferred_tools = []) ?(defer_loading = false) () =
  let selected = Tool_set.to_list tools in
  let wire_selected =
    if defer_loading
    then Tool_set.to_list (Tool_set.of_list (selected @ deferred_tools))
    else selected
  in
  let deferred_names =
    List.fold_left
      (fun names (tool : Tool.t) -> Deferred_name_set.add tool.schema.name names)
      Deferred_name_set.empty
      deferred_tools
  in
  Schema_observation.surface ~site:Sdk_prepare_json (fun () ->
    List.map (fun (tool : Tool.t) -> tool.schema) wire_selected);
  let tool_schemas =
    Schema_observation.with_site Sdk_prepare_json (fun () ->
      List.map
        (fun (tool : Tool.t) ->
           let json = Tool.schema_to_json tool in
           if defer_loading && Deferred_name_set.mem tool.schema.name deferred_names
           then
             (match json with
              | `Assoc fields -> `Assoc (("defer_loading", `Bool true) :: fields)
              | other -> other)
           else json)
        wire_selected)
  in
  let tools_json = if tool_schemas = [] then None else Some tool_schemas in
  let visible_tool_names = List.map (fun (t : Tool.t) -> t.schema.name) selected in
  tools_json, visible_tool_names
;;

let referenced_tool_names messages =
  let rec collect_block names = function
    | ToolReference { tool_name } -> Deferred_name_set.add tool_name names
    | ToolResult { content_blocks = Some blocks; _ } ->
      List.fold_left collect_block names blocks
    | Text _
    | Thinking _
    | ReasoningDetails _
    | RedactedThinking _
    | ToolUse _
    | ToolResult { content_blocks = None; _ }
    | Image _
    | Document _
    | Audio _ -> names
  in
  List.fold_left
    (fun names (message : Llm_provider.Types.message) ->
       List.fold_left collect_block names message.content)
    Deferred_name_set.empty
    messages
;;

let request_tools ~tools ~eager_tools ~deferred_tools ~defer_loading messages =
  match eager_tools with
  | Some eager when defer_loading ->
    let references = referenced_tool_names messages in
    Tool_set.of_list
      (Tool_set.to_list eager
       @ List.filter
           (fun (tool : Tool.t) -> Deferred_name_set.mem tool.schema.name references)
           deferred_tools)
  | Some _ | None -> tools
;;

(* Cadence premise: at most one fresh carrier per prepare call. The hook may
   attach on every agent-core turn (tool rounds are turns here), so each
   signed Anthropic turn that carries context retains one [Historical]
   carrier in history; the context window trims them as ordinary history.
   A caller that attaches per round must accept per-round history growth. *)
let context_message turn_params =
  match turn_params.Hooks.extra_system_context with
  | None -> None
  | Some ctx ->
    (* The request puts fresh context at the tail. Anthropic collection retains
       this exact carrier before its response so the next tool round keeps
       the signed thinking prefix; other providers retain their existing
       request-only context behavior. *)
    let system_msg =
      { origin = System_context; role = User
      ; content = [ Text ("[system context] " ^ ctx) ]
      ; name = None
      ; tool_call_id = None
      ; metadata = []
      }
    in
    Some system_msg
;;

let outside_context_message turn_params =
  match turn_params.Hooks.extra_outside_context with
  | None -> None
  | Some ctx when String.trim ctx = "" -> None
  | Some ctx ->
    Some
      { origin = Outside_context
      ; role = User
      ; content = [ Text ctx ]
      ; name = None
      ; tool_call_id = None
      ; metadata = []
      }
;;

let append_context_message ~messages ~context_message ?outside_context_message () =
  let messages =
    match context_message with
    | None -> messages
    | Some message -> Util.snoc messages message
  in
  match outside_context_message with
  | None -> messages
  | Some message -> Util.snoc messages message
;;

let prepare_messages ~messages ~turn_params () =
  append_context_message
    ~messages
    ~context_message:(context_message turn_params)
    ?outside_context_message:(outside_context_message turn_params)
    ()
;;

(* The caller's projection and its narrower requests run caller code; an
   exception it raises is that call's error. *)
let caller_result f =
  try f () with
  | exn ->
    Llm_provider.Reserved_exn.reraise_if_reserved exn;
    Error (Error.Internal (Printexc.to_string exn))
;;

let prepare_turn
      ~media_store
      ~tools
      ~messages
      ~turn_params
      ?eager_tools
      ?(deferred_tools = [])
      ?(defer_loading = false)
      ?model_input_projection
      ()
  =
  let context_message = context_message turn_params in
  let outside_context_message = outside_context_message turn_params in
  let prepared =
    append_context_message ~messages ~context_message ?outside_context_message ()
  in
  let request_of effective_messages =
    let tools =
      request_tools ~tools ~eager_tools ~deferred_tools ~defer_loading effective_messages
    in
    let tools_json, visible_tool_names =
      prepare_tools ~tools ~deferred_tools ~defer_loading ()
    in
    let context_message =
      match context_message with
      | None -> Ok None
      | Some _ ->
        (match List.filter (fun (message : Llm_provider.Types.message) ->
           message.origin = System_context)
           effective_messages with
         | [] -> Ok None
         | [message] ->
           (* The carrier as transmitted re-enters history: Anthropic
              collection retains it before its response. *)
           History.of_wire_message media_store message
           |> Result.map Option.some
           |> Result.map_error (fun error -> Error.Media error)
         | _ -> Error (Error.Internal "model input projection returned multiple current context carriers"))
    in
    { effective_messages; tools; tools_json; visible_tool_names; context_message }
  in
  let candidates =
    match model_input_projection with
    | None ->
      History.to_wire_messages media_store prepared
      |> Result.map Agent_types.one_request
      |> Result.map_error (fun error -> Error.Media error)
    | Some project -> caller_result (fun () -> project prepared)
  in
  Result.map (fun (candidates : Agent_types.model_input_candidates) ->
    let request = request_of candidates.Agent_types.request in
    let narrower =
      List.map (fun (narrow : Agent_types.narrower_model_input) refusal ->
          caller_result (fun () -> narrow refusal) |> Result.map (Option.map request_of))
        candidates.Agent_types.narrower
    in
    { tools_json = request.tools_json
    ; request
    ; narrower
    ; visible_tool_names = request.visible_tool_names
    })
    candidates
;;

let provider_config_with_agent_config
      ~(config : Types.agent_config)
      (provider_config : Llm_provider.Provider_config.t)
  =
  let model_id = Types.model_to_string config.model in
  let max_context, model_capabilities_override, model_anthropic_thinking_control_override =
    if model_id = provider_config.model_id
    then
      ( provider_config.max_context
      , provider_config.model_capabilities_override
      , provider_config.model_anthropic_thinking_control_override )
    else (
      let target_model =
        { provider_config with
          model_id
        ; max_context = None
        ; model_capabilities_override = None
        ; model_anthropic_thinking_control_override = None
        }
      in
      let max_context =
        Option.bind
          (Llm_provider.Provider_config.capabilities_for_config_model target_model)
          (fun capabilities -> capabilities.max_context_tokens)
      in
      max_context, None, None)
  in
  { provider_config with
    model_id
  ; max_context
  ; model_capabilities_override
  ; model_anthropic_thinking_control_override
  ; max_tokens = config.max_tokens
  ; temperature = config.temperature
  ; top_p = config.top_p
  ; top_k = config.top_k
  ; min_p = config.min_p
  ; system_prompt = config.system_prompt
  ; enable_thinking = config.enable_thinking
  ; preserve_thinking = config.preserve_thinking
  ; reasoning_effort = config.reasoning_effort
  ; tool_choice = config.tool_choice
  ; disable_parallel_tool_use = config.disable_parallel_tool_use
  ; response_format = config.response_format
  ; cache_system_prompt = config.cache_system_prompt
  ; cache_extended_ttl = config.cache_extended_ttl
  ; cache_session_key =
      (match config.cache_session_key with
       | Some _ as key -> key
       | None -> provider_config.cache_session_key)
  }
;;

(* ── Usage accumulation ───────────────────────────────────────── *)

let with_pricing_gap usage model_id =
  match usage.pricing_gap with
  | Some _ -> usage
  | None ->
    { usage with
      pricing_gap =
        Some
          (match model_id with
           | Some model_id -> Pricing_unavailable model_id
           | None -> Model_identity_unavailable)
    }
;;

let accumulate_usage ~current_usage ~response_model ~response_usage =
  match response_usage with
  | Some u ->
    let base = add_usage current_usage u in
    (match u.cost_usd with
     | Some cost -> { base with estimated_cost_usd = base.estimated_cost_usd +. cost }
     | None -> with_pricing_gap base response_model)
  | None -> add_missing_usage current_usage
;;

(* ── Turn params resolution ───────────────────────────────────── *)

type turn_params_resolution_error =
  | Illegal_decision of Hooks.hook_decision
  | Hook_failed of
      { stage : Hooks.hook_stage
      ; detail : string
      }

let history_tool_result_of_block : content_block -> Hooks.history_tool_result option =
  function
  | ToolResult { tool_use_id; content; outcome; content_blocks; json = _ } ->
    Some { tool_use_id; content; outcome; content_blocks }
  | Text _ | Thinking _ | ReasoningDetails _ | RedactedThinking _ | ToolUse _ | ToolReference _ | Image _
  | Document _ | Audio _ -> None
;;

let last_tool_results_from messages =
  let extract_results msg =
    match msg.role, msg.content with
    | Tool, (_ :: _ as content)
      when List.for_all
             (function
               | ToolResult _ -> true
               | Text _ | Thinking _ | ReasoningDetails _ | RedactedThinking _ | ToolUse _ | ToolReference _ | Image _
               | Document _ | Audio _ -> false)
             content ->
      List.filter_map history_tool_result_of_block content
    | User, _ | System, _ | Assistant, _ | Tool, _ -> []
  in
  List.fold_left
    (fun acc msg ->
       match extract_results msg with
       | [] -> acc
       | results -> results)
    []
    messages
;;

let resolve_turn_params ~hooks ~messages ~turn ~invoke_hook =
  match hooks.Hooks.before_turn_params with
  | None -> Ok Hooks.default_turn_params
  | Some _ ->
    let decision =
      invoke_hook
        ~hook_name:"before_turn_params"
        hooks.Hooks.before_turn_params
        (Hooks.BeforeTurnParams
           { turn
           ; messages
           ; last_tool_results = last_tool_results_from messages
           ; current_params = Hooks.default_turn_params
           ; reasoning = Hooks.extract_reasoning messages
           })
    in
    (match decision with
     | Hooks.AdjustParams params -> Ok params
     | Hooks.Continue -> Ok Hooks.default_turn_params
     | Hooks.HookFailed { stage; detail } -> Error (Hook_failed { stage; detail })
     | Hooks.ElicitInput _ | Hooks.ElicitToolApproval _ | Hooks.Nudge _ | Hooks.Block _ ->
       Error (Illegal_decision decision))
;;

(* ── Context injection after tool execution ───────────────────── *)

type context_injection_error =
  { tool_name : string option
  ; detail : string
  }

type context_injection_outcome =
  | No_injection
  | Injected of Types.message list

let apply_context_injection ~context ~messages ~injector ~tool_uses ~results =
  let rec collect
            updates_rev
            messages_rev
            (tool_uses : Llm_provider.Types.content_block list)
            results
    =
    match tool_uses, results with
    | [], [] -> Ok (List.rev updates_rev, List.rev messages_rev)
    | ( ToolUse { name; input; _ } :: tool_uses
      , (result : Agent_tools.tool_execution_result) :: results ) ->
      let output = Types.tool_result_of_outcome ?content_blocks:result.content_blocks ~content:result.content result.outcome in
      let injection =
        try Ok (injector ~tool_name:name ~input ~output) with
        | exn ->
          Llm_provider.Reserved_exn.reraise_if_reserved exn;
          Error { tool_name = Some name; detail = Printexc.to_string exn }
      in
      (match injection with
       | Error _ as error -> error
       | Ok None -> collect updates_rev messages_rev tool_uses results
       | Ok (Some injection) ->
         collect
           (List.rev_append injection.Hooks.context_updates updates_rev)
           (List.rev_append injection.extra_messages messages_rev)
           tool_uses
           results)
    | ( ( Text _
        | Thinking _
        | ReasoningDetails _
        | RedactedThinking _
        | ToolResult _
        | ToolReference _
        | Image _
        | Document _
        | Audio _ )
        :: _
      , _ ) ->
      Error
        { tool_name = None; detail = "context injection received a non-ToolUse block" }
    | [], _ :: _ | _ :: _, [] ->
      Error
        { tool_name = None
        ; detail = "context injection tool/result cardinality mismatch"
        }
  in
  match collect [] [] tool_uses results with
  | Error _ as error -> error
  | Ok ([], []) -> Ok No_injection
  | Ok (updates, extra_messages) ->
    List.iter (fun (key, value) -> Context.set context key value) updates;
    let messages =
      match extra_messages with
      | [] -> messages
      | _ :: _ -> Util.snoc_list messages extra_messages
    in
    Ok (Injected messages)
;;

(* A tool that returns a payload which is not padded standard base64 gets a
   failed result in place of its media: sending those bytes on would make
   every later request carrying this history fail at the provider. Any other
   media error fails the turn. *)
let undecodable_media_content ~media_type ~detail =
  Printf.sprintf
    "Tool result media %s was dropped: its payload is not padded standard base64 (%s)."
    media_type
    detail
;;

let make_tool_result ~media_store (result : Agent_tools.tool_execution_result) =
  let tool_use_id = Tool_contract.Invocation.tool_use_id result.invocation in
  let tool_result ~content ~outcome content_blocks =
    ToolResult { tool_use_id; content; outcome; json = None; content_blocks }
  in
  match result.content_blocks with
  | None -> Ok (tool_result ~content:result.content ~outcome:result.outcome None)
  | Some blocks ->
    (match History.of_wire_blocks media_store blocks with
     | Ok blocks ->
       Ok (tool_result ~content:result.content ~outcome:result.outcome (Some blocks))
     | Error (History.Invalid_base64 { media_type; detail }) ->
       let media_failure = undecodable_media_content ~media_type ~detail in
       let content =
         if String.equal result.content ""
         then media_failure
         else result.content ^ "\n\n" ^ media_failure
       in
       Ok
         (tool_result
            ~content
            ~outcome:
              (Tool_failed
                 { failure_kind = Non_retryable_tool_error
                 ; error_class = Some Deterministic
                 })
            None)
     | Error
         ((History.Store_failed _ | History.Missing_bytes _ | History.Digest_mismatch _) as
          error) -> Error (Error.Media error))
;;

(** Process tool results into ToolResult content blocks.
    All entries are valid ToolUse results — non-ToolUse blocks are filtered
    upstream in {!Agent_tools.execute_tools}. Tool result text is retained;
    undecodable media appends a diagnostic. Provider-specific projection is
    responsible for any transport adaptation. *)
let make_tool_results ~media_store results =
  let rec convert acc = function
    | [] -> Ok (List.rev acc)
    | result :: rest ->
      (match make_tool_result ~media_store result with
       | Ok block -> convert (block :: acc) rest
       | Error _ as error -> error)
  in
  convert [] results
;;

(* === make_tool_results inline tests === *)

(* Inline-test-only; the release profile strips the tests that call it. *)
let[@warning "-32"] mock_result ?(is_error = false) ~id content : Agent_tools.tool_execution_result =
  let schedule : Tool_contract.schedule =
    { planned_index = 0
    ; batch_index = 0
    ; batch_size = 1
    ; execution_mode = Tool_contract.Serial
    }
  in
  { invocation =
      Tool_contract.Invocation.create
        ~tool_use_id:id
        ~turn:0
        ~schedule
        ~completion:Tool_contract.Continue_after_success
  ; tool_name = "test"
  ; input = `Null
  ; content
  ; content_blocks = None
  ; outcome =
      (if is_error
       then
         Tool_failed
           { failure_kind = Agent_tools.Non_retryable_tool_error
           ; error_class = Some Types.Unknown
           }
       else Tool_succeeded)
  }
;;

(* Inline-test-only; the release profile strips the tests that call it. *)
let[@warning "-32"] single_tool_result = function
  | Error _ -> None
  | Ok [ ToolResult { tool_use_id; content; outcome; _ } ] ->
    Some (tool_use_id, content, Types.tool_result_outcome_is_error outcome)
  | Ok
      ( []
      | [ Text _ ]
      | [ Thinking _ ]
      | [ ReasoningDetails _ ]
      | [ RedactedThinking _ ]
      | [ ToolUse _ ]
      | [ ToolReference _ ]
      | [ Image _ ]
      | [ Document _ ]
      | [ Audio _ ]
      | _ :: _ :: _ ) -> None
;;

let%test "make_tool_results: small result passes through unchanged" =
  let results = [ mock_result ~id:"t1" "hello world" ] in
  match single_tool_result (make_tool_results ~media_store:(History.Memory_store.create ()) results) with
  | Some (_, content, _) -> content = "hello world"
  | None -> false
;;

let%test "make_tool_results: large result is preserved exactly" =
  let big = String.make 100_000 'x' in
  let results = [ mock_result ~id:"t1" big ] in
  match single_tool_result (make_tool_results ~media_store:(History.Memory_store.create ()) results) with
  | Some (_, content, _) -> String.equal content big
  | None -> false
;;

let%test "make_tool_results: tool_use_id and is_error preserved" =
  let results = [ mock_result ~id:"err1" ~is_error:true (String.make 60_000 'e') ] in
  match single_tool_result (make_tool_results ~media_store:(History.Memory_store.create ()) results) with
  | Some (tool_use_id, _, is_error) -> tool_use_id = "err1" && is_error = true
  | None -> false
;;

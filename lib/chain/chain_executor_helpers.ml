(** Chain Executor Helpers - Types, context, trace, input resolution, and
    substitution utilities used by chain_executor_eio.ml.

    This module contains all standalone helper functions that are not part of
    the mutually recursive execute_* block. *)

(* Fiber-safe random state for MCTS and random delay *)
let executor_rng = Random.State.make_self_init ()

(** {1 Type Aliases from Chain_types} *)

(** Re-export Chain_types for local use *)
type node = Chain_types.node
type node_type = Chain_types.node_type
type chain = Chain_types.chain
type chain_config = Chain_types.chain_config
type chain_result = Chain_types.chain_result
type execution_plan = Chain_types.execution_plan
type trace_entry = Chain_types.trace_entry
type token_usage = Chain_types.token_usage
type merge_strategy = Chain_types.merge_strategy
type adapter_transform = Chain_types.adapter_transform

(** {1 Trace Types} - From Chain_trace_types module *)
type trace_event = Chain_trace_types.trace_event =
  | NodeStart of { node_type : string; attempt : int }
  | NodeComplete of { duration_ms : int; success : bool; node_type : string; attempt : int }
  | NodeError of { message : string; error_class : string option; node_type : string; attempt : int }
  | ChainStart of { chain_id : string; mermaid_dsl : string option }
  | ChainComplete of { chain_id : string; success : bool }

type internal_trace = Chain_trace_types.internal_trace = {
  timestamp : float;
  node_id : string;
  event : trace_event;
}

type exec_phase = Chain_trace_types.exec_phase =
  | Planned | Running | Completed | Failed | Skipped

(** {1 Execution Context} *)

(** Iteration and conversation types from extracted modules *)
type iteration_ctx = Chain_iteration.iteration_ctx
type conv_message = Chain_conversation.conv_message
type conversation_ctx = Chain_conversation.conversation_ctx

(** Checkpoint configuration for resume support *)
type checkpoint_config = {
  checkpoint_store: Checkpoint_store.checkpoint_store option;  (** Store for saving/loading checkpoints *)
  checkpoint_enabled: bool;                                     (** Whether to save checkpoints after each node *)
  resume_from: string option;                                   (** run_id to resume from, or None for fresh start *)
  run_id: string;                                               (** Current run's unique identifier *)
  fs: Eio.Fs.dir_ty Eio.Path.t option;                         (** Eio filesystem for checkpoint I/O *)
}

(** Context passed through execution *)
type exec_context = {
  outputs: (string, string) Hashtbl.t;      (** Node outputs by ID *)
  traces: internal_trace list ref;           (** Accumulated trace entries *)
  start_time: float;                         (** Execution start time *)
  trace_enabled: bool;                       (** Whether to record traces *)
  timeout: int;                              (** Overall timeout in seconds *)
  mutable iteration_ctx: iteration_ctx option;  (** Iteration context for GoalDriven *)
  mutable conversation: conversation_ctx option; (** Conversation context for conversational mode *)
  cache: (string, string * float) Hashtbl.t;  (** Node cache: key -> (result, timestamp) *)
  mutable total_tokens: Chain_category.token_usage; (** Accumulated token usage *)
  langfuse_trace: unit option;                (** Reserved, unused (Langfuse removed) *)
  checkpoint: checkpoint_config;             (** Checkpoint/resume configuration *)
  node_status: (string, exec_phase) Hashtbl.t; (** Node status for observability *)
  node_attempts: (string, int) Hashtbl.t;       (** Node execution attempts *)
  chain_id: string;                            (** Current chain id *)
}

(** Default checkpoint configuration - no checkpointing *)
let default_checkpoint_config = {
  checkpoint_store = None;
  checkpoint_enabled = false;
  resume_from = None;
  run_id = Checkpoint_store.generate_run_id ();
  fs = None;
}

(** Create a new execution context *)
let make_context ~start_time ~trace_enabled ~timeout ~chain_id ?langfuse_trace ?checkpoint () = {
  outputs = Hashtbl.create 16;
  traces = ref [];
  start_time;
  trace_enabled;
  timeout;
  iteration_ctx = None;
  conversation = None;
  cache = Hashtbl.create 32;
  total_tokens = Chain_category.Token_monoid.empty;
  langfuse_trace;
  checkpoint = Option.value checkpoint ~default:default_checkpoint_config;
  node_status = Hashtbl.create 64;
  node_attempts = Hashtbl.create 64;
  chain_id;
}

let set_node_status ctx node_id status =
  Hashtbl.replace ctx.node_status node_id status

let next_attempt ctx node_id =
  let cur = match Hashtbl.find_opt ctx.node_attempts node_id with Some n -> n | None -> 0 in
  let next = cur + 1 in
  Hashtbl.replace ctx.node_attempts node_id next;
  next

(** {1 Safe Helpers from Chain_utils} *)
include Chain_utils

(** Create checkpoint configuration for execution *)
let make_checkpoint_config ?fs ?store ?(enabled = false) ?resume_from () =
  let store = match store with
    | Some s -> Some s
    | None when enabled -> Some (Checkpoint_store.create ())
    | None -> None
  in
  {
    checkpoint_store = store;
    checkpoint_enabled = enabled;
    resume_from;
    run_id = Checkpoint_store.generate_run_id ();
    fs;
  }

(** Save checkpoint for current execution state *)
let save_checkpoint ctx ~chain_id ~node_id =
  match ctx.checkpoint.checkpoint_store, ctx.checkpoint.fs with
  | Some store, Some fs when ctx.checkpoint.checkpoint_enabled ->
      let outputs = Hashtbl.fold (fun k v acc -> (k, v) :: acc) ctx.outputs [] in
      let traces = [] in  (* Don't include internal traces in checkpoint *)
      let cp = Checkpoint_store.make_checkpoint
        ~run_id:ctx.checkpoint.run_id
        ~chain_id
        ~node_id
        ~outputs
        ~traces
        ~total_tokens:ctx.total_tokens
        ()
      in
      (match Checkpoint_store.save_eio ~fs store cp with
       | Ok () -> ()
       | Error msg -> Log.Chain.error "Save failed: %s" msg)
  | Some store, None when ctx.checkpoint.checkpoint_enabled ->
      (* Fallback to non-Eio save *)
      let outputs = Hashtbl.fold (fun k v acc -> (k, v) :: acc) ctx.outputs [] in
      let traces = [] in
      let cp = Checkpoint_store.make_checkpoint
        ~run_id:ctx.checkpoint.run_id
        ~chain_id
        ~node_id
        ~outputs
        ~traces
        ~total_tokens:ctx.total_tokens
        ()
      in
      (match Checkpoint_store.save store cp with
       | Ok () -> ()
       | Error msg -> Log.Chain.error "Save failed: %s" msg)
  | _ -> ()

(** Load checkpoint and restore outputs to context *)
let restore_from_checkpoint ctx ~chain_id:_ =
  match ctx.checkpoint.checkpoint_store, ctx.checkpoint.resume_from with
  | Some store, Some run_id ->
      (match Checkpoint_store.load store ~run_id with
       | Ok cp ->
           (* Restore outputs to context *)
           List.iter (fun (k, v) -> Hashtbl.replace ctx.outputs k v) cp.outputs;
           (* Restore token usage if available *)
           (match cp.total_tokens with
            | Some tokens -> ctx.total_tokens <- tokens
            | None -> ());
           Ok cp.node_id  (* Return last completed node *)
       | Error msg -> Error msg)
  | _ -> Error "No checkpoint to resume from"

(** Check if a node was already completed in a resumed checkpoint *)
let node_completed_in_checkpoint ctx node_id =
  Hashtbl.mem ctx.outputs node_id

(** Store node output under node.id and optional output_key alias *)
let store_node_output ctx (node : node) (output : string) =
  Hashtbl.replace ctx.outputs node.id output;
  match node.output_key with
  | Some key ->
      let key = String.trim key in
      if key <> "" && key <> node.id then
        (match Hashtbl.find_opt ctx.outputs key with
         | Some existing ->
             if existing <> output then
               Log.Misc.warn "Warning: output_key '%s' for node '%s' ignored (already set)"
                 key
                 node.id
         | None ->
             Hashtbl.replace ctx.outputs key output)
  | None -> ()

(** {1 Trace Helpers} *)

let add_trace ctx node_id event =
  (* Record to local trace *)
  (if ctx.trace_enabled then
    let entry = {
      timestamp = Time_compat.now () -. ctx.start_time;
      node_id;
      event;
    } in
    ctx.traces := entry :: !(ctx.traces));
  (* Also emit to global telemetry for stats collection - ALWAYS, not just when tracing *)
  (match event with
   | ChainStart { chain_id; mermaid_dsl } ->
       Chain_telemetry.emit (Chain_telemetry.chain_start ~chain_id ~nodes:0 ?mermaid_dsl ())
   | ChainComplete { chain_id; success = _ } ->
       let duration_ms = int_of_float ((Time_compat.now () -. ctx.start_time) *. 1000.0) in
       Chain_telemetry.emit (Chain_telemetry.ChainComplete {
         Chain_telemetry.complete_chain_id = chain_id;
         complete_duration_ms = duration_ms;
         complete_tokens = ctx.total_tokens;
         nodes_executed = 0;
         nodes_skipped = 0;
       })
   | NodeStart { node_type; _ } ->
       Chain_telemetry.emit (Chain_telemetry.node_start ~node_id ~node_type ())
    | NodeComplete { duration_ms; success; _ } ->
       Chain_telemetry.emit (Chain_telemetry.node_complete
         ~node_id
         ~duration_ms
         ~tokens:Chain_category.Token_monoid.empty
         ~verdict:(if success then Chain_category.Pass "" else Chain_category.Fail "")
         ~confidence:1.0
         ())
   | NodeError { message; _ } ->
       Chain_telemetry.emit (Chain_telemetry.Error {
         Chain_telemetry.error_node_id = node_id;
         error_message = message;
         error_retries = 0;
         error_timestamp = Time_compat.now ();
       }))

let record_start ?(node_type = "unknown") ctx node_id =
  let attempt = next_attempt ctx node_id in
  set_node_status ctx node_id Running;
  if Run_log_eio.enabled () then
    Run_log_eio.record_event
      ~event:"node_start"
      ~run_id:ctx.checkpoint.run_id
      ~chain_id:ctx.chain_id
      ~node_id
      ~node_type
      ~attempt
      ()
  else
    ();
  add_trace ctx node_id (NodeStart { node_type; attempt })

let record_complete ?(node_type = "unknown") ctx node_id ~duration_ms ~success =
  let attempt = match Hashtbl.find_opt ctx.node_attempts node_id with Some n -> n | None -> 1 in
  set_node_status ctx node_id (if success then Completed else Failed);
  if Run_log_eio.enabled () then
    Run_log_eio.record_event
      ~event:"node_complete"
      ~run_id:ctx.checkpoint.run_id
      ~chain_id:ctx.chain_id
      ~node_id
      ~node_type
      ~attempt
      ~duration_ms
      ~success
      ()
  else
    ();
  add_trace ctx node_id (NodeComplete { duration_ms; success; node_type; attempt })

let record_error ?(node_type = "unknown") ctx node_id msg =
  let attempt = match Hashtbl.find_opt ctx.node_attempts node_id with Some n -> n | None -> 1 in
  if Run_log_eio.enabled () then
    Run_log_eio.record_event
      ~event:"node_error"
      ~run_id:ctx.checkpoint.run_id
      ~chain_id:ctx.chain_id
      ~node_id
      ~node_type
      ~attempt
      ~error_class:"node_error"
      ~error:msg
      ()
  else
    ();
  add_trace ctx node_id (NodeError { message = msg; error_class = None; node_type; attempt })

(** Trace conversion functions - from Chain_trace_types *)
let trace_to_entry = Chain_trace_types.trace_to_entry
let traces_to_entries = Chain_trace_types.traces_to_entries

(** {1 Input Resolution} *)


(** Resolve a single input reference to its value

    Supports:
    - {{node_id}} - get output from node
    - {{node_id.output}} - same, with explicit .output suffix
    - literal string - returns as-is
*)
let resolve_single_input ctx (ref_str : string) : string =
  (* starts_with and ends_with are now module-level helpers *)
  let try_extract_json_path raw path_parts =
    let parse_index part =
      if String.length part >= 3 && part.[0] = '[' && part.[String.length part - 1] = ']' then
        try Some (int_of_string (String.sub part 1 (String.length part - 2))) with Failure _ -> None
      else
        try Some (int_of_string part) with Failure _ -> None
    in
    try
      let json = Yojson.Safe.from_string raw in
      let rec walk j = function
        | [] ->
            (match j with
             | `String s -> Ok s
             | `Int i -> Ok (string_of_int i)
             | `Float f -> Ok (string_of_float f)
             | `Bool b -> Ok (string_of_bool b)
             | `Null -> Ok "null"
             | _ -> Ok (Yojson.Safe.to_string j))
        | key :: rest ->
            (match j with
             | `Assoc fields ->
                 (match List.assoc_opt key fields with
                  | Some v -> walk v rest
                  | None -> Error (Printf.sprintf "Key '%s' not found" key))
             | `List items ->
                 (match parse_index key with
                  | Some idx when idx >= 0 ->
                      (match List.nth_opt items idx with
                       | Some item -> walk item rest
                       | None -> Error "Invalid array index")
                  | _ -> Error "Invalid array index")
             | _ -> Error (Printf.sprintf "Cannot extract '%s' from non-object" key))
      in
      walk json path_parts
    with Yojson.Json_error _ -> Error "JSON parse error"
  in
  (* Support tools that return bullet lists instead of JSON.
     Example:
       - file_key: UID...
       - node_id: 123:456 *)
  let try_extract_bullet_value raw key =
    let prefix = "- " ^ key ^ ":" in
    raw
    |> String.split_on_char '\n'
    |> List.find_map (fun line ->
           let line = String.trim line in
           if starts_with ~prefix line then
             let start = String.length prefix in
             let len = String.length line - start in
             Some (String.trim (String.sub line start len))
           else None)
  in
  (* Check if it's a {{variable}} reference *)
  let trimmed = String.trim ref_str in
  let is_placeholder =
    starts_with ~prefix:"{{" trimmed && ends_with ~suffix:"}}" trimmed
  in
  if is_placeholder then
    (* Extract variable name from {{var}} *)
    let var = String.sub trimmed 2 (String.length trimmed - 4) in
    let parts = String.split_on_char '.' var in
    let node_id, path = match parts with
      | id :: rest -> (id, rest)
      | [] -> (var, [])
    in
    (match Hashtbl.find_opt ctx.outputs node_id with
     | Some value ->
         if path = [] then value
         else (match try_extract_json_path value path with
               | Ok v -> v
               | Error _ ->
                   (match path with
                    | [key] ->
                        (match try_extract_bullet_value value key with
                         | Some v -> v
                         | None -> value)
                    | _ -> value))
     | None -> ref_str)  (* Return original if not found *)
  else
    (* Direct node_id reference or literal, with optional dot-path *)
    let parts = String.split_on_char '.' trimmed in
    let node_id, path = match parts with
      | id :: rest -> (id, rest)
      | [] -> (trimmed, [])
    in
    match Hashtbl.find_opt ctx.outputs node_id with
    | Some value ->
        if path = [] then value
        else (match try_extract_json_path value path with
              | Ok v -> v
              | Error _ ->
                  (match path with
                   | [key] ->
                       (match try_extract_bullet_value value key with
                        | Some v -> v
                        | None -> value)
                   | _ -> value))
    | None -> ref_str  (* Return as literal *)

(** Resolve input mappings to actual values *)
let resolve_inputs ctx (mappings : (string * string) list) : (string * string) list =
  let use_key_as_source ~key ~ref_str =
    if ref_str = key then true
    else
      let klen = String.length key in
      let rlen = String.length ref_str in
      klen > rlen &&
      String.sub key 0 rlen = ref_str &&
      (key.[rlen] = '.' || key.[rlen] = '[')
  in
  List.filter_map (fun (key, ref_str) ->
    let source = if use_key_as_source ~key ~ref_str then key else ref_str in
    let value = resolve_single_input ctx source in
    if value = source then None else Some (key, value)
  ) mappings

(** Substitute {{var}} in prompt with resolved inputs *)
let substitute_prompt prompt (inputs : (string * string) list) : string =
  List.fold_left (fun acc (key, value) ->
    (* Replace {{key}} with value *)
    let pattern = "{{" ^ key ^ "}}" in
    let buf = Buffer.create (String.length acc) in
    let rec replace start =
      match String.index_from_opt acc start '{' with
      | None -> Buffer.add_substring buf acc start (String.length acc - start)
      | Some i ->
          if i + String.length pattern <= String.length acc &&
             String.sub acc i (String.length pattern) = pattern then begin
            Buffer.add_substring buf acc start (i - start);
            Buffer.add_string buf value;
            replace (i + String.length pattern)
          end else begin
            (* Bug fix: add skipped characters from start to i-1 before adding acc.[i] *)
            Buffer.add_substring buf acc start (i - start);
            Buffer.add_char buf acc.[i];
            replace (i + 1)
          end
    in
    replace 0;
    Buffer.contents buf
  ) prompt inputs

(** Substitute placeholders inside JSON values *)
let substitute_json ctx (json : Yojson.Safe.t) : Yojson.Safe.t =
  (* Tool args should not carry unresolved {{...}} placeholders, because
     external MCP servers may treat them as literal invalid values. *)
  let strip_unresolved_placeholders (s : string) : string =
    let re = Re.Pcre.re {|\{\{[^}]+\}\}|} |> Re.compile in
    if Re.execp re s then begin
      Log.Misc.info "unresolved placeholder stripped in tool args: %s"
        (truncate_with_ellipsis s);
      Re.replace_string re ~by:"" s
    end else
      s
  in
  let rec map = function
    | `String s ->
        let mappings = Chain_parser.extract_input_mappings s in
        if mappings = [] then `String s
        else
          let inputs = resolve_inputs ctx mappings in
          let substituted = substitute_prompt s inputs in
          `String (strip_unresolved_placeholders substituted)
    | `Assoc fields ->
        `Assoc (List.map (fun (k, v) -> (k, map v)) fields)
    | `List items ->
        `List (List.map map items)
    | other -> other
  in
  map json

(** {1 Iteration Variable Substitution from Chain_iteration} *)
let substitute_iteration_vars = Chain_iteration.substitute_vars

(** {1 Conversational Mode from Chain_conversation} *)

let estimate_tokens = Chain_conversation.estimate_tokens
let make_conversation_ctx = Chain_conversation.make
let add_message = Chain_conversation.add_message
let rotate_model = Chain_conversation.rotate_model
let needs_summarization = Chain_conversation.needs_summarization
let build_context_prompt = Chain_conversation.build_context_prompt
let maybe_summarize_and_rotate = Chain_conversation.maybe_summarize_and_rotate

(** {1 Node Execution Types and Helpers} *)

(** Type of execution function callback *)
type exec_fn = Chain_conversation.exec_fn

(** Judge/evaluator call routed through OAS cascade pipeline.
    Uses cascade_name "chain_judge" so inference parameters
    (temperature, max_tokens, model selection) come from
    config/cascade.json rather than being hardcoded. #2408 *)
let judge_call ~prompt () : (string, string) result =
  match
    Oas_worker.run_named ~cascade_name:"chain_judge"
      ~goal:prompt ~max_turns:1
      ~priority:Llm_provider.Request_priority.Interactive
      ()
  with
  | Ok run_result ->
    let text =
      Oas_response.text_of_response run_result.Oas_worker.response
      |> String.trim
    in
    if text <> "" then Ok text else Error "empty judge response"
  | Error msg -> Error msg

(** Prompt/model helpers - from Chain_utils *)
let is_complex_prompt = Chain_utils.is_complex_prompt
let is_glm_model = Chain_utils.is_glm_model

(** Type of tool execution callback *)
type tool_exec = name:string -> args:Yojson.Safe.t -> (string, string) result

(** Type of recursive execute_node callback for open recursion *)
type execute_node_fn = exec_context -> sw:Eio.Switch.t -> clock:float Eio.Time.clock_ty Eio.Resource.t -> exec_fn:exec_fn -> tool_exec:tool_exec -> Chain_types.node -> (string, string) result

let calculate_backoff_delay (strategy : Chain_types.backoff_strategy) (attempt : int) : float =
  match strategy with
  | Chain_types.Constant secs -> secs
  | Chain_types.Exponential base -> base *. (2.0 ** float_of_int attempt)
  | Chain_types.Linear base -> base *. float_of_int (attempt + 1)
  | Chain_types.Jitter (min_sec, max_sec) ->
      min_sec +. Random.State.float executor_rng (max_sec -. min_sec)

let should_retry (retry_on : string list) (error_msg : string) : bool =
  match retry_on with
  | [] -> true
  | patterns ->
      List.exists (fun pattern ->
        try
          let regex = Re.Pcre.re ~flags:[`CASELESS] pattern |> Re.compile in
          Re.execp regex error_msg
        with Failure _ | Re.Pcre.Parse_error | Re.Pcre.Not_supported ->
          String.sub error_msg 0 (min (String.length pattern) (String.length error_msg)) = pattern
      ) patterns

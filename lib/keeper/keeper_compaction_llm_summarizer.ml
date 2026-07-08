(** LLM-backed keeper context compaction (RFC-0313-adjacent W2 +
    RFC-0327 B-0 provider-agnostic structured output).

    See keeper_compaction_llm_summarizer.mli. Structure mirrors
    Keeper_memory_llm_summary: opt-in gate + fiber-local Eio capture +
    provider filter + timeout + fail-closed [None].

    RFC-0327 B-0: the plan is acquired via a hybrid dual path so the
    summarizer is not blocked on provider-native json_schema support.
    - provider accepts the native [response_format] json_schema  → native path (unchanged)
    - otherwise                                       → StructuredOutput tool-call fallback
    Either path parses the same [compaction_plan_output_schema]; a
    validation failure (out-of-range/duplicate/missing index, wrong types)
    is fed back to the model and retried up to
    [max_structured_output_retries]. The deterministic chain remains the
    guaranteed floor: [make] None, no provider, no Eio context, or
    [max_retries] exhausted all fall back to it. *)

module Schema = Keeper_structured_output_schema
module Int_set = Set.Make (Int)

(* Bound the summary output. Larger than the memory-bank 512 because a
   compaction summary stands in for many messages, but still capped so the
   emergency path (a near-full context) cannot request an unbounded reply. *)
let summary_max_tokens = 1024

(* Bound the serialized working set handed to the model. A compaction fires
   near the context limit, so the notes text must itself be bounded well below
   the window; the model classifies by index, so truncation loses tail detail
   but never the index mapping (the tail simply lands in [kept]). *)
let max_notes_bytes = 24_000

(* Tool name used both as the [tool_choice] target and the [Structured] schema
   name by which the tool_use input is extracted from the response. Shared so
   the tool we advertise and the block we look for cannot drift apart. *)
let compaction_plan_tool_name = "keeper_compaction_plan"

(* The tool definition handed to [Complete.complete ~tools]. We reuse the
   existing raw json_schema ([compaction_plan_output_schema]) verbatim as the
   tool's [input_schema] — the same fields [plan_of_json] parses — rather than
   re-deriving a [tool_param list], so the advertised schema and the parser
   share one SSOT. The shape ({name; description; input_schema}) matches
   [Agent_sdk.Structured.schema_to_tool_json] and is what the OpenAI/Anthropic
   backends consume. *)
let compaction_plan_tool_json : Yojson.Safe.t =
  `Assoc
    [ "name", `String compaction_plan_tool_name
    ; "description",
        `String
          "Compact the keeper working context. Return an object with fields \
           summary, kept_indices, summarized_indices, dropped_indices that \
           together partition every 0-based message index exactly once."
    ; "input_schema", Schema.compaction_plan_output_schema
    ]

(* Extraction schema for [extract_tool_input]: the [parse] step is the identity
   ([plan_of_json] does the real validation), so this only needs the [name] the
   tool_use block must carry. *)
let compaction_plan_extract_schema : Yojson.Safe.t Agent_sdk.Structured.schema =
  { Agent_sdk.Structured.name = compaction_plan_tool_name
  ; description = "keeper compaction plan (tool-call extraction)"
  ; params = []
  ; parse = (fun json -> Ok json)
  }

(* Retry budget when the model returns an invalid plan. Mirrors claude-code's
   [MAX_STRUCTURED_OUTPUT_RETRIES] (default 5). Overridable via env for A/B and
   incident throttling. *)
let max_structured_output_retries () =
  match Sys.getenv_opt "MASC_STRUCTURED_OUTPUT_MAX_RETRIES" with
  | None -> 5
  | Some s ->
    (match int_of_string_opt s with Some n when n >= 0 -> n | _ -> 5)

type compaction_plan =
  { summary : string
  ; kept : int list
  ; summarized : int list
  ; dropped : int list
  }

type summarizer = messages:Agent_sdk.Types.message list -> compaction_plan option

type complete_fn =
  sw:Eio.Switch.t ->
  net:Eio_context.eio_net ->
  ?clock:float Eio.Time.clock_ty Eio.Resource.t ->
  ?tools:Yojson.Safe.t list ->
  config:Llm_provider.Provider_config.t ->
  messages:Agent_sdk.Types.message list ->
  unit ->
  (Agent_sdk.Types.api_response, Llm_provider.Http_client.http_error) result

let default_complete ~sw ~net ?clock ?tools ~config ~messages () =
  Llm_provider.Complete.complete ~sw ~net ?clock ?tools ~config ~messages ()

(* RFC-0327 B-0: native if the provider accepts [response_format] json_schema,
   otherwise force the plan through a StructuredOutput tool call. *)
type plan_path = Native_plan | Tool_fallback_plan

let plan_path_for (provider_cfg : Llm_provider.Provider_config.t) =
  if
    Schema.provider_config_accepts_schema Schema.compaction_plan_output_schema
      provider_cfg
  then Native_plan
  else Tool_fallback_plan

let is_direct_completion_provider (provider_cfg : Llm_provider.Provider_config.t) : bool =
  match provider_cfg.kind with
  | Anthropic | Kimi | OpenAI_compat | Ollama | Gemini | Glm | DashScope -> true

let provider_for_plan (provider_cfg : Llm_provider.Provider_config.t)
    (path : plan_path) =
  let max_tokens =
    match provider_cfg.max_tokens with
    | Some n when n > 0 -> Some (min n summary_max_tokens)
    | _ -> Some summary_max_tokens
  in
  let base =
    { provider_cfg with
      max_tokens
    ; temperature = Some 0.0
    ; disable_parallel_tool_use = true
    }
  in
  match path with
  | Native_plan ->
    (* Full module path (not the [Schema] alias): the structured-output
       coverage test resolves callees literally via Ast_grep.count_calls, so
       this call must read [Keeper_structured_output_schema.apply_to_provider_config]
       in source — same pattern as the other registry entries. *)
    base
    |> Keeper_structured_output_schema.apply_to_provider_config
         Schema.compaction_plan_output_schema
  | Tool_fallback_plan ->
    (* Force the model to emit the plan as a tool_use on our compaction_plan
       tool. [disable_parallel_tool_use] is already set on [base]. *)
    { base with
      tool_choice = Some (Agent_sdk.Types.Tool compaction_plan_tool_name)
    }

let message role text : Agent_sdk.Types.message = Agent_sdk.Types.text_message role text

(* One indexed line per message: "[i] role: <text>". The model must classify
   every [i] into exactly one of kept/summarized/dropped. *)
let indexed_messages_text (messages : Agent_sdk.Types.message list) =
  messages
  |> List.mapi (fun idx (m : Agent_sdk.Types.message) ->
    let role =
      match m.role with
      | Agent_sdk.Types.System -> "system"
      | Agent_sdk.Types.User -> "user"
      | Agent_sdk.Types.Assistant -> "assistant"
      | Agent_sdk.Types.Tool -> "tool"
    in
    let text = Agent_sdk.Types.text_of_message m |> String.trim in
    Printf.sprintf "[%d] %s: %s" idx role text)
  |> String.concat "\n"
  |> String_util.utf8_safe ~max_bytes:max_notes_bytes ~suffix:"..."
  |> String_util.to_string

let messages_for_plan ~(messages : Agent_sdk.Types.message list) =
  let count = List.length messages in
  let system =
    "You compact a keeper's working context. Classify EVERY message, by its \
     0-based index, into exactly one of: kept (verbatim, still load-bearing), \
     summarized (folded into the summary), or dropped (low value, discard). \
     Every index in range must appear in exactly one list; do not invent \
     indices. Prefer keeping recent messages and any with concrete code paths, \
     commands, decisions, or unresolved blockers. Write one durable [summary] \
     prose block that stands in for the summarized messages. Do not invent \
     facts. Do not include [STATE] blocks or markdown fences."
  in
  let user =
    Printf.sprintf
      "message_count: %d\nmessages:\n%s\n\nReturn a JSON object with fields \
       summary, kept_indices, summarized_indices, dropped_indices covering \
       every index in [0, %d) exactly once."
      count
      (indexed_messages_text messages)
      count
  in
  [ message Agent_sdk.Types.System system; message Agent_sdk.Types.User user ]

(* -- structured plan parsing + validation (Parse, don't validate) -- *)

let int_list_field key = function
  | `Assoc fields ->
    (match List.assoc_opt key fields with
     | Some (`List items) ->
       List.fold_right
         (fun item acc ->
           match acc, item with
           | Ok xs, `Int n -> Ok (n :: xs)
           | Ok _, _ -> Error (Printf.sprintf "%s must contain only integers" key)
           | Error _, _ -> acc)
         items
         (Ok [])
     | Some _ -> Error (Printf.sprintf "%s must be an array" key)
     | None -> Error (Printf.sprintf "missing %s" key))
  | _ -> Error "plan must be a JSON object"

let string_field key = function
  | `Assoc fields ->
    (match List.assoc_opt key fields with
     | Some (`String s) -> Ok s
     | Some _ -> Error (Printf.sprintf "%s must be a string" key)
     | None -> Error (Printf.sprintf "missing %s" key))
  | _ -> Error "plan must be a JSON object"

let ( let* ) = Result.bind

(* The three index lists must together partition [0, message_count) exactly:
   every index in range, no out-of-range, no negatives, no duplicates across
   the union. A violation yields [Error] (caller retries, then falls back to
   deterministic), not a silent repair — an LLM that miscounts must not drop
   real messages. *)
let validate_partition ~message_count ~kept ~summarized ~dropped =
  let all = kept @ summarized @ dropped in
  let seen = Array.make message_count false in
  let rec check = function
    | [] -> Ok ()
    | idx :: rest ->
      if idx < 0 || idx >= message_count then
        Error (Printf.sprintf "index %d out of range [0, %d)" idx message_count)
      else if seen.(idx) then Error (Printf.sprintf "index %d appears more than once" idx)
      else begin
        seen.(idx) <- true;
        check rest
      end
  in
  let* () = check all in
  let missing = ref [] in
  Array.iteri (fun idx covered -> if not covered then missing := idx :: !missing) seen;
  match !missing with
  | [] -> Ok ()
  | xs ->
    Error
      (Printf.sprintf
         "indices not covered: %s"
         (String.concat "," (List.rev_map string_of_int xs)))

let validate_non_empty_output ~message_count ~kept ~summarized =
  if message_count > 0 && kept = [] && summarized = [] then
    Error "plan would produce empty compaction output"
  else Ok ()

let plan_of_json ~message_count json =
  let* summary = string_field Schema.compaction_plan_field_summary json in
  let summary = String.trim summary in
  let* kept = int_list_field Schema.compaction_plan_field_kept_indices json in
  let* summarized = int_list_field Schema.compaction_plan_field_summarized_indices json in
  let* dropped = int_list_field Schema.compaction_plan_field_dropped_indices json in
  (* The summary stands in for the [summarized] messages; it is consumed by
     [apply] only when [summarized] is non-empty. Requiring it non-empty
     unconditionally would reject a legitimate "keep everything, nothing to
     summarize" plan (summary="") and spuriously fall back to the
     deterministic chain. So the summary must be non-empty iff it will be
     used. *)
  let* () =
    if summarized <> [] && summary = ""
    then Error "summary must be non-empty when summarized indices are present"
    else Ok ()
  in
  let* () = validate_partition ~message_count ~kept ~summarized ~dropped in
  let* () = validate_non_empty_output ~message_count ~kept ~summarized in
  Ok { summary; kept; summarized; dropped }

(* Marker prefix so the folded summary is recognizable in the transcript and
   by downstream tooling, matching the memory-bank [MEMORY_SUMMARY] convention. *)
let summary_marker = "[COMPACTION_SUMMARY]"

let apply (plan : compaction_plan) ~(messages : Agent_sdk.Types.message list) =
  let summarized = List.fold_left (fun s i -> Int_set.add i s) Int_set.empty plan.summarized in
  let dropped = List.fold_left (fun s i -> Int_set.add i s) Int_set.empty plan.dropped in
  let first_summarized =
    List.fold_left min max_int plan.summarized
  in
  let summary_msg =
    message Agent_sdk.Types.Assistant (summary_marker ^ " " ^ plan.summary)
  in
  messages
  |> List.mapi (fun idx m -> idx, m)
  |> List.filter_map (fun (idx, m) ->
    if Int_set.mem idx dropped then None
    else if Int_set.mem idx summarized then
      (* Emit the single summary message at the position of the first
         summarized index; the rest of the summarized indices collapse away. *)
      if idx = first_summarized then Some summary_msg else None
    else Some m)

(* RFC-0327 B-0: native path reads the response_format json the provider
   returned; tool-fallback path extracts the tool_use input whose name matches
   our tool. Both then run the same [plan_of_json] validation. *)
let plan_of_response ~message_count ~(path : plan_path)
    (response : Agent_sdk.Types.api_response) =
  let json_result =
    match path with
    | Native_plan ->
      Agent_sdk_response.structured_json_of_response
        ~schema_name:compaction_plan_tool_name response
    | Tool_fallback_plan ->
      (match
         Agent_sdk.Structured.extract_tool_input ~schema:compaction_plan_extract_schema
           response.content
       with
       | Ok json -> Ok json
       | Error e -> Error (Agent_sdk.Error.to_string e))
  in
  let* json = json_result in
  plan_of_json ~message_count json

type 'a timeout_result =
  | Completed of 'a
  | Timed_out
  | Clock_unavailable

let with_timeout ?clock ~timeout_sec f =
  match clock with
  | None -> Clock_unavailable
  | Some clock ->
    (try Completed (Eio.Time.with_timeout_exn clock timeout_sec f) with
     | Eio.Time.Timeout -> Timed_out)

(* Feedback message appended to the request when a plan is rejected, so the
   retry turn sees the concrete validation error. Mirrors claude-code's
   is_error tool_result re-feed. *)
let feedback_message ~message_count detail =
  message Agent_sdk.Types.User
    (Printf.sprintf
       "Your previous compaction plan was rejected: %s. Call the %s tool again \
        with a corrected JSON object: fields summary, kept_indices, \
        summarized_indices, dropped_indices; every index in [0, %d) must appear \
        exactly once across the three index lists."
       detail compaction_plan_tool_name message_count)

(* RFC-0327 B-0: one initial attempt then up to [max_structured_output_retries]
   retries. Each retry re-sends the prior request with the validation error
   appended as a user message (delta counting: only attempts from this call
   count, because the request list is local). HTTP/timeout/clock failures are
   not retried here — [Complete.complete_with_retry] already handles transient
   HTTP errors; a non-retryable failure or schema rejection falls back to the
   deterministic chain via [None]. *)
let run_plan
    ?(complete : complete_fn = default_complete)
    ?clock
    ?(timeout_sec = Env_config_governance.Inference.timeout_seconds)
    ~(keeper_name : string)
    ~(runtime_id : string)
    ~sw
    ~net
    ~(provider_cfg : Llm_provider.Provider_config.t)
    ~(messages : Agent_sdk.Types.message list)
    () : compaction_plan option =
  let message_count = List.length messages in
  let path = plan_path_for provider_cfg in
  let provider_cfg = provider_for_plan provider_cfg path in
  let tools_opt =
    match path with Tool_fallback_plan -> Some [ compaction_plan_tool_json ] | Native_plan -> None
  in
  let max_retries = max_structured_output_retries () in
  let base_request = messages_for_plan ~messages in
  let rec attempt n request =
    if n > max_retries + 1 then
      (Log.Keeper.warn ~keeper_name
         "compaction LLM plan rejected after %d attempts (path=%s) runtime=%s"
         (max_retries + 1)
         (match path with Native_plan -> "native" | Tool_fallback_plan -> "tool-fallback")
         runtime_id;
       None)
    else
      let call () =
        complete ~sw ~net ?clock ?tools:tools_opt ~config:provider_cfg ~messages:request ()
      in
      match with_timeout ?clock ~timeout_sec call with
      | Timed_out ->
        Log.Keeper.warn ~keeper_name
          "compaction LLM plan timed out runtime=%s timeout_sec=%.1f"
          runtime_id timeout_sec;
        None
      | Clock_unavailable ->
        Log.Keeper.warn ~keeper_name
          "compaction LLM plan clock unavailable runtime=%s — refusing provider \
           call without enforcing timeout"
          runtime_id;
        None
      | Completed (Error err) ->
        Log.Keeper.warn ~keeper_name
          "compaction LLM plan failed runtime=%s: %s"
          runtime_id (Provider_http_error.to_message err);
        None
      | Completed (Ok response) ->
        (match plan_of_response ~message_count ~path response with
         | Ok plan -> Some plan
         | Error detail ->
           Log.Keeper.warn ~keeper_name
             "compaction LLM plan rejected (attempt %d/%d, path=%s) runtime=%s: %s"
             n (max_retries + 1)
             (match path with Native_plan -> "native" | Tool_fallback_plan -> "tool-fallback")
             runtime_id detail;
           attempt (n + 1) (request @ [ feedback_message ~message_count detail ]))
  in
  attempt 1 base_request

let make ?complete ?timeout_sec ~(runtime_id : string) ~(keeper_name : string) ()
  : summarizer option
  =
  if not (Keeper_memory_bank.memory_llm_summary_enabled ()) then None
  else
    match Eio_context.get_switch_opt (), Eio_context.get_net_opt () with
    | Some sw, Some net ->
      let clock = Eio_context.get_clock_opt () in
      let provider_runtime_id =
        Keeper_memory_runtime_resolution.runtime_id_for_librarian ~runtime_id
      in
      (match
         Keeper_memory_runtime_resolution.provider_for_runtime
           ~runtime_id:provider_runtime_id
       with
       | Error err ->
         Log.Keeper.warn ~keeper_name
           "compaction LLM summarizer provider resolution failed runtime=%s: %s"
           provider_runtime_id err;
         None
       | Ok provider ->
         (* RFC-0327 B-0: a direct completion provider suffices — native
            json_schema is no longer required because the tool-fallback path
            covers providers that lack it (e.g. glm-coding). A provider that
            advertises neither native schema nor tool_choice will simply fail
            to emit a usable plan and fall back to deterministic. *)
         let providers = [ provider ] |> List.filter is_direct_completion_provider in
         (match providers with
          | [] ->
            Log.Keeper.warn ~keeper_name
              "compaction LLM summarizer has no direct completion provider \
               runtime=%s"
              provider_runtime_id;
            None
          | provider_cfg :: _ ->
            (match plan_path_for provider_cfg with
             | Native_plan ->
               Log.Keeper.info ~keeper_name
                 "compaction LLM summarizer will use native json_schema runtime=%s"
                 provider_runtime_id
             | Tool_fallback_plan ->
               Log.Keeper.info ~keeper_name
                 "compaction LLM summarizer will use tool-call fallback (no \
                  native json_schema) runtime=%s"
                 provider_runtime_id);
            Some
              (fun ~messages ->
                run_plan ?complete ?clock ?timeout_sec ~keeper_name
                  ~runtime_id:provider_runtime_id ~sw ~net ~provider_cfg ~messages ())))
    | _ ->
      Log.Keeper.warn ~keeper_name
        "compaction LLM summarizer skipped: Eio context unavailable runtime=%s"
        runtime_id;
      None

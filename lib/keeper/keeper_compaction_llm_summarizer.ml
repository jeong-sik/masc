(** LLM-backed keeper context compaction (RFC-0313-adjacent W2).
    See keeper_compaction_llm_summarizer.mli. Structure mirrors
    Keeper_memory_llm_summary: opt-in gate + fiber-local Eio capture +
    schema-capable provider filter + timeout + fail-closed [None]. *)

module Schema = Keeper_structured_output_schema
module Int_set = Set.Make (Int)

(* Bound the summary output. Larger than the memory-bank 512 because a
   compaction summary stands in for many messages, but still capped so the
   emergency path (a near-full context) cannot request an unbounded reply. *)
let summary_max_tokens = 1024

(* Bound the serialized working set handed to the model. A compaction fires
   near the context limit, so the notes text must itself be bounded well below
   the window. Serialization stops at a complete-message boundary and carries
   the exact visible indices into plan validation; unseen tail indices are only
   valid in [kept]. *)
let max_notes_bytes = 24_000

type bounded_transcript =
  { text : string
  ; message_count : int
  ; visible_indices : int list
  }

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
  config:Llm_provider.Provider_config.t ->
  messages:Agent_sdk.Types.message list ->
  unit ->
  (Agent_sdk.Types.api_response, Llm_provider.Http_client.http_error) result

let default_complete ~sw ~net ?clock ~config ~messages () =
  Llm_provider.Complete.complete ~sw ~net ?clock ~config ~messages ()

let is_direct_completion_provider (provider_cfg : Llm_provider.Provider_config.t) : bool =
  match provider_cfg.kind with
  | Anthropic | Kimi | OpenAI_compat | Ollama | Gemini | Glm | DashScope -> true

let provider_for_plan ~runtime_id (provider_cfg : Llm_provider.Provider_config.t) =
  let max_tokens =
    match provider_cfg.max_tokens with
    | Some n when n > 0 -> Some (min n summary_max_tokens)
    | _ -> Some summary_max_tokens
  in
  let temperature =
    Runtime_inference.resolve_temperature
      ~runtime_id
      ~fallback:(fun () -> Runtime_provider_defaults.deterministic_temperature)
  in
  { provider_cfg with
    max_tokens
  ; temperature = Some temperature
  ; tool_choice = None
  ; disable_parallel_tool_use = true
  }
  (* Full module path (not the [Schema] alias): the structured-output
     coverage test resolves callees literally via Ast_grep.count_calls, so
     this call must read [Keeper_structured_output_schema.apply_to_provider_config]
     in source — same pattern as the other registry entries. *)
  |> Keeper_structured_output_schema.apply_to_provider_config
       Schema.compaction_plan_output_schema

let plan_schema_supported provider_cfg =
  Schema.provider_config_accepts_schema Schema.compaction_plan_output_schema provider_cfg

let message role text : Agent_sdk.Types.message = Agent_sdk.Types.text_message role text

let indexed_message_text idx (m : Agent_sdk.Types.message) =
  let role =
    match m.role with
    | Agent_sdk.Types.System -> "system"
    | Agent_sdk.Types.User -> "user"
    | Agent_sdk.Types.Assistant -> "assistant"
    | Agent_sdk.Types.Tool -> "tool"
  in
  let text = Agent_sdk.Types.text_of_message m |> String.trim in
  Printf.sprintf "[%d] %s: %s" idx role text

(* Add only complete indexed messages. This makes [visible_indices] the typed
   provenance of exactly what the model saw instead of inferring visibility
   after an arbitrary byte truncation. *)
let serialize_indexed_messages (messages : Agent_sdk.Types.message list) =
  let message_count = List.length messages in
  let buffer = Buffer.create max_notes_bytes in
  let rec add idx visible_indices = function
    | [] ->
      { text = Buffer.contents buffer
      ; message_count
      ; visible_indices = List.rev visible_indices
      }
    | m :: rest ->
      let indexed = indexed_message_text idx m in
      let separator_bytes = if Buffer.length buffer = 0 then 0 else 1 in
      if Buffer.length buffer + separator_bytes + String.length indexed > max_notes_bytes
      then
        { text = Buffer.contents buffer
        ; message_count
        ; visible_indices = List.rev visible_indices
        }
      else (
        if separator_bytes <> 0 then Buffer.add_char buffer '\n';
        Buffer.add_string buffer indexed;
        add (idx + 1) (idx :: visible_indices) rest)
  in
  add 0 [] messages

let messages_for_plan ~(transcript : bounded_transcript) =
  let count = transcript.message_count in
  let visible_count = List.length transcript.visible_indices in
  let system =
    "You compact a keeper's working context. Classify EVERY message, by its \
     0-based index, into exactly one of: kept (verbatim, still load-bearing), \
     summarized (folded into the summary), or dropped (low value, discard). \
     Every index in range must appear in exactly one list; do not invent \
     indices. You receive a bounded prefix of the transcript: only indices in \
     visible_index_range may be summarized or dropped. Every index outside \
     visible_index_range MUST be put in kept_indices. Prefer keeping recent \
     messages and any with concrete code paths, commands, decisions, or \
     unresolved blockers. Write one durable [summary] prose block that stands \
     in for the summarized messages. Do not invent facts. Do not include \
     markdown fences."
  in
  let user =
    Printf.sprintf
      "message_count: %d\nvisible_index_range: [0, %d)\nmessages:\n%s\n\nReturn a JSON object with fields \
       summary, kept_indices, summarized_indices, dropped_indices covering \
       every index in [0, %d) exactly once."
      count
      visible_count
      transcript.text
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
   the union. A violation yields [Error] (caller falls back to deterministic),
   not a silent repair — an LLM that miscounts must not drop real messages. *)
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

let validate_unseen_indices_kept ~(transcript : bounded_transcript) ~kept =
  let visible =
    List.fold_left (fun indices idx -> Int_set.add idx indices) Int_set.empty
      transcript.visible_indices
  in
  let kept =
    List.fold_left (fun indices idx -> Int_set.add idx indices) Int_set.empty kept
  in
  let rec first_unkept_unseen idx =
    if idx >= transcript.message_count
    then None
    else if Int_set.mem idx visible || Int_set.mem idx kept
    then first_unkept_unseen (idx + 1)
    else Some idx
  in
  match first_unkept_unseen 0 with
  | None -> Ok ()
  | Some idx ->
    Error
      (Printf.sprintf
         "index %d was omitted from the bounded prompt and must be kept"
         idx)

let plan_of_json ~(transcript : bounded_transcript) json =
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
  let message_count = transcript.message_count in
  let* () = validate_partition ~message_count ~kept ~summarized ~dropped in
  let* () = validate_unseen_indices_kept ~transcript ~kept in
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

let plan_of_response ~transcript response =
  match
    Agent_sdk_response.structured_json_of_response
      ~schema_name:"keeper_compaction_plan"
      response
  with
  | Ok json -> plan_of_json ~transcript json
  | Error detail -> Error ("invalid structured response: " ^ detail)

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
  let transcript = serialize_indexed_messages messages in
  let provider_cfg = provider_for_plan ~runtime_id provider_cfg in
  let request = messages_for_plan ~transcript in
  match
    with_timeout ?clock ~timeout_sec (fun () ->
      complete ~sw ~net ?clock ~config:provider_cfg ~messages:request ())
  with
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
    (match plan_of_response ~transcript response with
     | Ok plan -> Some plan
     | Error detail ->
       Log.Keeper.warn ~keeper_name
         "compaction LLM plan rejected runtime=%s: %s"
         runtime_id detail;
       None)

let make ?complete ?timeout_sec ~(runtime_id : string) ~(keeper_name : string) ()
  : summarizer option
  =
  (* Gating lives in the caller's [meta.compaction.mode] (Llm vs
     Deterministic). The memory-bank MASC_KEEPER_MEMORY_LLM_SUMMARY flag is a
     different subsystem's opt-in and must not silence compaction (38-bug
     campaign #3: the double gate kept the LLM path permanently dead). *)
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
       let providers =
         [ provider ]
         |> List.filter is_direct_completion_provider
         |> List.filter plan_schema_supported
       in
       (match providers with
        | [] ->
          Log.Keeper.warn ~keeper_name
            "compaction LLM summarizer has no schema-capable direct completion \
             provider runtime=%s"
            provider_runtime_id;
          None
        | provider_cfg :: _ ->
          Some
            (fun ~messages ->
              run_plan ?complete ?clock ?timeout_sec ~keeper_name
                ~runtime_id:provider_runtime_id ~sw ~net ~provider_cfg ~messages ())))
  | _ ->
    Log.Keeper.warn ~keeper_name
      "compaction LLM summarizer skipped: Eio context unavailable runtime=%s"
      runtime_id;
    None

module For_testing = struct
  let provider_for_plan = provider_for_plan
end

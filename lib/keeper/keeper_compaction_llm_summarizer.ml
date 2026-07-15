(** LLM-backed keeper context compaction (RFC-0313-adjacent W2).
    See keeper_compaction_llm_summarizer.mli. Structure mirrors
    Keeper_memory_llm_summary: opt-in gate + fiber-local Eio capture +
    schema-capable provider filter + timeout + fail-closed [None]. *)

module Schema = Keeper_structured_output_schema
module Int_set = Set.Make (Int)

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

let provider_for_plan (provider_cfg : Llm_provider.Provider_config.t) =
  { provider_cfg with
    tool_choice = None
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
     facts. Do not include markdown fences."
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

(* The three index lists must together partition [0, message_count) exactly.
   An invalid LLM plan is an explicit error, never a silent repair. *)
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
  (* The summary must be non-empty exactly when [apply] will use it. *)
  let* () =
    if summarized <> [] && summary = ""
    then Error "summary must be non-empty when summarized indices are present"
    else Ok ()
  in
  let* () = validate_partition ~message_count ~kept ~summarized ~dropped in
  let* () = validate_non_empty_output ~message_count ~kept ~summarized in
  let* () =
    if summarized = [] && dropped = []
    then Error "plan keeps every message without summarizing or dropping any"
    else Ok ()
  in
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

let plan_of_response ~message_count response =
  match
    Agent_sdk_response.structured_json_of_response
      ~schema_name:"keeper_compaction_plan"
      response
  with
  | Ok json -> plan_of_json ~message_count json
  | Error detail -> Error ("invalid structured response: " ^ detail)

let run_plan
    ?(complete : complete_fn = default_complete)
    ?clock
    ~(keeper_name : string)
    ~(runtime_id : string)
    ~sw
    ~net
    ~(provider_cfg : Llm_provider.Provider_config.t)
    ~(messages : Agent_sdk.Types.message list)
    () : compaction_plan option =
  let message_count = List.length messages in
  let provider_cfg = provider_for_plan provider_cfg in
  let request = messages_for_plan ~messages in
  match complete ~sw ~net ?clock ~config:provider_cfg ~messages:request () with
  | Error err ->
    Log.Keeper.warn ~keeper_name
      "compaction LLM plan failed runtime=%s: %s"
      runtime_id (Provider_http_error.to_message err);
    None
  | Ok response ->
    (match plan_of_response ~message_count response with
     | Ok plan -> Some plan
     | Error detail ->
       Log.Keeper.warn ~keeper_name
         "compaction LLM plan rejected runtime=%s: %s"
         runtime_id detail;
       None)

type candidate =
  { runtime_id : string
  ; provider_cfg : Llm_provider.Provider_config.t
  }

let eligible_candidate ~keeper_name (runtime : Runtime.t) =
  let runtime_id = runtime.Runtime.id in
  let provider_cfg = runtime.Runtime.provider_config in
  if not (is_direct_completion_provider provider_cfg)
  then (
    Log.Keeper.warn ~keeper_name
      "compaction LLM candidate skipped runtime=%s: provider does not support \
       direct completion"
      runtime_id;
    None)
  else if not (plan_schema_supported provider_cfg)
  then (
    Log.Keeper.warn ~keeper_name
      "compaction LLM candidate skipped runtime=%s: provider does not support \
       the compaction plan schema"
      runtime_id;
    None)
  else Some { runtime_id; provider_cfg }

let candidates_for_assignment ~keeper_name assignment_id =
  let rec resolve_lane acc = function
    | [] -> Some (List.rev acc)
    | runtime_id :: rest ->
      (match Runtime.get_runtime_by_id runtime_id with
       | None ->
         Log.Keeper.warn ~keeper_name
           "compaction LLM lane candidate disappeared runtime=%s assignment=%s"
           runtime_id assignment_id;
         None
       | Some runtime ->
         let acc =
           match eligible_candidate ~keeper_name runtime with
           | None -> acc
           | Some candidate -> candidate :: acc
         in
         resolve_lane acc rest)
  in
  match Runtime.resolve_assignment assignment_id with
  | `Missing ->
    Log.Keeper.warn ~keeper_name
      "compaction LLM assignment resolution failed runtime=%s: not configured"
      assignment_id;
    None
  | `Single_runtime runtime ->
    Some (Option.to_list (eligible_candidate ~keeper_name runtime))
  | `Lane lane ->
    resolve_lane [] (Runtime_lane.ordered_candidates lane)

type make_fn = runtime_id:string -> keeper_name:string -> unit -> summarizer option
let make_override : make_fn option Atomic.t = Atomic.make None

let make_resolved ?complete ~(runtime_id : string) ~(keeper_name : string) ()
  : summarizer option
  =
  match candidates_for_assignment ~keeper_name runtime_id with
  | None -> None
  | Some [] ->
    Log.Keeper.warn ~keeper_name
      "compaction LLM summarizer has no eligible candidate assignment=%s"
      runtime_id;
    None
  | Some candidates ->
    (match Eio_context.get_switch_opt (), Eio_context.get_net_opt () with
     | Some sw, Some net ->
       let clock = Eio_context.get_clock_opt () in
       Some
         (fun ~messages ->
           let rec attempt = function
             | [] ->
               Log.Keeper.warn ~keeper_name
                 "compaction LLM candidate chain exhausted assignment=%s"
                 runtime_id;
               None
             | candidate :: rest ->
               (match
                  run_plan ?complete ?clock ~keeper_name
                    ~runtime_id:candidate.runtime_id ~sw ~net
                    ~provider_cfg:candidate.provider_cfg ~messages ()
                with
                | Some _ as plan ->
                  Log.Keeper.info ~keeper_name
                    "compaction LLM candidate succeeded assignment=%s runtime=%s"
                    runtime_id candidate.runtime_id;
                  plan
                | None -> attempt rest)
           in
           attempt candidates)
     | _ ->
       List.iter
         (fun candidate ->
           Log.Keeper.warn ~keeper_name
             "compaction LLM candidate skipped runtime=%s assignment=%s: Eio \
              context unavailable"
             candidate.runtime_id runtime_id)
       candidates;
       None)

let make ?complete ~runtime_id ~keeper_name () =
  match Atomic.get make_override with
  | Some override -> override ~runtime_id ~keeper_name ()
  | None -> make_resolved ?complete ~runtime_id ~keeper_name ()

module For_testing = struct
  let with_make_override override f =
    let previous = Atomic.exchange make_override (Some override) in
    Fun.protect ~finally:(fun () -> Atomic.set make_override previous) f

  let provider_for_plan = provider_for_plan

  let candidate_runtime_ids_for_assignment ~keeper_name ~runtime_id =
    candidates_for_assignment ~keeper_name runtime_id
    |> Option.map (List.map (fun candidate -> candidate.runtime_id))
end

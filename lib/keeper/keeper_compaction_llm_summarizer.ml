(** LLM-backed keeper context compaction (RFC-0313-adjacent W2).
    See keeper_compaction_llm_summarizer.mli. Structure mirrors
    Keeper_memory_llm_summary: opt-in gate + fiber-local Eio capture +
    schema-capable provider filter + fail-closed [None]. *)

module Schema = Keeper_structured_output_schema
module Int_set = Set.Make (Int)

type compaction_plan =
  { summary : string
  ; kept : int list
  ; summarized : int list
  ; dropped : int list
  ; selected_runtime_id : string option
  }

type summarizer =
  units:Keeper_compaction_unit.closed_unit list -> compaction_plan option

type complete_fn = Keeper_provider_subcall.complete_fn

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

let messages_of_unit = function
  | Keeper_compaction_unit.Ordinary_message message -> [ message ]
  | Keeper_compaction_unit.Closed_tool_cycle messages -> messages

let role_label (message : Agent_sdk.Types.message) =
  match message.role with
  | Agent_sdk.Types.System -> "system"
  | Agent_sdk.Types.User -> "user"
  | Agent_sdk.Types.Assistant -> "assistant"
  | Agent_sdk.Types.Tool -> "tool"

(* Decisions index units; application uses the original typed messages. *)
let indexed_units_text units =
  units
  |> List.mapi (fun index unit_ ->
    let kind =
      match unit_ with
      | Keeper_compaction_unit.Ordinary_message _ -> "ordinary_message"
      | Keeper_compaction_unit.Closed_tool_cycle _ -> "closed_tool_cycle"
    in
    let visible_messages =
      messages_of_unit unit_
      |> List.map (fun message ->
        Printf.sprintf
          "%s: %s"
          (role_label message)
          (Agent_sdk.Types.text_of_message message |> String.trim))
      |> String.concat "\n"
    in
    Printf.sprintf "[%d] %s:\n%s" index kind visible_messages)
  |> String.concat "\n"

let messages_for_plan ~units =
  let count = List.length units in
  let system =
    "You compact a keeper's working context. Classify EVERY closed structural \
     unit, by its \
     0-based index, into exactly one of: kept (verbatim, still load-bearing), \
     summarized (folded into the summary), or dropped (low value, discard). \
     Every index in range must appear in exactly one list; do not invent \
     indices. A closed_tool_cycle is indivisible: classify the whole unit, \
     never an inner message. Prefer keeping recent units and any with concrete \
     code paths, commands, decisions, or unresolved blockers. Write one durable \
     [summary] prose block that stands in for the summarized units. Do not \
     invent facts. Do not include markdown fences."
  in
  let user =
    Printf.sprintf
      "unit_count: %d\nunits:\n%s\n\nReturn a JSON object with fields \
       summary, kept_indices, summarized_indices, dropped_indices covering \
       every index in [0, %d) exactly once."
      count
      (indexed_units_text units)
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

(* The three index lists must together partition [0, unit_count) exactly.
   An invalid LLM plan is an explicit error, never a silent repair. *)
let validate_partition ~unit_count ~kept ~summarized ~dropped =
  let all = kept @ summarized @ dropped in
  let seen = Array.make unit_count false in
  let rec check = function
    | [] -> Ok ()
    | idx :: rest ->
      if idx < 0 || idx >= unit_count then
        Error (Printf.sprintf "index %d out of range [0, %d)" idx unit_count)
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

let validate_non_empty_output ~unit_count ~kept ~summarized =
  if unit_count > 0 && kept = [] && summarized = [] then
    Error "plan would produce empty compaction output"
  else Ok ()

let plan_of_json ~unit_count json =
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
  let* () = validate_partition ~unit_count ~kept ~summarized ~dropped in
  let* () = validate_non_empty_output ~unit_count ~kept ~summarized in
  let* () =
    if summarized = [] && dropped = []
    then Error "plan keeps every unit without summarizing or dropping any"
    else Ok ()
  in
  Ok { summary; kept; summarized; dropped; selected_runtime_id = None }

(* Marker prefix so the folded summary is recognizable in the transcript and
   by downstream tooling, matching the memory-bank [MEMORY_SUMMARY] convention. *)
let summary_marker = "[COMPACTION_SUMMARY]"

let apply (plan : compaction_plan) ~units =
  let summarized = List.fold_left (fun s i -> Int_set.add i s) Int_set.empty plan.summarized in
  let dropped = List.fold_left (fun s i -> Int_set.add i s) Int_set.empty plan.dropped in
  let first_summarized =
    List.fold_left min max_int plan.summarized
  in
  let summary_msg =
    message Agent_sdk.Types.Assistant (summary_marker ^ " " ^ plan.summary)
  in
  units
  |> List.mapi (fun idx unit_ -> idx, unit_)
  |> List.concat_map (fun (idx, unit_) ->
    if Int_set.mem idx dropped then []
    else if Int_set.mem idx summarized then
      if idx = first_summarized then [ summary_msg ] else []
    else messages_of_unit unit_)

let plan_of_response ~unit_count response =
  match
    Agent_sdk_response.structured_json_of_response
      ~schema_name:"keeper_compaction_plan"
      response
  with
  | Ok json -> plan_of_json ~unit_count json
  | Error detail -> Error ("invalid structured response: " ^ detail)

let run_plan
    ?complete
    ?clock
    ~(keeper_name : string)
    ~(runtime_id : string)
    ~sw
    ~net
    ~(provider_cfg : Llm_provider.Provider_config.t)
    ~units
    () : compaction_plan option =
  let unit_count = List.length units in
  let provider_cfg = provider_for_plan provider_cfg in
  let request = messages_for_plan ~units in
  match
    Keeper_provider_subcall.complete ?override:complete ~sw ~net ?clock
      ~config:provider_cfg ~messages:request ()
  with
  | Error err ->
    Log.Keeper.warn ~keeper_name
      "compaction LLM plan failed runtime=%s: %s"
      runtime_id (Provider_http_error.to_message err);
    None
  | Ok response ->
    (match plan_of_response ~unit_count response with
     | Ok plan -> Some { plan with selected_runtime_id = Some runtime_id }
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
         (fun ~units ->
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
                    ~provider_cfg:candidate.provider_cfg ~units ()
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

(** LLM-backed keeper context compaction (RFC-0313-adjacent W2).
    See keeper_compaction_llm_summarizer.mli. Structure mirrors
    Keeper_memory_llm_summary: opt-in gate + fiber-local Eio capture +
    schema-capable provider filter + fail-closed [None]. *)

module Schema = Keeper_structured_output_schema
module Unit = Keeper_compaction_unit
module Unit_plan = Keeper_compaction_unit_plan

type compaction_plan =
  { plan : Unit_plan.t
  ; selected_runtime_id : string option
  }

type planning_outcome =
  | Planned of compaction_plan
  | No_compaction

type observation =
  { selected_runtime_id : string option
  ; summarized_message_count : int
  ; dropped_message_count : int
  }

type summarizer = messages:Agent_sdk.Types.message list -> planning_outcome option

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
       Schema.compaction_unit_plan_output_schema

let plan_schema_supported provider_cfg =
  Schema.provider_config_accepts_schema
    Schema.compaction_unit_plan_output_schema
    provider_cfg

let message role text : Agent_sdk.Types.message = Agent_sdk.Types.text_message role text

let messages_for_plan ~(source : Unit.partition) =
  let count = List.length source.closed_prefix in
  let system =
    "Decide every supplied atomic compaction unit exactly once: keep it \
     verbatim, summarize it with a unit-specific summary, or drop it. A \
     closed_tool_cycle contains a complete ToolUse/ToolResult cycle and must be \
     decided as one unit, but all three decisions are allowed. The omitted \
     open/in-flight suffix is preserved exactly outside your rewrite. Return \
     no invented indices or facts and no markdown fences."
  in
  let user =
    Printf.sprintf
      "Return kept_indices, dropped_indices, and summarized_units entries \
       containing unit_index and summary. Cover every unit index in [0,%d) \
       exactly once.\n%s"
      count
      (Yojson.Safe.to_string (Unit_plan.input_json source))
  in
  [ message Agent_sdk.Types.System system; message Agent_sdk.Types.User user ]

let plan_of_json ~messages json =
  match Unit.partition messages with
  | Error error -> Error (Unit.show_structural_error error)
  | Ok source ->
    (match Unit_plan.decode ~source json with
     | Ok plan -> Ok { plan; selected_runtime_id = None }
     | Error error -> Error (Unit_plan.show_decode_error error))

let apply plan = Unit_plan.apply plan.plan

let observation plan =
  let observed = Unit_plan.observation plan.plan in
  { selected_runtime_id = plan.selected_runtime_id
  ; summarized_message_count = observed.summarized_source_messages
  ; dropped_message_count = observed.dropped_source_messages
  }

let plan_of_response ~source response =
  match
    Agent_sdk_response.structured_json_of_response
      ~schema_name:"keeper_compaction_unit_plan"
      response
  with
  | Ok json ->
    (match Unit_plan.decode ~source json with
     | Ok plan -> Ok (Some { plan; selected_runtime_id = None })
     | Error Unit_plan.No_compaction -> Ok None
     | Error error -> Error (Unit_plan.show_decode_error error))
  | Error detail -> Error ("invalid structured response: " ^ detail)

let run_plan
    ?complete
    ?clock
    ~(keeper_name : string)
    ~(runtime_id : string)
    ~sw
    ~net
    ~(provider_cfg : Llm_provider.Provider_config.t)
    ~(source : Unit.partition)
    () : planning_outcome option =
  let provider_cfg = provider_for_plan provider_cfg in
  let request = messages_for_plan ~source in
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
    (match plan_of_response ~source response with
     | Ok (Some plan) ->
       Some (Planned { plan with selected_runtime_id = Some runtime_id })
     | Ok None ->
       Log.Keeper.info ~keeper_name
         "compaction LLM accepted no compaction runtime=%s" runtime_id;
       Some No_compaction
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
           match Unit.partition messages with
           | Error error ->
             Log.Keeper.warn ~keeper_name
               "compaction LLM source rejected assignment=%s: %s"
               runtime_id (Unit.show_structural_error error);
             None
           | Ok source ->
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
                      ~provider_cfg:candidate.provider_cfg ~source ()
                  with
                  | Some (Planned plan) ->
                    Log.Keeper.info ~keeper_name
                      "compaction LLM candidate succeeded assignment=%s runtime=%s"
                      runtime_id candidate.runtime_id;
                    Some (Planned plan)
                  | Some No_compaction -> Some No_compaction
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

(** LLM-backed keeper context compaction (RFC-0313-adjacent W2).
    See keeper_compaction_llm_summarizer.mli. Structure mirrors
    Keeper_memory_llm_summary: opt-in gate + fiber-local Eio capture +
    schema-capable provider filter + fail-closed [None]. *)

module Schema = Keeper_structured_output_schema
module Int_set = Set.Make (Int)
module Int_map = Map.Make (Int)
module String_set = Set.Make (String)

type eligible_source =
  { source_index : int
  ; message : Agent_sdk.Types.message
  ; text_blocks : string list
  }

type action =
  | Keep
  | Drop
  | Summarize of string

type decision =
  { source : eligible_source
  ; action : action
  }

type compaction_plan =
  { decisions : decision list
  ; selected_runtime_id : string
  ; source_units : Keeper_compaction_unit.closed_unit list
  }

type summarization_failure =
  | Provider_unavailable
  | Invalid_plan

type summarizer =
  units:Keeper_compaction_unit.closed_unit list ->
  (compaction_plan, summarization_failure) result

type complete_fn = Keeper_provider_subcall.complete_fn

let provider_for_plan (provider_cfg : Llm_provider.Provider_config.t) =
  { provider_cfg with
    tool_choice = None
  ; disable_parallel_tool_use = true
  }
  (* Three-tier (#25266): json_schema when the provider enforces it, else JSON
     mode for json_object-only providers (GLM/DeepSeek/Kimi), else prompt only.
     The plan prompt already states the exact decisions schema and
     [plan_of_response] validates every decision, so the json_object tier is
     safe here — it lifts the minimax-native SPOF. Full module path (not the
     [Schema] alias): the structured-output coverage test resolves callees
     literally via Ast_grep.count_calls. *)
  |> Keeper_structured_output_schema.apply_schema_json_mode_or_prompt_tier
       ~log_label:"compaction summarizer"
       Schema.compaction_plan_output_schema

let plan_schema_supported provider_cfg =
  Schema.provider_config_accepts_schema_or_json_mode
    Schema.compaction_plan_output_schema
    provider_cfg

let message role text : Agent_sdk.Types.message = Agent_sdk.Types.text_message role text

let messages_of_unit = function
  | Keeper_compaction_unit.Ordinary_message message -> [ message ]
  | Keeper_compaction_unit.Closed_tool_cycle messages -> messages

let text_blocks blocks =
  List.fold_right
    (fun block texts ->
      match block, texts with
      | Agent_sdk.Types.Text text, Some texts -> Some (text :: texts)
      | ( Agent_sdk.Types.Thinking _
        | Agent_sdk.Types.ReasoningDetails _
        | Agent_sdk.Types.RedactedThinking _
        | Agent_sdk.Types.ToolUse _
        | Agent_sdk.Types.ToolResult _
        | Agent_sdk.Types.Image _
        | Agent_sdk.Types.Document _
        | Agent_sdk.Types.Audio _ )
        , _ ->
        None
      | _, None -> None)
    blocks
    (Some [])

let eligible_source source_index = function
  | Keeper_compaction_unit.Ordinary_message
      ({ role = Agent_sdk.Types.Assistant
       ; content
       ; name = None
       ; tool_call_id = None
       ; metadata = []
       } as message) ->
    (match text_blocks content with
     | Some (_ :: _ as text_blocks)
       when List.exists (fun text -> String.trim text <> "") text_blocks ->
       Some { source_index; message; text_blocks }
     | Some [] | Some (_ :: _) | None -> None)
  | Keeper_compaction_unit.Ordinary_message _
  | Keeper_compaction_unit.Closed_tool_cycle _ ->
    None

let eligible_sources units =
  units
  |> List.mapi eligible_source
  |> List.filter_map Fun.id

let has_eligible_units units = eligible_sources units <> []

let eligible_units_json sources =
  `List
    (List.map
       (fun source ->
         `Assoc
           [ Schema.compaction_plan_field_unit_index, `Int source.source_index
           ; "role", `String (Agent_sdk.Types.role_to_string source.message.role)
           ; "text_blocks", `List (List.map (fun text -> `String text) source.text_blocks)
           ])
       sources)

let messages_for_plan ~units =
  let sources = eligible_sources units in
  let system =
    "You compact only the explicitly supplied eligible Assistant text units. \
     Return exactly one decision for every supplied unit_index and do not \
     invent indices. keep preserves the source verbatim. summarize replaces \
     that unit in place with its faithful summary. drop is valid only when the \
     unit contributes no state, decision, evidence, constraint, unresolved \
     work, or outcome. For keep and drop, summary must be null. For summarize, \
     summary must be a non-empty string. Do not infer recency policy, merge \
     units, relocate facts, invent facts, or include markdown fences. Respond \
     with a single JSON object and no other text."
  in
  let user =
    Printf.sprintf
      "eligible_units=%s\nReturn {\"%s\":[{\"%s\":integer,\"%s\":\
       \"%s|%s|%s\",\"%s\":string|null}]} with exactly one decision per \
       supplied unit_index."
      (eligible_units_json sources |> Yojson.Safe.to_string)
      Schema.compaction_plan_field_decisions
      Schema.compaction_plan_field_unit_index
      Schema.compaction_plan_field_action
      Schema.compaction_plan_action_keep
      Schema.compaction_plan_action_drop
      Schema.compaction_plan_action_summarize
      Schema.compaction_plan_field_summary
  in
  [ message Agent_sdk.Types.System system; message Agent_sdk.Types.User user ]

let ( let* ) = Result.bind

let object_fields ~context ~expected = function
  | `Assoc fields ->
    let expected = String_set.of_list expected in
    let rec check seen = function
      | [] ->
        let missing = String_set.diff expected seen |> String_set.elements in
        if missing = []
        then Ok fields
        else Error (Printf.sprintf "%s missing fields: %s" context (String.concat "," missing))
      | (key, _) :: rest ->
        if not (String_set.mem key expected)
        then Error (Printf.sprintf "%s has unknown field %s" context key)
        else if String_set.mem key seen
        then Error (Printf.sprintf "%s has duplicate field %s" context key)
        else check (String_set.add key seen) rest
    in
    check String_set.empty fields
  | _ -> Error (context ^ " must be a JSON object")

let required_field key fields =
  match List.assoc_opt key fields with
  | Some value -> Ok value
  | None -> Error ("missing field " ^ key)

let int_value ~field = function
  | `Int value -> Ok value
  | _ -> Error (field ^ " must be an integer")

let string_value ~field = function
  | `String value -> Ok value
  | _ -> Error (field ^ " must be a string")

let summary_value ~field = function
  | `Null -> Ok None
  | `String value -> Ok (Some value)
  | _ -> Error (field ^ " must be a string or null")

let parse_action ~action_token ~summary =
  if String.equal action_token Schema.compaction_plan_action_keep
  then
    (match summary with
     | None -> Ok Keep
     | Some _ -> Error "keep decision summary must be null")
  else if String.equal action_token Schema.compaction_plan_action_drop
  then
    (match summary with
     | None -> Ok Drop
     | Some _ -> Error "drop decision summary must be null")
  else if String.equal action_token Schema.compaction_plan_action_summarize
  then
    (match summary with
     | Some summary when String.trim summary <> "" -> Ok (Summarize summary)
     | Some _ -> Error "summarize decision summary must be non-empty"
     | None -> Error "summarize decision summary must be a string")
  else Error ("unknown compaction action " ^ action_token)

let decision_of_json sources_by_index json =
  let expected_fields =
    [ Schema.compaction_plan_field_unit_index
    ; Schema.compaction_plan_field_action
    ; Schema.compaction_plan_field_summary
    ]
  in
  let* fields = object_fields ~context:"decision" ~expected:expected_fields json in
  let* index_json = required_field Schema.compaction_plan_field_unit_index fields in
  let* source_index =
    int_value ~field:Schema.compaction_plan_field_unit_index index_json
  in
  let* source =
    match Int_map.find_opt source_index sources_by_index with
    | Some source -> Ok source
    | None -> Error (Printf.sprintf "unit_index %d is not eligible" source_index)
  in
  let* action_json = required_field Schema.compaction_plan_field_action fields in
  let* action_token =
    string_value ~field:Schema.compaction_plan_field_action action_json
  in
  let* summary_json = required_field Schema.compaction_plan_field_summary fields in
  let* summary = summary_value ~field:Schema.compaction_plan_field_summary summary_json in
  let* action = parse_action ~action_token ~summary in
  Ok { source; action }

let decisions_value json =
  let expected = [ Schema.compaction_plan_field_decisions ] in
  let* fields = object_fields ~context:"plan" ~expected json in
  let* decisions = required_field Schema.compaction_plan_field_decisions fields in
  match decisions with
  | `List decisions -> Ok decisions
  | _ -> Error (Schema.compaction_plan_field_decisions ^ " must be an array")

let parse_decisions ~sources decisions_json =
  let sources_by_index =
    List.fold_left
      (fun sources source -> Int_map.add source.source_index source sources)
      Int_map.empty
      sources
  in
  let rec parse seen decisions = function
    | [] -> Ok (List.rev decisions, seen)
    | json :: rest ->
      let* decision = decision_of_json sources_by_index json in
      let source_index = decision.source.source_index in
      if Int_set.mem source_index seen
      then Error (Printf.sprintf "unit_index %d appears more than once" source_index)
      else parse (Int_set.add source_index seen) (decision :: decisions) rest
  in
  parse Int_set.empty [] decisions_json

let plan_of_json ~runtime_id ~units json =
  let sources = eligible_sources units in
  if String.trim runtime_id = ""
  then Error "selected runtime id must be non-empty"
  else if sources = []
  then Error "source contains no eligible compaction units"
  else
  let expected_indices =
    List.fold_left
      (fun indices source -> Int_set.add source.source_index indices)
      Int_set.empty
      sources
  in
  let* decisions_json = decisions_value json in
  let* decisions, seen = parse_decisions ~sources decisions_json in
  let missing = Int_set.diff expected_indices seen |> Int_set.elements in
  let* () =
    if missing = []
    then Ok ()
    else
      Error
        (Printf.sprintf
           "eligible unit indices not covered: %s"
           (String.concat "," (List.map string_of_int missing)))
  in
  let* () =
    if List.exists
         (fun decision ->
           match decision.action with
           | Drop | Summarize _ -> true
           | Keep -> false)
         decisions
    then Ok ()
    else Error "plan keeps every eligible unit without changing any"
  in
  let* () =
    if List.exists
         (fun decision ->
           match decision.action with
           | Keep | Summarize _ -> true
           | Drop -> false)
         decisions
    then Ok ()
    else Error "plan would remove every eligible unit"
  in
  let decisions =
    List.sort
      (fun left right -> Int.compare left.source.source_index right.source.source_index)
      decisions
  in
  Ok { decisions; selected_runtime_id = runtime_id; source_units = units }

let apply (plan : compaction_plan) =
  let decisions =
    List.fold_left
      (fun decisions decision ->
        Int_map.add decision.source.source_index decision decisions)
      Int_map.empty
      plan.decisions
  in
  plan.source_units
  |> List.mapi (fun idx unit_ -> idx, unit_)
  |> List.concat_map (fun (idx, unit_) ->
    match Int_map.find_opt idx decisions with
    | None | Some { action = Keep; _ } -> messages_of_unit unit_
    | Some { action = Drop; _ } -> []
    | Some { source; action = Summarize summary } ->
      [ { source.message with
          content = [ Agent_sdk.Types.Text summary ]
        }
      ])

let selected_runtime_id plan = plan.selected_runtime_id

let indices_for_action predicate plan =
  plan.decisions
  |> List.filter_map (fun decision ->
    if predicate decision.action then Some decision.source.source_index else None)

let summarized_indices = indices_for_action (function Summarize _ -> true | Keep | Drop -> false)
let dropped_indices = indices_for_action (function Drop -> true | Keep | Summarize _ -> false)
let has_changes plan = summarized_indices plan <> [] || dropped_indices plan <> []

let plan_of_response ~runtime_id ~units response =
  match
    Agent_sdk_response.structured_json_of_response
      ~schema_name:"keeper_compaction_plan"
      response
  with
  | Ok json -> plan_of_json ~runtime_id ~units json
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
    () : (compaction_plan, summarization_failure) result =
  if not (has_eligible_units units)
  then Error Invalid_plan
  else
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
      Error Provider_unavailable
    | Ok response ->
      (match plan_of_response ~runtime_id ~units response with
       | Ok plan -> Ok plan
       | Error detail ->
         Log.Keeper.warn ~keeper_name
           "compaction LLM plan rejected runtime=%s: %s"
           runtime_id detail;
         Error Invalid_plan)

type candidate =
  { runtime_id : string
  ; lane_id : string option
  ; provider_cfg : Llm_provider.Provider_config.t
  }

let eligible_candidate ~keeper_name ~lane_id (runtime : Runtime.t) =
  let runtime_id = runtime.Runtime.id in
  let provider_cfg = runtime.Runtime.provider_config in
  (* #25266: a provider is eligible when it can enforce the schema (strict
     json_schema) OR at least honor JSON mode (json_object). This admits the
     json_object-only endpoints (GLM/DeepSeek/Kimi) that the strict-schema
     gate used to drop, which had left the single json_schema-native endpoint
     (minimax) as a SPOF — nearly every cloud model supports json_object, so
     compaction now works across them. A provider that supports NEITHER is
     still filtered: without any format guarantee, a prompt-only attempt would
     just churn the parser. [provider_for_plan] then selects the strongest
     available tier for the accepted provider. *)
  if not (plan_schema_supported provider_cfg)
  then (
    Log.Keeper.warn ~keeper_name
      "compaction LLM candidate skipped runtime=%s: provider supports neither \
       the compaction plan schema nor json mode"
      runtime_id;
    None)
  else Some { runtime_id; lane_id; provider_cfg }

let candidates_for_assignment ~keeper_name assignment_id =
  let rec resolve_lane ~lane_id acc = function
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
           match eligible_candidate ~keeper_name ~lane_id:(Some lane_id) runtime with
           | None -> acc
           | Some candidate -> candidate :: acc
         in
         resolve_lane ~lane_id acc rest)
  in
  match Runtime.resolve_assignment assignment_id with
  | `Missing ->
    Log.Keeper.warn ~keeper_name
      "compaction LLM assignment resolution failed runtime=%s: not configured"
      assignment_id;
    None
  | `Single_runtime runtime ->
    Some (Option.to_list (eligible_candidate ~keeper_name ~lane_id:None runtime))
  | `Lane lane ->
    (* Sticky failover: start from the last-good lane candidate when one is
       remembered, keeping the declared order for the rest. *)
    let lane_id = Runtime_lane.id lane in
    resolve_lane ~lane_id []
      (Runtime_lane_preference.prefer_order ~lane_id
         (Runtime_lane.ordered_candidates lane))

(* Collapse duplicate runtime ids while keeping the first (highest-priority)
   occurrence, so a seed assignment that resolves to the same runtime as a
   later seed is only ever tried once. *)
let dedup_candidates candidates =
  let rec loop seen unique_rev = function
    | [] -> List.rev unique_rev
    | candidate :: rest ->
      if String_set.mem candidate.runtime_id seen
      then loop seen unique_rev rest
      else
        loop
          (String_set.add candidate.runtime_id seen)
          (candidate :: unique_rev)
          rest
  in
  loop String_set.empty [] candidates

(* [assignment_ids] is a priority-ordered list of seed ids (each independently
   a Runtime or a Runtime Lane, per {!candidates_for_assignment}). Every
   eligible candidate from every seed is tried, seed order first and then
   per-seed lane order, with cross-seed duplicates collapsed. A seed that
   fails to resolve (Missing, or a Lane candidate that disappeared)
   contributes no candidates rather than aborting the other seeds — the
   overall chain is empty only when every seed is empty. *)
let candidates_for_assignments ~keeper_name assignment_ids =
  assignment_ids
  |> List.concat_map (fun assignment_id ->
    match candidates_for_assignment ~keeper_name assignment_id with
    | None -> []
    | Some candidates -> candidates)
  |> dedup_candidates

type make_fn = runtime_ids:string list -> keeper_name:string -> unit -> summarizer option
let make_override : make_fn option Atomic.t = Atomic.make None

let make_resolved ?complete ~(runtime_ids : string list) ~(keeper_name : string) ()
  : summarizer option
  =
  let assignments_label = String.concat "," runtime_ids in
  match candidates_for_assignments ~keeper_name runtime_ids with
  | [] ->
    Log.Keeper.warn ~keeper_name
      "compaction LLM summarizer has no eligible candidate assignments=%s"
      assignments_label;
    None
  | candidates ->
    (match Eio_context.get_switch_opt (), Eio_context.get_net_opt () with
     | Some sw, Some net ->
       let clock = Eio_context.get_clock_opt () in
       Some
         (fun ~units ->
           let rec attempt saw_provider_failure = function
             | [] ->
               Log.Keeper.warn ~keeper_name
                 "compaction LLM candidate chain exhausted assignments=%s"
                 assignments_label;
               if saw_provider_failure
               then Error Provider_unavailable
               else Error Invalid_plan
             | candidate :: rest ->
               (match
                  run_plan ?complete ?clock ~keeper_name
                    ~runtime_id:candidate.runtime_id ~sw ~net
                    ~provider_cfg:candidate.provider_cfg ~units ()
                with
                | Ok _ as plan ->
                  (* Sticky failover: remember the winning candidate for the
                     lane it came from, if any. *)
                  (match candidate.lane_id with
                   | Some lane_id ->
                     Runtime_lane_preference.note_success ~lane_id
                       ~candidate:candidate.runtime_id
                   | None -> ());
                  Log.Keeper.info ~keeper_name
                    "compaction LLM candidate succeeded assignments=%s runtime=%s"
                    assignments_label candidate.runtime_id;
                  plan
                | Error Provider_unavailable -> attempt true rest
                | Error Invalid_plan -> attempt saw_provider_failure rest)
           in
           attempt false candidates)
     | _ ->
       List.iter
         (fun candidate ->
           Log.Keeper.warn ~keeper_name
             "compaction LLM candidate skipped runtime=%s assignments=%s: Eio \
              context unavailable"
             candidate.runtime_id assignments_label)
       candidates;
       None)

let make ?complete ~runtime_ids ~keeper_name () =
  match Atomic.get make_override with
  | Some override -> override ~runtime_ids ~keeper_name ()
  | None -> make_resolved ?complete ~runtime_ids ~keeper_name ()

module For_testing = struct
  let with_make_override override f =
    let previous = Atomic.exchange make_override (Some override) in
    Fun.protect ~finally:(fun () -> Atomic.set make_override previous) f

  let provider_for_plan = provider_for_plan

  let candidate_runtime_ids_for_assignment ~keeper_name ~runtime_id =
    candidates_for_assignment ~keeper_name runtime_id
    |> Option.map (List.map (fun candidate -> candidate.runtime_id))
  let messages_for_plan = messages_for_plan

  let candidate_runtime_ids_for_assignments ~keeper_name ~runtime_ids =
    candidates_for_assignments ~keeper_name runtime_ids
    |> List.map (fun candidate -> candidate.runtime_id)
end

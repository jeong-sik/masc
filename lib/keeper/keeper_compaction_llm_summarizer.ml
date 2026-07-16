(** LLM-backed keeper context compaction (RFC-0313-adjacent W2).
    See keeper_compaction_llm_summarizer.mli. Structure mirrors
    Keeper_memory_llm_summary: opt-in gate + fiber-local Eio capture +
    schema-capable provider filter + fail-closed [None]. *)

module Schema = Keeper_structured_output_schema
module Unit = Keeper_compaction_unit
module Int_set = Set.Make (Int)

type compaction_plan =
  { summary : string
  ; kept : int list
  ; summarized : int list
  ; dropped : int list
  ; selected_runtime_id : string option
  ; source : Unit.partition
  }

type summarizer = messages:Agent_sdk.Types.message list -> compaction_plan option

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

let structural_error_to_string = Unit.show_structural_error
let unit_to_json unit_index = function
  | Unit.Ordinary_message message ->
    `Assoc
      [ "unit_index", `Int unit_index
      ; "unit_type", `String "ordinary_message"
      ; "must_keep", `Bool false
      ; "messages", `List [ Keeper_context_core.message_to_json message ]
      ]
  | Unit.Closed_tool_cycle messages ->
    `Assoc
      [ "unit_index", `Int unit_index
      ; "unit_type", `String "closed_tool_cycle"
      ; "must_keep", `Bool true
      ; "messages", `List (List.map Keeper_context_core.message_to_json messages)
      ]
let input_json (source : Unit.partition) =
  `Assoc
    [ "unit_count", `Int (List.length source.closed_prefix)
    ; ( "units"
      , `List (List.mapi unit_to_json source.closed_prefix) )
    ]
let messages_for_plan ~(source : Unit.partition) =
  let count = List.length source.closed_prefix in
  let system =
    "Classify every supplied compaction unit by unit_index into exactly one of \
     kept, summarized, or dropped. A unit with must_keep=true MUST be kept. \
     Only ordinary_message units may be summarized or dropped. Preserve facts \
     exactly and return one summary for summarized units. Do not invent indices \
     or facts and do not include markdown fences."
  in
  let user =
    Printf.sprintf
      "Canonical compaction input JSON follows. Return summary, kept_indices, \
       summarized_indices, and dropped_indices covering every unit index in \
       [0,%d) exactly once.\n%s"
      count
      (Yojson.Safe.to_string (input_json source))
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
  let rec check seen = function
    | [] ->
      if Int_set.cardinal seen = unit_count
      then Ok ()
      else Error (Printf.sprintf "indices do not cover [0,%d)" unit_count)
    | idx :: rest ->
      if idx < 0 || idx >= unit_count then
        Error (Printf.sprintf "index %d out of range [0, %d)" idx unit_count)
      else if Int_set.mem idx seen then
        Error (Printf.sprintf "index %d appears more than once" idx)
      else check (Int_set.add idx seen) rest
  in
  check Int_set.empty (kept @ summarized @ dropped)

let validate_closed_cycles ~source ~kept =
  let kept = List.fold_left (fun set i -> Int_set.add i set) Int_set.empty kept in
  let rec check index = function
    | [] -> Ok ()
    | Unit.Closed_tool_cycle _ :: _ when not (Int_set.mem index kept) ->
      Error (Printf.sprintf "closed tool cycle unit %d must be kept" index)
    | _ :: rest -> check (index + 1) rest
  in
  check 0 source.Unit.closed_prefix

let validate_contiguous indices =
  let rec check = function
    | [] | [ _ ] -> Ok ()
    | left :: ((right :: _) as rest) ->
      if right = left + 1
      then check rest
      else Error "summarized unit indices must form one contiguous run"
  in
  check (List.sort Int.compare indices)

let plan_of_json_for_source ~(source : Unit.partition) json =
  let unit_count = List.length source.closed_prefix in
  let* summary = string_field Schema.compaction_plan_field_summary json in
  let* kept = int_list_field Schema.compaction_plan_field_kept_indices json in
  let* summarized = int_list_field Schema.compaction_plan_field_summarized_indices json in
  let* dropped = int_list_field Schema.compaction_plan_field_dropped_indices json in
  (* The summary must be non-empty exactly when [apply] will use it. *)
  let* () =
    if summarized <> [] && String.trim summary = ""
    then Error "summary must be non-empty when summarized indices are present"
    else Ok ()
  in
  let* () = validate_partition ~unit_count ~kept ~summarized ~dropped in
  let* () = validate_closed_cycles ~source ~kept in
  let* () = validate_contiguous summarized in
  Ok { summary; kept; summarized; dropped; selected_runtime_id = None; source }

let plan_of_json ~messages json =
  match Unit.partition messages with
  | Error error -> Error (structural_error_to_string error)
  | Ok source -> plan_of_json_for_source ~source json

let apply (plan : compaction_plan) =
  let summarized = List.fold_left (fun s i -> Int_set.add i s) Int_set.empty plan.summarized in
  let dropped = List.fold_left (fun s i -> Int_set.add i s) Int_set.empty plan.dropped in
  let first_summarized = List.fold_left min max_int plan.summarized in
  let summary_msg = message Agent_sdk.Types.Assistant plan.summary in
  let compacted_prefix =
    plan.source.closed_prefix
    |> List.mapi (fun index unit -> index, unit)
    |> List.concat_map (fun (index, unit) ->
      match unit with
      | Unit.Closed_tool_cycle messages -> messages
      | Unit.Ordinary_message message ->
        if Int_set.mem index dropped then []
        else if Int_set.mem index summarized then
          if index = first_summarized then [ summary_msg ] else []
        else [ message ])
  in
  compacted_prefix @ plan.source.protected_suffix

let observation plan =
  plan.selected_runtime_id, List.length plan.summarized, List.length plan.dropped

let plan_of_response ~source response =
  match
    Agent_sdk_response.structured_json_of_response
      ~schema_name:"keeper_compaction_plan"
      response
  with
  | Ok json -> plan_of_json_for_source ~source json
  | Error detail -> Error ("invalid structured response: " ^ detail)

let run_plan
    ?complete
    ?clock
    ~(keeper_name : string)
    ~(runtime_id : string)
    ~sw
    ~net
    ~(provider_cfg : Llm_provider.Provider_config.t)
    ~(messages : Agent_sdk.Types.message list)
    () : compaction_plan option =
  match Unit.partition messages with
  | Error error ->
    Log.Keeper.warn ~keeper_name
      "compaction LLM source rejected runtime=%s: %s"
      runtime_id (structural_error_to_string error);
    None
  | Ok source ->
    let provider_cfg = provider_for_plan provider_cfg in
    let request = messages_for_plan ~source in
    (match
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
        | Ok plan -> Some { plan with selected_runtime_id = Some runtime_id }
        | Error detail ->
          Log.Keeper.warn ~keeper_name
            "compaction LLM plan rejected runtime=%s: %s"
            runtime_id detail;
          None))

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

  let input_json ~messages =
    match Unit.partition messages with
    | Ok source -> Ok (input_json source)
    | Error error -> Error (structural_error_to_string error)

  let candidate_runtime_ids_for_assignment ~keeper_name ~runtime_id =
    candidates_for_assignment ~keeper_name runtime_id
    |> Option.map (List.map (fun candidate -> candidate.runtime_id))
end

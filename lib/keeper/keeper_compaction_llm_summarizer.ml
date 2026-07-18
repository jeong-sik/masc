(** LLM-backed keeper context compaction (RFC-0313-adjacent W2).
    See keeper_compaction_llm_summarizer.mli. Structure mirrors
    Keeper_memory_llm_summary: opt-in gate + fiber-local Eio capture +
    schema-capable provider filter + fail-closed [None]. *)

module Schema = Keeper_structured_output_schema
module Int_set = Set.Make (Int)

type compaction_plan =
  { summary : string
  ; keep_from : int
  ; pinned_keep : int list
  ; message_count : int
  ; selected_runtime_id : string option
  }

(* Messages folded into the summary: everything below [keep_from] except the
   pinned exceptions. [plan_of_json] guarantees pinned_keep ⊂ [0, keep_from). *)
let summarized_count plan = plan.keep_from - List.length plan.pinned_keep

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

(* One indexed line per message: "[i] role: <text>". The model reads the
   indices to place the [keep_from] boundary and the pinned exceptions. *)
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
    "You compact a keeper's working context. Pick ONE cut index keep_from: \
     every message at index >= keep_from is kept verbatim; every message \
     before it is folded into one durable summary. Choose keep_from so the \
     recent, still load-bearing tail survives. If a few messages BEFORE the \
     cut must survive verbatim (concrete code paths, commands, decisions, \
     unresolved blockers), list their indices in pinned_keep; keep that list \
     short, and use [] when nothing qualifies. Write the summary so it stands \
     in for everything before keep_from except the pinned messages. Do not \
     invent facts. Do not include markdown fences."
  in
  let user =
    Printf.sprintf
      "message_count: %d\nmessages:\n%s\n\nReturn a JSON object with fields \
       summary (string), keep_from (integer in [0, %d]), and pinned_keep \
       (array of integers, each in [0, keep_from), [] when empty)."
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

let int_field key = function
  | `Assoc fields ->
    (match List.assoc_opt key fields with
     | Some (`Int n) -> Ok n
     | Some _ -> Error (Printf.sprintf "%s must be an integer" key)
     | None -> Error (Printf.sprintf "missing %s" key))
  | _ -> Error "plan must be a JSON object"

let ( let* ) = Result.bind

(* Boundary validation (masc#25099): the cut must land inside [0,
   message_count] and every pinned exception must precede it. Coverage gaps
   and duplicate bucket assignments are unrepresentable in this form, so
   there is no partition check to fail. Duplicates inside [pinned_keep]
   denote the same set and collapse under set parsing; an out-of-range pin
   is a semantic violation and stays an explicit error, never a silent
   repair. *)
let plan_of_json ~message_count json =
  let* summary = string_field Schema.compaction_plan_field_summary json in
  let summary = String.trim summary in
  let* keep_from = int_field Schema.compaction_plan_field_keep_from json in
  let* pinned_raw = int_list_field Schema.compaction_plan_field_pinned_keep json in
  let* () =
    if keep_from < 0 || keep_from > message_count
    then
      Error
        (Printf.sprintf "keep_from %d out of range [0, %d]" keep_from message_count)
    else Ok ()
  in
  let pinned_keep = List.sort_uniq compare pinned_raw in
  let* () =
    match List.find_opt (fun idx -> idx < 0 || idx >= keep_from) pinned_keep with
    | Some idx ->
      Error
        (Printf.sprintf
           "pinned_keep index %d out of range [0, keep_from=%d)"
           idx
           keep_from)
    | None -> Ok ()
  in
  let* () =
    if keep_from - List.length pinned_keep = 0
    then Error "plan keeps every message without summarizing any"
    else Ok ()
  in
  (* The summary always stands in for at least one message here, so it must
     carry content. *)
  let* () =
    if summary = "" then Error "summary must be non-empty" else Ok ()
  in
  Ok { summary; keep_from; pinned_keep; message_count; selected_runtime_id = None }

(* Marker prefix so the folded summary is recognizable in the transcript and
   by downstream tooling, matching the memory-bank [MEMORY_SUMMARY] convention. *)
let summary_marker = "[COMPACTION_SUMMARY]"

let apply (plan : compaction_plan) ~(messages : Agent_sdk.Types.message list) =
  let pinned = Int_set.of_list plan.pinned_keep in
  (* Position of the first summarized message: the lowest index below the cut
     that is not pinned. [plan_of_json] guarantees one exists; [-1] keeps this
     total anyway (it matches no index, so a malformed plan degrades to
     keeping the pinned/tail messages rather than raising). *)
  let first_summarized =
    let rec go idx =
      if idx >= plan.keep_from then -1
      else if Int_set.mem idx pinned then go (idx + 1)
      else idx
    in
    go 0
  in
  let summary_msg =
    message Agent_sdk.Types.Assistant (summary_marker ^ " " ^ plan.summary)
  in
  messages
  |> List.mapi (fun idx m -> idx, m)
  |> List.filter_map (fun (idx, m) ->
    if idx >= plan.keep_from then Some m
    else if Int_set.mem idx pinned then Some m
    else if idx = first_summarized then
      (* Emit the single summary message at the position of the first
         summarized index; the rest of the summarized indices collapse away. *)
      Some summary_msg
    else None)

let plan_of_response ~message_count response =
  match
    Agent_sdk_response.structured_json_of_response
      ~schema_name:"keeper_compaction_plan"
      response
  with
  | Ok json -> plan_of_json ~message_count json
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
  let message_count = List.length messages in
  let provider_cfg = provider_for_plan provider_cfg in
  let request = messages_for_plan ~messages in
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
    (match plan_of_response ~message_count response with
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

(* Collapse duplicate runtime ids while keeping the first (highest-priority)
   occurrence, so a seed assignment that resolves to the same runtime as a
   later seed is only ever tried once. *)
let dedup_candidates candidates =
  let seen = Hashtbl.create 8 in
  List.filter
    (fun candidate ->
      if Hashtbl.mem seen candidate.runtime_id
      then false
      else begin
        Hashtbl.add seen candidate.runtime_id ();
        true
      end)
    candidates

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
         (fun ~messages ->
           let rec attempt = function
             | [] ->
               Log.Keeper.warn ~keeper_name
                 "compaction LLM candidate chain exhausted assignments=%s"
                 assignments_label;
               None
             | candidate :: rest ->
               (match
                  run_plan ?complete ?clock ~keeper_name
                    ~runtime_id:candidate.runtime_id ~sw ~net
                    ~provider_cfg:candidate.provider_cfg ~messages ()
                with
                | Some _ as plan ->
                  Log.Keeper.info ~keeper_name
                    "compaction LLM candidate succeeded assignments=%s runtime=%s"
                    assignments_label candidate.runtime_id;
                  plan
                | None -> attempt rest)
           in
           attempt candidates)
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

  let candidate_runtime_ids_for_assignments ~keeper_name ~runtime_ids =
    candidates_for_assignments ~keeper_name runtime_ids
    |> List.map (fun candidate -> candidate.runtime_id)
end

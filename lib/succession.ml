(** Succession — Cross-model relay engine for infinite agent lifecycle.

    DNA extraction compresses working context into a structured payload
    that can be hydrated by a successor agent, potentially on a different
    LLM model.  Cross-model normalization handles format differences.

    @since 2.61.0 *)

open Printf

let text_of_message = Llm_client.text_of_message

(* ================================================================ *)
(* Types                                                            *)
(* ================================================================ *)

type succession_metrics = {
  total_turns : int;
  total_tokens_used : int;
  total_cost_usd : float;
  tasks_completed : int;
  errors_encountered : int;
  elapsed_seconds : float;
}

type succession_dna = {
  generation : int;
  trace_id : string;
  goal : string;
  progress_summary : string;
  compressed_context : string;
  pending_actions : string list;
  key_decisions : string list;
  memory_refs : string list;
  warnings : string list;
  metrics : succession_metrics;
}

type successor_spec = {
  model : Llm_client.model_spec;
  inherit_tools : bool;
  context_budget : float;
}

(* ================================================================ *)
(* Metrics                                                          *)
(* ================================================================ *)

let empty_metrics = {
  total_turns = 0;
  total_tokens_used = 0;
  total_cost_usd = 0.0;
  tasks_completed = 0;
  errors_encountered = 0;
  elapsed_seconds = 0.0;
}

let merge_metrics a b = {
  total_turns = a.total_turns + b.total_turns;
  total_tokens_used = a.total_tokens_used + b.total_tokens_used;
  total_cost_usd = a.total_cost_usd +. b.total_cost_usd;
  tasks_completed = a.tasks_completed + b.tasks_completed;
  errors_encountered = a.errors_encountered + b.errors_encountered;
  elapsed_seconds = a.elapsed_seconds +. b.elapsed_seconds;
}

(* ================================================================ *)
(* DNA Extraction                                                   *)
(* ================================================================ *)

(** Build a progress summary from the most recent assistant messages. *)
let build_progress_summary (msgs : Llm_client.message list) : string =
  let clip s max_len =
    if String.length s > max_len then String.sub s 0 max_len ^ "..." else s
  in
  let last_opt = function
    | [] -> None
    | xs -> Some (List.nth xs (List.length xs - 1))
  in
  let latest_state_block () =
    let rec loop = function
      | [] -> None
      | (m : Llm_client.message) :: rest ->
        let blocks = Context_manager.extract_state_blocks (text_of_message m) in
        (match last_opt blocks with
         | Some b -> Some b
         | None -> loop rest)
    in
    loop (List.rev msgs)
  in
  match latest_state_block () with
  | Some b ->
    (* Prefer the structured continuity snapshot when available. *)
    clip (Printf.sprintf "[STATE]\n%s\n[/STATE]" b) 3000
  | None ->
    (* Fallback heuristic: last assistant outputs, clipped. *)
    let assistant_msgs = List.filter (fun (m : Llm_client.message) ->
      m.role = Llm_client.Assistant
    ) msgs in
    let recent = match List.length assistant_msgs with
      | n when n > 5 ->
        let start = n - 5 in
        List.filteri (fun i _ -> i >= start) assistant_msgs
      | _ -> assistant_msgs
    in
    let parts = List.map (fun (m : Llm_client.message) ->
      clip (text_of_message m) 200
    ) recent in
    String.concat "\n" parts

(** Extract pending actions from user messages that haven't been addressed. *)
let extract_pending_actions (msgs : Llm_client.message list) : string list =
  let starts_with_ci ~prefix s =
    let prefix = String.lowercase_ascii prefix in
    let s = String.lowercase_ascii (String.trim s) in
    let lp = String.length prefix in
    String.length s >= lp && String.sub s 0 lp = prefix
  in
  let extract_next_from_state block =
    let lines =
      block
      |> String.split_on_char '\n'
      |> List.map String.trim
      |> List.filter (fun l -> l <> "")
    in
    match List.find_opt (fun l -> starts_with_ci ~prefix:"next:" l) lines with
    | None -> []
    | Some l ->
      let value =
        match String.split_on_char ':' l with
        | _k :: rest -> String.concat ":" rest |> String.trim
        | [] -> ""
      in
      if value = "" then [] else
        value
        |> String.split_on_char ';'
        |> List.map String.trim
        |> List.filter (fun s -> s <> "")
        |> (fun xs -> if List.length xs > 5 then List.filteri (fun i _ -> i < 5) xs else xs)
  in
  let last_opt = function
    | [] -> None
    | xs -> Some (List.nth xs (List.length xs - 1))
  in
  let latest_state_block () =
    let rec loop = function
      | [] -> None
      | (m : Llm_client.message) :: rest ->
        let blocks = Context_manager.extract_state_blocks (text_of_message m) in
        (match last_opt blocks with
         | Some b -> Some b
         | None -> loop rest)
    in
    loop (List.rev msgs)
  in
  match latest_state_block () with
  | Some b ->
    let next = extract_next_from_state b in
    if next <> [] then next else
      (match List.rev msgs with
       | [] -> []
       | (last : Llm_client.message) :: _ when last.role = Llm_client.User -> [text_of_message last]
       | _ -> [])
  | None ->
    (match List.rev msgs with
     | [] -> []
     | (last : Llm_client.message) :: _ when last.role = Llm_client.User -> [text_of_message last]
     | _ -> [])

(** Extract key decisions from assistant messages containing decision markers. *)
let extract_key_decisions (msgs : Llm_client.message list) : string list =
  let starts_with_ci ~prefix s =
    let prefix = String.lowercase_ascii prefix in
    let s = String.lowercase_ascii (String.trim s) in
    let lp = String.length prefix in
    String.length s >= lp && String.sub s 0 lp = prefix
  in
  let extract_decisions_from_state block =
    let lines =
      block
      |> String.split_on_char '\n'
      |> List.map String.trim
      |> List.filter (fun l -> l <> "")
    in
    match List.find_opt (fun l -> starts_with_ci ~prefix:"decisions:" l) lines with
    | None -> []
    | Some l ->
      let value =
        match String.split_on_char ':' l with
        | _k :: rest -> String.concat ":" rest |> String.trim
        | [] -> ""
      in
      if value = "" then [] else
        value
        |> String.split_on_char ';'
        |> List.map String.trim
        |> List.filter (fun s -> s <> "")
        |> (fun xs -> if List.length xs > 5 then List.filteri (fun i _ -> i < 5) xs else xs)
  in
  let last_opt = function
    | [] -> None
    | xs -> Some (List.nth xs (List.length xs - 1))
  in
  let latest_state_block () =
    let rec loop = function
      | [] -> None
      | (m : Llm_client.message) :: rest ->
        let blocks = Context_manager.extract_state_blocks (text_of_message m) in
        (match last_opt blocks with
         | Some b -> Some b
         | None -> loop rest)
    in
    loop (List.rev msgs)
  in
  match latest_state_block () with
  | Some b ->
    let d = extract_decisions_from_state b in
    if d <> [] then d else []
  | None ->
    let decision_markers = ["decided"; "chosen"; "selected"; "using"; "approach:";
                            "strategy:"; "will use"; "going with"] in
    List.filter_map (fun (m : Llm_client.message) ->
      if m.role <> Llm_client.Assistant then None
      else
        let mc = text_of_message m in
        let lower = String.lowercase_ascii mc in
        let has_marker = List.exists (fun marker ->
          try
            let _ = Str.search_forward (Str.regexp_string marker) lower 0 in
            true
          with Not_found -> false
        ) decision_markers in
        if has_marker then
          Some (if String.length mc > 150
                then String.sub mc 0 150 ^ "..."
                else mc)
        else None
    ) msgs

let extract_dna ~(working_ctx : Context_manager.working_context)
    ~(session_ctx : Context_manager.session_context)
    ~goal ~generation ~trace_id ~metrics =
  (* Compact the working context for transfer *)
  let compacted = Context_manager.compact working_ctx
    [PruneToolOutputs; MergeContiguous; SummarizeOld] in
  let compressed = Context_manager.serialize_context compacted in
  let all_msgs = working_ctx.messages in
  {
    generation;
    trace_id;
    goal;
    progress_summary = build_progress_summary all_msgs;
    compressed_context = compressed;
    pending_actions = extract_pending_actions all_msgs;
    key_decisions = extract_key_decisions all_msgs;
    memory_refs = [];  (* Populated externally via pgvector *)
    warnings =
      (if session_ctx.checkpoints = [] then ["No checkpoints saved"] else []) @
      (if metrics.errors_encountered > 3 then
        [sprintf "High error rate: %d errors in %d turns"
          metrics.errors_encountered metrics.total_turns]
       else []);
    metrics;
  }

(* ================================================================ *)
(* Cross-Model Normalization                                        *)
(* ================================================================ *)

(** Normalize messages for the target model's constraints. *)
let normalize_for_model (msgs : Llm_client.message list)
    (target : Llm_client.model_spec) : Llm_client.message list =
  let msgs = match target.provider with
    | Llm_client.Llama ->
      (* Local llama runtimes: merge consecutive system messages, simplify tool messages *)
      List.map (fun (m : Llm_client.message) ->
        match m.role with
        | Llm_client.Tool ->
          (* Convert tool messages to user messages for models without tool support *)
          { m with role = Llm_client.User;
                   content = [Agent_sdk.Types.Text (sprintf "[Tool result: %s]\n%s"
                     (Option.value ~default:"unknown" m.name) (text_of_message m))] }
        | _ -> m
      ) msgs
    | Llm_client.Claude ->
      (* Claude: ensure alternating user/assistant, no consecutive same roles *)
      let rec fix_alternation = function
        | [] -> []
        | [m] -> [m]
        | (m1 : Llm_client.message) :: ((m2 : Llm_client.message) :: rest as tail) ->
          if m1.role = m2.role && m1.role <> Llm_client.System then
            (* Merge consecutive same-role *)
            let merged = { m1 with content = [Agent_sdk.Types.Text (text_of_message m1 ^ "\n" ^ text_of_message m2)] } in
            fix_alternation (merged :: rest)
          else
            m1 :: fix_alternation tail
      in
      fix_alternation msgs
    | _ -> msgs
  in
  (* Trim to fit within target context budget *)
  let max_tokens = target.max_context * 8 / 10 in  (* Leave 20% for response *)
  let rec trim msgs =
    let total = Llm_client.estimate_tokens msgs in
    if total <= max_tokens || List.length msgs <= 2 then msgs
    else
      (* Remove oldest non-system message *)
      match msgs with
      | (m : Llm_client.message) :: rest when m.role = Llm_client.System ->
        m :: trim rest
      | _ :: rest -> trim rest
      | [] -> []
  in
  trim msgs

(* ================================================================ *)
(* DNA Hydration                                                    *)
(* ================================================================ *)

(** Build the system prompt for a successor agent from DNA. *)
let build_successor_system_prompt (dna : succession_dna) : string =
  let parts = [
    sprintf "You are generation %d of a continuous agent (trace: %s)." dna.generation dna.trace_id;
    sprintf "Goal: %s" dna.goal;
    "";
    sprintf "Previous progress:\n%s" dna.progress_summary;
  ] in
  let with_pending = match dna.pending_actions with
    | [] -> parts
    | actions ->
      parts @ [""; "Pending actions:"] @
      List.map (fun a -> sprintf "- %s" a) actions
  in
  let with_decisions = match dna.key_decisions with
    | [] -> with_pending
    | decisions ->
      with_pending @ [""; "Key decisions made:"] @
      List.map (fun d -> sprintf "- %s" d) decisions
  in
  let with_warnings = match dna.warnings with
    | [] -> with_decisions
    | warnings ->
      with_decisions @ [""; "Warnings:"] @
      List.map (fun w -> sprintf "- %s" w) warnings
  in
  let with_metrics =
    with_warnings @ [
      "";
      sprintf "Chain metrics: %d turns, %d tokens, $%.4f, %d tasks done, %d errors"
        dna.metrics.total_turns dna.metrics.total_tokens_used
        dna.metrics.total_cost_usd dna.metrics.tasks_completed
        dna.metrics.errors_encountered;
    ]
  in
  (* Phase 3B: Inject procedural memory from predecessor *)
  let with_procedures =
    let proc_block = Procedural_memory.format_for_dna
      ~agent_name:"_global" ~limit:5 in
    if proc_block = "" then with_metrics
    else with_metrics @ [""; proc_block]
  in
  String.concat "\n" with_procedures

let hydrate (dna : succession_dna) (spec : successor_spec) : Context_manager.working_context =
  let restored_opt =
    if dna.compressed_context = "" then None
    else
      try Some (Context_manager.deserialize_context
                  dna.compressed_context ~max_tokens:spec.model.max_context)
      with exn ->
        Log.Misc.warn "succession: context deserialize failed: %s" (Printexc.to_string exn);
        None
  in
  (* Preserve the previous system prompt (keeper/perpetual constitution + custom instructions).
     This is critical for continuity across handoffs. *)
  let inherited_prompt =
    match restored_opt with
    | None -> ""
    | Some restored -> String.trim restored.system_prompt
  in
  let succession_prompt = build_successor_system_prompt dna in
  let system_prompt =
    if inherited_prompt = "" then succession_prompt
    else inherited_prompt ^ "\n\n" ^ succession_prompt
  in
  let base_ctx = Context_manager.create ~system_prompt ~max_tokens:spec.model.max_context in
  (* If context budget allows, restore compressed context messages *)
  match restored_opt with
  | None -> base_ctx
  | Some restored ->
    if spec.context_budget <= 0.0 then base_ctx
    else begin
      let budget_tokens = int_of_float
        (float_of_int spec.model.max_context *. spec.context_budget *. 0.5) in
      let rec take_up_to budget acc = function
        | [] -> List.rev acc
        | m :: rest ->
          let tok = Llm_client.estimate_tokens [m] in
          if budget - tok < 0 then List.rev acc
          else take_up_to (budget - tok) (m :: acc) rest
      in
      let transferred = take_up_to budget_tokens [] restored.messages in
      let normalized = normalize_for_model transferred spec.model in
      Context_manager.append_many base_ctx normalized
    end

(* ================================================================ *)
(* JSON Serialization                                               *)
(* ================================================================ *)

let metrics_to_json m : Yojson.Safe.t =
  `Assoc [
    ("total_turns", `Int m.total_turns);
    ("total_tokens_used", `Int m.total_tokens_used);
    ("total_cost_usd", `Float m.total_cost_usd);
    ("tasks_completed", `Int m.tasks_completed);
    ("errors_encountered", `Int m.errors_encountered);
    ("elapsed_seconds", `Float m.elapsed_seconds);
  ]

let metrics_of_json json =
  let open Yojson.Safe.Util in
  {
    total_turns = json |> member "total_turns" |> to_int;
    total_tokens_used = json |> member "total_tokens_used" |> to_int;
    total_cost_usd = json |> member "total_cost_usd" |> to_number;
    tasks_completed = json |> member "tasks_completed" |> to_int;
    errors_encountered = json |> member "errors_encountered" |> to_int;
    elapsed_seconds = json |> member "elapsed_seconds" |> to_number;
  }

let str_list_to_json lst = `List (List.map (fun s -> `String s) lst)

let str_list_of_json json =
  let open Yojson.Safe.Util in
  json |> to_list |> List.map to_string

let dna_to_json dna : Yojson.Safe.t =
  `Assoc [
    ("generation", `Int dna.generation);
    ("trace_id", `String dna.trace_id);
    ("goal", `String dna.goal);
    ("progress_summary", `String dna.progress_summary);
    ("compressed_context", `String dna.compressed_context);
    ("pending_actions", str_list_to_json dna.pending_actions);
    ("key_decisions", str_list_to_json dna.key_decisions);
    ("memory_refs", str_list_to_json dna.memory_refs);
    ("warnings", str_list_to_json dna.warnings);
    ("metrics", metrics_to_json dna.metrics);
  ]

let dna_of_json json =
  try
    let open Yojson.Safe.Util in
    Ok {
      generation = json |> member "generation" |> to_int;
      trace_id = json |> member "trace_id" |> to_string;
      goal = json |> member "goal" |> to_string;
      progress_summary = json |> member "progress_summary" |> to_string;
      compressed_context = json |> member "compressed_context" |> to_string;
      pending_actions = json |> member "pending_actions" |> str_list_of_json;
      key_decisions = json |> member "key_decisions" |> str_list_of_json;
      memory_refs = json |> member "memory_refs" |> str_list_of_json;
      warnings = json |> member "warnings" |> str_list_of_json;
      metrics = json |> member "metrics" |> metrics_of_json;
    }
  with exn ->
    Error (sprintf "DNA parse error: %s" (Printexc.to_string exn))

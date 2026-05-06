(** Keeper_tool_disclosure — tool selection, usage tracking, and response normalization.

    Extracted from keeper_agent_run.ml as part of #5732 god-module split.
    Contains helpers for tool usage snapshots, delta computation, response
    validation, query text extraction, and tool selection boundary merging. *)

let keeper_tool_usage_snapshot ~base_path ~keeper_name : (string * int) list =
  Keeper_registry.tool_usage_of ~base_path keeper_name
  |> List.map (fun (tool_name, entry) -> tool_name, entry.Keeper_types.count)
  |> List.sort (fun (left, _) (right, _) -> String.compare left right)
;;

let tool_usage_delta ~(before : (string * int) list) ~(after : (string * int) list)
  : string list
  =
  let before_counts = Hashtbl.create 16 in
  List.iter
    (fun (tool_name, count) -> Hashtbl.replace before_counts tool_name count)
    before;
  after
  |> List.concat_map (fun (tool_name, after_count) ->
    let before_count =
      Option.value ~default:0 (Hashtbl.find_opt before_counts tool_name)
    in
    List.init (max 0 (after_count - before_count)) (fun _ -> tool_name))
;;

let merge_observed_tool_names
      ~(registry_observed_tool_names : string list)
      ~(hook_observed_tool_names : string list)
  : string list
  =
  let hook_counts = Hashtbl.create 16 in
  List.iter
    (fun tool_name ->
      let count = Option.value ~default:0 (Hashtbl.find_opt hook_counts tool_name) in
      Hashtbl.replace hook_counts tool_name (count + 1))
    hook_observed_tool_names;
  let emitted_extra = Hashtbl.create 16 in
  hook_observed_tool_names
  @ List.filter
      (fun tool_name ->
        let hook_count =
          Option.value ~default:0 (Hashtbl.find_opt hook_counts tool_name)
        in
        let already_emitted =
          Option.value ~default:0 (Hashtbl.find_opt emitted_extra tool_name)
        in
        if already_emitted < hook_count then (
          Hashtbl.replace emitted_extra tool_name (already_emitted + 1);
          false)
        else true)
      registry_observed_tool_names
;;

let merge_reported_and_observed_tool_names
      ~(reported_tool_names : string list)
      ~(observed_tool_names : string list)
  : string list
  =
  match observed_tool_names with
  | [] -> reported_tool_names
  | _ ->
    let observed = Hashtbl.create 16 in
    List.iter (fun tool_name -> Hashtbl.replace observed tool_name ()) observed_tool_names;
    observed_tool_names
    @ List.filter
        (fun tool_name -> not (Hashtbl.mem observed tool_name))
        reported_tool_names
;;

let final_keeper_tool_names
      ~(reported_tool_names : string list)
      ~(observed_tool_names : string list)
      ~(allowed_tool_names : string list)
  : string list
  =
  merge_reported_and_observed_tool_names
    ~reported_tool_names
    ~observed_tool_names
  |> Keeper_tool_alias.canonicalize_observed
  |> List.filter (fun tool_name -> List.mem tool_name allowed_tool_names)
;;

let unexpected_tool_names
      ~(allowed_tool_names : string list)
      ~(tool_names : string list)
  : string list
  =
  let allowed = Hashtbl.create (List.length allowed_tool_names) in
  let seen = Hashtbl.create (List.length tool_names) in
  List.iter (fun tool_name -> Hashtbl.replace allowed tool_name ()) allowed_tool_names;
  tool_names
  |> List.filter (fun tool_name ->
       if Hashtbl.mem allowed tool_name || Hashtbl.mem seen tool_name
       then false
       else (
         Hashtbl.replace seen tool_name ();
         true))
;;

(** [has_valid_tool_call ~unexpected_tool_names ~tool_names] returns
    true iff at least one name in [tool_names] is absent from
    [unexpected_tool_names] — i.e. at least one call is on the keeper
    surface. Used by [Keeper_agent_run] (#8471) to decide whether a
    turn mixing unknown tools with valid ones should hard-fail or
    continue with a partial-tolerance WARN. *)
let has_valid_tool_call
      ~(unexpected_tool_names : string list)
      ~(tool_names : string list)
  : bool
  =
  let unexpected = Hashtbl.create (List.length unexpected_tool_names) in
  List.iter (fun n -> Hashtbl.replace unexpected n ()) unexpected_tool_names;
  List.exists (fun n -> not (Hashtbl.mem unexpected n)) tool_names
;;

type completion_contract =
  | Allow_text_or_tool
  | Require_tool_use

let merge_completion_contract
      ~(previous : completion_contract)
      ~(current : completion_contract)
  : completion_contract
  =
  match previous, current with
  | Require_tool_use, _
  | _, Require_tool_use -> Require_tool_use
  | Allow_text_or_tool, Allow_text_or_tool -> Allow_text_or_tool

(** Issue #8696: exhaustive match against [Agent_sdk.Types.tool_choice].
    Previous catch-all silently mapped any future SDK constructor to
    [Allow_text_or_tool]; on an OAS pin bump that adds a constructor
    (e.g. requiring tool use under new conditions) the keeper would
    silently degrade. Listing every variant turns SDK drift into a
    compile error here so it is reviewed at the boundary. *)
let completion_contract_of_tool_choice
      (tool_choice : Agent_sdk.Types.tool_choice option)
  : completion_contract
  =
  match tool_choice with
  | Some (Agent_sdk.Types.Any | Agent_sdk.Types.Tool _) -> Require_tool_use
  | Some (Agent_sdk.Types.Auto | Agent_sdk.Types.None_) -> Allow_text_or_tool
  | None -> Allow_text_or_tool

let run_completion_contract
      ~(turn_contract : completion_contract)
      ~(required_tool_use_seen : bool)
  : completion_contract
  =
  if required_tool_use_seen then Require_tool_use else turn_contract

let validate_completion_contract_presence
      ~(contract : completion_contract)
      ~(tool_present : bool)
  : (unit, string) result
  =
  match contract with
  | Allow_text_or_tool -> Ok ()
  | Require_tool_use ->
    if tool_present
    then Ok ()
    else
      Error
        "keeper turn violated required tool contract: no keeper-surface tools were called"

let validate_completion_contract
      ~(contract : completion_contract)
      ~(tool_names : string list)
      ()
  : (unit, string) result
  =
  match contract with
  | Allow_text_or_tool -> Ok ()
  | Require_tool_use ->
    (match tool_names with
     | _ :: _ -> Ok ()
     | [] ->
       Error
         "keeper turn violated required tool contract: no tools were called")

(** Keeper tool progress classes are the shared contract between prompt
    disclosure, required-tool validation, runtime receipts, and liveness
    metrics.  Keep these classes conservative: state/reporting tools do not
    count as productive progress, and claim tools only bind work; execution
    or completion tools are what prove the keeper is alive past task pickup. *)
type tool_progress_class =
  | Passive_status
  | Claim_context
  | Execution
  | Completion

let tool_progress_class_to_string = function
  | Passive_status -> "passive_status"
  | Claim_context -> "claim_context"
  | Execution -> "execution"
  | Completion -> "completion"

let canonical_tool_name name =
  match Keeper_tool_alias.canonicalize_observed [ name ] with
  | canonical :: _ -> canonical
  | [] -> name

let claim_context_tool_names : string list =
  Tool_name.
    [ Masc Claim_next; Masc Claim_task; Keeper Task_claim ]
  |> List.map Tool_name.to_string

let completion_tool_names : string list =
  (* Stay_silent is the explicit "no work for me this turn" decisive no-op.
     LLM evaluates the situation via passive reads, then signals stay_silent
     to terminate the turn intentionally. Classifying it as Completion lets
     the contract accept the turn as satisfied; abuse is bounded separately
     by keeper_stay_silent_loop_detector (consecutive-stay metric + circuit
     breaker). Without this, 4+ events/day were rejected as passive_only
     even though the LLM had decided no fit (sangsu/janitor/taskmaster on
     2026-04-27 00:17-00:58 UTC, idle_seconds 28-40h, claimable_count 44-46). *)
  Tool_name.
    [
      Masc Cancel_task;
      Masc Complete_task;
      Masc Deliver;
      Masc Release_task;
      Keeper Stay_silent;
      Keeper Task_done;
      Keeper Task_force_done;
      Keeper Task_force_release;
      Keeper Task_submit_for_verification;
    ]
  |> List.map Tool_name.to_string

let is_claim_tool_name name =
  let name = canonical_tool_name name in
  match Tool_name.of_string name with
  | Some (Keeper Task_claim) | Some (Masc Claim_next) | Some (Masc Claim_task) ->
    true
  | _ -> false

let is_claim_context_tool_name name =
  let name = canonical_tool_name name in
  let canonical_name =
    match Tool_name.of_string name with
    | Some tool -> Tool_name.to_string tool
    | None -> name
  in
  List.mem canonical_name claim_context_tool_names

let is_completion_tool_name name =
  let name = canonical_tool_name name in
  let canonical_name =
    match Tool_name.of_string name with
    | Some tool -> Tool_name.to_string tool
    | None -> name
  in
  List.mem canonical_name completion_tool_names

let is_stay_silent_tool_name name =
  let name = canonical_tool_name name in
  match Tool_name.of_string name with
  | Some (Keeper Stay_silent) -> true
  | _ -> false

let tool_name_can_satisfy_required_contract name =
  let name = canonical_tool_name name in
  (* Completion tools (stay_silent, release, done, etc.) intentionally
     satisfy the contract even though their effect_domain is Read_only.
     Without this exemption, analyst/janitor keepers that correctly
     call keeper_stay_silent alongside status reads trigger false
     contract violations — observed 2026-04-28 when codex-spark
     returned stay_silent + keeper_task_list on an actionable signal. *)
  if is_completion_tool_name name then true
  else
    match Tool_catalog.effect_domain name with
    | Some Tool_catalog.Read_only -> false
    | Some
        ( Tool_catalog.Masc_coordination
        | Tool_catalog.Playground_write
        | Tool_catalog.Main_worktree_write ) ->
        true
    | None -> not (Tool_dispatch.is_read_only name)

let required_tool_satisfaction
      (call : Agent_sdk.Completion_contract.tool_call)
  : (unit, string) result
  =
  let tool_name = canonical_tool_name call.name in
  (* Completion tools intentionally satisfy the contract.  See
     tool_name_can_satisfy_required_contract for the same exemption. *)
  if is_completion_tool_name tool_name then Ok ()
  else
    let mutates =
      match Tool_catalog.effect_domain tool_name with
      | Some Tool_catalog.Read_only -> false
      | _ ->
        Keeper_exec_tools.has_mutating_side_effect_with_input
          ~tool_name ~input:call.input
    in
    if mutates then Ok ()
    else
      Error
        (Printf.sprintf
           "tool '%s' is read-only/passive and cannot satisfy a required-tool contract"
           tool_name)

let classify_tool_progress name =
  let name = canonical_tool_name name in
  if is_completion_tool_name name
  then Completion
  else if is_claim_context_tool_name name
  then Claim_context
  else if tool_name_can_satisfy_required_contract name
  then Execution
  else Passive_status

let is_owned_task_progress_tool_name name =
  if is_stay_silent_tool_name name then false
  else
    match classify_tool_progress name with
    | Execution | Completion -> true
    | Passive_status | Claim_context -> false

let is_passive_status_tool_name name =
  match classify_tool_progress name with
  | Passive_status -> true
  | Claim_context | Execution | Completion -> false

let is_execution_progress_tool_name name =
  match classify_tool_progress name with
  | Execution | Completion -> true
  | Passive_status | Claim_context -> false

(* #10091: record a [require_tool_use] contract violation with
   the labels the operator needs to fix the underlying cause
   (tool_preset mismatch vs. active-task refusal vs. cohort
   misconfiguration).  Split out of [keeper_agent_run.ml] so the
   counter emission is directly testable without standing up a
   full OAS/Eio harness.  [contract_status] is the same string
   already assigned to [receipt_tool_contract_result_ref] at the
   call site, so receipt JSON and fleet metric share one
   vocabulary. *)
let record_require_tool_use_violation
      ~(keeper_name : string)
      ~(has_current_task : bool)
      ~(contract_status : string) : unit =
  Prometheus.inc_counter
    Prometheus.metric_keeper_require_tool_use_violations
    ~labels:[
      ("keeper", keeper_name);
      ("has_current_task", if has_current_task then "true" else "false");
      ("contract_status", contract_status);
    ] ()

let actionable_tool_contract_violation_reason
      ~(claim_context_allowed : bool)
      ~(actionable_signal_context : bool)
      ~(tool_names : string list)
  : string option
  =
  if not actionable_signal_context then None
  else
    match tool_names with
    | [] ->
      Some
        "actionable keeper signal was present, but the model called no keeper tools"
    | names when List.exists is_owned_task_progress_tool_name names -> None
    | names
      when (not claim_context_allowed)
           && not (List.exists is_owned_task_progress_tool_name names) ->
      Some
        (Printf.sprintf
           "actionable keeper signal was present for an owned active task, but the model only used passive/claim/stay_silent tools without execution progress: %s"
           (String.concat ", " names))
    | names when List.exists is_stay_silent_tool_name names ->
      Some
        (Printf.sprintf
           "actionable keeper signal was present, but the model used keeper_stay_silent without typed no-work proof: %s"
           (String.concat ", " names))
    | names
      when List.for_all
             (fun name ->
                not (tool_name_can_satisfy_required_contract name))
             names ->
      Some
        (Printf.sprintf
           "actionable keeper signal was present, but the model only used passive status/read tools: %s"
           (String.concat ", " names))
    | names
      when (not claim_context_allowed)
           && List.for_all is_claim_context_tool_name names ->
      Some
        (Printf.sprintf
           "actionable keeper signal was present, but the model only used claim/context tools without execution progress: %s"
           (String.concat ", " names))
    | _ -> None

let normalize_response_text ~(text : string) ~(tool_names : string list) ()
  : (string, string) result
  =
  let trimmed = String.trim text in
  if trimmed <> ""
  then Ok text
  else (
    match tool_names with
    | [] -> Error "keeper turn completed with no textual reply"
    | _ ->
      Ok
        (Printf.sprintf
           "Completed without a textual reply. Tools used: %s."
           (String.concat ", " tool_names)))
;;

let tool_query_text_of_user_message (text : string) : string =
  let allowed_sections =
    [ "### Pending Mentions"
    ; "### Scope Messages"
    ; "### Active Goals"
    ; "### Namespace State"
    ; "### Board Activity"
    ; "### Live Worktree Delta"
    ]
  in
  let is_allowed_section section =
    List.exists
      (fun allowed -> String.starts_with ~prefix:allowed section)
      allowed_sections
  in
  let lines = String.split_on_char '\n' text in
  let rec loop current_section kept = function
    | [] ->
      let filtered = List.rev kept |> String.concat "\n" |> String.trim in
      if filtered <> "" then filtered else String.trim text
    | line :: rest ->
      let trimmed = String.trim line in
      let current_section =
        if String.starts_with ~prefix:"### " trimmed
        then Some trimmed
        else current_section
      in
      let keep_line =
        match current_section with
        | None -> String.starts_with ~prefix:"## Current World State" trimmed
        | Some section -> is_allowed_section section
      in
      if keep_line
      then loop current_section (line :: kept) rest
      else loop current_section kept rest
  in
  loop None [] lines
;;

let contains_any_ci (text : string) (needles : string list) : bool =
  let haystack = String.lowercase_ascii text in
  List.exists
    (fun needle ->
      let needle = String.lowercase_ascii needle in
      let hay_len = String.length haystack in
      let needle_len = String.length needle in
      let rec loop idx =
        if needle_len = 0 then true
        else if idx + needle_len > hay_len then false
        else if String.sub haystack idx needle_len = needle then true
        else loop (idx + 1)
      in
      loop 0)
    needles
;;

let code_context_needles =
  [ "code"; "codebase"; "source code"; "source file"; "repo"; "repository";
    "symbol"; "function"; "class"; "method"; "module"; "implementation";
    "snippet";
    "코드"; "소스코드"; "소스 파일"; "심볼"; "함수"; "클래스"; "모듈";
    "구현" ]
;;

let contains_code_path_hint (query_text : string) : bool =
  contains_any_ci query_text
    [ ".ml"; ".mli"; ".py"; ".ts"; ".tsx"; ".js"; ".jsx"; ".rs"; ".go";
      ".java"; ".kt"; ".c"; ".cc"; ".cpp"; ".h"; ".hpp";
      "lib/"; "src/"; "test/"; "tests/"; "app/"; "bin/" ]
;;

let query_requests_code_search (query_text : string) : bool =
  let search_needles =
    [ "search"; "find"; "grep"; "lookup"; "query"; "where is"; "locate";
      "검색"; "찾"; "grep"; "조회" ]
  in
  contains_any_ci query_text search_needles
  && contains_any_ci query_text code_context_needles
;;

let query_requests_code_read (query_text : string) : bool =
  let read_needles =
    [ "read"; "view"; "open"; "inspect"; "contents"; "content";
      "implementation"; "snippet"; "cat";
      "읽"; "열"; "확인"; "내용" ]
  in
  let read_context_needles =
    [ "source"; "source code"; "source file"; "code"; "function"; "class";
      "method"; "module"; "implementation"; "snippet"; "line";
      "소스"; "소스코드"; "소스 파일"; "코드"; "함수"; "클래스"; "메서드";
      "모듈"; "라인"; "구현" ]
  in
  contains_any_ci query_text read_needles
  && (contains_any_ci query_text read_context_needles
      || contains_code_path_hint query_text)
;;

let query_requests_code_symbols (query_text : string) : bool =
  let symbol_needles =
    [ "symbol"; "symbols"; "function"; "functions"; "class"; "classes";
      "method"; "methods"; "definition"; "definitions"; "outline";
      "structure"; "api surface";
      "심볼"; "함수"; "클래스"; "메서드"; "정의"; "구조" ]
  in
  contains_any_ci query_text symbol_needles
;;

let allow_deterministic_tool ~(query_text : string) (name : string) : bool =
  match name with
  | "masc_code_search" -> query_requests_code_search query_text
  | "masc_code_read" -> query_requests_code_read query_text
  | "masc_code_symbols" -> query_requests_code_symbols query_text
  | _ -> true
;;

let deterministic_prefilter_names
    ~(search_index : Agent_sdk.Tool_index.t)
    ~(query_text : string)
    ~(selection_limit : int)
    ~(core : string list) : string list =
  if selection_limit <= 0 then []
  else
    Agent_sdk.Tool_index.retrieve search_index query_text
    |> List.filter_map (fun (name, _) ->
         if List.mem name core then None
         else if not (allow_deterministic_tool ~query_text name)
         then None
         else Some name)
    |> List.filteri (fun i _ -> i < selection_limit)
;;

let merge_tool_selection_boundary
    ~(core : string list)
    ~(deterministic_prefilter : string list)
    ~(llm_selected : string list)
    ~(discovered : string list) : string list =
  let sorted_discovered = List.sort String.compare discovered in
  (* BM25-relevant tools first: when downstream truncation caps at
     max_tools, the tail is dropped.  Placing deterministic_prefilter
     and discovered before core ensures context-relevant tools survive
     while generic core tools are truncated first.
     Core tools that also appear in deterministic_prefilter are deduped
     (first occurrence wins), so they naturally keep their BM25 rank. *)
  let deterministic_floor =
    Keeper_types.dedupe_keep_order
      (deterministic_prefilter @ sorted_discovered @ core)
  in
  Keeper_types.dedupe_keep_order (deterministic_floor @ llm_selected)

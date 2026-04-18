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

type completion_contract =
  | Allow_text_or_tool
  | Require_tool_use

let completion_contract_of_tool_choice
      (tool_choice : Agent_sdk.Types.tool_choice option)
  : completion_contract
  =
  match tool_choice with
  | Some (Agent_sdk.Types.Any | Agent_sdk.Types.Tool _) -> Require_tool_use
  | _ -> Allow_text_or_tool

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

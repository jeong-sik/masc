(** Provider capability snapshots for pre-dispatch required-tool checks. *)

type t =
  { provider_name : string
  ; satisfying_tools_snapshot : string list option
  ; tool_choice_support : bool option
  }

type unsupported =
  { missing_tools : string list
  ; tool_choice_required : bool
  ; tool_choice_supported : bool option
  }

type decision =
  | Can_satisfy
  | Cannot_satisfy of unsupported
  | Capability_unknown

let unknown ~provider_name =
  { provider_name; satisfying_tools_snapshot = None; tool_choice_support = None }

let strip_mcp_prefix name =
  let prefix = "mcp__" in
  if String.starts_with ~prefix name then
    match String.split_on_char '_' name with
    | "mcp" :: "" :: _server :: "" :: rest when rest <> [] ->
      String.concat "_" rest
    | _ -> name
  else name

let canonical_tool_name name = strip_mcp_prefix (String.trim name)

let dedupe_canonical tools =
  tools |> List.map canonical_tool_name |> Json_util.dedupe_keep_order

let known ~provider_name ~satisfying_tools ~tool_choice_support =
  {
    provider_name;
    satisfying_tools_snapshot = Some (dedupe_canonical satisfying_tools);
    tool_choice_support = Some tool_choice_support;
  }

let missing_required_tools t ~(required_tools : string list) =
  match t.satisfying_tools_snapshot with
  | None -> None
  | Some satisfying_tools ->
    let satisfying_tools = dedupe_canonical satisfying_tools in
    let required_tools = dedupe_canonical required_tools in
    Some
      (List.filter
         (fun required -> not (List.mem required satisfying_tools))
         required_tools)

let decide_required_action ?(require_tool_choice = true) t ~required_tools =
  let missing = missing_required_tools t ~required_tools in
  let tool_choice_blocks =
    require_tool_choice && t.tool_choice_support = Some false
  in
  match missing, tool_choice_blocks, require_tool_choice, t.tool_choice_support with
  | Some missing_tools, _, _, _ when missing_tools <> [] ->
    Cannot_satisfy
      {
        missing_tools;
        tool_choice_required = require_tool_choice;
        tool_choice_supported = t.tool_choice_support;
      }
  | _, true, _, _ ->
    Cannot_satisfy
      {
        missing_tools = [];
        tool_choice_required = true;
        tool_choice_supported = Some false;
      }
  | Some [], _, false, _ -> Can_satisfy
  | Some [], _, true, Some true -> Can_satisfy
  | None, _, false, _ when required_tools = [] -> Can_satisfy
  | None, _, true, Some true when required_tools = [] -> Can_satisfy
  | _ -> Capability_unknown

let can_satisfy_required_action ?require_tool_choice t ~required_tools =
  match decide_required_action ?require_tool_choice t ~required_tools with
  | Can_satisfy -> Some true
  | Cannot_satisfy _ -> Some false
  | Capability_unknown -> None

let filtered_missing_tools t required_tools =
  match missing_required_tools t ~required_tools with
  | Some missing -> missing
  | None -> []

let filter_candidates_for_required_tools
    ?(require_tool_choice = true)
    candidates
    ~required_tools =
  let passed_rev, filtered_rev =
    List.fold_left
      (fun (passed, filtered) candidate ->
        match
          can_satisfy_required_action
            ~require_tool_choice
            candidate
            ~required_tools
        with
        | Some false ->
          let missing = filtered_missing_tools candidate required_tools in
          passed, (candidate, missing) :: filtered
        | Some true | None -> candidate :: passed, filtered)
      ([], [])
      candidates
  in
  List.rev passed_rev, List.rev filtered_rev

let record_pre_dispatch_required_tool_filtered ~provider ~missing_count =
  Prometheus.inc_counter
    Prometheus.metric_cascade_pre_dispatch_required_tool_filtered
    ~labels:[ "provider", provider; "missing_count", string_of_int missing_count ]
    ()

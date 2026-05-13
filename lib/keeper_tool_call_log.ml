(** Keeper_tool_call_log — Full I/O logging for keeper tool calls.

    Persists complete tool call records (input arguments + output text)
    to [.masc/tool_calls/YYYY-MM/DD.jsonl] via {!Dated_jsonl}.

    Unlike {!Tool_usage_log} (metadata only) and {!Tool_metrics_persist}
    (aggregated counts), this module stores the actual I/O for debugging
    and dashboard inspection.

    Output is truncated to {!max_output_len} bytes to prevent disk
    explosion from large tool results (e.g. full file reads).

    @since 2.249.0 — Keeper observability *)

let max_output_len = 4000

(** Pre-truncation info, keyed by keeper name.
    Set by the tool handler wrapper (keeper_tools_oas), consumed by the
    OAS on_tool_result hook (keeper_hooks_oas).  Per-keeper isolation
    prevents cross-keeper corruption when multiple keepers call tools
    concurrently. Within a single keeper's Agent.run, tool calls are
    sequential so set→consume ordering is guaranteed. *)
let pending_truncation : (string, int * int option) Hashtbl.t = Hashtbl.create 8

let handler_logged_mutex = Stdlib.Mutex.create ()
let handler_logged_recent : (string, float) Hashtbl.t = Hashtbl.create 32
let handler_logged_ttl_sec = 300.0

type turn_context =
  { agent_name : string option
  ; lane : string option
  ; tool_choice : string option
  ; thinking_enabled : bool option
  ; thinking_budget : int option
  ; prompt_fingerprint : string option
  ; trace_id : string option
  ; session_id : string option
  ; generation : int option
  ; turn : int option
  ; keeper_turn_id : int option
  ; task_id : string option
  ; goal_ids : string list option
  ; sandbox_profile : string option
  ; sandbox_root : string option
  ; allowed_paths : string list option
  ; network_mode : string option
  ; approval_mode : string option
  ; tool_surface_class : string option
  ; visible_tool_count : int option
  ; required_tools : string list option
  ; missing_required_tools : string list option
  ; cascade_profile : string option
  }

let empty_turn_context =
  { agent_name = None
  ; lane = None
  ; tool_choice = None
  ; thinking_enabled = None
  ; thinking_budget = None
  ; prompt_fingerprint = None
  ; trace_id = None
  ; session_id = None
  ; generation = None
  ; turn = None
  ; keeper_turn_id = None
  ; task_id = None
  ; goal_ids = None
  ; sandbox_profile = None
  ; sandbox_root = None
  ; allowed_paths = None
  ; network_mode = None
  ; approval_mode = None
  ; tool_surface_class = None
  ; visible_tool_count = None
  ; required_tools = None
  ; missing_required_tools = None
  ; cascade_profile = None
  }
;;

let pending_turn_context : (string, turn_context) Hashtbl.t = Hashtbl.create 8

let handler_logged_key ~keeper_name ~tool_name ~output_text ~success =
  let canonical_tool_name =
    match Keeper_tool_alias.route tool_name with
    | Some r -> r.internal_name
    | None -> tool_name
  in
  Printf.sprintf
    "%s\000%s\000%b\000%d"
    keeper_name
    canonical_tool_name
    success
    (Hashtbl.hash output_text)
;;

let remember_handler_logged ~keeper_name ~tool_name ~output_text ~success () =
  let key = handler_logged_key ~keeper_name ~tool_name ~output_text ~success in
  let now = Time_compat.now () in
  Stdlib.Mutex.protect handler_logged_mutex (fun () ->
    let stale =
      Hashtbl.fold
        (fun key ts acc -> if now -. ts > handler_logged_ttl_sec then key :: acc else acc)
        handler_logged_recent
        []
    in
    List.iter (Hashtbl.remove handler_logged_recent) stale;
    Hashtbl.replace handler_logged_recent key now)
;;

let consume_handler_logged ~keeper_name ~tool_name ~output_text ~success () =
  let key = handler_logged_key ~keeper_name ~tool_name ~output_text ~success in
  let now = Time_compat.now () in
  Stdlib.Mutex.protect handler_logged_mutex (fun () ->
    match Hashtbl.find_opt handler_logged_recent key with
    | Some ts when now -. ts <= handler_logged_ttl_sec ->
      Hashtbl.remove handler_logged_recent key;
      true
    | Some _ ->
      Hashtbl.remove handler_logged_recent key;
      false
    | None -> false)
;;

let set_truncation_info ~keeper_name ~original_bytes ?truncated_to () =
  Hashtbl.replace pending_truncation keeper_name (original_bytes, truncated_to)
;;

let consume_truncation_info ~keeper_name () =
  match Hashtbl.find_opt pending_truncation keeper_name with
  | Some info ->
    Hashtbl.remove pending_truncation keeper_name;
    info
  | None -> 0, None
;;

let set_turn_context
      ~keeper_name
      ?agent_name
      ?lane
      ?tool_choice
      ?thinking_enabled
      ?thinking_budget
      ?prompt_fingerprint
      ?trace_id
      ?session_id
      ?generation
      ?turn
      ?keeper_turn_id
      ?task_id
      ?goal_ids
      ?sandbox_profile
      ?sandbox_root
      ?allowed_paths
      ?network_mode
      ?approval_mode
      ?tool_surface_class
      ?visible_tool_count
      ?required_tools
      ?missing_required_tools
      ?cascade_profile
      ()
  =
  Hashtbl.replace
    pending_turn_context
    keeper_name
    { agent_name
    ; lane
    ; tool_choice
    ; thinking_enabled
    ; thinking_budget
    ; prompt_fingerprint
    ; trace_id
    ; session_id
    ; generation
    ; turn
    ; keeper_turn_id
    ; task_id
    ; goal_ids
    ; sandbox_profile
    ; sandbox_root
    ; allowed_paths
    ; network_mode
    ; approval_mode
    ; tool_surface_class
    ; visible_tool_count
    ; required_tools
    ; missing_required_tools
    ; cascade_profile
    }
;;

let get_turn_context_record ~keeper_name () =
  match Hashtbl.find_opt pending_turn_context keeper_name with
  | Some ctx -> ctx
  | None -> empty_turn_context
;;

let get_turn_context ~keeper_name () =
  let ctx = get_turn_context_record ~keeper_name () in
  ( ctx.lane
  , ctx.tool_choice
  , ctx.thinking_enabled
  , ctx.thinking_budget
  , ctx.prompt_fingerprint
  , ctx.trace_id
  , ctx.session_id
  , ctx.turn
  , ctx.keeper_turn_id
  , ctx.task_id
  , ctx.goal_ids
  , ctx.sandbox_profile
  , ctx.network_mode
  , ctx.approval_mode )
;;

let optional_model model =
  match model with
  | Some value when String.trim value <> "" -> Some value
  | _ -> None
;;

let runtime_contract_json_for_call ~keeper_name ?model () =
  let ctx = get_turn_context_record ~keeper_name () in
  Keeper_runtime_contract.runtime_contract_json_from_fields
    ~keeper_name
    ?agent_name:ctx.agent_name
    ?trace_id:ctx.trace_id
    ?session_id:ctx.session_id
    ?generation:ctx.generation
    ?keeper_turn_id:ctx.keeper_turn_id
    ?task_id:ctx.task_id
    ?goal_ids:ctx.goal_ids
    ?sandbox_profile:ctx.sandbox_profile
    ?sandbox_root:ctx.sandbox_root
    ?allowed_paths:ctx.allowed_paths
    ?network_mode:ctx.network_mode
    ?approval_mode:ctx.approval_mode
    ?tool_surface_class:ctx.tool_surface_class
    ?visible_tool_count:ctx.visible_tool_count
    ?required_tools:ctx.required_tools
    ?missing_required_tools:ctx.missing_required_tools
    ?model:(optional_model model)
    ?cascade_profile:ctx.cascade_profile
    ()
;;

let action_radius_json_for_call
      ~keeper_name
      ~tool_name
      ~input
      ~success
      ~duration_ms
      ?error
      ()
  =
  let ctx = get_turn_context_record ~keeper_name () in
  Keeper_runtime_contract.action_radius_json
    ~tool_name
    ~input
    ~success
    ~duration_ms
    ?error
    ?sandbox_target:ctx.sandbox_profile
    ()
;;

let assoc_opt = function
  | `Assoc fields -> Some fields
  | _ -> None
;;

let assoc_member_opt name = function
  | `Assoc fields -> List.assoc_opt name fields
  | _ -> None
;;

let assoc_string_opt name json =
  match assoc_member_opt name json with
  | Some (`String value) when String.trim value <> "" -> Some value
  | _ -> None
;;

let assoc_bool_opt name json =
  match assoc_member_opt name json with
  | Some (`Bool value) -> Some value
  | _ -> None
;;

let route_candidate_has_fields json =
  match assoc_opt json with
  | None -> false
  | Some fields ->
    List.exists
      (fun (name, _) ->
         List.mem
           name
           [ "via"
           ; "sandbox_profile"
           ; "git_creds_enabled"
           ; "network_mode"
           ; "status"
           ; "effective_sandbox_image"
           ])
      fields
;;

let route_candidate_of_output json =
  if route_candidate_has_fields json
  then Some json
  else (
    match assoc_member_opt "result" json with
    | Some result when route_candidate_has_fields result -> Some result
    | _ ->
      (match assoc_member_opt "detail" json with
       | Some detail when route_candidate_has_fields detail -> Some detail
       | _ -> None))
;;

let find_substring ~needle haystack =
  let needle_len = String.length needle in
  let haystack_len = String.length haystack in
  if needle_len = 0
  then Some 0
  else (
    let rec loop idx =
      if idx + needle_len > haystack_len
      then None
      else if String.sub haystack idx needle_len = needle
      then Some idx
      else loop (idx + 1)
    in
    loop 0)
;;

let github_pull_url_of_text text =
  match find_substring ~needle:"https://github.com/" text with
  | None -> None
  | Some start ->
    let len = String.length text in
    let rec stop idx =
      if idx >= len
      then idx
      else (
        match text.[idx] with
        | ' ' | '\n' | '\r' | '\t' | '"' | '\'' | ')' | ']' -> idx
        | _ -> stop (idx + 1))
    in
    let finish = stop start in
    let url = String.sub text start (finish - start) in
    if find_substring ~needle:"/pull/" url |> Option.is_some then Some url else None
;;

let route_output_url output_json output_text =
  match assoc_string_opt "url" output_json with
  | Some url when find_substring ~needle:"/pull/" url |> Option.is_some -> Some url
  | _ -> github_pull_url_of_text output_text
;;

let route_safe_input_string value =
  Option.map (Observability_redact.redact_preview ~max_len:max_output_len) value
;;

let route_text_for_evidence output_text =
  match Tool_output.decode_from_oas output_text with
  | Tool_output.Stored { preview; _ } -> preview
  | Tool_output.Inline value -> value
;;

let route_evidence_json_of_tool_io ~tool_name ~input ~output_text =
  let route_text = route_text_for_evidence output_text in
  let parsed_output =
    match
      Safe_ops.parse_json_safe ~context:"Keeper_tool_call_log.route_evidence" route_text
    with
    | Ok json -> Some json
    | Error _ -> None
  in
  let route_json =
    match parsed_output with
    | Some json -> route_candidate_of_output json
    | None -> None
  in
  let command =
    match assoc_string_opt "cmd" input with
    | Some cmd -> Some cmd
    | None -> assoc_string_opt "op" input
  in
  let add_string name value fields =
    match value with
    | Some value -> (name, `String value) :: fields
    | None -> fields
  in
  let add_bool name value fields =
    match value with
    | Some value -> (name, `Bool value) :: fields
    | None -> fields
  in
  let add_json name value fields =
    match value with
    | Some value -> (name, value) :: fields
    | None -> fields
  in
  let output_json = Option.value ~default:(`Assoc []) route_json in
  let pr_url =
    match parsed_output with
    | Some json -> route_output_url json route_text
    | None -> github_pull_url_of_text route_text
  in
  if Option.is_none route_json && Option.is_none pr_url
  then None
  else (
    let fields =
      []
      |> add_string "pr_url" pr_url
      |> add_json
           "status"
           (Option.map
              (Observability_redact.preview_json_strings ~max_len:max_output_len)
              (assoc_member_opt "status" output_json))
      |> add_string
           "effective_sandbox_image"
           (assoc_string_opt "effective_sandbox_image" output_json)
      |> add_string "network_mode" (assoc_string_opt "network_mode" output_json)
      |> add_bool "git_creds_enabled" (assoc_bool_opt "git_creds_enabled" output_json)
      |> add_string "sandbox_profile" (assoc_string_opt "sandbox_profile" output_json)
      |> add_string "via" (assoc_string_opt "via" output_json)
      |> add_string "path" (route_safe_input_string (assoc_string_opt "path" input))
      |> add_string "cwd" (route_safe_input_string (assoc_string_opt "cwd" input))
      |> add_string "command" (route_safe_input_string command)
      |> add_string "tool_name" (Some tool_name)
    in
    match fields with
    | [ ("tool_name", _) ] -> None
    | _ -> Some (`Assoc (List.rev fields)))
;;

let store_ref : Dated_jsonl.t option ref = ref None
let configured_store_ref : (string * string) option ref = ref None

let init ?cluster_name ~base_path () =
  let cluster_name =
    Option.value ~default:(Env_config_core.cluster_name ()) cluster_name
  in
  let masc_root = Coord_utils.masc_root_dir_from ~base_path ~cluster_name in
  let dir = Filename.concat masc_root "tool_calls" in
  configured_store_ref := Some (masc_root, dir);
  try
    let store = Dated_jsonl.create ~base_dir:dir () in
    store_ref := Some store
  with
  | Eio.Cancel.Cancelled _ as e -> raise e
  | exn ->
    store_ref := None;
    Log.Misc.warn "keeper_tool_call_log: init failed: %s" (Printexc.to_string exn);
    (try
       Telemetry_coverage_gap.record
         ~masc_root
         ~source:"tool_call_io"
         ~producer:"keeper_tool_call_log.init"
         ~durable_store:dir
         ~dashboard_surface:"/api/v1/keepers/:name/tool-calls"
         ~stale_reason:"tool_call_io_init_failed"
         ~error:(Printexc.to_string exn)
         ()
     with
     | Eio.Cancel.Cancelled _ as cancel -> raise cancel
     | gap_exn ->
       Log.Misc.warn
         "keeper_tool_call_log: init coverage gap append failed: %s"
         (Printexc.to_string gap_exn))
;;

let reset_for_testing () =
  store_ref := None;
  configured_store_ref := None;
  Hashtbl.reset pending_truncation;
  Hashtbl.reset pending_turn_context;
  Stdlib.Mutex.protect handler_logged_mutex (fun () ->
    Hashtbl.reset handler_logged_recent)
;;

let store_dir () =
  match !store_ref with
  | Some store -> Some (Dated_jsonl.base_dir store)
  | None -> None
;;

let current_log_path () =
  match store_dir () with
  | None -> None
  | Some dir ->
    let tm = Unix.gmtime (Unix.gettimeofday ()) in
    let month =
      Printf.sprintf "%04d-%02d" (tm.Unix.tm_year + 1900) (tm.Unix.tm_mon + 1)
    in
    let day = Printf.sprintf "%02d.jsonl" tm.Unix.tm_mday in
    Some (Filename.concat (Filename.concat dir month) day)
;;

let configured_masc_root () = Option.map fst !configured_store_ref

let record_append_coverage_gap ~store ~keeper_name ~tool_name ?trace_id exn =
  let durable_store = Dated_jsonl.base_dir store in
  let masc_root = Filename.dirname durable_store in
  try
    Telemetry_coverage_gap.record
      ~masc_root
      ~source:"tool_call_io"
      ~producer:"keeper_hooks_oas|mcp_server_eio_call_tool"
      ~durable_store
      ~dashboard_surface:"/api/v1/keepers/:name/tool-calls"
      ~stale_reason:"tool_call_io_append_failed"
      ~keeper_name
      ?trace_id
      ~error:(Printf.sprintf "%s/%s: %s" keeper_name tool_name (Printexc.to_string exn))
      ()
  with
  | Eio.Cancel.Cancelled _ as cancel -> raise cancel
  | gap_exn ->
    Log.Misc.warn
      "keeper_tool_call_log: coverage gap append failed for %s/%s: %s"
      keeper_name
      tool_name
      (Printexc.to_string gap_exn)
;;

let record_unavailable_coverage_gap ~keeper_name ~tool_name ?trace_id () =
  match !configured_store_ref with
  | None -> ()
  | Some (masc_root, durable_store) ->
    (try
       Telemetry_coverage_gap.record
         ~masc_root
         ~source:"tool_call_io"
         ~producer:"keeper_hooks_oas|mcp_server_eio_call_tool"
         ~durable_store
         ~dashboard_surface:"/api/v1/keepers/:name/tool-calls"
         ~stale_reason:"tool_call_io_store_unavailable"
         ~keeper_name
         ?trace_id
         ~error:
           (Printf.sprintf "%s/%s: tool call store unavailable" keeper_name tool_name)
         ()
     with
     | Eio.Cancel.Cancelled _ as cancel -> raise cancel
     | gap_exn ->
       Log.Misc.warn
         "keeper_tool_call_log: unavailable coverage gap append failed for %s/%s: %s"
         keeper_name
         tool_name
         (Printexc.to_string gap_exn))
;;

(** [blob_aware_output_json safe_output] wraps a tool-output string for
    persistence as the [output] field. When [safe_output] is the OCaml
    [%S]-quoted [masc:blob ...] sentinel produced by
    [Tool_output.encode_for_oas], the wire format escapes the inner
    preview JSON twice (OCaml string-literal + JSON string), which makes
    the telemetry record illegible and inflates disk usage by 30-40%.

    We decode the sentinel and emit a structured object instead:
      {"_blob": {"sha256":"...", "bytes":N, "mime":"...", "preview":"..."}}

    Non-sentinel outputs keep the historical [String _] shape so that
    older readers (dashboard, jq scripts) keep working. The dashboard
    consumers are updated in the same change to accept either shape. *)
let blob_aware_output_json (output : string) : Yojson.Safe.t =
  match Tool_output.decode_from_oas output with
  | Tool_output.Stored { sha256; bytes; preview; mime } ->
    `Assoc
      [ ( "_blob"
        , `Assoc
            [ "sha256", `String sha256
            ; "bytes", `Int bytes
            ; "mime", `String mime
            ; "preview", `String preview
            ] )
      ]
  | Tool_output.Inline _ -> `String output
;;

let semantic_outcome_of_output ~success output =
  match
    Safe_ops.parse_json_safe ~context:"Keeper_tool_call_log.semantic_outcome" output
  with
  | Ok json ->
    let ok_field = Safe_ops.json_bool_opt "ok" json in
    let error_field = Safe_ops.json_string_opt "error" json |> Option.map String.trim in
    (match error_field with
     | Some "tool_not_allowed" -> false, "policy_denied"
     | Some error when error <> "" -> false, "structured_error"
     | _ ->
       (match ok_field with
        | Some false -> false, "structured_error"
        | Some true -> success, if success then "success" else "tool_failure"
        | None -> if success then true, "success" else false, "tool_failure"))
  | Error _ -> if success then true, "success" else false, "tool_failure"
;;

let input_to_json (input : Yojson.Safe.t) : Yojson.Safe.t =
  (* Per-leaf sentinel-aware truncation. Previously
     [String.sub (Yojson.Safe.to_string input) 0 (max - suffix)] chopped
     through a [masc:blob ...] marker embedded in a nested JSON string
     value and stranded sha256/bytes/mime halfway, breaking the keeper
     artifact hydrator on replay. *)
  let input = Observability_redact.preview_json_strings ~max_len:max_output_len input in
  let s = Yojson.Safe.to_string input in
  if String.length s > max_output_len
  then `String (Observability_redact.redact_preview ~max_len:max_output_len s)
  else input
;;

let log_call
      ~keeper_name
      ~tool_name
      ~(input : Yojson.Safe.t)
      ~(output_text : string)
      ~(success : bool)
      ~(duration_ms : float)
      ?(model : string = "")
      ?agent_name
      ?lane
      ?tool_choice
      ?thinking_enabled
      ?thinking_budget
      ?prompt_fingerprint
      ?trace_id
      ?session_id
      ?generation
      ?turn
      ?keeper_turn_id
      ?task_id
      ?goal_ids
      ?sandbox_profile
      ?sandbox_root
      ?allowed_paths
      ?network_mode
      ?approval_mode
      ?tool_surface_class
      ?visible_tool_count
      ?required_tools
      ?missing_required_tools
      ?cascade_profile
      ?result_bytes
      ?truncated_to
      ()
  =
  if Observability_redact.is_denied_tool ~tool_name
  then ()
  else (
    match !store_ref with
    | None -> record_unavailable_coverage_gap ~keeper_name ~tool_name ?trace_id ()
    | Some store ->
      let ctx = get_turn_context_record ~keeper_name () in
      let ( ctx_lane
          , ctx_tool_choice
          , ctx_thinking_enabled
          , ctx_thinking_budget
          , ctx_prompt_fingerprint
          , ctx_trace_id
          , ctx_session_id
          , ctx_turn
          , ctx_keeper_turn_id
          , ctx_task_id
          , ctx_goal_ids
          , ctx_sandbox_profile
          , ctx_network_mode
          , ctx_approval_mode )
        =
        get_turn_context ~keeper_name ()
      in
      let lane =
        match lane with
        | Some _ -> lane
        | None -> ctx_lane
      in
      let tool_choice =
        match tool_choice with
        | Some _ -> tool_choice
        | None -> ctx_tool_choice
      in
      let thinking_enabled =
        match thinking_enabled with
        | Some _ -> thinking_enabled
        | None -> ctx_thinking_enabled
      in
      let thinking_budget =
        match thinking_budget with
        | Some _ -> thinking_budget
        | None -> ctx_thinking_budget
      in
      let prompt_fingerprint =
        match prompt_fingerprint with
        | Some _ -> prompt_fingerprint
        | None -> ctx_prompt_fingerprint
      in
      let trace_id =
        match trace_id with
        | Some _ -> trace_id
        | None -> ctx_trace_id
      in
      let session_id =
        match session_id with
        | Some _ -> session_id
        | None -> ctx_session_id
      in
      let turn =
        match turn with
        | Some _ -> turn
        | None -> ctx_turn
      in
      let keeper_turn_id =
        match keeper_turn_id with
        | Some _ -> keeper_turn_id
        | None -> ctx_keeper_turn_id
      in
      let task_id =
        match task_id with
        | Some _ -> task_id
        | None -> ctx_task_id
      in
      let goal_ids =
        match goal_ids with
        | Some _ -> goal_ids
        | None -> ctx_goal_ids
      in
      let sandbox_profile =
        match sandbox_profile with
        | Some _ -> sandbox_profile
        | None -> ctx_sandbox_profile
      in
      let network_mode =
        match network_mode with
        | Some _ -> network_mode
        | None -> ctx_network_mode
      in
      let approval_mode =
        match approval_mode with
        | Some _ -> approval_mode
        | None -> ctx_approval_mode
      in
      let agent_name =
        match agent_name with
        | Some _ -> agent_name
        | None -> ctx.agent_name
      in
      let generation =
        match generation with
        | Some _ -> generation
        | None -> ctx.generation
      in
      let sandbox_root =
        match sandbox_root with
        | Some _ -> sandbox_root
        | None -> ctx.sandbox_root
      in
      let allowed_paths =
        match allowed_paths with
        | Some _ -> allowed_paths
        | None -> ctx.allowed_paths
      in
      let tool_surface_class =
        match tool_surface_class with
        | Some _ -> tool_surface_class
        | None -> ctx.tool_surface_class
      in
      let visible_tool_count =
        match visible_tool_count with
        | Some _ -> visible_tool_count
        | None -> ctx.visible_tool_count
      in
      let required_tools =
        match required_tools with
        | Some _ -> required_tools
        | None -> ctx.required_tools
      in
      let missing_required_tools =
        match missing_required_tools with
        | Some _ -> missing_required_tools
        | None -> ctx.missing_required_tools
      in
      let cascade_profile =
        match cascade_profile with
        | Some _ -> cascade_profile
        | None -> ctx.cascade_profile
      in
      let model_field =
        if model = "" then [] else [ "model", `String "runtime" ]
      in
      let result_bytes_field =
        match result_bytes with
        | Some n -> [ "result_bytes", `Int n ]
        | None -> []
      in
      let truncated_to_field =
        match truncated_to with
        | Some n -> [ "truncated_to", `Int n ]
        | None -> []
      in
      let lane_field =
        match lane with
        | Some value -> [ "lane", `String value ]
        | None -> []
      in
      let tool_choice_field =
        match tool_choice with
        | Some value -> [ "tool_choice", `String value ]
        | None -> []
      in
      let thinking_enabled_field =
        match thinking_enabled with
        | Some value -> [ "thinking_enabled", `Bool value ]
        | None -> []
      in
      let thinking_budget_field =
        match thinking_budget with
        | Some value -> [ "thinking_budget", `Int value ]
        | None -> []
      in
      let prompt_fingerprint_field =
        match prompt_fingerprint with
        | Some value -> [ "prompt_fingerprint", `String value ]
        | None -> []
      in
      let trace_id_field =
        match trace_id with
        | Some value -> [ "trace_id", `String value ]
        | None -> []
      in
      let session_id_field =
        match session_id with
        | Some value -> [ "session_id", `String value ]
        | None -> []
      in
      let turn_field =
        match turn with
        | Some value -> [ "turn", `Int value ]
        | None -> []
      in
      let keeper_turn_id_field =
        match keeper_turn_id with
        | Some value -> [ "keeper_turn_id", `Int value ]
        | None -> []
      in
      let task_id_field =
        match task_id with
        | Some value -> [ "task_id", `String value ]
        | None -> []
      in
      let goal_ids_field =
        match goal_ids with
        | Some values ->
          [ "goal_ids", `List (List.map (fun value -> `String value) values) ]
        | None -> []
      in
      let sandbox_profile_field =
        match sandbox_profile with
        | Some value -> [ "sandbox_profile", `String value ]
        | None -> []
      in
      let network_mode_field =
        match network_mode with
        | Some value -> [ "network_mode", `String value ]
        | None -> []
      in
      let approval_mode_field =
        match approval_mode with
        | Some value -> [ "approval_mode", `String value ]
        | None -> []
      in
      let safe_input = input_to_json (Observability_redact.redact_json_value input) in
      let safe_output =
        Observability_redact.redact_preview ~max_len:max_output_len output_text
      in
      let output_json = blob_aware_output_json safe_output in
      let semantic_success, semantic_outcome =
        semantic_outcome_of_output ~success safe_output
      in
      let model_opt = optional_model (Some model) in
      let runtime_contract =
        Keeper_runtime_contract.runtime_contract_json_from_fields
          ~keeper_name
          ?agent_name
          ?trace_id
          ?session_id
          ?generation
          ?keeper_turn_id
          ?task_id
          ?goal_ids
          ?sandbox_profile
          ?sandbox_root
          ?allowed_paths
          ?network_mode
          ?approval_mode
          ?tool_surface_class
          ?visible_tool_count
          ?required_tools
          ?missing_required_tools
          ?model:model_opt
          ?cascade_profile
          ()
      in
      let error = if success then None else Some safe_output in
      let action_radius =
        Keeper_runtime_contract.action_radius_json
          ~tool_name
          ~input:safe_input
          ~success
          ~duration_ms
          ?error
          ?sandbox_target:sandbox_profile
          ()
      in
      let route_evidence_field =
        match
          route_evidence_json_of_tool_io ~tool_name ~input:safe_input ~output_text
        with
        | Some evidence -> [ "route_evidence", evidence ]
        | None -> []
      in
      let json =
        `Assoc
          ([ "ts", `Float (Time_compat.now ())
           ; "keeper", `String keeper_name
           ; "tool", `String tool_name
           ; "input", safe_input
           ; "output", output_json
           ; "success", `Bool success
           ; "semantic_success", `Bool semantic_success
           ; "semantic_outcome", `String semantic_outcome
           ; "duration_ms", `Float duration_ms
           ; "runtime_contract", runtime_contract
           ; "action_radius", action_radius
           ]
           @ route_evidence_field
           @ model_field
           @ lane_field
           @ tool_choice_field
           @ thinking_enabled_field
           @ thinking_budget_field
           @ prompt_fingerprint_field
           @ trace_id_field
           @ session_id_field
           @ turn_field
           @ keeper_turn_id_field
           @ task_id_field
           @ goal_ids_field
           @ sandbox_profile_field
           @ network_mode_field
           @ approval_mode_field
           @ result_bytes_field
           @ truncated_to_field)
      in
      (* Sanitize UTF-8 before persisting.  Tool output may contain invalid
         byte sequences (truncated UTF-8, binary output from subprocess
         captures) that would corrupt the JSONL file and cause downstream
         readers — including the dashboard — to silently skip entire rows. *)
      let safe_json = Inference_utils.sanitize_json_utf8 json in
      (try Dated_jsonl.append store safe_json with
       | Eio.Cancel.Cancelled _ as e -> raise e
       | exn ->
         Log.Misc.warn
           "keeper_tool_call_log: append failed for %s/%s: %s"
           keeper_name
           tool_name
           (Printexc.to_string exn);
         record_append_coverage_gap ~store ~keeper_name ~tool_name ?trace_id exn))
;;

let read_recent ?keeper_name ?(n = 100) () : Yojson.Safe.t list =
  if n <= 0
  then []
  else (
    match !store_ref with
    | None -> []
    | Some store ->
      let keeper_matches name json =
        match Safe_ops.json_string_opt "keeper" json with
        | Some k -> String.equal k name
        | None -> false
      in
      (* Single-pass: read from store, filter, and collect last n in one traversal *)
      let raw = Dated_jsonl.read_recent store (n * 5) in
      let buf = Array.make n (`Null : Yojson.Safe.t) in
      let pos = ref 0 in
      let total = ref 0 in
      List.iter
        (fun json ->
           let dominated =
             match keeper_name with
             | None -> true
             | Some name -> keeper_matches name json
           in
           if dominated
           then (
             buf.(!pos mod n) <- json;
             incr pos;
             incr total))
        raw;
      let count = min !total n in
      if count = 0
      then []
      else (
        let start = if !total <= n then 0 else !pos mod n in
        List.init count (fun i -> buf.((start + i) mod n))))
;;

let iso_date_of_unix ts =
  let tm = Unix.gmtime ts in
  Printf.sprintf
    "%04d-%02d-%02d"
    (tm.Unix.tm_year + 1900)
    (tm.Unix.tm_mon + 1)
    tm.Unix.tm_mday
;;

let ts_of_entry (json : Yojson.Safe.t) : float option =
  match json with
  | `Assoc fields ->
    (match List.assoc_opt "ts" fields with
     | Some (`Float f) -> Some f
     | Some (`Int i) -> Some (Float.of_int i)
     | _ -> None)
  | _ -> None
;;

let read_window ?keeper_name ~(window_hours : float) () : Yojson.Safe.t list =
  if window_hours <= 0.0
  then []
  else (
    match !store_ref with
    | None -> []
    | Some store ->
      let now = Time_compat.now () in
      let since_ts = now -. (window_hours *. 3600.0) in
      let since_date = iso_date_of_unix since_ts in
      let until_date = iso_date_of_unix now in
      let keeper_matches name json =
        match Safe_ops.json_string_opt "keeper" json with
        | Some k -> String.equal k name
        | None -> false
      in
      Dated_jsonl.read_range store ~since:since_date ~until:until_date
      |> List.filter (fun json ->
        let in_window =
          match ts_of_entry json with
          | Some ts -> ts >= since_ts
          | None -> false
        in
        in_window
        &&
        match keeper_name with
        | None -> true
        | Some name -> keeper_matches name json))
;;

let read_latest ?keeper_name () : Yojson.Safe.t option =
  let keeper_matches name json =
    match Safe_ops.json_string_opt "keeper" json with
    | Some k -> String.equal k name
    | None -> false
  in
  match !store_ref with
  | None -> None
  | Some store ->
    let scan_limit =
      match keeper_name with
      | None -> 1
      | Some _ -> 16
    in
    let raw_lines = Dated_jsonl.read_recent_lines store scan_limit in
    let rec loop = function
      | [] -> None
      | line :: rest ->
        (match Yojson.Safe.from_string line with
         | exception Yojson.Json_error _ -> loop rest
         | json ->
           let dominated =
             match keeper_name with
             | None -> true
             | Some name -> keeper_matches name json
           in
           if dominated then Some json else loop rest)
    in
    loop (List.rev raw_lines)
;;

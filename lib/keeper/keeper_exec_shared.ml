open Keeper_types
open Keeper_alerting
module StringMap = Set_util.StringMap

let count_context_tokens (ctx : working_context) = Keeper_exec_context.token_count ctx

let has_json_field name fields =
  List.exists (fun (field, _) -> String.equal field name) fields
;;

let inferred_failure_class_fields message fields =
  if has_json_field "failure_class" fields
  then []
  else if String_util.contains_substring message "sandbox_image_missing"
  then [ "failure_class", `String "policy_rejection" ]
  else []
;;

let error_json ?(fields = []) (message : string) =
  let fields = inferred_failure_class_fields message fields @ fields in
  Yojson.Safe.to_string (`Assoc (("error", `String message) :: fields))
;;

let tool_result_error_json (tr : Tool_result.t) =
  let fields =
    match Tool_result.failure_class tr with
    | None -> []
    | Some cls ->
      [ "failure_class", `String (Tool_result.tool_failure_class_to_string cls) ]
  in
  error_json ~fields (Tool_result.message tr)
;;

let tool_result_or_error (tr : Tool_result.t) =
  let ok = tr.success in
  let msg = Tool_result.message tr in
  if ok then msg else tool_result_error_json tr
;;

(** Phase B PR-5 precursor (2026-04-28): the action mapping itself,
    parameterised by the typed [Keeper_failure_circuit_breaker.error_class].
    Callers that already hold a typed class (sandbox / shell typed
    error paths in Phase B PR-5) call this directly and skip the
    string → class round-trip entirely.  String-only callers go through
    [actionable_path_error] below, which classifies once and delegates. *)
let actionable_path_action_for_class
      ~(playground : string)
      ~(raw_path : string)
      (cls : Keeper_failure_circuit_breaker.error_class)
  : string
  =
  if String.length raw_path = 0
  then "Provide a path. Your playground root is " ^ playground
  else (
    match cls with
    | Path_not_found ->
      Printf.sprintf
        "File does not exist. Use Bash executable='ls' argv=['%s'] first to see available \
         files, or use a visible file-listing tool if one is present."
        playground
    | Path_not_allowed ->
      Printf.sprintf
        "Path is outside your allowed roots. Stay inside %s or use keeper_context_status \
         to see allowed paths."
        playground
    | Cwd_not_directory ->
      "The cwd is not a directory. Omit cwd to use your default playground root, or \
       create/repair the repo worktree first with the visible clone/worktree tool, then \
       masc_worktree_create for repos/<repo>/.worktrees/<task>."
    | Shell_exit_nonzero | Other ->
      Printf.sprintf "Check the path. Your playground: %s" playground)
;;

(** Actionable error for path resolution failures.
    Follows Samchon harness pattern: field-level diagnostics with
    exact path, expected constraint, and concrete next action.
    Claude Code pattern: validateInput returns actionable guidance.

    Phase A F4 (2026-04-27): the error → action mapping dispatches on
    the typed [Keeper_failure_circuit_breaker.error_class] instead of a
    parallel [contains_substring] ladder.  String-matching collapses
    from two sites (here + circuit_breaker) to one (the SSOT).

    Phase B PR-5 precursor (2026-04-28): the action mapping is now
    parameterised on the typed class via
    [actionable_path_action_for_class].  This keeps the string-input
    entry point (for callers that only have a raw error message) but
    exposes the typed mapping so Phase B PR-5 can route typed callers
    directly without a redundant classify pass. *)
let actionable_path_error
      ~(op : string)
      ~(meta : keeper_meta)
      ~(raw_path : string)
      ~(error : string)
  =
  let playground = Keeper_sandbox.allowed_root_rel_of_meta ~meta in
  let cls = Keeper_failure_circuit_breaker.classify_error error in
  let action = actionable_path_action_for_class ~playground ~raw_path cls in
  Yojson.Safe.to_string
    (`Assoc
        [ "ok", `Bool false
        ; "op", `String op
        ; "error", `String error
        ; "tried", `String raw_path
        ; "your_playground", `String playground
        ; "action", `String action
        ])
;;

let file_not_found_prefix = "File not found:"

let missing_file_error_json
      ~(config : Coord.config)
      ~(target : string)
      ~(fallback_dir : string)
      ~(error : string)
  =
  ignore (config, fallback_dir);
  (* #10349: do NOT echo directory entries back to the LLM.  When keeper
     identity drifts, the resolved parent may belong to a sibling sandbox,
     and listing its contents leaks its directory layout (oracle leak).
     The generic error string already contains the path that was tried,
     which is sufficient for the LLM to self-correct. *)
  Yojson.Safe.to_string
    (`Assoc [ "ok", `Bool false; "error", `String error; "path", `String target ])
;;

let find_registry_meta ~(keeper_name : string) ~(source_layer : string)
  : Keeper_types.keeper_meta option
  =
  match Keeper_registry_lookup.find_by_name keeper_name with
  | None ->
    Prometheus.inc_counter
      Keeper_metrics.metric_keeper_path_resolver_identity_mismatch
      ~labels:[ "source_layer", source_layer; "field", "registry_missing" ]
      ();
    None
  | Some entry ->
    if not (String.equal entry.meta.name keeper_name) then
      Prometheus.inc_counter
        Keeper_metrics.metric_keeper_path_resolver_identity_mismatch
        ~labels:[ "source_layer", source_layer; "field", "name_mismatch" ]
        ();
    Some entry.meta
;;

let with_registry_meta ~(keeper_name : string) ~(source_layer : string) f =
  match find_registry_meta ~keeper_name ~source_layer with
  | None ->
    error_json (Printf.sprintf "keeper not found in registry: %s" keeper_name)
  | Some meta -> f meta
;;

let assoc_override_string (key : string) (value : string) = function
  | `Assoc fields ->
    let kept_fields = List.filter (fun (k, _) -> k <> key) fields in
    `Assoc ((key, `String value) :: kept_fields)
  | other -> other
;;

(** Path resolution helpers extracted to [Keeper_exec_shared_path].
    JSON helpers, registry helpers, and tool list below. *)

include Keeper_exec_shared_path

let keeper_agent_sender ~(meta : keeper_meta) = meta.agent_name

let shell_readonly_limit args =
  max 1 (min 200 (Safe_ops.json_int ~default:40 "limit" args))
;;

let shell_readonly_cat_max_bytes args =
  max 256 (min 100000 (Safe_ops.json_int ~default:4000 "max_bytes" args))
;;

let lines_to_json ?(limit = max_int) ?(max_bytes = 32_000) (text : string) : Yojson.Safe.t
  =
  let all_nonempty =
    String.split_on_char '\n' text
    |> List.filter (fun line -> line <> "")
  in
  let total = List.length all_nonempty in
  let truncated_by_limit, limit_overflow =
    if total > limit
    then take limit all_nonempty, total - limit
    else all_nonempty, 0
  in
  (* Byte-budget: accumulate lines until max_bytes is reached.
     This prevents 200 long lines from producing 500KB+ JSON arrays
     that stall the LLM context window. *)
  let rec collect acc bytes_used = function
    | [] -> List.rev acc, 0
    | line :: rest ->
      let line_len =
        String.length line + 4
        (* JSON overhead: quotes, comma *)
      in
      if bytes_used + line_len > max_bytes && acc <> []
      then List.rev acc, List.length rest + 1
      else collect (`String line :: acc) (bytes_used + line_len) rest
  in
  let kept, byte_overflow = collect [] 0 truncated_by_limit in
  let omitted = limit_overflow + byte_overflow in
  if omitted > 0
  then
    `List
      (kept
       @ [ `String
             (Printf.sprintf
                "...[%d more lines omitted — narrow your search pattern or add \
                 --glob/--type filter]"
                omitted)
         ])
  else `List kept
;;

let keeper_text_fallback_json ~(agent_id : string) ~(message : string) =
  let voice = Voice_bridge.get_voice_for_agent agent_id in
  `Assoc
    [ "status", `String "text_fallback"
    ; "agent_id", `String agent_id
    ; "voice", `String voice
    ; "message_preview", `String (short_preview ~max_len:50 message)
    ]
;;

let tag_dispatch_fn
  : (config:Coord.config
     -> agent_name:string
     -> tag:Tool_dispatch.module_tag
     -> name:string
     -> args:Yojson.Safe.t
     -> Tool_result.t option)
      ref
  =
  ref (fun ~config:_ ~agent_name:_ ~tag:_ ~name:_ ~args:_ -> None)
;;

let keeper_tools_list_json ~(meta : keeper_meta) =
  let names = Keeper_tool_policy.keeper_allowed_tool_names meta in
  let categorize_keeper_tool = function
    | Tool_name.Keeper.Board_cleanup
    | Tool_name.Keeper.Board_comment
    | Tool_name.Keeper.Board_comment_vote
    | Tool_name.Keeper.Board_curation_read
    | Tool_name.Keeper.Board_curation_submit
    | Tool_name.Keeper.Board_delete
    | Tool_name.Keeper.Board_get
    | Tool_name.Keeper.Board_list
    | Tool_name.Keeper.Board_post
    | Tool_name.Keeper.Board_search
    | Tool_name.Keeper.Board_stats
    | Tool_name.Keeper.Board_sub_board_create
    | Tool_name.Keeper.Board_sub_board_delete
    | Tool_name.Keeper.Board_sub_board_get
    | Tool_name.Keeper.Board_sub_board_list
    | Tool_name.Keeper.Board_sub_board_update
    | Tool_name.Keeper.Board_vote -> "board"
    | Tool_name.Keeper.Voice_agent
    | Tool_name.Keeper.Voice_listen
    | Tool_name.Keeper.Voice_session_end
    | Tool_name.Keeper.Voice_session_start
    | Tool_name.Keeper.Voice_sessions
    | Tool_name.Keeper.Voice_speak -> "voice"
    | Tool_name.Keeper.Task_claim
    | Tool_name.Keeper.Task_create
    | Tool_name.Keeper.Task_done
    | Tool_name.Keeper.Task_force_done
    | Tool_name.Keeper.Task_force_release
    | Tool_name.Keeper.Task_submit_for_verification
    | Tool_name.Keeper.Tasks_audit
    | Tool_name.Keeper.Tasks_list -> "coordination"
    | Tool_name.Keeper.Bash | Tool_name.Keeper.Shell -> "shell"
    | Tool_name.Keeper.Fs_edit
    | Tool_name.Keeper.Fs_read
    | Tool_name.Keeper.Ide_annotate
    | Tool_name.Keeper.Write -> "fs"
    | Tool_name.Keeper.Library_read
    | Tool_name.Keeper.Library_search
    | Tool_name.Keeper.Memory_search
    | Tool_name.Keeper.Memory_write -> "memory"
    | Tool_name.Keeper.Broadcast | Tool_name.Keeper.Handoff -> "coordination"
    | Tool_name.Keeper.Pr_list
    | Tool_name.Keeper.Pr_review_comment
    | Tool_name.Keeper.Pr_review_read
    | Tool_name.Keeper.Pr_review_reply
    | Tool_name.Keeper.Pr_status -> "vcs"
    | Tool_name.Keeper.Code_read -> "fs"
    | Tool_name.Keeper.Context_status
    | Tool_name.Keeper.Discovery
    | Tool_name.Keeper.Preflight_check
    | Tool_name.Keeper.Stay_silent
    | Tool_name.Keeper.Time_now
    | Tool_name.Keeper.Tool_search
    | Tool_name.Keeper.Tools_list -> "meta"
  in
  let categorize n =
    match Tool_name.of_string n with
    | Some (Tool_name.Keeper tool) -> categorize_keeper_tool tool
    | Some typed ->
      (match Tool_catalog.tool_group (Tool_name.to_string typed) with
       | Some group -> Tool_catalog.tool_group_to_string group
       | None -> "core")
    | None -> "core"
  in
  let map =
    List.fold_left
      (fun acc n ->
         let cat = categorize n in
         let list = StringMap.find_opt cat acc |> Option.value ~default:[] in
         StringMap.add cat (n :: list) acc)
      StringMap.empty
      names
  in
  let assoc =
    StringMap.fold
      (fun cat list acc -> (cat, `List (List.map (fun s -> `String s) list)) :: acc)
      map
      []
  in
  Yojson.Safe.to_string (`Assoc assoc)
;;

open Keeper_types
open Keeper_alerting
module StringMap = Map.Make (String)

let count_context_tokens (ctx : working_context) = Keeper_exec_context.token_count ctx

let error_json ?(fields = []) (message : string) =
  Yojson.Safe.to_string (`Assoc (("error", `String message) :: fields))
;;

let tool_result_or_error (tr : Tool_result.t) =
  let ok = tr.success in
  let msg = Tool_result.message tr in
  if ok then msg else error_json msg
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
        "File does not exist. Run `keeper_shell op=ls path=%s` first to see available \
         files."
        playground
    | Path_not_allowed ->
      Printf.sprintf
        "Path is outside your allowed roots. Stay inside %s or use keeper_context_status \
         to see allowed paths."
        playground
    | Cwd_not_directory ->
      "The cwd is not a directory. Omit cwd to use your default playground root, or \
       create/repair the repo worktree first (keeper_shell op=git_clone, then \
       git_worktree/masc_worktree_create for repos/<repo>/.worktrees/<task>)."
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
  match Keeper_registry.find_by_name keeper_name with
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

let lowercase_shell_words text =
  text
  |> String.map (function
    | '\t' | '\r' | '\n' -> ' '
    | c -> c)
  |> String.lowercase_ascii
  |> String.split_on_char ' '
  |> List.filter (fun token -> token <> "")
;;

let assoc_override_string (key : string) (value : string) = function
  | `Assoc fields ->
    let kept_fields = List.filter (fun (k, _) -> k <> key) fields in
    `Assoc ((key, `String value) :: kept_fields)
  | other -> other
;;

let keeper_effective_allowed_paths ~(meta : keeper_meta) =
  Keeper_alerting_path.effective_allowed_paths ~meta
;;

let keeper_effective_write_allowed_paths ~(meta : keeper_meta) =
  Keeper_alerting_path.effective_write_allowed_paths ~meta
;;

let keeper_playground_root ~(config : Coord.config) ~(meta : keeper_meta) =
  ignore (Keeper_alerting_path.ensure_sandbox_bundle ~config ~meta);
  Keeper_sandbox.host_root_abs_of_meta ~config meta
;;

let keeper_default_write_root ~(config : Coord.config) ~(meta : keeper_meta) =
  keeper_playground_root ~config ~meta
;;

let keeper_default_read_root ~(config : Coord.config) ~(meta : keeper_meta) =
  keeper_playground_root ~config ~meta
;;

let safe_file_exists path =
  try Fs_compat.file_exists path with
  | Sys_error _ -> false
;;

let safe_is_dir path =
  try Fs_compat.file_exists path && Sys.is_directory path with
  | Sys_error _ -> false
;;

let keeper_sandbox_repo_names ~(config : Coord.config) ~(meta : keeper_meta) =
  let repos_dir = Filename.concat (keeper_playground_root ~config ~meta) "repos" in
  if not (safe_is_dir repos_dir)
  then []
  else
    Sys.readdir repos_dir
    |> Array.to_list
    |> List.sort String.compare
    |> List.filter (fun entry ->
      let candidate = Filename.concat repos_dir entry in
      safe_is_dir candidate && safe_file_exists (Filename.concat candidate ".git"))
;;

let relative_path_targets_allowed_root ~(meta : keeper_meta) (raw : string) =
  let boundary prefix =
    let prefix = Keeper_alerting_path.strip_trailing_slashes prefix in
    prefix <> ""
    && (String.equal raw prefix || String.starts_with ~prefix:(prefix ^ "/") raw)
  in
  keeper_effective_allowed_paths ~meta
  |> List.filter Filename.is_relative
  |> List.exists boundary
;;

let is_playground_lane_relative_path (raw : string) =
  List.exists
    (fun prefix ->
       String.equal raw prefix || String.starts_with ~prefix:(prefix ^ "/") raw)
    [ "mind"; "repos" ]
;;

let strip_keeper_playground_prefix ~(meta : keeper_meta) (raw : string) =
  let try_strip ~prefix text =
    if
      Filename.is_relative text
      && String.length text >= String.length prefix
      && String.starts_with ~prefix text
    then (
      let rest =
        String.sub text (String.length prefix) (String.length text - String.length prefix)
      in
      Some (if rest = "" then "." else rest))
    else None
  in
  let sandbox_root = Keeper_sandbox.allowed_root_rel_of_meta ~meta in
  let legacy_bundle_root = Playground_paths.bundle_root meta.name in
  let short_root =
    let rel = Keeper_alerting_path.strip_trailing_slashes sandbox_root in
    if String.starts_with ~prefix:(Common.masc_dirname ^ "/") rel
    then String.sub rel 6 (String.length rel - 6)
    else rel
  in
  let prefixes =
    [ sandbox_root
    ; Keeper_alerting_path.strip_trailing_slashes sandbox_root
    ; legacy_bundle_root
    ; Keeper_alerting_path.strip_trailing_slashes legacy_bundle_root
    ; short_root ^ "/"
    ; short_root
    ]
  in
  List.find_map (fun prefix -> try_strip ~prefix raw) prefixes
;;

let repo_relative_path_candidate ~(meta : keeper_meta) (raw : string) =
  let first_segment =
    match String.split_on_char '/' raw with
    | segment :: _ -> segment
    | [] -> raw
  in
  Filename.is_relative raw
  && raw <> ""
  && String.contains raw '/'
  && (not (is_playground_lane_relative_path raw))
  && (not (relative_path_targets_allowed_root ~meta raw))
  && not
       (List.mem
          first_segment
          [ Common.masc_dirname; "playground"; "workspace"; ".worktrees" ])
;;

let rewrite_single_repo_relative_path
      ~(config : Coord.config)
      ~(meta : keeper_meta)
      (raw : string)
  =
  if not (repo_relative_path_candidate ~meta raw)
  then Ok None
  else (
    let first_segment =
      match String.split_on_char '/' raw with
      | segment :: _ -> segment
      | [] -> raw
    in
    match keeper_sandbox_repo_names ~config ~meta with
    | repo_names when List.mem first_segment repo_names ->
      let sandbox_relative = Filename.concat "repos" raw in
      let rewritten =
        Filename.concat (keeper_playground_root ~config ~meta) sandbox_relative
      in
      Log.Keeper.debug "playground_relative: explicit repo rewrite %S → %S" raw rewritten;
      Ok (Some rewritten)
    | [ repo_name ] ->
      let sandbox_relative = Filename.concat ("repos/" ^ repo_name) raw in
      let rewritten =
        Filename.concat (keeper_playground_root ~config ~meta) sandbox_relative
      in
      Log.Keeper.debug "playground_relative: single-repo rewrite %S → %S" raw rewritten;
      Ok (Some rewritten)
    | [] -> Ok None
    | repo_names ->
      Error
        (Printf.sprintf
           "ambiguous_repo_relative_path: %s (sandbox repos: [%s]). Use repos/<repo>/%s \
            or <repo>/%s explicitly."
           raw
           (String.concat ", " repo_names)
           raw
           raw))
;;

let host_path_of_own_container_path
      ~(config : Coord.config)
      ~(meta : keeper_meta)
      (raw : string)
  =
  if Filename.is_relative raw || meta.sandbox_profile <> Keeper_types.Docker
  then None
  else (
    let strip = Keeper_alerting_path.strip_trailing_slashes in
    let normalize path = Keeper_alerting_path.normalize_path_for_check_stripped path in
    let container_root = Keeper_sandbox.container_root meta.name |> normalize in
    let raw_norm = normalize raw in
    let host_root = keeper_playground_root ~config ~meta |> strip in
    if String.equal raw_norm container_root
    then Some host_root
    else if String.starts_with ~prefix:(container_root ^ "/") raw_norm
    then (
      let suffix =
        String.sub
          raw_norm
          (String.length container_root + 1)
          (String.length raw_norm - String.length container_root - 1)
      in
      Some (Filename.concat host_root suffix))
    else None)
;;

(* Bare filenames and canonical sandbox lanes default to the keeper sandbox,
   but rooted-looking relative paths (for example
   "workspace/..." or "lib/...") keep project-root/boundary semantics.

   Additionally, strip the keeper's legacy playground prefix when the path
   already includes it.  Keeper LLMs sometimes construct paths like
   ".masc/playground/<name>/repos" (relative) or
   "<base>/.masc/playground/<name>/.masc/playground/<name>/repos" (absolute,
   doubled).  Stripping early
   prevents the downstream resolver from doubling the prefix again. *)
let playground_relative_unless_allowed_root
      ~(config : Coord.config)
      ~(meta : keeper_meta)
      (raw : string)
  : (string, string) result
  =
  let trimmed = String.trim raw in
  let trimmed =
    match host_path_of_own_container_path ~config ~meta trimmed with
    | Some host_path ->
      Log.Keeper.debug
        "playground_relative: mapped container path %S → %S"
        trimmed
        host_path;
      host_path
    | None -> trimmed
  in
  let trimmed =
    match strip_keeper_playground_prefix ~meta trimmed with
    | Some stripped ->
      Log.Keeper.debug "playground_relative: stripped prefix %S → %S" trimmed stripped;
      stripped
    | None -> trimmed
  in
  (* 2. Fix doubled playground prefix in absolute paths.
     E.g. "/base/.masc/playground/X/.masc/playground/X/repos" →
          "/base/.masc/playground/X/repos" *)
  let trimmed =
    if not (Filename.is_relative trimmed)
    then (
      let pg_root =
        keeper_playground_root ~config ~meta
        |> Keeper_alerting_path.strip_trailing_slashes
      in
      let pg_bundle = Keeper_sandbox.allowed_root_rel_of_meta ~meta in
      let doubled_prefix = pg_root ^ "/" ^ pg_bundle in
      if String.starts_with ~prefix:doubled_prefix trimmed
      then (
        let rest =
          String.sub
            trimmed
            (String.length doubled_prefix)
            (String.length trimmed - String.length doubled_prefix)
        in
        let fixed = Filename.concat pg_root rest in
        Log.Keeper.debug "playground_relative: fixed doubled abs %S → %S" trimmed fixed;
        fixed)
      else trimmed)
    else trimmed
  in
  match rewrite_single_repo_relative_path ~config ~meta trimmed with
  | Error _ as err -> err
  | Ok (Some rewritten) -> Ok rewritten
  | Ok None ->
    if
      trimmed = ""
      || (not (Filename.is_relative trimmed))
      || (String.contains trimmed '/' && not (is_playground_lane_relative_path trimmed))
      || relative_path_targets_allowed_root ~meta trimmed
    then Ok trimmed
    else (
      let pg = keeper_playground_root ~config ~meta in
      Ok (Filename.concat pg trimmed))
;;

let resolve_keeper_path
      ~(config : Coord.config)
      ~(meta : keeper_meta)
      ~(raw_path : string)
  =
  match playground_relative_unless_allowed_root ~config ~meta raw_path with
  | Error e -> Error e
  | Ok normalized ->
    match Keeper_alerting_path.resolve_keeper_target_path
      ~config
      ~allowed_paths:(keeper_effective_write_allowed_paths ~meta)
      ~raw_path:normalized
    with
    | Error rej -> Error (Keeper_alerting_path.rejection_to_user_message rej)
    | Ok p -> Ok p
;;

let resolve_keeper_read_path
      ~(config : Coord.config)
      ~(meta : keeper_meta)
      ~(raw_path : string)
  =
  match playground_relative_unless_allowed_root ~config ~meta raw_path with
  | Error e -> Error e
  | Ok normalized ->
    match Keeper_alerting_path.resolve_keeper_read_path
      ~config
      ~allowed_paths:(keeper_effective_allowed_paths ~meta)
      ~raw_path:normalized
    with
    | Error rej -> Error (Keeper_alerting_path.rejection_to_user_message rej)
    | Ok p -> Ok p
;;

let keeper_agent_sender ~(meta : keeper_meta) = meta.agent_name

let shell_readonly_limit args =
  max 1 (min 200 (Safe_ops.json_int ~default:40 "limit" args))
;;

let shell_readonly_cat_max_bytes args =
  max 256 (min 100000 (Safe_ops.json_int ~default:4000 "max_bytes" args))
;;

let lines_to_json ?(limit = max_int) ?(max_bytes = 32_000) (text : string) : Yojson.Safe.t
  =
  let all_lines =
    String.split_on_char '\n' text
    |> List.filter (fun line -> line <> "")
    |> fun rows -> if List.length rows > limit then take limit rows else rows
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
  let kept, omitted = collect [] 0 all_lines in
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
    | Tool_name.Keeper.Bash
    | Tool_name.Keeper.Bash_kill
    | Tool_name.Keeper.Bash_output
    | Tool_name.Keeper.Shell -> "shell"
    | Tool_name.Keeper.Fs_edit | Tool_name.Keeper.Fs_read | Tool_name.Keeper.Write -> "fs"
    | Tool_name.Keeper.Library_read
    | Tool_name.Keeper.Library_search
    | Tool_name.Keeper.Memory_search
    | Tool_name.Keeper.Memory_write -> "memory"
    | Tool_name.Keeper.Broadcast | Tool_name.Keeper.Handoff -> "coordination"
    | Tool_name.Keeper.Pr_create
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

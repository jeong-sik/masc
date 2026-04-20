open Keeper_types
open Keeper_alerting

module StringMap = Map.Make (String)

let count_context_tokens (ctx : working_context) =
  Keeper_exec_context.token_count ctx
;;

let error_json ?(fields = []) (message : string) =
  Yojson.Safe.to_string (`Assoc (("error", `String message) :: fields))
;;

let tool_result_or_error (ok, msg) = if ok then msg else error_json msg

(** Actionable error for path resolution failures.
    Follows Samchon harness pattern: field-level diagnostics with
    exact path, expected constraint, and concrete next action.
    Claude Code pattern: validateInput returns actionable guidance. *)
let actionable_path_error ~(op : string) ~(keeper_name : string)
      ~(raw_path : string) ~(error : string) =
  let playground = Printf.sprintf ".masc/playground/%s/" keeper_name in
  let contains sub = String_util.contains_substring error sub in
  let action = match () with
    | () when String.length raw_path = 0 ->
      "Provide a path. Your playground root is " ^ playground
    | () when contains "path_not_found" ->
      Printf.sprintf "File does not exist. Run `keeper_shell op=ls path=%s` first to see available files." playground
    | () when contains "path_not_in_allowed" ->
      Printf.sprintf "Path is outside your allowed roots. Stay inside %s or use keeper_context_status to see allowed paths." playground
    | () when contains "cwd_not_directory" ->
      "The cwd is not a directory. Omit cwd to use your default playground root."
    | () ->
      Printf.sprintf "Check the path. Your playground: %s" playground
  in
  Yojson.Safe.to_string (`Assoc [
    "ok", `Bool false;
    "op", `String op;
    "error", `String error;
    "tried", `String raw_path;
    "your_playground", `String playground;
    "action", `String action;
  ])

let max_suggested_entries = 12

let file_not_found_prefix = "File not found:"

let missing_file_error_json ~(config : Coord.config) ~(target : string)
      ~(fallback_dir : string) ~(error : string) =
  ignore config;
  let parent = Filename.dirname target in
  let suggestion_dir =
    if Fs_compat.file_exists parent && Sys.is_directory parent then parent
    else fallback_dir
  in
  let suggested_entries =
    match Safe_ops.list_dir_safe suggestion_dir with
    | Ok entries ->
      entries
      |> List.sort String.compare
      |> List.filteri (fun i _ -> i < max_suggested_entries)
    | Error _ -> []
  in
  let message =
    match suggested_entries with
    | [] -> error
    | entries ->
      Printf.sprintf "%s\nAvailable entries in %s: %s"
        error suggestion_dir (String.concat ", " entries)
  in
  Yojson.Safe.to_string
    (`Assoc
        [ "error", `String message
        ; "path", `String target
        ; "suggestion_dir", `String suggestion_dir
        ; ( "suggested_entries"
          , `List (List.map (fun entry -> `String entry) suggested_entries) )
        ])
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
  ignore (Keeper_alerting_path.ensure_playground_bundle ~config ~name:meta.name);
  Keeper_sandbox.host_root_abs ~config meta.name
;;

let keeper_default_write_root ~(config : Coord.config) ~(meta : keeper_meta) =
  keeper_playground_root ~config ~meta
;;

let keeper_default_read_root ~(config : Coord.config) ~(meta : keeper_meta) =
  keeper_playground_root ~config ~meta
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

let is_playground_lane_relative_path (raw : string) =
  List.exists
    (fun prefix ->
       String.equal raw prefix
       || String.starts_with ~prefix:(prefix ^ "/") raw)
    [ "mind"; "repos" ]

(* Bare filenames and canonical sandbox lanes default to the keeper sandbox,
   but rooted-looking relative paths (for example
   "workspace/..." or "lib/...") keep project-root/boundary semantics.

   Additionally, strip the keeper's legacy playground prefix when the path
   already includes it.  Keeper LLMs sometimes construct paths like
   ".masc/playground/<name>/repos" (relative) or
   "<base>/.masc/playground/<name>/.masc/playground/<name>/repos" (absolute,
   doubled).  Stripping early
   prevents the downstream resolver from doubling the prefix again. *)
let playground_relative_unless_allowed_root ~(config : Coord.config)
    ~(meta : keeper_meta) (raw : string) : string =
  let trimmed = String.trim raw in
  (* 1. Strip keeper's playground prefix from relative paths.
     E.g. ".masc/playground/masc-improver/repos" → "repos" *)
  let pg_bundle = Playground_paths.bundle_root meta.name in
  let trimmed =
    if Filename.is_relative trimmed
       && String.length trimmed >= String.length pg_bundle
       && String.starts_with ~prefix:pg_bundle trimmed
    then
      let rest = String.sub trimmed (String.length pg_bundle)
                   (String.length trimmed - String.length pg_bundle) in
      let stripped = if rest = "" then "." else rest in
      Log.Keeper.debug "playground_relative: stripped prefix %S → %S"
        trimmed stripped;
      stripped
    else trimmed
  in
  (* 2. Fix doubled playground prefix in absolute paths.
     E.g. "/base/.masc/playground/X/.masc/playground/X/repos" →
          "/base/.masc/playground/X/repos" *)
  let trimmed =
    if not (Filename.is_relative trimmed) then
      let pg_root =
        keeper_playground_root ~config ~meta
        |> Keeper_alerting_path.strip_trailing_slashes
      in
      let doubled_prefix = pg_root ^ "/" ^ pg_bundle in
      if String.starts_with ~prefix:doubled_prefix trimmed then
        let rest = String.sub trimmed
                     (String.length doubled_prefix)
                     (String.length trimmed - String.length doubled_prefix) in
        let fixed = Filename.concat pg_root rest in
        Log.Keeper.debug "playground_relative: fixed doubled abs %S → %S"
          trimmed fixed;
        fixed
      else trimmed
    else trimmed
  in
  if trimmed = ""
     || not (Filename.is_relative trimmed)
     || (String.contains trimmed '/'
         && not (is_playground_lane_relative_path trimmed))
     || relative_path_targets_allowed_root ~meta trimmed
  then trimmed
  else
    let pg = keeper_playground_root ~config ~meta in
    Filename.concat pg trimmed

let resolve_keeper_path ~(config : Coord.config) ~(meta : keeper_meta) ~(raw_path : string)
  =
  resolve_keeper_target_path
    ~config
    ~allowed_paths:(keeper_effective_write_allowed_paths ~meta)
    ~raw_path:(playground_relative_unless_allowed_root ~config ~meta raw_path)
;;

let resolve_keeper_read_path ~(config : Coord.config) ~(meta : keeper_meta)
      ~(raw_path : string) =
  Keeper_alerting_path.resolve_keeper_read_path
    ~config
    ~allowed_paths:(keeper_effective_allowed_paths ~meta)
    ~raw_path:(playground_relative_unless_allowed_root ~config ~meta raw_path)
;;

let keeper_agent_sender ~(meta : keeper_meta) =
  meta.agent_name

let shell_readonly_limit args =
  max 1 (min 200 (Safe_ops.json_int ~default:40 "limit" args))
;;

let shell_readonly_cat_max_bytes args =
  max 256 (min 100000 (Safe_ops.json_int ~default:4000 "max_bytes" args))
;;

let lines_to_json ?(limit = max_int) ?(max_bytes = 32_000) (text : string) : Yojson.Safe.t =
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
      let line_len = String.length line + 4 (* JSON overhead: quotes, comma *) in
      if bytes_used + line_len > max_bytes && acc <> []
      then List.rev acc, List.length rest + 1
      else collect (`String line :: acc) (bytes_used + line_len) rest
  in
  let kept, omitted = collect [] 0 all_lines in
  if omitted > 0
  then `List (kept @ [ `String (Printf.sprintf "...[%d more lines omitted — narrow your search pattern or add --glob/--type filter]" omitted) ])
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
     -> (bool * string) option)
      ref
  =
  ref (fun ~config:_ ~agent_name:_ ~tag:_ ~name:_ ~args:_ -> None)




let keeper_tools_list_json ~(meta : keeper_meta) =
  let names = Keeper_tool_policy.keeper_allowed_tool_names meta in
  let categorize n =
    if String.starts_with ~prefix:"keeper_board" n then "board"
    else if String.starts_with ~prefix:"keeper_voice" n then "voice"
    else if String.starts_with ~prefix:"keeper_task" n then "coordination"
    else if String.starts_with ~prefix:"keeper_shell" n || n = "keeper_bash" then "shell"
    else if String.starts_with ~prefix:"keeper_fs" n then "fs"
    else if String.starts_with ~prefix:"keeper_memory" n then "memory"
    else "core"
  in
  let map =
    List.fold_left (fun acc n ->
      let cat = categorize n in
      let list = try StringMap.find cat acc with Not_found -> [] in
      StringMap.add cat (n :: list) acc)
      StringMap.empty names
  in
  let assoc = StringMap.fold (fun cat list acc ->
    (cat, `List (List.map (fun s -> `String s) list)) :: acc
  ) map [] in
  Yojson.Safe.to_string (`Assoc assoc)

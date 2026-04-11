open Keeper_types
open Keeper_alerting

let count_context_tokens (ctx : working_context) =
  Keeper_exec_context.token_count ctx
;;

let error_json ?(fields = []) (message : string) =
  Yojson.Safe.to_string (`Assoc (("error", `String message) :: fields))
;;

let tool_result_or_error (ok, msg) = if ok then msg else error_json msg

let max_suggested_entries = 12

let file_not_found_prefix = "File not found:"

let missing_file_error_json ~(config : Room.config) ~(target : string)
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

let keeper_playground_root ~(config : Room.config) ~(meta : keeper_meta) =
  ignore (Keeper_alerting_path.ensure_playground_bundle ~config ~name:meta.name);
  Filename.concat
    (Keeper_alerting_path.project_root_of_config config)
    (Keeper_alerting_path.playground_path_of_keeper meta.name)
;;

let keeper_default_write_root ~(config : Room.config) ~(meta : keeper_meta) =
  keeper_playground_root ~config ~meta
;;

let keeper_default_read_root ~(config : Room.config) ~(meta : keeper_meta) =
  keeper_playground_root ~config ~meta
;;

let resolve_keeper_path ~(config : Room.config) ~(meta : keeper_meta) ~(raw_path : string)
  =
  resolve_keeper_target_path
    ~config
    ~allowed_paths:(keeper_effective_allowed_paths ~meta)
    ~raw_path
;;

let resolve_keeper_read_path ~(config : Room.config) ~(meta : keeper_meta)
      ~(raw_path : string) =
  Keeper_alerting_path.resolve_keeper_read_path
    ~config
    ~allowed_paths:(keeper_effective_allowed_paths ~meta)
    ~raw_path
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
  : (config:Room.config
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
    else if String.starts_with ~prefix:"keeper_shell" n || n = "keeper_bash" || n = "keeper_github" then "shell"
    else if String.starts_with ~prefix:"keeper_fs" n then "fs"
    else if String.starts_with ~prefix:"keeper_memory" n then "memory"
    else "core"
  in
  let map = Hashtbl.create 8 in
  List.iter (fun n ->
    let cat = categorize n in
    let list = match Hashtbl.find_opt map cat with Some l -> l | None -> [] in
    Hashtbl.replace map cat (n :: list)
  ) names;
  let assoc = Hashtbl.fold (fun cat list acc ->
    (cat, `List (List.map (fun s -> `String s) list)) :: acc
  ) map [] in
  Yojson.Safe.to_string (`Assoc assoc)

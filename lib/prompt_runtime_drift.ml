type file_status =
  | In_sync
  | Modified
  | Missing_runtime
  | Runtime_only

type file_drift =
  { key : string
  ; status : file_status
  ; runtime_path : string option
  ; repo_path : string option
  ; runtime_digest : string option
  ; repo_digest : string option
  }

type summary =
  { status : string
  ; runtime_prompt_dir : string
  ; repo_prompt_dir : string option
  ; repo_head_commit : string option
  ; repo_head_commit_source : string option
  ; runtime_file_count : int
  ; repo_file_count : int
  ; modified_count : int
  ; missing_runtime_count : int
  ; runtime_only_count : int
  ; checked_count : int
  ; drifts : file_drift list
  }

let source_stamp_filename = ".masc-prompt-source.json"

let file_status_to_string = function
  | In_sync -> "in_sync"
  | Modified -> "modified"
  | Missing_runtime -> "missing_runtime"
  | Runtime_only -> "runtime_only"
;;

let string_opt_json = function
  | None -> `Null
  | Some value -> `String value
;;

let read_file_opt path =
  if Sys.file_exists path && not (Sys.is_directory path)
  then
    try Some (Fs_compat.load_file path) with
    | Eio.Cancel.Cancelled _ as e -> raise e
    | _ -> None
  else None
;;

let digest_text text =
  Digestif.SHA256.(to_hex (digest_string text))
;;

let file_digest_opt path = Option.map digest_text (read_file_opt path)

let repo_prompt_dir () =
  match Build_identity.repo_root () with
  | None -> None
  | Some root ->
    let path = Filename.concat root "config/prompts" in
    if Sys.file_exists path && Sys.is_directory path then Some path else None
;;

let runtime_prompt_dir () =
  match Prompt_registry.get_markdown_dir () with
  | Some dir -> dir
  | None -> Config_dir_resolver.prompts_dir ()
;;

let md_file_keys dir =
  if Sys.file_exists dir && Sys.is_directory dir
  then
    Sys.readdir dir
    |> Array.to_list
    |> List.filter (fun name -> Filename.check_suffix name ".md")
    |> List.map Filename.remove_extension
    |> List.sort_uniq String.compare
  else []
;;

let key_path dir key = Filename.concat dir (key ^ ".md")

let compare_key ~runtime_dir ~repo_dir key =
  let runtime_path = key_path runtime_dir key in
  let repo_path = key_path repo_dir key in
  let runtime_digest = file_digest_opt runtime_path in
  let repo_digest = file_digest_opt repo_path in
  let status =
    match runtime_digest, repo_digest with
    | Some left, Some right when String.equal left right -> In_sync
    | Some _, Some _ -> Modified
    | None, Some _ -> Missing_runtime
    | Some _, None -> Runtime_only
    | None, None -> In_sync
  in
  { key
  ; status
  ; runtime_path = if Option.is_some runtime_digest then Some runtime_path else None
  ; repo_path = if Option.is_some repo_digest then Some repo_path else None
  ; runtime_digest
  ; repo_digest
  }
;;

let summarize ?(limit = 25) () =
  let runtime_prompt_dir = runtime_prompt_dir () in
  let repo_prompt_dir = repo_prompt_dir () in
  let build = Build_identity.current () in
  match repo_prompt_dir with
  | None ->
    { status = "unknown"
    ; runtime_prompt_dir
    ; repo_prompt_dir = None
    ; repo_head_commit = build.repo_head_commit
    ; repo_head_commit_source = build.repo_head_commit_source
    ; runtime_file_count = List.length (md_file_keys runtime_prompt_dir)
    ; repo_file_count = 0
    ; modified_count = 0
    ; missing_runtime_count = 0
    ; runtime_only_count = 0
    ; checked_count = 0
    ; drifts = []
    }
  | Some repo_dir ->
    let runtime_keys = md_file_keys runtime_prompt_dir in
    let repo_keys = md_file_keys repo_dir in
    let keys = List.sort_uniq String.compare (runtime_keys @ repo_keys) in
    let rows = List.map (compare_key ~runtime_dir:runtime_prompt_dir ~repo_dir) keys in
    let count_status wanted =
      rows |> List.filter (fun (row : file_drift) -> row.status = wanted) |> List.length
    in
    let modified_count = count_status Modified in
    let missing_runtime_count = count_status Missing_runtime in
    let runtime_only_count = count_status Runtime_only in
    let drift_rows = List.filter (fun (row : file_drift) -> row.status <> In_sync) rows in
    let bounded_drifts =
      let rec take n acc = function
        | _ when n <= 0 -> List.rev acc
        | [] -> List.rev acc
        | x :: xs -> take (n - 1) (x :: acc) xs
      in
      take limit [] drift_rows
    in
    let status =
      if modified_count = 0 && missing_runtime_count = 0 && runtime_only_count = 0
      then "ok"
      else "warn"
    in
    { status
    ; runtime_prompt_dir
    ; repo_prompt_dir = Some repo_dir
    ; repo_head_commit = build.repo_head_commit
    ; repo_head_commit_source = build.repo_head_commit_source
    ; runtime_file_count = List.length runtime_keys
    ; repo_file_count = List.length repo_keys
    ; modified_count
    ; missing_runtime_count
    ; runtime_only_count
    ; checked_count = List.length keys
    ; drifts = bounded_drifts
    }
;;

let file_drift_to_yojson row =
  `Assoc
    [ "key", `String row.key
    ; "status", `String (file_status_to_string row.status)
    ; "runtime_path", string_opt_json row.runtime_path
    ; "repo_path", string_opt_json row.repo_path
    ; "runtime_digest", string_opt_json row.runtime_digest
    ; "repo_digest", string_opt_json row.repo_digest
    ]
;;

let to_yojson summary =
  `Assoc
    [ "status", `String summary.status
    ; "runtime_prompt_dir", `String summary.runtime_prompt_dir
    ; "repo_prompt_dir", string_opt_json summary.repo_prompt_dir
    ; "repo_head_commit", string_opt_json summary.repo_head_commit
    ; "repo_head_commit_source", string_opt_json summary.repo_head_commit_source
    ; "runtime_file_count", `Int summary.runtime_file_count
    ; "repo_file_count", `Int summary.repo_file_count
    ; "modified_count", `Int summary.modified_count
    ; "missing_runtime_count", `Int summary.missing_runtime_count
    ; "runtime_only_count", `Int summary.runtime_only_count
    ; "checked_count", `Int summary.checked_count
    ; "drifts", `List (List.map file_drift_to_yojson summary.drifts)
    ]
;;

let warning_messages summary =
  match summary.status with
  | "ok" -> []
  | "unknown" ->
    [ "Prompt seed drift status is unknown; running repo config/prompts was not found." ]
  | _ ->
    let repo_commit =
      match summary.repo_head_commit with
      | Some commit -> commit
      | None -> "unknown"
    in
    [ Printf.sprintf
        "Live prompt config differs from repo seed: modified=%d missing_runtime=%d runtime_only=%d repo_commit=%s."
        summary.modified_count
        summary.missing_runtime_count
        summary.runtime_only_count
        repo_commit
    ]
;;

let log_if_drift summary =
  List.iter
    (fun warning -> Log.Misc.warn "prompt drift: %s" warning)
    (warning_messages summary)
;;

let prompt_key_status_json key =
  let runtime_dir = runtime_prompt_dir () in
  let build = Build_identity.current () in
  match repo_prompt_dir () with
  | None ->
    `Assoc
      [ "key", `String key
      ; "status", `String "unknown"
      ; "runtime_path", `String (key_path runtime_dir key)
      ; "repo_path", `Null
      ; "repo_head_commit", string_opt_json build.repo_head_commit
      ]
  | Some repo_dir ->
    let row = compare_key ~runtime_dir ~repo_dir key in
    (match file_drift_to_yojson row with
     | `Assoc fields ->
       `Assoc
         (fields
          @ [ "repo_head_commit", string_opt_json build.repo_head_commit
            ; "repo_head_commit_source", string_opt_json build.repo_head_commit_source
            ])
     | other -> other)
;;

let digest_dir dir =
  md_file_keys dir
  |> List.filter_map (fun key ->
    let path = key_path dir key in
    Option.map (fun digest -> key ^ ":" ^ digest) (file_digest_opt path))
  |> String.concat "\n"
  |> digest_text
;;

let write_source_stamp ~prompt_markdown_dir =
  try
    Fs_compat.mkdir_p prompt_markdown_dir;
    let build = Build_identity.current () in
    let json =
      `Assoc
        [ "schema", `String "masc.prompt_source_stamp.v1"
        ; "written_at", `String (Masc_domain.now_iso ())
        ; "runtime_prompt_dir", `String prompt_markdown_dir
        ; "repo_prompt_dir", string_opt_json (repo_prompt_dir ())
        ; "repo_head_commit", string_opt_json build.repo_head_commit
        ; "repo_head_commit_source", string_opt_json build.repo_head_commit_source
        ; "runtime_prompt_digest", `String (digest_dir prompt_markdown_dir)
        ; ( "repo_prompt_digest"
          , match repo_prompt_dir () with
            | None -> `Null
            | Some dir -> `String (digest_dir dir) )
        ]
    in
    Fs_compat.save_file
      (Filename.concat prompt_markdown_dir source_stamp_filename)
      (Yojson.Safe.pretty_to_string json ^ "\n")
  with
  | Eio.Cancel.Cancelled _ as e -> raise e
  | exn ->
    Log.Misc.warn "prompt source stamp write failed: %s" (Printexc.to_string exn)
;;

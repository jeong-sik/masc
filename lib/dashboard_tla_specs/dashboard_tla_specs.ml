type spec_entry =
  { name : string
  ; path : string
  ; category : string
  ; has_clean_cfg : bool
  ; has_buggy_cfg : bool
  ; mtime : float
  }

type tlc_status =
  | Tlc_passed
  | Tlc_violated
  | Tlc_running
  | Tlc_error
  | Tlc_not_run

type tlc_result_entry =
  { spec_name : string
  ; cfg_name : string
  ; category : string
  ; status : tlc_status
  ; states_explored : int option
  ; distinct_states : int option
  ; diameter : int option
  ; last_run_at : float option
  ; violation : string option
  ; log_path : string option
  }

let specs_dir () =
  match Sys.getenv_opt "MASC_SPECS_DIR" with
  | Some p when not (String.equal p "") -> p
  | _ -> "specs"
;;

let tlc_results_dir () =
  match Sys.getenv_opt "MASC_TLC_RESULTS_DIR" with
  | Some p when not (String.equal p "") -> p
  | _ -> Filename.get_temp_dir_name ()
;;

let category_of_subdir = function
  | "boundary" -> "boundary"
  | "bug-models" -> "bug-models"
  | _ -> "other"
;;

let is_tla_file name = Filename.check_suffix name ".tla"

let safe_stat_mtime path =
  try (Unix.stat path).st_mtime with
  | Unix.Unix_error _ -> 0.0
;;

let readdir_safe dir =
  try Sys.readdir dir |> Array.to_list with
  | Sys_error _ -> []
;;

let is_directory_safe p =
  try Sys.is_directory p with
  | Sys_error _ -> false
;;

let file_exists_safe p =
  try Sys.file_exists p with
  | Sys_error _ -> false
;;

let companion_paths ~directory name =
  Filename.concat directory (name ^ ".cfg"),
  Filename.concat directory (name ^ "-buggy.cfg")
;;

let entry_for_file ~exists ~mtime ~root ~sub file =
  let name = Filename.chop_suffix file ".tla" in
  let directory = Filename.concat root sub in
  let clean_cfg, buggy_cfg = companion_paths ~directory name in
  { name
  ; path = Filename.concat sub file
  ; category = category_of_subdir sub
  ; has_clean_cfg = exists clean_cfg
  ; has_buggy_cfg = exists buggy_cfg
  ; mtime = mtime (Filename.concat directory file)
  }
;;

let scan_subdir ~root sub =
  let subpath = Filename.concat root sub in
  if not (is_directory_safe subpath)
  then []
  else
    readdir_safe subpath
    |> List.filter is_tla_file
    |> List.map (entry_for_file ~exists:file_exists_safe ~mtime:safe_stat_mtime ~root ~sub)
;;

let list_specs () =
  let root = specs_dir () in
  if not (is_directory_safe root)
  then []
  else
    readdir_safe root
    |> List.concat_map (fun sub -> scan_subdir ~root sub)
    |> List.sort (fun (a : spec_entry) (b : spec_entry) ->
      match String.compare a.category b.category with
      | 0 -> String.compare a.name b.name
      | c -> c)
;;

;;

let entry_to_json e : Yojson.Safe.t =
  `Assoc
    [ "name", `String e.name
    ; "path", `String e.path
    ; "category", `String e.category
    ; "has_clean_cfg", `Bool e.has_clean_cfg
    ; "has_buggy_cfg", `Bool e.has_buggy_cfg
    ; "mtime_iso", `String (Masc_domain.iso8601_of_unix_seconds e.mtime)
    ]
;;

let specs_dir_json root =
  if not (file_exists_safe root)
  then `Null
  else (
    try `String (Unix.realpath root) with
    | Unix.Unix_error _ -> `String root)
;;

let specs_json () : Yojson.Safe.t =
  let root = specs_dir () in
  let entries = list_specs () in
  `Assoc
    [ "updated_at", `String (Masc_domain.now_iso ())
    ; "specs_dir", specs_dir_json root
    ; "count", `Int (List.length entries)
    ; "entries", `List (List.map entry_to_json entries)
    ]
;;

let read_file_safe path =
  try Some (Fs_compat.load_file path) with
  | Sys_error _ | End_of_file -> None
;;

let normalize_int s =
  Stdlib.String.to_seq s
  |> Stdlib.Seq.filter (fun c -> not (Char.equal c ','))
  |> String.of_seq
  |> Stdlib.int_of_string_opt
;;



let split_lines text = String.split_on_char '\n' text |> List.map String.trim

let digit_token_to_int token =
  let cleaned =
    token
    |> Stdlib.String.to_seq
    |> Stdlib.Seq.filter (function
      | '0' .. '9' | ',' -> true
      | _ -> false)
    |> String.of_seq
  in
  if String.equal cleaned "" then None else normalize_int cleaned
;;

let ints_in_line line =
  line |> String.split_on_char ' ' |> List.filter_map digit_token_to_int
;;

let violation_line text =
  split_lines text
  |> List.find_opt (fun line ->
    String_util.contains_substring line " is violated"
    || String_util.contains_substring line "Temporal properties were violated"
    || (String_util.contains_substring line "Invariant " && String_util.contains_substring line "violated"))
  |> Option.map String.trim
;;

let status_of_log text =
  if String_util.contains_substring text "Model checking completed. No error has been found."
  then Tlc_passed
  else if Option.is_some (violation_line text)
  then Tlc_violated
  else if
    String_util.contains_substring text "Error:"
    || String_util.contains_substring text "Exception"
    || String_util.contains_substring text "Parsing failed"
  then Tlc_error
  else Tlc_running
;;

let tlc_status_to_string = function
  | Tlc_passed -> "passed"
  | Tlc_violated -> "violated"
  | Tlc_running -> "running"
  | Tlc_error -> "error"
  | Tlc_not_run -> "not_run"
;;

let metrics_of_log text =
  let state_pair =
    split_lines text
    |> List.find_map (fun line ->
      if
        String_util.contains_substring line "states generated"
        && String_util.contains_substring line "distinct states"
      then (
        match ints_in_line line with
        | a :: b :: _ -> Some (a, b)
        | _ -> None)
      else None)
  in
  let states_explored, distinct_states =
    match state_pair with
    | Some (a, b) -> Some a, Some b
    | None -> None, None
  in
  let diameter =
    split_lines text
    |> List.find_map (fun line ->
      if String_util.contains_substring line "depth of the complete state graph search"
      then (
        match ints_in_line line with
        | value :: _ -> Some value
        | [] -> None)
      else None)
  in
  states_explored, distinct_states, diameter
;;

let cfg_entries_for_spec (entry : spec_entry) =
  let clean = if entry.has_clean_cfg then [ entry.name ^ ".cfg", entry.name ] else [] in
  let buggy =
    if entry.has_buggy_cfg
    then [ entry.name ^ "-buggy.cfg", entry.name ^ "-buggy" ]
    else []
  in
  clean @ buggy
;;

let log_path_for_cfg ~results_dir cfg_stem =
  Filename.concat results_dir ("tlc-" ^ cfg_stem ^ ".log")
;;

let result_for_cfg ~results_dir (spec : spec_entry) (cfg_name, cfg_stem) =
  let log_path = log_path_for_cfg ~results_dir cfg_stem in
  match read_file_safe log_path with
  | None ->
    { spec_name = spec.name
    ; cfg_name
    ; category = spec.category
    ; status = Tlc_not_run
    ; states_explored = None
    ; distinct_states = None
    ; diameter = None
    ; last_run_at = None
    ; violation = None
    ; log_path = None
    }
  | Some text ->
    let states_explored, distinct_states, diameter = metrics_of_log text in
    { spec_name = spec.name
    ; cfg_name
    ; category = spec.category
    ; status = status_of_log text
    ; states_explored
    ; distinct_states
    ; diameter
    ; last_run_at = Some (safe_stat_mtime log_path)
    ; violation = violation_line text
    ; log_path = Some log_path
    }
;;

let list_tlc_results () =
  let results_dir = tlc_results_dir () in
  list_specs ()
  |> List.concat_map (fun spec ->
    cfg_entries_for_spec spec |> List.map (result_for_cfg ~results_dir spec))
;;


let option_time_json = function
  | Some v -> `String (Masc_domain.iso8601_of_unix_seconds v)
  | None -> `Null
;;

let tlc_entry_to_json e : Yojson.Safe.t =
  `Assoc
    [ "spec_name", `String e.spec_name
    ; "cfg_name", `String e.cfg_name
    ; "category", `String e.category
    ; "status", `String (tlc_status_to_string e.status)
    ; "states_explored", Json_util.int_opt_to_json e.states_explored
    ; "distinct_states", Json_util.int_opt_to_json e.distinct_states
    ; "diameter", Json_util.int_opt_to_json e.diameter
    ; "last_run_at", option_time_json e.last_run_at
    ; "violation", Json_util.string_opt_to_json e.violation
    ; "log_path", Json_util.string_opt_to_json e.log_path
    ]
;;

let tlc_results_json () : Yojson.Safe.t =
  let results_dir = tlc_results_dir () in
  let entries = list_tlc_results () in
  `Assoc
    [ "updated_at", `String (Masc_domain.now_iso ())
    ; ( "results_dir"
      , if is_directory_safe results_dir
        then (
          try `String (Unix.realpath results_dir) with
          | Unix.Unix_error _ -> `String results_dir)
        else `Null )
    ; "count", `Int (List.length entries)
    ; "entries", `List (List.map tlc_entry_to_json entries)
    ]
;;

type source_inventory = {
  specs_directory : string;
  results_directory : string;
  spec_directories : string list;
  spec_files : string list;
  cfg_files : string list;
  expected_log_files : string list;
}

type scan_error = { path : string; error : Unix.error }

let observation_source_inventory () =
  let stat path =
    match Unix.stat path with
    | status -> Some status
    | exception Unix.Unix_error ((Unix.ENOENT | Unix.ENOTDIR), _, _) -> None
  in
  let is_dir path = match stat path with Some status -> status.Unix.st_kind = Unix.S_DIR | None -> false in
  let names directory =
    if not (is_dir directory) then []
    else
      let channel = Unix.opendir directory in
      Fun.protect ~finally:(fun () -> Unix.closedir channel) (fun () ->
        let rec read acc =
          match Unix.readdir channel with
          | "." | ".." -> read acc
          | name -> read (name :: acc)
          | exception End_of_file -> List.sort String.compare acc
        in
        read [])
  in
  match
    let specs_directory = specs_dir () in
    let results_directory = tlc_results_dir () in
    let children = names specs_directory in
    let subdirs = children
        |> List.filter (fun name -> is_dir (Filename.concat specs_directory name)) in
    let watch_subdirs = children |> List.filter (fun name ->
      let path = Filename.concat specs_directory name in
      match Unix.lstat path with
      | status -> status.st_kind = Unix.S_LNK || status.st_kind = Unix.S_DIR
      | exception Unix.Unix_error ((Unix.ENOENT | Unix.ENOTDIR), _, _) -> false) in
    let entries = subdirs |> List.concat_map (fun sub ->
      names (Filename.concat specs_directory sub)
      |> List.filter is_tla_file
      |> List.map (entry_for_file ~root:specs_directory ~sub
          ~exists:(fun path -> Option.is_some (stat path))
          ~mtime:(fun path -> match stat path with Some status -> status.st_mtime | None -> 0.0))) in
    let cfgs = entries |> List.concat_map (fun (spec : spec_entry) ->
      cfg_entries_for_spec spec |> List.map (fun (name, stem) ->
        Filename.concat (Filename.concat specs_directory (Filename.dirname spec.path)) name,
        log_path_for_cfg ~results_dir:results_directory stem)) in
    Ok {
      specs_directory; results_directory;
      spec_directories = List.map (Filename.concat specs_directory) watch_subdirs;
      spec_files = List.map (fun (spec : spec_entry) -> Filename.concat specs_directory spec.path) entries;
      cfg_files = entries |> List.concat_map (fun (spec : spec_entry) ->
        let directory = Filename.concat specs_directory (Filename.dirname spec.path) in
        let clean, buggy = companion_paths ~directory spec.name in
        [ clean; buggy ]);
      expected_log_files = List.map snd cfgs |> List.sort_uniq String.compare;
    }
  with
  | result -> result
  | exception Unix.Unix_error (error, _, path) -> Error { path; error }
;;

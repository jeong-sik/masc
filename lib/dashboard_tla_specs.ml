module Format = Stdlib.Format
module Map = Stdlib.Map
module Set = Stdlib.Set
module Queue = Stdlib.Queue
module Hashtbl = Stdlib.Hashtbl
module Mutex = Stdlib.Mutex
module Option = Stdlib.Option
module Result = Stdlib.Result
module Sys = Stdlib.Sys
module Filename = Stdlib.Filename
module List = Stdlib.List
module Array = Stdlib.Array
module String = Stdlib.String
module Char = Stdlib.Char
module Int = Stdlib.Int
module Float = Stdlib.Float

type spec_entry = {
  name : string;
  path : string;
  category : string;
  has_clean_cfg : bool;
  has_buggy_cfg : bool;
  mtime : float;
}

type tlc_status =
  | Tlc_passed
  | Tlc_violated
  | Tlc_running
  | Tlc_queued
  | Tlc_error
  | Tlc_not_run

type tlc_result_entry = {
  spec_name : string;
  cfg_name : string;
  category : string;
  status : tlc_status;
  states_explored : int option;
  distinct_states : int option;
  diameter : int option;
  last_run_at : float option;
  violation : string option;
  log_path : string option;
}

let specs_dir () =
  match Sys.getenv_opt "MASC_SPECS_DIR" with
  | Some p when not (String.equal p "") -> p
  | _ -> "specs"

let tlc_results_dir () =
  match Sys.getenv_opt "MASC_TLC_RESULTS_DIR" with
  | Some p when not (String.equal p "") -> p
  | _ -> Filename.get_temp_dir_name ()

let category_of_subdir = function
  | "boundary" -> "boundary"
  | "bug-models" -> "bug-models"
  | _ -> "other"

let is_tla_file name = Filename.check_suffix name ".tla"

let safe_stat_mtime path =
  try (Unix.stat path).st_mtime
  with Unix.Unix_error _ -> 0.0

let readdir_safe dir =
  try Sys.readdir dir |> Array.to_list
  with Sys_error _ -> []

let is_directory_safe p =
  try Sys.is_directory p
  with Sys_error _ -> false

let file_exists_safe p =
  try Sys.file_exists p
  with Sys_error _ -> false

let scan_subdir ~root sub =
  let subpath = Filename.concat root sub in
  if not (is_directory_safe subpath) then []
  else
    readdir_safe subpath
    |> List.filter is_tla_file
    |> List.map (fun f ->
      let name = Filename.chop_suffix f ".tla" in
      let file_path = Filename.concat subpath f in
      let clean_cfg = Filename.concat subpath (name ^ ".cfg") in
      let buggy_cfg = Filename.concat subpath (name ^ "-buggy.cfg") in
      {
        name;
        path = Filename.concat sub f;
        category = category_of_subdir sub;
        has_clean_cfg = file_exists_safe clean_cfg;
        has_buggy_cfg = file_exists_safe buggy_cfg;
        mtime = safe_stat_mtime file_path;
      })

let list_specs () =
  let root = specs_dir () in
  if not (is_directory_safe root) then []
  else
    readdir_safe root
    |> List.concat_map (fun sub -> scan_subdir ~root sub)
    |> List.sort (fun (a : spec_entry) (b : spec_entry) ->
      match String.compare a.category b.category with
      | 0 -> String.compare a.name b.name
      | c -> c)

let iso_of_unix_time t =
  let open Unix in
  let tm = gmtime t in
  Printf.sprintf "%04d-%02d-%02dT%02d:%02d:%02dZ"
    (tm.tm_year + 1900) (tm.tm_mon + 1) tm.tm_mday
    tm.tm_hour tm.tm_min tm.tm_sec

let entry_to_json e : Yojson.Safe.t =
  `Assoc [
    "name", `String e.name;
    "path", `String e.path;
    "category", `String e.category;
    "has_clean_cfg", `Bool e.has_clean_cfg;
    "has_buggy_cfg", `Bool e.has_buggy_cfg;
    "mtime_iso", `String (iso_of_unix_time e.mtime);
  ]

let specs_dir_json root =
  if not (file_exists_safe root) then `Null
  else
    try `String (Unix.realpath root)
    with Unix.Unix_error _ -> `String root

let specs_json () : Yojson.Safe.t =
  let root = specs_dir () in
  let entries = list_specs () in
  `Assoc [
    "updated_at", `String (iso_of_unix_time (Unix.gettimeofday ()));
    "specs_dir", specs_dir_json root;
    "count", `Int (List.length entries);
    "entries", `List (List.map entry_to_json entries);
  ]

let read_file_safe path =
  try
    let ic = Stdlib.open_in_bin path in
    Stdlib.Fun.protect
      ~finally:(fun () -> Stdlib.close_in_noerr ic)
      (fun () ->
         let len = Stdlib.in_channel_length ic in
         Stdlib.really_input_string ic len)
    |> fun contents -> Some contents
  with Sys_error _ | End_of_file -> None

let normalize_int s =
  Stdlib.String.to_seq s
  |> Stdlib.Seq.filter (fun c -> not (Char.equal c ','))
  |> String.of_seq
  |> Stdlib.int_of_string_opt

let contains_substring needle haystack =
  let needle_len = String.length needle in
  let haystack_len = String.length haystack in
  if needle_len = 0 then true
  else if needle_len > haystack_len then false
  else
    let rec loop i =
      i + needle_len <= haystack_len
      && (String.equal (Stdlib.String.sub haystack i needle_len) needle || loop (i + 1))
    in
    loop 0

let split_lines text =
  String.split_on_char '\n' text |> List.map String.trim

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

let ints_in_line line =
  line
  |> String.split_on_char ' '
  |> List.filter_map digit_token_to_int

let violation_line text =
  split_lines text
  |> List.find_opt (fun line ->
       contains_substring " is violated" line
       || contains_substring "Temporal properties were violated" line
       || contains_substring "Invariant " line
          && contains_substring "violated" line)
  |> Option.map String.trim

let status_of_log text =
  if contains_substring "Model checking completed. No error has been found." text
  then Tlc_passed
  else if Option.is_some (violation_line text)
  then Tlc_violated
  else if contains_substring "Error:" text
          || contains_substring "Exception" text
          || contains_substring "Parsing failed" text
  then Tlc_error
  else Tlc_running

let tlc_status_to_string = function
  | Tlc_passed -> "passed"
  | Tlc_violated -> "violated"
  | Tlc_running -> "running"
  | Tlc_queued -> "queued"
  | Tlc_error -> "error"
  | Tlc_not_run -> "not_run"

let metrics_of_log text =
  let state_pair =
    split_lines text
    |> List.find_map (fun line ->
         if contains_substring "states generated" line
            && contains_substring "distinct states" line
         then
           match ints_in_line line with
           | a :: b :: _ -> Some (a, b)
           | _ -> None
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
         if contains_substring "depth of the complete state graph search" line
         then
           match ints_in_line line with
           | value :: _ -> Some value
           | [] -> None
         else None)
  in
  states_explored, distinct_states, diameter

let cfg_entries_for_spec (entry : spec_entry) =
  let clean =
    if entry.has_clean_cfg then
      [ (entry.name ^ ".cfg", entry.name) ]
    else []
  in
  let buggy =
    if entry.has_buggy_cfg then
      [ (entry.name ^ "-buggy.cfg", entry.name ^ "-buggy") ]
    else []
  in
  clean @ buggy

let result_for_cfg ~results_dir (spec : spec_entry) (cfg_name, cfg_stem) =
  let log_path = Filename.concat results_dir ("tlc-" ^ cfg_stem ^ ".log") in
  match read_file_safe log_path with
  | None ->
      {
        spec_name = spec.name;
        cfg_name;
        category = spec.category;
        status = Tlc_not_run;
        states_explored = None;
        distinct_states = None;
        diameter = None;
        last_run_at = None;
        violation = None;
        log_path = None;
      }
  | Some text ->
      let states_explored, distinct_states, diameter = metrics_of_log text in
      {
        spec_name = spec.name;
        cfg_name;
        category = spec.category;
        status = status_of_log text;
        states_explored;
        distinct_states;
        diameter;
        last_run_at = Some (safe_stat_mtime log_path);
        violation = violation_line text;
        log_path = Some log_path;
      }

let list_tlc_results () =
  let results_dir = tlc_results_dir () in
  list_specs ()
  |> List.concat_map (fun spec ->
       cfg_entries_for_spec spec
       |> List.map (result_for_cfg ~results_dir spec))

let option_int_json = function
  | Some v -> `Int v
  | None -> `Null

let option_string_json = function
  | Some v -> `String v
  | None -> `Null

let option_time_json = function
  | Some v -> `String (iso_of_unix_time v)
  | None -> `Null

let tlc_entry_to_json e : Yojson.Safe.t =
  `Assoc [
    "spec_name", `String e.spec_name;
    "cfg_name", `String e.cfg_name;
    "category", `String e.category;
    "status", `String (tlc_status_to_string e.status);
    "states_explored", option_int_json e.states_explored;
    "distinct_states", option_int_json e.distinct_states;
    "diameter", option_int_json e.diameter;
    "last_run_at", option_time_json e.last_run_at;
    "violation", option_string_json e.violation;
    "log_path", option_string_json e.log_path;
  ]

let tlc_results_json () : Yojson.Safe.t =
  let results_dir = tlc_results_dir () in
  let entries = list_tlc_results () in
  `Assoc [
    "updated_at", `String (iso_of_unix_time (Unix.gettimeofday ()));
    "results_dir",
      (if is_directory_safe results_dir then
         try `String (Unix.realpath results_dir)
         with Unix.Unix_error _ -> `String results_dir
       else `Null);
    "count", `Int (List.length entries);
    "entries", `List (List.map tlc_entry_to_json entries);
  ]

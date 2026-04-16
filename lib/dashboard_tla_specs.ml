type spec_entry = {
  name : string;
  path : string;
  category : string;
  has_clean_cfg : bool;
  has_buggy_cfg : bool;
  mtime : float;
}

let specs_dir () =
  match Sys.getenv_opt "MASC_SPECS_DIR" with
  | Some p when p <> "" -> p
  | _ -> "specs"

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
    |> List.sort (fun a b ->
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

(** Diagnose runtime base-path facts with a single authoritative [.masc] root.

    The runtime no longer treats a cwd-local [.masc] tree as a second live
    authority. Cwd-relative fields remain observational only so health and
    startup payloads can explain where the process was launched from without
    reviving stale-path warnings or abort paths. *)

type t = {
  process_cwd : string;
  input_base_path : string option;
  effective_base_path : string;
  effective_masc_root : string;
  current_task_path : string;
  current_task_shape : string;
  current_task_error : string option;
  env_masc_base_path : string option;
  resolution_source : string option;
  effective_has_masc_dir : bool;
  effective_legacy_dirs : string list;
  roots_diverge : bool;
  strict_mode_requested : bool;
  startup_rejected : bool;
  startup_abort_eligible : bool;
  warning : string option;
}

let trim_opt = function
  | Some raw ->
      let trimmed = String.trim raw in
      if trimmed = "" then None else Some trimmed
  | None -> None

let strip_trailing_slashes path =
  let rec loop idx =
    if idx <= 1 then String.sub path 0 idx
    else if path.[idx - 1] = '/' then loop (idx - 1)
    else String.sub path 0 idx
  in
  if path = "" then "."
  else loop (String.length path)

let normalize_path ~cwd path =
  let base = strip_trailing_slashes (String.trim path) in
  let absolute =
    if Filename.is_relative base then Filename.concat cwd base else base
  in
  try Unix.realpath absolute with
  | Unix.Unix_error _ -> absolute

let dir_exists path =
  Sys.file_exists path && Sys.is_directory path

let legacy_dir_names = [ "perpetual"; "resident-keepers"; "rooms" ]

let legacy_dirs_under masc_root =
  if not (dir_exists masc_root) then
    []
  else
    List.filter (fun name -> dir_exists (Filename.concat masc_root name))
      legacy_dir_names

let format_legacy_dirs = function
  | [] -> "none"
  | dirs -> String.concat ", " dirs

let strict_mode_env_enabled () =
  match Sys.getenv_opt "MASC_BASE_PATH_STRICT" with
  | Some raw -> (
      match String.lowercase_ascii (String.trim raw) with
      | "1" | "true" | "yes" -> true
      | _ -> false)
  | None -> false

let resolution_source_opt ?resolution_source () =
  match resolution_source with
  | Some raw -> trim_opt (Some raw)
  | None -> trim_opt (Sys.getenv_opt "MASC_BASE_PATH_RESOLUTION_SOURCE")

let unix_error_to_string err op arg =
  let target =
    match String.trim arg with
    | "" -> ""
    | value -> Printf.sprintf " %S" value
  in
  Printf.sprintf "%s%s: %s" op target (Unix.error_message err)

let file_kind_to_shape = function
  | Unix.S_REG -> "regular"
  | Unix.S_DIR -> "directory"
  | Unix.S_CHR -> "character_device"
  | Unix.S_BLK -> "block_device"
  | Unix.S_LNK -> "symlink"
  | Unix.S_FIFO -> "fifo"
  | Unix.S_SOCK -> "socket"

let inspect_regular_current_task path =
  try
    let fd = Unix.openfile path [ Unix.O_RDWR ] 0 in
    (try Unix.close fd with Unix.Unix_error _ -> ());
    ("regular", None)
  with
  | Unix.Unix_error (err, op, arg) ->
      ("regular_unusable", Some (unix_error_to_string err op arg))

let inspect_current_task_path effective_masc_root =
  let path = Filename.concat effective_masc_root "current_task" in
  try
    let stat = Unix.lstat path in
    match stat.Unix.st_kind with
    | Unix.S_REG ->
        let shape, error = inspect_regular_current_task path in
        (path, shape, error)
    | kind ->
        ( path,
          file_kind_to_shape kind,
          Some
            (Printf.sprintf
               "expected absent or a regular read/write file, got %s"
               (file_kind_to_shape kind)) )
  with
  | Unix.Unix_error (Unix.ENOENT, _, _) -> (path, "absent", None)
  | Unix.Unix_error (err, op, arg) ->
      (path, "inaccessible", Some (unix_error_to_string err op arg))

let current_task_shape_ok = function
  | "absent" | "regular" -> true
  | _ -> false

let current_task_warning ~path ~shape ~error =
  if current_task_shape_ok shape then None
  else
    let detail =
      match error with
      | Some msg -> Printf.sprintf " (%s)" msg
      | None -> ""
    in
    Some
      (Printf.sprintf
         "Invalid current_task startup state: %s is %s%s; expected absent or \
          a regular read/write file. Repair by moving/removing the path \
          before starting the server."
         path shape detail)

let detect ?cwd ?env_masc_base_path ?strict ?input_base_path ?resolution_source
    ~effective_base_path ~effective_masc_root () =
  let cwd =
    match cwd with
    | Some path -> path
    | None -> Sys.getcwd ()
  in
  let cwd_norm = normalize_path ~cwd cwd in
  let effective_base_norm = normalize_path ~cwd effective_base_path in
  let effective_masc_norm = normalize_path ~cwd effective_masc_root in
  let current_task_path, current_task_shape, current_task_error =
    inspect_current_task_path effective_masc_norm
  in
  let effective_has_masc_dir = dir_exists effective_masc_norm in
  let effective_legacy_dirs = legacy_dirs_under effective_masc_norm in
  let roots_diverge = not (String.equal cwd_norm effective_base_norm) in
  let resolution_source = resolution_source_opt ?resolution_source () in
  let strict_mode_requested =
    match strict with
    | Some enabled -> enabled
    | None -> strict_mode_env_enabled ()
  in
  let warning =
    current_task_warning ~path:current_task_path ~shape:current_task_shape
      ~error:current_task_error
  in
  let startup_rejected = Option.is_some warning in
  let startup_abort_eligible = startup_rejected in
  {
    process_cwd = cwd_norm;
    input_base_path;
    effective_base_path = effective_base_norm;
    effective_masc_root = effective_masc_norm;
    current_task_path;
    current_task_shape;
    current_task_error;
    env_masc_base_path = trim_opt env_masc_base_path;
    resolution_source;
    effective_has_masc_dir;
    effective_legacy_dirs;
    roots_diverge;
    strict_mode_requested;
    startup_rejected;
    startup_abort_eligible;
    warning;
  }

let strict_violation (diag : t) =
  let _ = diag in
  false

let startup_should_abort diag =
  diag.startup_rejected || diag.startup_abort_eligible

let startup_lines (diag : t) =
  let lines =
    [
      Some (Printf.sprintf "   Process cwd: %s" diag.process_cwd);
      (match diag.input_base_path with
       | Some path when not (String.equal path diag.effective_base_path) ->
           Some (Printf.sprintf "   Base path (input): %s" path)
       | _ -> None);
      (match diag.env_masc_base_path with
       | Some path -> Some (Printf.sprintf "   MASC_BASE_PATH(env): %s" path)
       | None -> None);
      (match diag.resolution_source with
       | Some source -> Some (Printf.sprintf "   Base path source: %s" source)
       | None -> None);
      (match diag.warning with
       | Some message -> Some (Printf.sprintf "   Path warning: %s" message)
       | None -> None);
      (if diag.effective_has_masc_dir then
         Some
           (Printf.sprintf "   Active .masc legacy dirs: %s"
              (format_legacy_dirs diag.effective_legacy_dirs))
       else
         None);
      (if diag.strict_mode_requested then
         Some "   Path strict mode: enabled"
       else
         None);
      (if diag.startup_rejected then
         Some "   Path startup rejection: enabled"
       else
         None);
      (if startup_should_abort diag then
         Some
           (Printf.sprintf "   current_task path: %s (%s)"
              diag.current_task_path diag.current_task_shape)
       else
         None);
    ]
  in
  List.filter_map (fun line -> line) lines

let logged_once : bool ref = ref false

let log_startup_warning (diag : t) =
  match diag.warning with
  | Some message when not !logged_once ->
      logged_once := true;
      Log.Server.warn "%s%s" message
        (if diag.strict_mode_requested then " (strict mode enabled)" else "")
  | Some message ->
      Log.Server.debug "%s%s" message
        (if diag.strict_mode_requested then " (strict mode enabled)" else "")
  | None -> ()

let option_field name = function
  | Some value -> Some (name, `String value)
  | None -> None

let to_yojson (diag : t) =
  `Assoc
    ([
       ("cwd", `String diag.process_cwd);
       ("effective_base_path", `String diag.effective_base_path);
       ("effective_masc_root", `String diag.effective_masc_root);
       ("current_task_path", `String diag.current_task_path);
       ("current_task_shape", `String diag.current_task_shape);
       ("effective_has_masc_dir", `Bool diag.effective_has_masc_dir);
       ( "effective_legacy_dirs",
         `List (List.map (fun dir -> `String dir) diag.effective_legacy_dirs) );
       ("roots_diverge", `Bool diag.roots_diverge);
       ("strict_mode_requested", `Bool diag.strict_mode_requested);
       ("startup_rejected", `Bool diag.startup_rejected);
       ("startup_abort_eligible", `Bool diag.startup_abort_eligible);
       ("strict_violation", `Bool (strict_violation diag));
     ]
    @ List.filter_map (fun item -> item)
        [
          option_field "input_base_path" diag.input_base_path;
          option_field "env_masc_base_path" diag.env_masc_base_path;
          option_field "resolution_source" diag.resolution_source;
          option_field "current_task_error" diag.current_task_error;
          option_field "warning" diag.warning;
        ])

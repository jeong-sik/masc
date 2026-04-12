(** Diagnose runtime base-path mismatches that can make two [.masc] roots
    look simultaneously authoritative to operators. *)

type t = {
  process_cwd : string;
  input_base_path : string option;
  effective_base_path : string;
  effective_masc_root : string;
  env_masc_base_path : string option;
  resolution_source : string option;
  cwd_masc_root : string;
  cwd_has_masc_dir : bool;
  cwd_legacy_dirs : string list;
  effective_has_masc_dir : bool;
  effective_legacy_dirs : string list;
  roots_diverge : bool;
  dual_masc_roots : bool;
  fail_fast_enabled : bool;
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

let fail_fast_env_enabled () =
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

let explicit_resolution_source = function
  | Some ("explicit_env" | "explicit_cli") -> true
  | _ -> false

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
  let cwd_masc_root = normalize_path ~cwd (Filename.concat cwd_norm ".masc") in
  let cwd_has_masc_dir = dir_exists cwd_masc_root in
  let cwd_legacy_dirs = legacy_dirs_under cwd_masc_root in
  let effective_has_masc_dir = dir_exists effective_masc_norm in
  let effective_legacy_dirs = legacy_dirs_under effective_masc_norm in
  let roots_diverge = not (String.equal cwd_norm effective_base_norm) in
  let dual_masc_roots =
    roots_diverge
    && cwd_has_masc_dir
    && effective_has_masc_dir
    && not (String.equal cwd_masc_root effective_masc_norm)
  in
  let resolution_source = resolution_source_opt ?resolution_source () in
  (* Dual .masc roots only force fail-fast when the effective base
     path was derived from a cwd heuristic (i.e. NOT an explicit env
     or CLI flag). If the operator, CI harness, or test driver
     explicitly set [MASC_BASE_PATH] / [--base-path], the warning
     already documents that "runtime will use the explicit base path,
     but operator surfaces may inspect stale state from cwd" — that is
     exactly the contract that lets test harnesses point the server at
     a [/tmp/...-base-<hex>] directory from inside a checked-out git
     worktree that happens to carry its own committed [.masc/] tree.
     Pre-#6548 behavior had this escape; removing it broke the
     [Run SSE reconnect e2e] CI step which fails immediately on
     [Dual .masc roots are not supported]. *)
  let implicit_dual_roots =
    dual_masc_roots && not (explicit_resolution_source resolution_source)
  in
  let fail_fast_enabled =
    match strict with
    | Some enabled -> enabled || implicit_dual_roots
    | None -> fail_fast_env_enabled () || implicit_dual_roots
  in
  let warning =
    if dual_masc_roots then
      let stale_suffix =
        if cwd_legacy_dirs = [] then
          ""
        else
          Printf.sprintf
            "; ignored cwd .masc still contains legacy dirs (%s)"
            (format_legacy_dirs cwd_legacy_dirs)
      in
      if explicit_resolution_source resolution_source then
        Some
          (Printf.sprintf
             "process cwd (%s) differs from explicit effective base path (%s) and both .masc roots exist (%s vs %s); runtime will use the explicit base path, but operator surfaces may inspect stale state from cwd%s"
             cwd_norm effective_base_norm cwd_masc_root effective_masc_norm
             stale_suffix)
      else
        Some
          (Printf.sprintf
             "process cwd (%s) differs from effective base path (%s) and both .masc roots exist (%s vs %s); operator surfaces may inspect stale state%s"
             cwd_norm effective_base_norm cwd_masc_root effective_masc_norm
             stale_suffix)
    else
      None
  in
  {
    process_cwd = cwd_norm;
    input_base_path;
    effective_base_path = effective_base_norm;
    effective_masc_root = effective_masc_norm;
    env_masc_base_path = trim_opt env_masc_base_path;
    resolution_source;
    cwd_masc_root;
    cwd_has_masc_dir;
    cwd_legacy_dirs;
    effective_has_masc_dir;
    effective_legacy_dirs;
    roots_diverge;
    dual_masc_roots;
    fail_fast_enabled;
    warning;
  }

let strict_violation (diag : t) =
  (* Only a *heuristic* dual-root detection should abort startup. If the
     operator explicitly pointed the server at a base path via env or
     CLI, honor that decision — the warning still fires so operator
     tools can flag the stale cwd [.masc] tree, but the runtime must
     not kill itself out from under a CI/test harness or a developer
     who deliberately pointed at a tmp directory. Pairs with the same
     escape condition used to compute [fail_fast_enabled] above. *)
  diag.dual_masc_roots
  && not (explicit_resolution_source diag.resolution_source)

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
      (if diag.dual_masc_roots then
         Some
           (Printf.sprintf "   Ignored cwd .masc legacy dirs: %s"
              (format_legacy_dirs diag.cwd_legacy_dirs))
       else
         None);
      (if diag.effective_has_masc_dir then
         Some
           (Printf.sprintf "   Active .masc legacy dirs: %s"
              (format_legacy_dirs diag.effective_legacy_dirs))
       else
         None);
      (if diag.fail_fast_enabled then
         Some "   Path strict mode: enabled"
       else
         None);
    ]
  in
  List.filter_map (fun line -> line) lines

let _logged_once : bool ref = ref false

let log_startup_warning (diag : t) =
  match diag.warning with
  | Some message when not !_logged_once ->
      _logged_once := true;
      Log.Server.warn "%s%s" message
        (if diag.fail_fast_enabled then " (strict mode enabled)" else "")
  | Some message ->
      Log.Server.debug "%s%s" message
        (if diag.fail_fast_enabled then " (strict mode enabled)" else "")
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
       ("cwd_masc_root", `String diag.cwd_masc_root);
       ("cwd_has_masc_dir", `Bool diag.cwd_has_masc_dir);
       ("cwd_legacy_dirs", `List (List.map (fun dir -> `String dir) diag.cwd_legacy_dirs));
       ("effective_has_masc_dir", `Bool diag.effective_has_masc_dir);
       ( "effective_legacy_dirs",
         `List (List.map (fun dir -> `String dir) diag.effective_legacy_dirs) );
       ("roots_diverge", `Bool diag.roots_diverge);
       ("dual_masc_roots", `Bool diag.dual_masc_roots);
       ("fail_fast_enabled", `Bool diag.fail_fast_enabled);
       ("strict_violation", `Bool (strict_violation diag));
     ]
    @ List.filter_map (fun item -> item)
        [
          option_field "input_base_path" diag.input_base_path;
          option_field "env_masc_base_path" diag.env_masc_base_path;
          option_field "resolution_source" diag.resolution_source;
          option_field "warning" diag.warning;
        ])

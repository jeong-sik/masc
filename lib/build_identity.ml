(** Build identity for the running server process. *)

type t =
  { release_version : string
  ; binary_version : string
  ; repo_version : string option [@default None]
  ; commit : string option [@default None]
  ; commit_source : string option [@default None]
  ; binary_commit : string option [@default None]
  ; binary_commit_source : string option [@default None]
  ; source_fingerprint : string option [@default None]
  ; provenance_source : string [@default "absent"]
  ; executable_sha256 : string option [@default None]
  ; executable_provenance_path : string option [@default None]
  ; executable_provenance_sha256 : string option [@default None]
  ; binary_commit_unix_ts : float option [@default None]
  ; binary_commit_age_seconds : int option [@default None]
  ; repo_head_commit : string option [@default None]
  ; repo_head_commit_source : string option [@default None]
  ; repo_head_commit_unix_ts : float option [@default None]
  ; repo_head_commit_age_seconds : int option [@default None]
  ; executable_path : string [@default ""]
  ; executable_dir : string [@default ""]
  ; executable_in_worktree : bool [@default false]
  ; repo_root : string option [@default None]
  ; runtime_instance_id : string
  ; started_at : string
  ; uptime_seconds : int
  }
[@@deriving yojson { strict = false }]

let rec find_git_root dir =
  let git_marker = Filename.concat dir ".git" in
  if Sys.file_exists git_marker
  then Some dir
  else (
    let parent = Filename.dirname dir in
    if String.equal parent dir then None else find_git_root parent)
;;

let runtime_cwd () = Config_dir_resolver.current_working_dir ()

(** The path to try for the running binary, given what the process knows.

    A relative [argv0] is not relative to the current directory. POSIX says a
    name with no slash is looked up in [PATH], so joining "masc" to the cwd
    builds a path that does not exist -- ".../masc/masc" for a checkout named
    masc -- and every probe below then falls back to the cwd. That is not just
    a warning: {!pick_repo_candidates} exists to let the binary's own source
    tree outrank the cwd, and it cannot when the two are the same string.

    [Sys.executable_name] is what the runtime resolved at start-up, through
    _NSGetExecutablePath on macOS and /proc/self/exe on Linux, so it is the
    real binary even for a PATH launch. It is preferred, and joined to the cwd
    only when it carries a directory of its own.

    Pure -- exposed for unit testing. *)
let executable_candidate ~cwd ~executable_name ~argv0 =
  let cwd_relative name =
    (* Only a name that already carries a directory is cwd-relative. *)
    if Filename.is_relative name && String.contains name '/'
    then Some (Filename.concat cwd name)
    else if Filename.is_relative name
    then None
    else Some name
  in
  match cwd_relative executable_name with
  | Some path -> path
  | None ->
    (match cwd_relative argv0 with
     | Some path -> path
     | None ->
       (* Both are bare names resolved through PATH, which this cannot
          reproduce. Answer the name itself rather than a cwd-joined path
          that is certainly wrong. *)
       executable_name)
;;

let executable_path () =
  let cwd = runtime_cwd () in
  let argv0 = if Array.length Sys.argv > 0 then Sys.argv.(0) else cwd in
  let path =
    executable_candidate ~cwd ~executable_name:Sys.executable_name ~argv0
  in
  try Unix.realpath path with
  | exn ->
    Log.Identity.warn
      "build_identity: Unix.realpath failed for %s: %s"
      path
      (Printexc.to_string exn);
    path
;;

let executable_dir () = Filename.dirname (executable_path ())

let git_capture_output_result ~repo_root args =
  let argv = [ "git"; "-C"; repo_root ] @ args in
  match
    Process_eio.run_argv_with_status argv
  with
  | Unix.WEXITED 0, output -> Ok output
  | status, _ -> Error status
;;

let git_capture_output ~repo_root args =
  match git_capture_output_result ~repo_root args with
  | Ok output -> Some output
  | Error _ -> None
;;

let string_of_process_status = function
  | Unix.WEXITED code -> Printf.sprintf "exit %d" code
  | Unix.WSIGNALED signal -> Printf.sprintf "signal %d" signal
  | Unix.WSTOPPED signal -> Printf.sprintf "stopped %d" signal
;;

let git_probe_from_root repo_root =
  let output =
    try git_capture_output ~repo_root [ "rev-parse"; "--short"; "HEAD" ] with
    | Sys_error msg ->
      Log.Identity.warn "git_probe_from_root read failed: %s" msg;
      None
    | Unix.Unix_error (code, fn, arg) ->
      Log.Identity.warn
        "git_probe_from_root unix error: %s (%s %s)"
        (Unix.error_message code)
        fn
        arg;
      None
    | exn ->
      Log.Identity.warn "git_probe_from_root unexpected: %s" (Printexc.to_string exn);
      None
  in
  Option.bind output String_util.trim_nonempty
;;

let observe_probe_failure ~site exn =
  match exn with
  | Eio.Cancel.Cancelled _ as e -> raise e
  | exn ->
    Otel_metric_store.inc_counter
      Otel_metric_store.metric_build_identity_probe_failures
      ~labels:[ "site", site ]
      ();
    Log.Identity.warn "build_identity %s failed: %s" site (Printexc.to_string exn)
;;

(** Pick the ordered list of directories to probe for a git repo,
    executable_dir first so the binary's own source tree wins over
    whatever cwd the user started the process from.

    Rationale: running `cd ~/me && ~/.../masc/_build/.../main_eio.exe`
    used to report ~/me's git HEAD instead of masc's because the old
    implementation sorted candidates with [List.sort_uniq String.compare]
    and cwd happened to sort first alphabetically.

    Pure — exposed for unit testing. *)
let pick_repo_candidates ~exe_dir ~cwd =
  if String.equal exe_dir cwd then [ exe_dir ] else [ exe_dir; cwd ]
;;

let probe_git_commit () =
  pick_repo_candidates ~exe_dir:(executable_dir ()) ~cwd:(runtime_cwd ())
  |> List.find_map (fun dir ->
    match find_git_root dir with
    | Some root -> git_probe_from_root root
    | None -> None)
;;

let probe_repo_root () =
  pick_repo_candidates ~exe_dir:(executable_dir ()) ~cwd:(runtime_cwd ())
  |> List.find_map find_git_root
;;

let parse_dune_project_version raw =
  raw
  |> String.split_on_char '\n'
  |> List.find_map (fun line ->
    let line = String.trim line in
    let prefix = "(version " in
    if String.starts_with ~prefix line && String.ends_with ~suffix:")" line
    then
      String.sub
        line
        (String.length prefix)
        (String.length line - String.length prefix - String.length ")")
      |> String_util.trim_nonempty
    else None)
;;

let read_file path =
  try
    let ic = open_in path in
    Fun.protect
      ~finally:(fun () -> close_in_noerr ic)
      (fun () -> really_input_string ic (in_channel_length ic))
    |> fun contents -> Some contents
  with
  | Sys_error _ -> None
  | exn ->
    Log.Identity.warn "build_identity read_file %s failed: %s" path (Printexc.to_string exn);
    None
;;

let probe_repo_version repo_root =
  let dune_project = Filename.concat repo_root "dune-project" in
  Option.bind (read_file dune_project) parse_dune_project_version
;;

let decimal_digits_only s =
  String.length s > 0 && String.for_all (fun c -> c >= '0' && c <= '9') s
;;

(* 2100-01-01T00:00:00Z.  This keeps obviously corrupt/far-future git
   output out of /health while leaving enough workspace for normal source history
   and reproducible-build timestamps. *)
let max_reasonable_commit_unix_ts = 4_102_444_800L

let parse_commit_unix_ts_output raw =
  match String_util.trim_nonempty raw with
  | None -> None
  | Some s when not (decimal_digits_only s) -> None
  | Some s ->
    (match Int64.of_string_opt s with
     | Some ts
       when Int64.compare ts 0L >= 0
            && Int64.compare ts max_reasonable_commit_unix_ts <= 0 ->
       Some (Int64.to_float ts)
     | _ -> None)
;;

(** Probe the unix timestamp of [commit] from the same git repo we
    resolved [commit] against.  Best-effort: returns [None] if [commit]
    is [None], the repo cannot be located, or git fails / output is
    not a sane integer Unix timestamp.

    Why we run this: a 2026-05-05 fleet-stuck recurrence boiled down
    to a deploy gap — the server kept running an 8-hour-old binary
    while every fix-PR shipped to main.  Health endpoint had no signal
    that the running binary was behind, so the operator (rightly)
    re-asked the same diagnostic prompt 7 times before noticing.
    Surfacing [binary_commit_unix_ts] on /health closes that loop without
    requiring the dashboard to fetch anything from the git remote. *)
let probe_commit_unix_ts commit_hash_opt =
  match commit_hash_opt with
  | None -> None
  | Some commit_hash ->
    let repo_roots =
      pick_repo_candidates ~exe_dir:(executable_dir ()) ~cwd:(runtime_cwd ())
      |> List.filter_map find_git_root
      |> List.fold_left
           (fun roots repo_root ->
              if List.exists (String.equal repo_root) roots
              then roots
              else repo_root :: roots)
           []
      |> List.rev
    in
    let probe_one repo_root =
      let raw_opt =
        try
          match
            git_capture_output_result
              ~repo_root
              [ "log"; "-1"; "--format=%ct"; commit_hash ]
          with
          | Ok raw -> Some raw
          | Error status ->
            observe_probe_failure
              ~site:"commit_ts_git_status"
              (Failure
                 (Printf.sprintf
                    "git log failed with %s"
                    (string_of_process_status status)));
            None
        with
        | exn ->
          observe_probe_failure ~site:"commit_ts_git_capture" exn;
          None
      in
      match raw_opt with
      | None -> None
      | Some raw ->
        (match parse_commit_unix_ts_output raw with
         | Some ts -> Some ts
         | None ->
           observe_probe_failure
             ~site:"commit_ts_parse"
             (Failure (Printf.sprintf "invalid commit timestamp output %S" raw));
           None)
    in
    List.find_map probe_one repo_roots
;;

let resolve_commit ~embedded ~probe =
  match Option.bind embedded String_util.trim_nonempty with
  | Some commit -> Some commit
  | None -> probe ()
;;

type commit_resolution =
  { commit : string option
  ; commit_source : string option
  ; binary_commit : string option
  ; binary_commit_source : string option
  ; repo_head_commit : string option
  ; repo_head_commit_source : string option
  }

let embedded_commit_source = "embedded"
let runtime_repo_head_source = "runtime_repo_head"

let resolve_commit_details ~embedded ~probe =
  (* The binary's own testimony wins: the embedded hash is stamped by the
     build rule from the checkout being compiled, while the repo-head probe
     describes the source tree next to the process, which moves
     independently of the binary. *)
  let binary_commit, binary_commit_source =
    match Option.bind embedded String_util.trim_nonempty with
    | Some commit -> Some commit, Some embedded_commit_source
    | None -> None, None
  in
  let repo_head_commit = probe () in
  let commit, commit_source =
    match binary_commit, repo_head_commit with
    | Some commit, _ -> Some commit, binary_commit_source
    | None, Some commit -> Some commit, Some runtime_repo_head_source
    | None, None -> None, None
  in
  { commit
  ; commit_source
  ; binary_commit
  ; binary_commit_source
  ; repo_head_commit
  ; repo_head_commit_source = Option.map (fun _ -> runtime_repo_head_source) repo_head_commit
  }
;;

let age_seconds ~now ts_opt =
  match ts_opt with
  | None -> None
  | Some ts ->
    let age = now -. ts in
    if Float.is_finite age then Some (max 0 (int_of_float age)) else None
;;

let started_at_unix = Unix.gettimeofday ()
let started_at_iso = Masc_domain.iso8601_of_unix_seconds started_at_unix
let runtime_instance_id = Random_id.uuid_v7 ()
let resolved_executable_path = executable_path ()
let resolved_executable_dir = Filename.dirname resolved_executable_path

(* Worktrees live under <repo>/.worktrees/ by workspace convention
   (instructions/workflow-git.md); an executable resolved from inside one is
   a working tree's build serving live traffic, which operators repeatedly
   mistook for the root binary (2026-08-27: two restarts in one evening kept
   an old-generation worktree exe on the live port). Path convention is the
   SSOT here — there is no git probe that answers "was this exe built from a
   worktree" after the fact. *)
let path_is_in_worktree path =
  let marker = Filename.dir_sep ^ ".worktrees" ^ Filename.dir_sep in
  String_util.contains_substring path marker
;;

let resolved_executable_in_worktree = path_is_in_worktree resolved_executable_path

(** Commit hashes — eagerly resolved at startup.
    Not using [Eio.Lazy] because this is called from tests without Eio context.
    Embedded stamp + git probe are fast and side-effect-free. *)
let commit_resolution =
  resolve_commit_details
    ~embedded:Build_commit_generated.commit
    ~probe:probe_git_commit
;;

type executable_provenance =
  { binary_commit : string
  ; build_input_fingerprint : string
  ; source_root : string
  ; source_root_device : int
  ; source_root_inode : int
  ; dashboard_assets : dashboard_assets_provenance option
  ; executable_sha256 : string
  ; executable_device : int
  ; executable_inode : int
  }

and dashboard_asset_entry =
  { relative_path : string
  ; size : int
  ; sha256 : string
  }

and dashboard_assets_provenance =
  { source_root : string
  ; snapshot_root : string
  ; snapshot_device : int
  ; snapshot_inode : int
  ; tree_sha256 : string
  ; build_source_commit : string
  ; build_head_tree : string
  ; build_index_tree : string
  ; build_input_sha256 : string
  ; build_input_file_count : int
  ; build_input_matches_head : bool
  ; build_lock_sha256 : string
  ; build_mode : string
  ; build_environment_path : string
  ; build_environment_path_identity_sha256 : string
  ; build_environment_path_executable_sha256 : string
  ; build_environment_path_executable_count : int
  ; build_environment_profile_sha256 : string
  ; build_producer : string
  ; build_node_executable : string
  ; build_node_executable_sha256 : string
  ; build_node_version : string
  ; build_node_platform : string
  ; build_node_arch : string
  ; build_package_manager_kind : string
  ; build_package_manager_executable : string
  ; build_package_manager_executable_sha256 : string
  ; build_pnpm_version : string
  ; build_vite_version : string
  ; build_installed_graph_metadata_sha256 : string
  ; build_installed_graph_metadata_count : int
  ; files : dashboard_asset_entry list
  }

type source_root_invalid_reason =
  | Source_root_unreadable
  | Source_root_not_canonical
  | Source_root_not_directory
  | Source_root_owner_differs
  | Source_root_device_differs
  | Source_root_inode_differs

type launch_source_root_state =
  | Unbound
  | Bound_valid of string
  | Bound_invalid of source_root_invalid_reason

type dashboard_asset_invalid_reason =
  | Dashboard_source_root_invalid of source_root_invalid_reason
  | Dashboard_snapshot_unreadable
  | Dashboard_snapshot_not_canonical
  | Dashboard_snapshot_metadata_differs
  | Dashboard_asset_metadata_differs

type dashboard_asset_resolution =
  | Dashboard_assets_unbound
  | Dashboard_assets_invalid of dashboard_asset_invalid_reason
  | Dashboard_assets_unavailable
  | Dashboard_asset_not_manifested
  | Dashboard_asset_bound of
      { path : string
      ; launch_source_root : string
      ; launch_source_device : int
      ; launch_source_inode : int
      ; expected_size : int
      ; expected_sha256 : string
      ; tree_sha256 : string
      ; snapshot_root : string
      ; snapshot_device : int
      ; snapshot_inode : int
      ; file_count : int
      ; build_source_commit : string
      ; build_head_tree : string
      ; build_index_tree : string
      ; build_input_sha256 : string
      ; build_input_file_count : int
      ; build_input_matches_head : bool
      ; build_lock_sha256 : string
      ; build_mode : string
      ; build_environment_path : string
      ; build_environment_path_identity_sha256 : string
      ; build_environment_path_executable_sha256 : string
      ; build_environment_path_executable_count : int
      ; build_environment_profile_sha256 : string
      ; build_producer : string
      ; build_node_executable : string
      ; build_node_executable_sha256 : string
      ; build_node_version : string
      ; build_node_platform : string
      ; build_node_arch : string
      ; build_package_manager_kind : string
      ; build_package_manager_executable : string
      ; build_package_manager_executable_sha256 : string
      ; build_pnpm_version : string
      ; build_vite_version : string
      ; build_installed_graph_metadata_sha256 : string
      ; build_installed_graph_metadata_count : int
      }


let executable_provenance_schema = "masc.run-local-executable-identity.v2"
let dashboard_assets_schema = "masc.run-local-dashboard-assets.v1"
let sha256_hex_length = Digestif.SHA256.digest_size * 2

let valid_sha256 value =
  String.length value = sha256_hex_length
  && String.for_all
       (function
         | '0' .. '9' | 'a' .. 'f' -> true
         | _ -> false)
       value
;;

let parse_executable_provenance
      ~expected_binary_commit
      ~expected_executable_sha256
      ~expected_executable_device
      ~expected_executable_inode
      raw
  =
  let required_string fields name =
    match List.find_all (fun (field, _) -> String.equal field name) fields with
    | [ _, `String value ] -> Ok value
    | [ _ ] -> Error (Printf.sprintf "executable provenance %s is not a string" name)
    | [] -> Error (Printf.sprintf "executable provenance %s is missing" name)
    | _ -> Error (Printf.sprintf "executable provenance %s is duplicated" name)
  in
  let ( let* ) = Result.bind in
  let required_nonnegative_int fields name =
    match List.find_all (fun (field, _) -> String.equal field name) fields with
    | [ _, `Int value ] when value >= 0 -> Ok value
    | [ _ ] -> Error (Printf.sprintf "executable provenance %s is not a nonnegative integer" name)
    | [] -> Error (Printf.sprintf "executable provenance %s is missing" name)
    | _ -> Error (Printf.sprintf "executable provenance %s is duplicated" name)
  in
  let required_bool fields name =
    match List.find_all (fun (field, _) -> String.equal field name) fields with
    | [ _, `Bool value ] -> Ok value
    | [ _ ] -> Error (Printf.sprintf "executable provenance %s is not a boolean" name)
    | [] -> Error (Printf.sprintf "executable provenance %s is missing" name)
    | _ -> Error (Printf.sprintf "executable provenance %s is duplicated" name)
  in
  let required_assoc fields name =
    match List.find_all (fun (field, _) -> String.equal field name) fields with
    | [ _, `Assoc value ] -> Ok value
    | [ _ ] -> Error (Printf.sprintf "executable provenance %s is not an object" name)
    | [] -> Error (Printf.sprintf "executable provenance %s is missing" name)
    | _ -> Error (Printf.sprintf "executable provenance %s is duplicated" name)
  in
  let required_list fields name =
    match List.find_all (fun (field, _) -> String.equal field name) fields with
    | [ _, `List value ] -> Ok value
    | [ _ ] -> Error (Printf.sprintf "executable provenance %s is not a list" name)
    | [] -> Error (Printf.sprintf "executable provenance %s is missing" name)
    | _ -> Error (Printf.sprintf "executable provenance %s is duplicated" name)
  in
  let safe_relative_path value =
    String.length value > 0
    && Filename.is_relative value
    && not (String.contains value '\\')
    && not (String.contains value '\000')
    && (String.split_on_char '/' value
        |> List.for_all (fun segment ->
          String.length segment > 0
          && not (String.equal segment ".")
          && not (String.equal segment "..")))
  in
  let valid_lower_hex ~length value =
    String.length value = length
    && String.for_all
         (function
           | '0' .. '9' | 'a' .. 'f' -> true
           | _ -> false)
         value
  in
  let has_exact_fields fields expected =
    List.sort String.compare (List.map fst fields)
    = List.sort String.compare expected
  in
  let dashboard_asset_fields =
    [ "build_receipt"
    ; "file_count"
    ; "files"
    ; "schema"
    ; "snapshot_device"
    ; "snapshot_inode"
    ; "snapshot_root"
    ; "source_root"
    ; "state"
    ; "tree_sha256"
    ]
  in
  let dashboard_build_receipt_fields =
    [ "build_mode"
    ; "environment_path"
    ; "environment_path_executable_count"
    ; "environment_path_executable_sha256"
    ; "environment_path_identity_sha256"
    ; "environment_profile_sha256"
    ; "head_tree"
    ; "index_tree"
    ; "input_file_count"
    ; "input_matches_head"
    ; "input_sha256"
    ; "installed_graph_metadata_count"
    ; "installed_graph_metadata_sha256"
    ; "lock_sha256"
    ; "node_arch"
    ; "node_executable"
    ; "node_executable_sha256"
    ; "node_platform"
    ; "node_version"
    ; "output_file_count"
    ; "output_tree_sha256"
    ; "package_manager_executable"
    ; "package_manager_executable_sha256"
    ; "package_manager_kind"
    ; "pnpm_version"
    ; "producer"
    ; "schema"
    ; "source_commit"
    ; "source_root"
    ; "source_root_device"
    ; "source_root_inode"
    ; "vite_version"
    ]
  in
  let executable_provenance_fields =
    [ "binary_commit"
    ; "build_input_fingerprint"
    ; "dashboard_assets"
    ; "executable_device"
    ; "executable_inode"
    ; "executable_sha256"
    ; "schema"
    ; "source_root"
    ; "source_root_device"
    ; "source_root_inode"
    ]
  in
  let parse_dashboard_assets
        ~launch_source_root
        ~launch_source_device
        ~launch_source_inode
        fields
    =
    let* state = required_string fields "state" in
    if String.equal state "unavailable"
    then (
      let* reason = required_string fields "reason" in
      if has_exact_fields fields [ "reason"; "state" ]
         && String.equal reason "build_receipt_missing"
      then Ok None
      else Error "executable provenance dashboard unavailable state is invalid")
    else if not (String.equal state "available")
    then Error "executable provenance dashboard asset state is unsupported"
    else
    let* schema = required_string fields "schema" in
    let* source_root = required_string fields "source_root" in
    let* snapshot_root = required_string fields "snapshot_root" in
    let* snapshot_device = required_nonnegative_int fields "snapshot_device" in
    let* snapshot_inode = required_nonnegative_int fields "snapshot_inode" in
    let* tree_sha256 = required_string fields "tree_sha256" in
    let* file_count = required_nonnegative_int fields "file_count" in
    let* raw_files = required_list fields "files" in
    let* build_receipt = required_assoc fields "build_receipt" in
    let* build_schema = required_string build_receipt "schema" in
    let* build_producer = required_string build_receipt "producer" in
    let* build_source_root = required_string build_receipt "source_root" in
    let* build_source_device = required_nonnegative_int build_receipt "source_root_device" in
    let* build_source_inode = required_nonnegative_int build_receipt "source_root_inode" in
    let* build_source_commit = required_string build_receipt "source_commit" in
    let* build_head_tree = required_string build_receipt "head_tree" in
    let* build_index_tree = required_string build_receipt "index_tree" in
    let* build_input_sha256 = required_string build_receipt "input_sha256" in
    let* build_input_file_count = required_nonnegative_int build_receipt "input_file_count" in
    let* build_input_matches_head = required_bool build_receipt "input_matches_head" in
    let* build_lock_sha256 = required_string build_receipt "lock_sha256" in
    let* build_mode = required_string build_receipt "build_mode" in
    let* build_environment_path = required_string build_receipt "environment_path" in
    let* build_environment_path_identity_sha256 = required_string build_receipt "environment_path_identity_sha256" in
    let* build_environment_path_executable_sha256 = required_string build_receipt "environment_path_executable_sha256" in
    let* build_environment_path_executable_count = required_nonnegative_int build_receipt "environment_path_executable_count" in
    let* build_environment_profile_sha256 = required_string build_receipt "environment_profile_sha256" in
    let* build_node_executable = required_string build_receipt "node_executable" in
    let* build_node_executable_sha256 = required_string build_receipt "node_executable_sha256" in
    let* build_node_version = required_string build_receipt "node_version" in
    let* build_node_platform = required_string build_receipt "node_platform" in
    let* build_node_arch = required_string build_receipt "node_arch" in
    let* build_package_manager_kind = required_string build_receipt "package_manager_kind" in
    let* build_package_manager_executable = required_string build_receipt "package_manager_executable" in
    let* build_package_manager_executable_sha256 = required_string build_receipt "package_manager_executable_sha256" in
    let* build_pnpm_version = required_string build_receipt "pnpm_version" in
    let* build_vite_version = required_string build_receipt "vite_version" in
    let* build_installed_graph_metadata_sha256 = required_string build_receipt "installed_graph_metadata_sha256" in
    let* build_installed_graph_metadata_count = required_nonnegative_int build_receipt "installed_graph_metadata_count" in
    let* build_output_sha256 = required_string build_receipt "output_tree_sha256" in
    let* build_output_count = required_nonnegative_int build_receipt "output_file_count" in
    let parse_file = function
      | `Assoc file_fields when has_exact_fields file_fields [ "path"; "sha256"; "size" ] ->
        let* relative_path = required_string file_fields "path" in
        let* size = required_nonnegative_int file_fields "size" in
        let* sha256 = required_string file_fields "sha256" in
        if not (safe_relative_path relative_path)
        then Error "executable provenance dashboard asset path is invalid"
        else if not (valid_sha256 sha256)
        then Error "executable provenance dashboard asset digest is invalid"
        else Ok { relative_path; size; sha256 }
      | `Assoc _ -> Error "executable provenance dashboard asset has unsupported fields"
      | _ -> Error "executable provenance dashboard asset is not an object"
    in
    let rec parse_files acc = function
      | [] -> Ok (List.rev acc)
      | raw_file :: rest ->
        let* file = parse_file raw_file in
        parse_files (file :: acc) rest
    in
    let* files = parse_files [] raw_files in
    let unique_paths =
      files
      |> List.map (fun file -> file.relative_path)
      |> List.sort_uniq String.compare
    in
    let ordered_paths = List.map (fun file -> file.relative_path) files in
    let canonical_tree_sha256 =
      `List
        (List.map
           (fun file ->
             `Assoc
               [ "path", `String file.relative_path
               ; "sha256", `String file.sha256
               ; "size", `Int file.size
               ])
           files)
      |> Yojson.Safe.to_string
      |> fun value -> Digestif.SHA256.(digest_string value |> to_hex)
    in
    let environment_paths = String.split_on_char ':' build_environment_path in
    let environment_paths_are_valid =
      environment_paths <> []
      && List.for_all
           (fun path -> String_util.trim_nonempty path <> None && not (Filename.is_relative path))
           environment_paths
      && List.length environment_paths
         = List.length (List.sort_uniq String.compare environment_paths)
    in
    if not (has_exact_fields fields dashboard_asset_fields)
    then Error "executable provenance dashboard assets has unsupported fields"
    else if not (has_exact_fields build_receipt dashboard_build_receipt_fields)
    then Error "executable provenance dashboard build receipt has unsupported fields"
    else if not (String.equal schema dashboard_assets_schema)
    then Error "executable provenance dashboard assets schema is unsupported"
    else if not (String.equal build_schema "masc.run-local-dashboard-build.v1")
    then Error "executable provenance dashboard build receipt schema is unsupported"
    else if not (String.equal build_producer "scripts/build-dashboard-if-needed.sh --prepare-exact + --build-exact")
    then Error "executable provenance dashboard build producer is unsupported"
    else if not (String.equal build_mode "production")
    then Error "executable provenance dashboard build mode is unsupported"
    else if not environment_paths_are_valid
    then Error "executable provenance dashboard build environment path is invalid"
    else if Filename.is_relative source_root || Filename.is_relative snapshot_root
    then Error "executable provenance dashboard asset root is not absolute"
    else if not (valid_sha256 tree_sha256)
    then Error "executable provenance dashboard tree digest is invalid"
    else if not (String.equal canonical_tree_sha256 tree_sha256)
    then Error "executable provenance dashboard tree digest differs from manifest"
    else if not (valid_sha256 build_input_sha256)
    then Error "executable provenance dashboard input digest is invalid"
    else if not (valid_sha256 build_lock_sha256)
            || not (valid_sha256 build_environment_path_identity_sha256)
            || not (valid_sha256 build_environment_path_executable_sha256)
            || not (valid_sha256 build_environment_profile_sha256)
            || not (valid_sha256 build_node_executable_sha256)
            || not (valid_sha256 build_package_manager_executable_sha256)
            || not (valid_sha256 build_installed_graph_metadata_sha256)
    then Error "executable provenance dashboard build identity digest is invalid"
    else if Filename.is_relative build_node_executable
            || Filename.is_relative build_package_manager_executable
    then Error "executable provenance dashboard toolchain path is not absolute"
    else if build_environment_path_executable_count = 0
    then Error "executable provenance dashboard PATH executable inventory is empty"
    else if List.exists
              (fun value -> String_util.trim_nonempty value = None)
              [ build_node_version
              ; build_node_platform
              ; build_node_arch
              ; build_pnpm_version
              ; build_vite_version
              ]
    then Error "executable provenance dashboard toolchain identity is blank"
    else if not (String.equal build_package_manager_kind "pnpm"
                 || String.equal build_package_manager_kind "corepack")
    then Error "executable provenance dashboard package-manager kind is invalid"
    else if not (valid_lower_hex ~length:40 build_head_tree)
            || not (valid_lower_hex ~length:40 build_index_tree)
    then Error "executable provenance dashboard source tree identity is invalid"
    else if not (String.equal source_root (Filename.concat launch_source_root "assets/dashboard"))
    then Error "executable provenance dashboard source asset root differs"
    else if not (String.equal build_source_commit expected_binary_commit)
    then Error "executable provenance dashboard source commit differs"
    else if not (String.equal build_source_root launch_source_root)
            || build_source_device <> launch_source_device
            || build_source_inode <> launch_source_inode
    then Error "executable provenance dashboard source identity differs"
    else if not (String.equal build_output_sha256 tree_sha256)
            || build_output_count <> file_count
    then Error "executable provenance dashboard output identity differs"
    else if file_count <> List.length files
    then Error "executable provenance dashboard file count differs"
    else if List.length unique_paths <> List.length files
    then Error "executable provenance dashboard asset paths are duplicated"
    else if ordered_paths <> List.sort String.compare ordered_paths
    then Error "executable provenance dashboard asset paths are not ordered"
    else if not (List.exists (fun file -> String.equal file.relative_path "index.html") files)
    then Error "executable provenance dashboard index is missing"
    else
      Ok (Some
        { source_root
        ; snapshot_root
        ; snapshot_device
        ; snapshot_inode
        ; tree_sha256
        ; build_source_commit
        ; build_head_tree
        ; build_index_tree
        ; build_input_sha256
        ; build_input_file_count
        ; build_input_matches_head
        ; build_lock_sha256
        ; build_mode
        ; build_environment_path
        ; build_environment_path_identity_sha256
        ; build_environment_path_executable_sha256
        ; build_environment_path_executable_count
        ; build_environment_profile_sha256
        ; build_producer
        ; build_node_executable
        ; build_node_executable_sha256
        ; build_node_version
        ; build_node_platform
        ; build_node_arch
        ; build_package_manager_kind
        ; build_package_manager_executable
        ; build_package_manager_executable_sha256
        ; build_pnpm_version
        ; build_vite_version
        ; build_installed_graph_metadata_sha256
        ; build_installed_graph_metadata_count
        ; files
        })
  in
  match Yojson.Safe.from_string raw with
  | exception Yojson.Json_error message -> Error ("invalid executable provenance JSON: " ^ message)
  | `Assoc fields when has_exact_fields fields executable_provenance_fields ->
    let* schema = required_string fields "schema" in
    let* binary_commit = required_string fields "binary_commit" in
    let* build_input_fingerprint = required_string fields "build_input_fingerprint" in
    let* source_root = required_string fields "source_root" in
    let* source_root_device = required_nonnegative_int fields "source_root_device" in
    let* source_root_inode = required_nonnegative_int fields "source_root_inode" in
    let* dashboard_assets_fields = required_assoc fields "dashboard_assets" in
    let* dashboard_assets =
      parse_dashboard_assets
        ~launch_source_root:source_root
        ~launch_source_device:source_root_device
        ~launch_source_inode:source_root_inode
        dashboard_assets_fields
    in
    let* executable_sha256 = required_string fields "executable_sha256" in
    let* executable_device = required_nonnegative_int fields "executable_device" in
    let* executable_inode = required_nonnegative_int fields "executable_inode" in
    if not (String.equal schema executable_provenance_schema)
    then Error "executable provenance schema is unsupported"
    else if not (String.equal binary_commit expected_binary_commit)
    then Error "executable provenance binary commit differs"
    else if not (valid_sha256 build_input_fingerprint)
    then Error "executable provenance build-input fingerprint is invalid"
    else if Filename.is_relative source_root
    then Error "executable provenance source root is not absolute"
    else if not (valid_sha256 executable_sha256)
    then Error "executable provenance executable digest is invalid"
    else if not (String.equal executable_sha256 expected_executable_sha256)
    then Error "executable provenance executable digest differs"
    else if executable_device <> expected_executable_device
    then Error "executable provenance executable device differs"
    else if executable_inode <> expected_executable_inode
    then Error "executable provenance executable inode differs"
    else
      Ok
        { binary_commit
        ; build_input_fingerprint
        ; source_root
        ; source_root_device
        ; source_root_inode
        ; dashboard_assets
        ; executable_sha256
        ; executable_device
        ; executable_inode
        }
  | `Assoc _ -> Error "executable provenance has unsupported fields"
  | _ -> Error "executable provenance is not an object"
;;

let sha256_channel ic =
  let buffer = Bytes.create Sys.io_buffer_size in
  let rec loop context =
    match input ic buffer 0 (Bytes.length buffer) with
    | 0 -> Digestif.SHA256.(get context |> to_hex)
    | count -> Digestif.SHA256.feed_bytes context ~off:0 ~len:count buffer |> loop
  in
  loop Digestif.SHA256.empty
;;

let sha256_string value = Digestif.SHA256.(digest_string value |> to_hex)

(* The hash of the binary that is running, read from its own path.

   Not the same claim as the launcher's. run-local.sh rebuilds, hashes the
   link result, and refuses to exec if anything moved between the two -- its
   number says "this is the binary that build produced". This one says only
   "this is the binary answering you". Both are worth having and they must
   not arrive under one name, which is what [provenance_source] is for.

   Failure is absence, not a guess: an unreadable executable leaves the field
   out rather than reporting a hash of nothing. *)
(* Memoised per path, because [current ()] is called on every render frame and
   the executable does not change under a running process. Hashing a 60 MB
   binary each frame put the TUI at 88% of a core, all of it in
   sha256_do_chunk. *)
let self_observed_cache : (string * string option) option Atomic.t =
  Atomic.make None
;;

let self_observed_executable_sha256_uncached path =
  match open_in_bin path with
  | exception Sys_error _ -> None
  | ic ->
    Fun.protect ~finally:(fun () -> close_in_noerr ic) (fun () ->
      match sha256_channel ic with
      | digest -> Some digest
      | exception Sys_error _ -> None)
;;

let self_observed_executable_sha256 path =
  match Atomic.get self_observed_cache with
  | Some (cached_path, digest) when String.equal cached_path path -> digest
  | _ ->
    let digest = self_observed_executable_sha256_uncached path in
    Atomic.set self_observed_cache (Some (path, digest));
    digest
;;

let validate_source_root_identity provenance =
  try
    let canonical_source_root = Unix.realpath provenance.source_root in
    let source_root_stat = Unix.stat canonical_source_root in
    if not (String.equal canonical_source_root provenance.source_root)
    then Bound_invalid Source_root_not_canonical
    else if source_root_stat.st_kind <> Unix.S_DIR
    then Bound_invalid Source_root_not_directory
    else if source_root_stat.st_uid <> Unix.geteuid ()
    then Bound_invalid Source_root_owner_differs
    else if source_root_stat.st_dev <> provenance.source_root_device
    then Bound_invalid Source_root_device_differs
    else if source_root_stat.st_ino <> provenance.source_root_inode
    then Bound_invalid Source_root_inode_differs
    else Bound_valid provenance.source_root
  with
  | Sys_error _ | Unix.Unix_error _ -> Bound_invalid Source_root_unreadable
;;

let validate_dashboard_snapshot_identity dashboard_assets =
  try
    let canonical_root = Unix.realpath dashboard_assets.snapshot_root in
    let snapshot_stat = Unix.stat canonical_root in
    if not (String.equal canonical_root dashboard_assets.snapshot_root)
    then Error Dashboard_snapshot_not_canonical
    else if snapshot_stat.st_kind <> Unix.S_DIR
            || snapshot_stat.st_uid <> Unix.geteuid ()
            || snapshot_stat.st_perm <> 0o700
            || snapshot_stat.st_dev <> dashboard_assets.snapshot_device
            || snapshot_stat.st_ino <> dashboard_assets.snapshot_inode
    then Error Dashboard_snapshot_metadata_differs
    else Ok canonical_root
  with
  | Sys_error _ | Unix.Unix_error _ -> Error Dashboard_snapshot_unreadable
;;

let validate_executable_provenance_binding
      ~path
      ~expected_sidecar_sha256
      ~expected_sidecar_device
      ~expected_sidecar_inode
      ~expected_binary_commit
      ~expected_executable_sha256
      ~expected_executable_device
      ~expected_executable_inode
  =
  if Filename.is_relative path
  then Error "executable provenance path is not absolute"
  else if not (valid_sha256 expected_sidecar_sha256)
  then Error "executable provenance sidecar digest is invalid"
  else
    try
      let ic = open_in_bin path in
      Fun.protect
        ~finally:(fun () -> close_in_noerr ic)
        (fun () ->
          match Unix.fstat (Unix.descr_of_in_channel ic) with
          | { st_kind = Unix.S_REG; st_uid; st_perm; st_nlink; st_dev; st_ino; _ }
            when st_uid = Unix.geteuid ()
                 && st_perm = 0o400
                 && st_nlink = 1
                 && st_dev = expected_sidecar_device
                 && st_ino = expected_sidecar_inode ->
            let raw = really_input_string ic (in_channel_length ic) in
            if not (String.equal (sha256_string raw) expected_sidecar_sha256)
            then Error "executable provenance sidecar digest differs"
            else
              Result.bind
                (parse_executable_provenance
                   ~expected_binary_commit
                   ~expected_executable_sha256
                   ~expected_executable_device
                   ~expected_executable_inode
                   raw)
                (fun provenance ->
                match validate_source_root_identity provenance with
                | Unbound -> Error "executable provenance source root is unbound"
                | Bound_invalid Source_root_unreadable ->
                  Error "executable provenance source root is unreadable"
                | Bound_invalid Source_root_not_canonical ->
                  Error "executable provenance source root is not canonical"
                | Bound_invalid Source_root_not_directory ->
                  Error "executable provenance source root is not a directory"
                | Bound_invalid Source_root_owner_differs ->
                  Error "executable provenance source root owner differs"
                | Bound_invalid Source_root_device_differs ->
                  Error "executable provenance source root device differs"
                | Bound_invalid Source_root_inode_differs ->
                  Error "executable provenance source root inode differs"
                | Bound_valid _ ->
                  (match provenance.dashboard_assets with
                   | None -> Ok provenance
                   | Some dashboard_assets ->
                     (match validate_dashboard_snapshot_identity dashboard_assets with
                      | Ok _ -> Ok provenance
                      | Error _ -> Error "executable provenance dashboard snapshot differs")))
          | _ -> Error "executable provenance sidecar metadata differs")
    with
    | Sys_error _ | Unix.Unix_error _ ->
      Error "executable provenance sidecar is unreadable"
;;

module String_map = Map.Make (String)

type bound_executable_provenance =
  { path : string
  ; sidecar_sha256 : string
  ; provenance : executable_provenance
  ; dashboard_asset_index : dashboard_asset_entry String_map.t
  }

let executable_provenance_binding : bound_executable_provenance option Atomic.t =
  Atomic.make None
;;

let dashboard_asset_index provenance =
  Option.fold ~none:[] ~some:(fun assets -> assets.files) provenance.dashboard_assets
  |> List.fold_left
       (fun index file -> String_map.add file.relative_path file index)
       String_map.empty
;;

let bind_executable_provenance ~path ~sha256 ~device ~inode =
  let ( let* ) = Result.bind in
  let* expected_binary_commit =
    match commit_resolution.binary_commit with
    | Some value -> Ok value
    | None -> Error "running executable has no embedded commit"
  in
  let* executable_stat, expected_executable_sha256 =
    try
      let ic = open_in_bin resolved_executable_path in
      Fun.protect
        ~finally:(fun () -> close_in_noerr ic)
        (fun () ->
          match Unix.fstat (Unix.descr_of_in_channel ic) with
          | { st_kind = Unix.S_REG; st_uid; st_perm; st_nlink; _ } as value
            when st_uid = Unix.geteuid () && st_perm = 0o500 && st_nlink = 1 ->
            Ok (value, sha256_channel ic)
          | _ -> Error "running executable metadata differs")
    with
    | Sys_error _ | Unix.Unix_error _ ->
      Error "running executable cannot be inspected"
  in
  let* provenance =
    validate_executable_provenance_binding
      ~path
      ~expected_sidecar_sha256:sha256
      ~expected_sidecar_device:device
      ~expected_sidecar_inode:inode
      ~expected_binary_commit
      ~expected_executable_sha256
      ~expected_executable_device:executable_stat.st_dev
      ~expected_executable_inode:executable_stat.st_ino
  in
  let dashboard_asset_index = dashboard_asset_index provenance in
  let binding = { path; sidecar_sha256 = sha256; provenance; dashboard_asset_index } in
  let rec publish () =
    match Atomic.get executable_provenance_binding with
    | Some existing when existing = binding -> Ok ()
    | Some _ -> Error "executable provenance was already bound to another identity"
    | None ->
      if Atomic.compare_and_set executable_provenance_binding None (Some binding)
      then Ok ()
      else publish ()
  in
  publish ()
;;

let resolved_repo_root = probe_repo_root ()

let launch_source_root_state () =
  match Atomic.get executable_provenance_binding with
  | None -> Unbound
  | Some binding -> validate_source_root_identity binding.provenance
;;

let repo_root () =
  match launch_source_root_state () with
  | Unbound -> resolved_repo_root
  | Bound_valid source_root -> Some source_root
  | Bound_invalid _ -> None
;;

let resolve_dashboard_asset_in_binding binding relative_path =
    (match validate_source_root_identity binding.provenance with
     | Unbound -> Dashboard_assets_unbound
     | Bound_invalid reason ->
       Dashboard_assets_invalid (Dashboard_source_root_invalid reason)
     | Bound_valid _ ->
       (match binding.provenance.dashboard_assets with
        | None -> Dashboard_assets_unavailable
        | Some dashboard_assets ->
       (match validate_dashboard_snapshot_identity dashboard_assets with
        | Error reason -> Dashboard_assets_invalid reason
        | Ok snapshot_root ->
          (match String_map.find_opt relative_path binding.dashboard_asset_index with
           | None -> Dashboard_asset_not_manifested
           | Some file ->
             let path = Filename.concat snapshot_root file.sha256 in
             (try
                let info = Unix.lstat path in
                if info.st_kind <> Unix.S_REG
                   || info.st_uid <> Unix.geteuid ()
                   || info.st_perm <> 0o600
                   || info.st_nlink <> 1
                   || info.st_size <> file.size
                then Dashboard_assets_invalid Dashboard_asset_metadata_differs
                else
                  Dashboard_asset_bound
                    { path
                    ; launch_source_root = binding.provenance.source_root
                    ; launch_source_device = binding.provenance.source_root_device
                    ; launch_source_inode = binding.provenance.source_root_inode
                    ; expected_size = file.size
                    ; expected_sha256 = file.sha256
                    ; tree_sha256 = dashboard_assets.tree_sha256
                    ; snapshot_root
                    ; snapshot_device = dashboard_assets.snapshot_device
                    ; snapshot_inode = dashboard_assets.snapshot_inode
                    ; file_count = String_map.cardinal binding.dashboard_asset_index
                    ; build_source_commit = dashboard_assets.build_source_commit
                    ; build_head_tree = dashboard_assets.build_head_tree
                    ; build_index_tree = dashboard_assets.build_index_tree
                    ; build_input_sha256 = dashboard_assets.build_input_sha256
                    ; build_input_file_count = dashboard_assets.build_input_file_count
                    ; build_input_matches_head = dashboard_assets.build_input_matches_head
                    ; build_lock_sha256 = dashboard_assets.build_lock_sha256
                    ; build_mode = dashboard_assets.build_mode
                    ; build_environment_path = dashboard_assets.build_environment_path
                    ; build_environment_path_identity_sha256 = dashboard_assets.build_environment_path_identity_sha256
                    ; build_environment_path_executable_sha256 = dashboard_assets.build_environment_path_executable_sha256
                    ; build_environment_path_executable_count = dashboard_assets.build_environment_path_executable_count
                    ; build_environment_profile_sha256 = dashboard_assets.build_environment_profile_sha256
                    ; build_producer = dashboard_assets.build_producer
                    ; build_node_executable = dashboard_assets.build_node_executable
                    ; build_node_executable_sha256 = dashboard_assets.build_node_executable_sha256
                    ; build_node_version = dashboard_assets.build_node_version
                    ; build_node_platform = dashboard_assets.build_node_platform
                    ; build_node_arch = dashboard_assets.build_node_arch
                    ; build_package_manager_kind = dashboard_assets.build_package_manager_kind
                    ; build_package_manager_executable = dashboard_assets.build_package_manager_executable
                    ; build_package_manager_executable_sha256 = dashboard_assets.build_package_manager_executable_sha256
                    ; build_pnpm_version = dashboard_assets.build_pnpm_version
                    ; build_vite_version = dashboard_assets.build_vite_version
                    ; build_installed_graph_metadata_sha256 = dashboard_assets.build_installed_graph_metadata_sha256
                    ; build_installed_graph_metadata_count = dashboard_assets.build_installed_graph_metadata_count
                    }
              with
              | Sys_error _ | Unix.Unix_error _ ->
                Dashboard_assets_invalid Dashboard_asset_metadata_differs)))))
;;

let resolve_dashboard_asset relative_path =
  match Atomic.get executable_provenance_binding with
  | None -> Dashboard_assets_unbound
  | Some binding -> resolve_dashboard_asset_in_binding binding relative_path
;;

let dashboard_manifest_identity () =
  match Atomic.get executable_provenance_binding with
  | None -> None
  | Some binding -> binding.provenance.dashboard_assets
;;


let binary_commit_unix_ts = probe_commit_unix_ts commit_resolution.binary_commit
let repo_head_commit_unix_ts = probe_commit_unix_ts commit_resolution.repo_head_commit

let current () =
  let now = Unix.gettimeofday () in
  let provenance_binding = Atomic.get executable_provenance_binding in
  let active_repo_root = repo_root () in
  let repo_version = Option.bind active_repo_root probe_repo_version in
  let repo_head_commit, repo_head_commit_source, repo_head_commit_unix_ts =
    match provenance_binding with
    | Some binding ->
      ( Some binding.provenance.binary_commit
      , Some runtime_repo_head_source
      , binary_commit_unix_ts )
    | None ->
      ( commit_resolution.repo_head_commit
      , commit_resolution.repo_head_commit_source
      , repo_head_commit_unix_ts )
  in
  { release_version = Runtime_build_version.current
  ; binary_version = Runtime_build_version.current
  ; repo_version
  ; commit = commit_resolution.commit
  ; commit_source = commit_resolution.commit_source
  ; binary_commit = commit_resolution.binary_commit
  ; binary_commit_source = commit_resolution.binary_commit_source
  ; source_fingerprint =
      Option.map
        (fun binding -> binding.provenance.build_input_fingerprint)
        provenance_binding
  ; provenance_source =
      (match provenance_binding with
       | Some _ -> "launcher_verified"
       | None -> "self_observed")
  ; executable_sha256 =
      (match provenance_binding with
       | Some binding -> Some binding.provenance.executable_sha256
       | None -> self_observed_executable_sha256 resolved_executable_path)
  ; executable_provenance_path = Option.map (fun binding -> binding.path) provenance_binding
  ; executable_provenance_sha256 =
      Option.map (fun binding -> binding.sidecar_sha256) provenance_binding
  ; binary_commit_unix_ts
  ; binary_commit_age_seconds = age_seconds ~now binary_commit_unix_ts
  ; repo_head_commit
  ; repo_head_commit_source
  ; repo_head_commit_unix_ts
  ; repo_head_commit_age_seconds = age_seconds ~now repo_head_commit_unix_ts
  ; executable_path = resolved_executable_path
  ; executable_dir = resolved_executable_dir
  ; executable_in_worktree = resolved_executable_in_worktree
  ; repo_root = active_repo_root
  ; runtime_instance_id
  ; started_at = started_at_iso
  ; uptime_seconds = max 0 (int_of_float (now -. started_at_unix))
  }
;;

module For_testing = struct
  let validate_executable_provenance_binding = validate_executable_provenance_binding
  let observe_probe_failure = observe_probe_failure
  let probe_commit_unix_ts = probe_commit_unix_ts
  let runtime_cwd = runtime_cwd
  let resolve_dashboard_asset provenance relative_path =
    resolve_dashboard_asset_in_binding
      { path = "<test>"
      ; sidecar_sha256 = ""
      ; provenance
      ; dashboard_asset_index = dashboard_asset_index provenance
      }
      relative_path
end

(* [to_yojson] is generated by [ppx_deriving_yojson] from the type definition. *)

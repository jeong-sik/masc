open Keeper_types
open Keeper_meta_contract
open Keeper_types_profile
open Keeper_tool_shared_runtime
open Result.Syntax

(* Issue #8490: Variant SSOT for filesystem write mode. Adding a constructor
   forces compilation in [fs_write_mode_to_string] and
   [fs_write_mode_dispatch] AND extends [valid_fs_write_mode_strings];
   the schema mirrors the SSOT through [Tool_shard_types] (cycle
   avoidance per #8480/#8484 pattern). The previous code used 5 hardcoded sites:
   parse default, validate, dispatch, label normalisation, and schema. *)
type fs_write_mode =
  | Overwrite
  | Append
  | Patch
  (** RFC-0006 Phase A.4: read-replace-write for the Anthropic Code
        [Edit] cognate. Caller supplies [old_string] + [new_string]
        (and optional [replace_all]) instead of [content]. *)

let fs_write_mode_to_string = function
  | Overwrite -> "overwrite"
  | Append -> "append"
  | Patch -> "patch"
;;

(* Sound partial parser: only canonical mode strings decode to a real
   variant. Missing mode defaults before this parser; explicit empty
   strings are invalid input. *)
let fs_write_mode_of_string_opt raw =
  match String.trim (String.lowercase_ascii raw) with
  | "overwrite" -> Some Overwrite
  | "append" -> Some Append
  | "patch" -> Some Patch
  | _ -> None
;;

let all_fs_write_modes = [ Overwrite; Append; Patch ]
let valid_fs_write_mode_strings = List.map fs_write_mode_to_string all_fs_write_modes

(** Read max_bytes clamp. [read_file_default_max_bytes] is the
    canonical default; [Tool_shard_limits.read_file_default_max_bytes]
    re-exports it at a leaf module so the tool schema in tool_shard.ml
    can reference the same value without creating a dependency cycle. *)
let read_file_default_max_bytes = Tool_shard_limits.read_file_default_max_bytes

let read_file_min_max_bytes = 512
let read_file_max_max_bytes = 200_000

type read_file_resolution_error = Read_path_error of string

let string_opt_nonempty name json =
  match Safe_ops.json_string_opt name json with
  | None -> None
  | Some raw ->
    let trimmed = String.trim raw in
    if trimmed = "" then None else Some trimmed
;;

let resolve_read_file_cwd ~(config : Workspace.config) ~(meta : keeper_meta) ~cwd =
  match cwd with
  | None -> Ok (keeper_default_read_root ~config ~meta)
  | Some raw_cwd ->
    let* cwd = resolve_keeper_read_path ~config ~meta ~raw_path:raw_cwd in
    if safe_is_dir cwd
    then Ok cwd
    else if safe_file_exists cwd
    then Error (Printf.sprintf "cwd_not_directory: %s (path_is_file_not_directory)" cwd)
    else
      Error
        (Printf.sprintf
           "cwd_not_directory: %s (directory does not exist; Read will not create cwd)"
           cwd)
;;

let resolve_read_file_target
      ~(config : Workspace.config)
      ~(meta : keeper_meta)
      ~(args : Yojson.Safe.t)
      ~(raw_path : string)
  =
  let cwd = string_opt_nonempty "cwd" args in
  let raw_path = String.trim raw_path in
  if raw_path = ""
  then
    Error
      (Read_path_error
         (Keeper_alerting_path.rejection_to_user_message Keeper_alerting_path.Path_required))
  else
    let* cwd_abs =
      resolve_read_file_cwd ~config ~meta ~cwd
      |> Result.map_error (fun e -> Read_path_error e)
    in
    let candidate =
      if Filename.is_relative raw_path then Filename.concat cwd_abs raw_path else raw_path
    in
    resolve_projected_keeper_read_path
      ~config
      ~meta
      ~raw_for_error:raw_path
      ~projected_path:candidate
    |> Result.map_error (fun error -> Read_path_error error)
;;

type read_file_attempt =
  | Read_succeeded of string
  | Read_failed_payload of string
  | Read_failed_message of string

let handle_read_file_with_outcome
      ~(turn_sandbox_factory : Keeper_sandbox_factory.t option)
      ~(config : Workspace.config)
      ~(keeper_name : string)
      ~(args : Yojson.Safe.t)
  =
  match find_registry_meta ~keeper_name ~source_layer:"fs_resolver" with
  | None ->
    Keeper_tool_execution.failure
      (error_json (Printf.sprintf "keeper not found in registry: %s" keeper_name))
  | Some meta ->
  let path = Safe_ops.json_string ~default:"" "path" args in
  let max_bytes =
    Safe_ops.json_int ~default:read_file_default_max_bytes "max_bytes" args
    |> fun n -> max read_file_min_max_bytes (min read_file_max_max_bytes n)
  in
  let cwd = string_opt_nonempty "cwd" args in
  match resolve_read_file_target ~config ~meta ~args ~raw_path:path with
  | Error (Read_path_error e) -> Keeper_tool_execution.failure (error_json e)
  | Ok target ->
    let run_read () =
         (* RFC-0006 Phase B-1: Docker keepers are always contained to their
            playground bundle on the host before any read-side I/O proceeds.
            The resolver-level allowed_paths check is augmented by this
            strict containment so host FS cannot leak through Read
            while Execute is container-isolated. *)
         let* () = Keeper_sandbox_containment.check_read_target ~config ~meta ~target in
         (* RFC-0006 Phase B-2: sandbox-backed keepers route the actual
            byte read through the backend read runner so the backend mount
            restrictions are the load-bearing isolation. The host containment
            check above remains as defense-in-depth. *)
         if Keeper_sandbox_read_runner.should_route_read ~meta
         then (
           let timeout_sec =
             Env_config_sandbox.Shell_timeout.timeout_sec ~bucket:Read ()
           in
           let+ body =
             Keeper_sandbox_read_runner.read_file
               ?turn_sandbox_factory
               ~config
               ~meta
               ~host_path:target
               ~max_bytes
               ~timeout_sec
               ()
           in
           let total = String.length body in
           let truncated = total >= max_bytes in
           Read_succeeded
             (Yojson.Safe.to_string
                (`Assoc
                    [ "ok", `Bool true
                    ; "path", `String target
                    ; "bytes", `Int total
                    ; "truncated", `Bool truncated
                    ; "content", `String body
                    ; "via", `String Keeper_sandbox_read_runner.backend_via
                    ])))
         else (
           match Safe_ops.read_file_safe target with
           | Error e when String.starts_with ~prefix:file_not_found_prefix e ->
             Ok
               (Read_failed_payload
                  (missing_file_error_json
                     ~cwd
                     ~raw_path:(Some path)
                     ~target
                     ~error:e))
           | Error e -> Ok (Read_failed_message e)
           | Ok content ->
             let total = String.length content in
             let truncated = total > max_bytes in
             let body =
               if truncated then String.sub content 0 max_bytes else content
             in
             Ok
               (Read_succeeded
                  (Yojson.Safe.to_string
                     (`Assoc
                          [ "ok", `Bool true
                          ; "path", `String target
                          ; "bytes", `Int total
                          ; "truncated", `Bool truncated
                          ; "content", `String body
                          ]))))
    in
    (match run_read () with
     | Ok (Read_succeeded json) -> Keeper_tool_execution.success json
     | Ok (Read_failed_payload payload) -> Keeper_tool_execution.failure payload
     | Ok (Read_failed_message msg) ->
       Keeper_tool_execution.failure
         (error_json ~fields:[ "path", `String target ] msg)
     | Error msg ->
       Keeper_tool_execution.failure
         (error_json ~fields:[ "path", `String target ] msg))
;;

let handle_read_file ~turn_sandbox_factory ~config ~keeper_name ~args =
  (handle_read_file_with_outcome
     ~turn_sandbox_factory
     ~config
     ~keeper_name
     ~args).raw_output
;;

(* RFC-0006 Phase A.4: replace [old] with [new] in [text]. When
   [replace_all=false], requires exactly one occurrence so accidental
   multi-edits are rejected (mirrors Edit semantics). *)
let apply_patch ~old_string ~new_string ~replace_all text =
  if old_string = ""
  then Error "old_string must be non-empty for mode=patch."
  else (
    let count_occurrences ~needle haystack =
      let nlen = String.length needle in
      if nlen = 0
      then 0
      else (
        let hlen = String.length haystack in
        let rec loop i acc =
          if i + nlen > hlen
          then acc
          else if String.sub haystack i nlen = needle
          then loop (i + nlen) (acc + 1)
          else loop (i + 1) acc
        in
        loop 0 0)
    in
    let occurrences = count_occurrences ~needle:old_string text in
    if occurrences = 0
    then Error "old_string not found in file. Patch did not match anything."
    else if (not replace_all) && occurrences > 1
    then
      Error
        (Printf.sprintf
           "old_string occurs %d times. Pass replace_all=true to apply to all, or supply \
            a more specific old_string."
           occurrences)
    else (
      let buf = Buffer.create (String.length text) in
      let nlen = String.length old_string in
      let hlen = String.length text in
      let rec loop i =
        if i + nlen > hlen
        then Buffer.add_substring buf text i (hlen - i)
        else if String.sub text i nlen = old_string
        then (
          Buffer.add_string buf new_string;
          if replace_all
          then loop (i + nlen)
          else Buffer.add_substring buf text (i + nlen) (hlen - i - nlen))
        else (
          Buffer.add_char buf text.[i];
          loop (i + 1))
      in
      loop 0;
      Ok (Buffer.contents buf, occurrences)))
;;

(* RFC-0128 §4.5 — resolve an absolute or base-relative file_path to
   a partition + repo-relative path. Four outcomes:

   1. [Repo_store.find_repo_by_path_prefix] hits AND the repo's [url]
      normalises via [Agent_observation.canonical_url_of_remote] → [By_url slug]
      bucket + the repo-relative [rel_path].
   2. [Repo_store.find_repo_by_path_prefix] hits but the URL is blank or
      unparseable → [No_canonical_url] + original path. Counter labelled
      [reason=blank_url] or [reason=url_unparseable].
   3. A sandbox playground [repo_id] is not present in the repository store →
      [Unmatched] + original path. Counter labelled
      [reason=sandbox_unregistered_repo].
   4. No registered repo contains this path → [Base_unresolved] + original path.
      Counter labelled [reason=unregistered_repo].

   The keeper write path is fire-and-forget; this resolver also never
   raises — unresolved paths degrade to typed non-[By_url] partitions with
   metric labels so the operator can see how often each reason appears. *)
let resolve_partition_for_write ~base_dir ~kind ~file_path =
  let abs =
    if Filename.is_relative file_path
    then Filename.concat base_dir file_path
    else file_path
  in
  let bump_orphan ~reason =
    Otel_metric_store.inc_counter
      Keeper_metrics.(to_string IdeOrphanWrites)
      ~labels:[ "kind", kind; "reason", reason ]
      ()
  in
  let resolve_by_url ~rel ~repo_url ~orphan_reasons =
    let url = String.trim repo_url in
    if url = "" then begin
      bump_orphan ~reason:(snd orphan_reasons);
      (Agent_observation.No_canonical_url, file_path)
    end
    else
      match Agent_observation.canonical_url_of_remote url with
      | None ->
        bump_orphan ~reason:(fst orphan_reasons);
        (Agent_observation.No_canonical_url, file_path)
      | Some slug -> (Agent_observation.By_url slug, rel)
  in
  (* RFC-0128 §4.5 PR-6: keeper writes inside the sandbox playground
     never appear under a registered repo's [local_path] (the playground
     clone path is opaque to [repositories.toml]). Use the SSOT
     {!Playground_paths.parse_playground_repo_path} to recover the
     [(repo_id, rel)] pair, then look up the repository's URL by id.
     This makes the sandbox/working-tree join work without forcing the
     operator to also register every playground clone path. *)
  match
    Playground_paths.parse_playground_repo_path ~base_path:base_dir ~abs_path:abs
  with
  | Some (repo_id, rel) ->
    (match Repo_store.find_url_by_id ~base_path:base_dir repo_id with
     | Some url ->
       resolve_by_url
         ~rel
         ~repo_url:url
         ~orphan_reasons:("sandbox_url_unparseable", "sandbox_blank_url")
     | None ->
       bump_orphan ~reason:"sandbox_unregistered_repo";
       (Agent_observation.Unmatched, file_path))
  | None ->
    (match Repo_store.find_repo_by_path_prefix ~base_path:base_dir abs with
     | None ->
       bump_orphan ~reason:"unregistered_repo";
       (Agent_observation.Base_unresolved, file_path)
     | Some (repo, rel) ->
       resolve_by_url
         ~rel
         ~repo_url:repo.url
         ~orphan_reasons:("url_unparseable", "blank_url"))
;;

(** After a successful file write, record the code region in [.masc-ide/].
    Fire-and-forget: errors are logged but never block the write path.
    Emits a neutral [Agent_observation.write_region_event]; the IDE adapter
    registers the concrete region-tracker sink.

    RFC-0128 §4.5: the partition is resolved per-write from the
    [file_path] so sandbox-clone keeper writes and working-tree IDE
    reads see the same [By_url <slug>] bucket. When the path cannot
    be resolved to a registered repo the record goes to
    [.masc-ide/_orphan/] and the [masc_ide_orphan_writes_total]
    counter increments. *)
let track_write_region
      ~config
      ~keeper_name
      ~file_path
      ~content
      ~mode_raw
      ~old_string
      ~new_string
      ?(turn = 0)
      ()
  =
  let base_dir = Keeper_alerting_path.project_root_of_config config in
  let partition, rel_file_path =
    resolve_partition_for_write ~base_dir ~kind:"region" ~file_path
  in
  let tool_name =
    match fs_write_mode_of_string_opt mode_raw with
    | Some Patch -> "edit_file"
    | _ -> "write_file"
  in
  (* RFC-0128 PR-1e: the legacy meta-sync invocation that used to live here
     wrote to the Legacy partition (server base_path) while
     region observation below now writes to the
     resolved partition (PR-1c). That produced a double-write of the
     same region into two different bucket layouts. The full-file
     region fallback meta_sync was carrying for edit_file/apply_patch
     is now served directly by the IDE sink, so we drop this path entirely. *)
  let arguments =
    let fields = [ "path", `String rel_file_path; "content", `String content ] in
    match fs_write_mode_of_string_opt mode_raw with
    | Some Patch ->
      `Assoc
        (fields @ [ "old_string", `String old_string; "new_string", `String new_string ])
    | _ -> `Assoc fields
  in
  let tool_call_json = `Assoc [ "name", `String tool_name; "arguments", arguments ] in
  let warn_and_surface message =
    Log.Keeper.warn
      "IDE region tracking failed for keeper=%s path=%s: %s"
      keeper_name
      file_path
      message;
    Some message
  in
  try
    match
      Agent_observation.emit_write_region_event
        { base_path = base_dir; partition; keeper_id = keeper_name; turn; tool_call_json }
    with
    | Ok () -> None
    | Error err ->
      Agent_observation.write_region_error_to_string err |> warn_and_surface
  with
  | Eio.Cancel.Cancelled _ as exn -> raise exn
  | exn -> Printexc.to_string exn |> warn_and_surface
;;

let ide_observation_failure_fields = function
  | None -> []
  | Some error ->
    [ ( "ide_observation"
      , `Assoc
          [ ( "write_region"
            , `Assoc [ "ok", `Bool false; "error", `String error ] )
          ] )
    ]
;;

let atomic_tmp_rng = Random.State.make_self_init ()
let atomic_tmp_rng_mutex = Stdlib.Mutex.create ()

let fresh_atomic_tmp_name () =
  Stdlib.Mutex.protect atomic_tmp_rng_mutex (fun () ->
    Uuidm.v4_gen atomic_tmp_rng () |> Uuidm.to_string)
  |> Printf.sprintf ".atomic_%s.tmp"
;;

let cleanup_confined_tmp tmp =
  Eio.Cancel.protect @@ fun () ->
  try
    match Eio.Path.kind ~follow:false tmp with
    | `Not_found -> ()
    | _ -> Eio.Path.unlink tmp
  with
  | Eio.Cancel.Cancelled _ as exn -> raise exn
  | exn ->
    Log.Keeper.warn
      "filesystem_runtime: confined temp cleanup failed: %s"
      (Printexc.to_string exn)
;;

let fsync_confined_directory_best_effort dir =
  try
    Eio.Path.with_open_in Eio.Path.(dir / ".") @@ fun directory_file ->
    match Eio_unix.Resource.fd_opt directory_file with
    | None ->
      Log.Keeper.warn
        "filesystem_runtime: opened confined directory has no POSIX fd; directory fsync skipped"
    | Some fd ->
       Eio_unix.run_in_systhread ~label:"keeper-fs-dir-fsync" (fun () ->
         Eio_unix.Fd.use_exn "keeper-fs-dir-fsync" fd Unix.fsync)
  with
  | Eio.Cancel.Cancelled _ as exn -> raise exn
  | Unix.Unix_error ((Unix.EINVAL | Unix.EOPNOTSUPP) as error, operation, _) ->
    Log.Keeper.info
      "filesystem_runtime: confined directory fsync unsupported operation=%s error=%s"
      operation
      (Unix.error_message error)
  | exn ->
    Log.Keeper.warn
      "filesystem_runtime: confined directory fsync failed: %s"
      (Printexc.to_string exn)
;;

let created_file_permissions = 0o644
let created_directory_permissions = 0o755

let set_open_resource_permissions ~label resource permissions =
  match Eio_unix.Resource.fd_opt resource with
  | None ->
    Error
      (Printf.sprintf
         "filesystem resource has no POSIX fd; cannot apply exact permissions: %s"
         label)
  | Some fd ->
    (try
       Eio_unix.run_in_systhread ~label (fun () ->
         Eio_unix.Fd.use_exn label fd (fun unix_fd ->
           Unix.fchmod unix_fd permissions));
       Ok ()
     with
     | Eio.Cancel.Cancelled _ as exn -> raise exn
     | exn -> Error (Printexc.to_string exn))
;;

let same_file_resource (left : Eio.File.Stat.t) (right : Eio.File.Stat.t) =
  Int64.equal left.dev right.dev && Int64.equal left.ino right.ino
;;

let set_created_directory_permissions ~expected path permissions =
  Eio.Path.with_open_in path @@ fun directory_file ->
  let opened = Eio.File.stat directory_file in
  if opened.kind <> `Directory || not (same_file_resource expected opened)
  then Error "filesystem created directory changed before exact permissions were applied"
  else
    set_open_resource_permissions
      ~label:"keeper-fs-created-directory-fchmod"
      directory_file
      permissions
;;

let replacement_file_permissions ~parent_dir ~leaf =
  let target = Eio.Path.(parent_dir / leaf) in
  match Eio.Path.kind ~follow:false target with
  | `Not_found | `Symbolic_link -> Ok created_file_permissions
  | `Regular_file -> Ok (Eio.Path.stat ~follow:false target).perm
  | (`Block_device
    | `Character_special
    | `Directory
    | `Fifo
    | `Socket
    | `Unknown) as kind ->
    Error
      (Fmt.str
         "filesystem atomic replacement target must be a regular file, symbolic link, or missing entry; found %a"
         Eio.File.Stat.pp_kind
         kind)
;;

let save_confined_atomic ~parent_dir ~leaf ~permissions content =
  let target = Eio.Path.(parent_dir / leaf) in
  let tmp = Eio.Path.(parent_dir / fresh_atomic_tmp_name ()) in
  let prepared =
    match
      Eio.Path.with_open_out ~create:(`Exclusive 0o600) tmp (fun file ->
        Eio.Flow.copy_string content file;
        let* () =
          set_open_resource_permissions
            ~label:"keeper-fs-atomic-temp-fchmod"
            file
            permissions
        in
        Eio.File.sync file;
        Ok ())
    with
    | result -> result
    | exception exn ->
      let bt = Printexc.get_raw_backtrace () in
      cleanup_confined_tmp tmp;
      Printexc.raise_with_backtrace exn bt
  in
  match prepared with
  | Error _ as error ->
    cleanup_confined_tmp tmp;
    error
  | Ok () ->
    (match Eio.Path.rename tmp target with
     | () -> ()
     | exception exn ->
       let bt = Printexc.get_raw_backtrace () in
       cleanup_confined_tmp tmp;
       Printexc.raise_with_backtrace exn bt);
    fsync_confined_directory_best_effort parent_dir;
    Ok ()
;;

let append_open_file file content =
  Eio.Flow.copy_string content file;
  Eio.File.sync file;
  Ok ()
;;

let load_open_file file =
  Eio.Buf_read.parse_exn ~max_size:max_int Eio.Buf_read.take_all file
;;

let create_file_exclusive ~parent_dir ~leaf ~permissions content =
  let target = Eio.Path.(parent_dir / leaf) in
  let created =
    match
      Eio.Path.with_open_out ~create:(`Exclusive 0o600) target (fun file ->
        Eio.Flow.copy_string content file;
        let* () =
          set_open_resource_permissions
            ~label:"keeper-fs-created-file-fchmod"
            file
            permissions
        in
        Eio.File.sync file;
        Ok ())
    with
    | result -> result
    | exception exn ->
      let bt = Printexc.get_raw_backtrace () in
      cleanup_confined_tmp target;
      Printexc.raise_with_backtrace exn bt
  in
  match created with
  | Error _ as error ->
    cleanup_confined_tmp target;
    error
  | Ok () ->
    fsync_confined_directory_best_effort parent_dir;
    Ok ()
;;

let rec with_created_parent_directories
          ~permissions
          parent_dir
          missing_parents
          f
  =
  match missing_parents with
  | [] -> f parent_dir
  | component :: rest ->
    let child = Eio.Path.(parent_dir / component) in
    Eio.Path.mkdir ~perm:0o700 child;
    let created = Eio.Path.stat ~follow:false child in
    let* () = set_created_directory_permissions ~expected:created child permissions in
    Eio.Path.with_open_dir child @@ fun child_dir ->
    let lexical = Eio.Path.stat ~follow:false child in
    let opened = Eio.Path.stat ~follow:true child_dir in
    if created.kind <> `Directory
       || lexical.kind <> `Directory
       || opened.kind <> `Directory
       || not (same_file_resource created lexical)
       || not (same_file_resource lexical opened)
    then
      Error
        (Printf.sprintf
           "filesystem parent directory changed during capability acquisition: %s"
           component)
    else with_created_parent_directories ~permissions child_dir rest f
;;

let rec with_deepest_existing_parent
          parent
          parent_relative_path
          missing_parents
          f
  =
  Eio.Switch.run @@ fun sw ->
  match
    try Ok (Eio.Path.open_dir ~sw parent) with
    | Eio.Io (Eio.Fs.E (Eio.Fs.Not_found _), _) -> Error `Missing
  with
  | Ok parent_dir ->
    f ~parent_dir ~parent_relative_path ~missing_parents
  | Error `Missing ->
    (match Eio.Path.split parent with
     | None ->
       Error
         "filesystem capability acquisition failed: no existing parent directory"
     | Some (ancestor, missing_component) ->
       with_deepest_existing_parent
         ancestor
         (Filename.dirname parent_relative_path)
         (missing_component :: missing_parents)
         f)
;;

let with_confined_write_parent confined f =
  match Fs_compat.get_fs_opt () with
  | None ->
    Error
      "filesystem capability unavailable: Eio filesystem was not installed at runtime startup"
  | Some fs ->
    (try
       let anchor_root = Keeper_alerting_path.confined_anchor_root confined in
       let root_relative_path =
         Keeper_alerting_path.confined_root_relative_path confined
       in
       let relative_path =
         Keeper_alerting_path.confined_relative_path confined
       in
       let with_root root_dir =
         let* () =
           Keeper_alerting_path.verify_confined_root_capability confined root_dir
         in
         match Eio.Path.split Eio.Path.(root_dir / relative_path) with
         | None -> Error "filesystem target has no writable leaf"
         | Some (parent, leaf) ->
           with_deepest_existing_parent
             parent
             (Filename.dirname relative_path)
             []
             (fun ~parent_dir ~parent_relative_path ~missing_parents ->
                f
                  ~root_dir
                  ~parent_dir
                  ~parent_relative_path
                  ~missing_parents
                  ~leaf)
       in
       Eio.Path.with_open_dir Eio.Path.(fs / anchor_root) @@ fun anchor_dir ->
       if String.equal root_relative_path "."
       then with_root anchor_dir
       else
         Eio.Path.with_open_dir Eio.Path.(anchor_dir / root_relative_path)
         @@ fun root_dir ->
         with_root root_dir
     with
     | Eio.Cancel.Cancelled _ as exn -> raise exn
     | Eio.Io _ as exn -> Error (Printexc.to_string exn))
;;

let check_invariant_sandbox_isolation
      ~(turn_sandbox_factory : Keeper_sandbox_factory.t option)
      ~confined
  =
  let target = Keeper_alerting_path.confined_containment_path confined in
  match turn_sandbox_factory with
  | None -> Ok ()
  | Some factory ->
    let cwd = Filename.dirname target in
    (match Keeper_sandbox_factory.resolve_opt (Some factory) ~cwd with
     | No_factory | Local_profile -> Ok ()
     | Runtime runtime ->
       let host_root = Keeper_turn_sandbox_runtime.host_root runtime in
       Keeper_invariant.sandbox_isolation
         ~sandbox_roots:[ host_root ]
         ~sandbox_paths:[ target ])
;;

let file_write_gate_input
      ~gate_effect
      ~requested_target
      ~content
      ?old_string
      ?new_string
      ?replace_all
      ()
  =
  let optional_string name = function
    | None -> []
    | Some value -> [ name, `String value ]
  in
  let optional_bool name = function
    | None -> []
    | Some value -> [ name, `Bool value ]
  in
  `Assoc
    ([ "effect", Keeper_alerting_path.path_effect_to_yojson gate_effect
     ; "requested_target", `String requested_target
     ; "content", `String content
     ]
     @ optional_string "old_string" old_string
     @ optional_string "new_string" new_string
     @ optional_bool "replace_all" replace_all)
;;

let decide_file_write
      ~config
      ~(meta : keeper_meta)
      ?continuation_channel
      ?gate_context
      ?gate_grant
      ~input
      ()
  =
  Keeper_gate.decide
    ?cycle_grant:gate_grant
    ~keeper_always_allow:(Option.value ~default:false meta.always_allow)
    { keeper_name = meta.name
    ; operation = "filesystem_write"
    ; input
    ; base_path = config.Workspace.base_path
    ; causal_context = Option.map (fun current -> current ()) gate_context
    ; task_id = Option.map Keeper_id.Task_id.to_string meta.current_task_id
    ; goal_ids = meta.active_goal_ids
    ; continuation_channel
    }
;;

let file_write_deferred_json ~target ~approval_id ~reason =
  error_json
    ~fields:
      [ "path", `String target
      ; "error", `String "gate_deferred"
      ; "gate_request_id", `String approval_id
      ; "gate_status", `String "pending"
      ; "gate_nonblocking", `Bool true
      ; "gate_reason", `String (Keeper_gate.deferred_reason_to_string reason)
      ]
    "External effect deferred without blocking this Keeper. Continue other work; the originating Keeper lane will wake after resolution."
;;

type file_write_attempt =
  | Write_succeeded of string
  | Write_failed of
      { payload : string
      ; class_ : Tool_result.tool_failure_class
      }

let file_write_attempt_to_execution = function
  | Write_succeeded payload -> Keeper_tool_execution.success payload
  | Write_failed { payload; class_ } -> Keeper_tool_execution.failure ~class_ payload
;;

let handle_file_write_with_outcome
      ~(turn_sandbox_factory : Keeper_sandbox_factory.t option)
      ~(config : Workspace.config)
      ~(keeper_name : string)
      ?continuation_channel
      ?gate_context
      ?gate_grant
      ~(args : Yojson.Safe.t)
      ()
  =
  match find_registry_meta ~keeper_name ~source_layer:"fs_resolver" with
  | None ->
    Keeper_tool_execution.failure
      (error_json (Printf.sprintf "keeper not found in registry: %s" keeper_name))
  | Some meta ->
  let via_field =
    match turn_sandbox_factory with
    | Some _ ->
      [ ( "via"
        , `String
            (Keeper_sandbox_runner.route_label
               Keeper_sandbox_runner.Sandbox_backend) )
      ]
    | None -> []
  in
  let path = Safe_ops.json_string ~default:"" "path" args in
  let content = Safe_ops.json_string ~default:"" "content" args in
  let mode_raw = Safe_ops.json_string ~default:"overwrite" "mode" args in
  let mode_opt = fs_write_mode_of_string_opt mode_raw in
  let after_gate ~target ~input continue =
    match
      decide_file_write
        ~config
        ~meta
        ?continuation_channel
        ?gate_context
        ?gate_grant
        ~input
        ()
    with
    | Keeper_gate.Deferred { approval_id; reason } ->
      Ok
        (Write_failed
           { payload = file_write_deferred_json ~target ~approval_id ~reason
           ; class_ = Tool_result.Workflow_rejection
           })
    | Keeper_gate.Unavailable reason ->
      Ok
        (Write_failed
           { payload =
               error_json
                 ~fields:
                   [ "path", `String target
                   ; "error", `String "gate_unavailable"
                   ; "gate_reason"
                   , `String (Keeper_gate.unavailable_reason_to_string reason)
                   ]
                 "External effect was not executed because the Gate could not durably record its decision state. This Keeper remains active and may continue other work."
           ; class_ = Tool_result.Runtime_failure
           })
    | Keeper_gate.Allow authorization ->
      Log.Keeper.info
        ~keeper_name:meta.name
        "external effect authorized operation=filesystem_write source=%s"
        (Keeper_gate.authorization_source_to_string authorization.source);
      continue ()
  in
  let protect_write ~target f =
    try f () with
    | Eio.Cancel.Cancelled _ as e -> raise e
    | Eio.Io _ as e ->
      Ok
        (Write_failed
           { payload =
               error_json ~fields:[ "path", `String target ] (Printexc.to_string e)
           ; class_ = Tool_result.Runtime_failure
           })
    | Invalid_argument e | Sys_error e ->
      Ok
        (Write_failed
           { payload = error_json ~fields:[ "path", `String target ] e
           ; class_ = Tool_result.Runtime_failure
           })
    | Unix.Unix_error (err, _, _) ->
      Ok
        (Write_failed
           { payload =
               error_json
                 ~fields:[ "path", `String target ]
                 (Unix.error_message err)
           ; class_ = Tool_result.Runtime_failure
           })
  in
  let finish_content_write ~target ~mode_label ~gate_effect write =
    let input =
      file_write_gate_input
        ~gate_effect
        ~requested_target:target
        ~content
        ()
    in
    after_gate ~target ~input
    @@ fun () ->
    protect_write ~target
    @@ fun () ->
    let* () = write () in
    Log.Keeper.info
      "WRITE_AUDIT: keeper=%s fs_edit path=%s mode=%s bytes=%d"
      meta.name
      target
      mode_label
      (String.length content);
    let ide_observation_error =
      track_write_region
        ~config
        ~keeper_name:meta.name
        ~file_path:target
        ~content
        ~mode_raw:mode_label
        ~old_string:""
        ~new_string:""
        ()
    in
    Ok
      (Write_succeeded
         (Yojson.Safe.to_string
            (`Assoc
                ([ "ok", `Bool true
                 ; "path", `String target
                 ; "mode", `String mode_label
                 ; "bytes_written", `Int (String.length content)
                 ]
                 @ ide_observation_failure_fields ide_observation_error
                 @ via_field))))
  in
  let parent_effect_scope ~parent_dir ~parent_relative_path ~missing_parents =
    Keeper_alerting_path.path_effect_parent_scope
      ~relative_path:parent_relative_path
      ~resource:(Eio.Path.stat ~follow:true parent_dir)
      ~create_missing_parents:missing_parents
      ~created_directory_permissions
  in
  let handle_atomic_content_write ~mode_label ~make_effect =
    match
      resolve_keeper_confined_write_path
        ~config
        ~meta
        ~endpoint:Keeper_alerting_path.Lexical_entry
        ~raw_path:path
    with
    | Error msg -> Keeper_tool_execution.failure (error_json msg)
    | Ok confined ->
      let target = Keeper_alerting_path.confined_host_path confined in
      let run () =
        let* () =
          check_invariant_sandbox_isolation ~turn_sandbox_factory ~confined
        in
        with_confined_write_parent confined
        @@ fun ~root_dir:_ ~parent_dir ~parent_relative_path ~missing_parents ~leaf ->
        let* parent =
          parent_effect_scope ~parent_dir ~parent_relative_path ~missing_parents
        in
        let* result_file_permissions =
          if missing_parents = []
          then replacement_file_permissions ~parent_dir ~leaf
          else Ok created_file_permissions
        in
        let* gate_effect =
          make_effect ~parent ~result_file_permissions confined
        in
        finish_content_write ~target ~mode_label ~gate_effect (fun () ->
          with_created_parent_directories
            ~permissions:created_directory_permissions
            parent_dir
            missing_parents
          @@ fun final_parent ->
          save_confined_atomic
            ~parent_dir:final_parent
            ~leaf
            ~permissions:result_file_permissions
            content)
      in
      (match run () with
       | Ok attempt -> file_write_attempt_to_execution attempt
       | Error msg ->
         Keeper_tool_execution.failure
           (error_json ~fields:[ "path", `String target ] msg))
  in
  let handle_append () =
    let mode_label = fs_write_mode_to_string Append in
    match
      resolve_keeper_confined_write_path
        ~config
        ~meta
        ~endpoint:Keeper_alerting_path.Follow_referent
        ~raw_path:path
    with
    | Error msg -> Keeper_tool_execution.failure (error_json msg)
    | Ok confined ->
      let target = Keeper_alerting_path.confined_host_path confined in
      let run () =
        let* () =
          check_invariant_sandbox_isolation ~turn_sandbox_factory ~confined
        in
        with_confined_write_parent confined
        @@ fun ~root_dir ~parent_dir ~parent_relative_path ~missing_parents ~leaf ->
        let create_missing_entry () =
          let* parent =
            parent_effect_scope ~parent_dir ~parent_relative_path ~missing_parents
          in
          let* gate_effect =
            Keeper_alerting_path.create_entry_exclusive_effect
              ~parent
              ~result_file_permissions:created_file_permissions
              confined
          in
          finish_content_write ~target ~mode_label ~gate_effect (fun () ->
            with_created_parent_directories
              ~permissions:created_directory_permissions
              parent_dir
              missing_parents
            @@ fun final_parent ->
            create_file_exclusive
              ~parent_dir:final_parent
              ~leaf
              ~permissions:created_file_permissions
              content)
        in
        if missing_parents <> []
        then create_missing_entry ()
        else
          let endpoint_relative_path =
            Keeper_alerting_path.confined_endpoint_relative_path confined
          in
          Eio.Switch.run @@ fun sw ->
          (match
             try
               Ok
                 (Eio.Path.open_out
                    ~sw
                    ~append:true
                    ~create:`Never
                    Eio.Path.(root_dir / endpoint_relative_path))
             with
             | Eio.Io (Eio.Fs.E (Eio.Fs.Not_found _), _) -> Error `Missing
           with
           | Error `Missing -> create_missing_entry ()
           | Ok file ->
             let stat = Eio.File.stat file in
             if stat.kind <> `Regular_file
             then Error "filesystem append target is not a regular file"
             else
               let* gate_effect =
                 Keeper_alerting_path.append_pinned_resource_effect confined stat
               in
               finish_content_write ~target ~mode_label ~gate_effect (fun () ->
                 append_open_file file content))
      in
      (match run () with
       | Ok attempt -> file_write_attempt_to_execution attempt
       | Error msg ->
         Keeper_tool_execution.failure
           (error_json ~fields:[ "path", `String target ] msg))
  in
  if String.trim path = ""
  then
    Keeper_tool_execution.failure
      ~class_:Tool_result.Policy_rejection
      (error_json "path is required. Good: path='lib/foo.ml'. Bad: path=''.")
  else (
    match mode_opt with
    | None ->
      Keeper_tool_execution.failure
        ~class_:Tool_result.Policy_rejection
        (error_json
           (Printf.sprintf
              "mode must be one of [%s], got %S."
              (String.concat ", " valid_fs_write_mode_strings)
              mode_raw))
    | Some Patch ->
      let old_string = Safe_ops.json_string ~default:"" "old_string" args in
      let new_string = Safe_ops.json_string ~default:"" "new_string" args in
      let replace_all = Safe_ops.json_bool ~default:false "replace_all" args in
      if old_string = ""
      then
        Keeper_tool_execution.failure
          ~class_:Tool_result.Policy_rejection
          (error_json
             "mode=patch requires non-empty old_string. Good: old_string='let x = 1'.")
      else
        (match
           resolve_keeper_confined_write_path
             ~config
             ~meta
             ~endpoint:Keeper_alerting_path.Follow_referent
             ~raw_path:path
         with
         | Error msg -> Keeper_tool_execution.failure (error_json msg)
         | Ok confined ->
              let target = Keeper_alerting_path.confined_host_path confined in
              let finish_write ~gate_effect ~updated ~occurrences write =
                let input =
                  file_write_gate_input
                    ~gate_effect
                    ~requested_target:target
                    ~content:updated
                    ~old_string
                    ~new_string
                    ~replace_all
                    ()
                in
                after_gate ~target ~input
                @@ fun () ->
                protect_write ~target
                @@ fun () ->
                let* () = write updated in
                Log.Keeper.info
                  "WRITE_AUDIT: keeper=%s fs_edit path=%s mode=patch replace_all=%b \
                   occurrences=%d bytes=%d"
                  meta.name
                  target
                  replace_all
                  occurrences
                  (String.length updated);
                let ide_observation_error =
                  track_write_region
                    ~config
                    ~keeper_name:meta.name
                    ~file_path:target
                    ~content:updated
                    ~mode_raw:"patch"
                    ~old_string
                    ~new_string
                    ()
                in
                Ok
                  (Write_succeeded
                     (Yojson.Safe.to_string
                        (`Assoc
                            ([ "ok", `Bool true
                             ; "path", `String target
                             ; "mode", `String "patch"
                             ; "replace_all", `Bool replace_all
                             ; "occurrences", `Int occurrences
                             ; "bytes_written", `Int (String.length updated)
                             ]
                             @ ide_observation_failure_fields ide_observation_error
                             @ via_field))))
              in
              let patch_current
                    ~parent
                    ~source_relative_path
                    ~source_resource
                    ~result_file_permissions
                    current
                    write
                =
                let* updated, occurrences =
                  apply_patch ~old_string ~new_string ~replace_all current
                in
                let* gate_effect =
                  Keeper_alerting_path.patch_then_atomic_replace_effect
                    ~parent
                    ~source_relative_path
                    ~source_resource
                    ~result_file_permissions
                    confined
                in
                finish_write ~gate_effect ~updated ~occurrences write
              in
              let missing_target () =
                Ok
                  (Write_failed
                     { payload =
                         error_json
                           ~fields:[ "path", `String target ]
                           "patch target file does not exist. Use mode=overwrite to create it."
                     ; class_ = Tool_result.Workflow_rejection
                     })
              in
              let run () =
                let* () =
                  check_invariant_sandbox_isolation ~turn_sandbox_factory ~confined
                in
                with_confined_write_parent confined
                @@ fun ~root_dir ~parent_dir ~parent_relative_path ~missing_parents ~leaf ->
                if missing_parents <> []
                then missing_target ()
                else
                  let source_relative_path =
                    Keeper_alerting_path.confined_endpoint_relative_path confined
                  in
                  let confined_source = Eio.Path.(root_dir / source_relative_path) in
                  (match Eio.Path.kind ~follow:true confined_source with
                   | `Not_found -> missing_target ()
                   | `Regular_file ->
                     Eio.Path.with_open_in confined_source @@ fun source_file ->
                     let source_resource = Eio.File.stat source_file in
                     if source_resource.kind <> `Regular_file
                     then Error "filesystem patch source changed before capability acquisition"
                     else
                       let current = load_open_file source_file in
                       let* result_file_permissions =
                         replacement_file_permissions ~parent_dir ~leaf
                       in
                       let* parent =
                         parent_effect_scope
                           ~parent_dir
                           ~parent_relative_path
                           ~missing_parents:[]
                       in
                       patch_current
                         ~parent
                         ~source_relative_path
                         ~source_resource
                         ~result_file_permissions
                         current
                         (fun updated ->
                            save_confined_atomic
                              ~parent_dir
                              ~leaf
                              ~permissions:result_file_permissions
                              updated)
                   | (`Block_device
                     | `Character_special
                     | `Directory
                     | `Fifo
                     | `Socket
                     | `Symbolic_link
                     | `Unknown) as kind ->
                     Error
                       (Fmt.str
                          "filesystem patch target must resolve to a regular file; found %a"
                          Eio.File.Stat.pp_kind
                          kind))
              in
              (match run () with
               | Ok attempt -> file_write_attempt_to_execution attempt
               | Error msg ->
                 Keeper_tool_execution.failure
                   (error_json ~fields:[ "path", `String target ] msg)))
    | Some Overwrite ->
      handle_atomic_content_write
        ~mode_label:(fs_write_mode_to_string Overwrite)
        ~make_effect:Keeper_alerting_path.atomic_replace_effect
    | Some Append -> handle_append ()
  )
;;

let handle_file_write
      ~turn_sandbox_factory
      ~config
      ~keeper_name
      ?continuation_channel
      ?gate_context
      ?gate_grant
      ~args
      ()
  =
  (handle_file_write_with_outcome
     ~turn_sandbox_factory
     ~config
     ~keeper_name
     ?continuation_channel
     ?gate_context
     ?gate_grant
     ~args
     ()).raw_output
;;

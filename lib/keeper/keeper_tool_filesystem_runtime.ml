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
      ~(meta : Keeper_meta_contract.keeper_meta)
      ~(args : Yojson.Safe.t)
  =
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

let handle_read_file ~turn_sandbox_factory ~config ~meta ~args =
  (handle_read_file_with_outcome
     ~turn_sandbox_factory
     ~config
     ~meta
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

let created_file_permissions = 0o644
let created_directory_permissions = 0o755

let same_file_resource (left : Eio.File.Stat.t) (right : Eio.File.Stat.t) =
  Int64.equal left.dev right.dev && Int64.equal left.ino right.ino
;;

let replacement_file_permissions ~parent_dir ~leaf =
  let target = Eio.Path.(parent_dir / leaf) in
  try
    let resource = Eio.Path.stat ~follow:false target in
    match resource.kind with
    | `Symbolic_link -> Ok created_file_permissions
    | `Regular_file -> Ok resource.perm
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
  with
  | Eio.Io (Eio.Fs.E (Eio.Fs.Not_found _), _) -> Ok created_file_permissions
;;

let load_open_file file =
  Eio.Buf_read.parse_exn ~max_size:max_int Eio.Buf_read.take_all file
;;

type created_directory_commit =
  { component : string
  ; target_effect : created_directory_target_effect
  ; primary_failure : created_directory_failure option
  ; child_sync : created_directory_sync_outcome
  ; parent_sync : created_directory_sync_outcome
  }

and created_directory_target_effect =
  | Directory_unchanged
  | Directory_created_validated
  | Directory_created_requested_mode
  | Directory_state_unknown

and created_directory_stage =
  | Create_directory
  | Inspect_created_directory
  | Acquire_directory_capability
  | Validate_directory_capability
  | Apply_directory_permissions

and created_directory_operation_failure =
  { exception_ : exn
  ; backtrace : Printexc.raw_backtrace
  }

and created_directory_failure_cause =
  | Directory_posix_descriptor_unavailable
  | Directory_unexpected_resource_kind of Eio.File.Stat.kind
  | Directory_resource_identity_changed
  | Directory_operation_failed of created_directory_operation_failure

and created_directory_failure =
  { stage : created_directory_stage
  ; cause : created_directory_failure_cause
  }

and created_directory_sync_outcome =
  | Directory_sync_not_attempted
  | Directory_sync_succeeded
  | Directory_sync_failed of Fs_compat.capability_directory_sync_error

type append_target_effect =
  | Append_target_unchanged
  | Append_target_extended_complete
  | Append_target_extended_partial
  | Append_target_extended_detached
  | Append_target_state_unknown

type append_write_outcome = Fs_compat.capability_append_outcome =
  { requested_bytes : int
  ; bytes_written : int
  ; write_failure : Fs_compat.capability_append_failure option
  ; sync_failure : Fs_compat.capability_append_operation_failure option
  ; target_binding : Fs_compat.capability_append_target_binding
  }

type content_write_error =
  | Content_write_message of string
  | Content_write_capability of
      { error : Fs_compat.capability_write_error
      ; created_parents : created_directory_commit list
      }
  | Content_write_directory of
      { failed_commit : created_directory_commit
      ; created_parents : created_directory_commit list
      }
  | Content_write_append of append_write_outcome

type content_publication =
  | Recovery_independent of (unit -> (unit, content_write_error) result)
  | Recovery_guarded of
      (Fs_compat.publication_recovery_access
       -> (unit, content_write_error) result)

let append_capability ~on_cancelled file content =
  let outcome =
    Eio.Cancel.protect (fun () ->
      Fs_compat.append_capability_observed file content)
  in
  (try Eio.Fiber.check () with
   | Eio.Cancel.Cancelled _ as cancellation ->
     on_cancelled outcome;
     raise cancellation);
  match outcome.write_failure, outcome.sync_failure, outcome.target_binding with
  | None, None, Fs_compat.Capability_append_target_verified -> Ok ()
  | ( None
    , None
    , Fs_compat.Capability_append_target_not_checked )
    when outcome.requested_bytes = 0 -> Ok ()
  | _ -> Error (Content_write_append outcome)
;;

let created_directory_operation stage f =
  try Ok (f ()) with
  | Eio.Cancel.Cancelled _ as cancellation -> raise cancellation
  | exception_ ->
    let backtrace = Printexc.get_raw_backtrace () in
    Error
      { stage
      ; cause = Directory_operation_failed { exception_; backtrace }
      }
;;

let sync_created_directory directory =
  match Fs_compat.sync_directory_capability directory with
  | Ok () -> Directory_sync_succeeded
  | Error error -> Directory_sync_failed error
;;

let create_and_commit_directory_component
      ~sw
      ~permissions
      ~parent_dir
      ~component
  =
  let unchanged primary_failure =
    ( None
    , { component
      ; target_effect = Directory_unchanged
      ; primary_failure = Some primary_failure
      ; child_sync = Directory_sync_not_attempted
      ; parent_sync = Directory_sync_not_attempted
      } )
  in
  let created_without_child ~target_effect primary_failure =
    let parent_sync = sync_created_directory parent_dir in
    ( None
    , { component
      ; target_effect
      ; primary_failure = Some primary_failure
      ; child_sync = Directory_sync_not_attempted
      ; parent_sync
      } )
  in
  let child = Eio.Path.(parent_dir / component) in
  match
    created_directory_operation Create_directory (fun () ->
      Eio.Path.mkdir ~perm:0o700 child)
  with
  | Error primary_failure -> unchanged primary_failure
  | Ok () ->
    (match
       created_directory_operation Inspect_created_directory (fun () ->
         Eio.Path.stat ~follow:false child)
     with
     | Error primary_failure ->
       created_without_child
         ~target_effect:Directory_state_unknown
         primary_failure
     | Ok created when created.kind <> `Directory ->
       created_without_child
         ~target_effect:Directory_state_unknown
         { stage = Inspect_created_directory
         ; cause = Directory_unexpected_resource_kind created.kind
         }
     | Ok created ->
       (match
          created_directory_operation Acquire_directory_capability (fun () ->
            Eio.Path.open_dir ~sw child)
        with
        | Error primary_failure ->
          created_without_child
            ~target_effect:Directory_state_unknown
            primary_failure
        | Ok child_dir ->
          let directory_file =
            created_directory_operation Acquire_directory_capability (fun () ->
              Eio.Path.open_in ~sw Eio.Path.(child_dir / "."))
          in
          let validation =
            match directory_file with
            | Error _ as error -> error
            | Ok directory_file ->
              (match
                 created_directory_operation
                   Validate_directory_capability
                   (fun () ->
                      Eio.Path.stat ~follow:false child, Eio.File.stat directory_file)
               with
               | Error _ as error -> error
               | Ok (lexical, opened)
              when lexical.kind <> `Directory || opened.kind <> `Directory ->
                 let kind =
                   if lexical.kind <> `Directory then lexical.kind else opened.kind
                 in
                 Error
                   { stage = Validate_directory_capability
                   ; cause = Directory_unexpected_resource_kind kind
                   }
               | Ok (lexical, opened)
              when not (same_file_resource created lexical)
                   || not (same_file_resource lexical opened) ->
                 Error
                   { stage = Validate_directory_capability
                   ; cause = Directory_resource_identity_changed
                   }
               | Ok _ -> Ok ())
          in
          (match validation with
           | Error primary_failure ->
             let parent_sync = sync_created_directory parent_dir in
             ( None
             , { component
               ; target_effect = Directory_state_unknown
               ; primary_failure = Some primary_failure
               ; child_sync = Directory_sync_not_attempted
               ; parent_sync
               } )
           | Ok () ->
             let permissions_result =
               match directory_file with
               | Error failure -> Error failure
               | Ok directory_file ->
                 (match Eio_unix.Resource.fd_opt directory_file with
               | None ->
                 Error
                   { stage = Apply_directory_permissions
                   ; cause = Directory_posix_descriptor_unavailable
                   }
               | Some fd ->
                 created_directory_operation Apply_directory_permissions (fun () ->
                   Eio_unix.run_in_systhread
                     ~label:"keeper-fs-created-directory-fchmod"
                     (fun () ->
                        Eio_unix.Fd.use_exn
                          "keeper-fs-created-directory-fchmod"
                          fd
                          (fun unix_fd -> Unix.fchmod unix_fd permissions));
                   Eio.Fiber.check ()))
             in
             let child_sync = sync_created_directory child_dir in
             let parent_sync = sync_created_directory parent_dir in
             let target_effect, primary_failure =
               match permissions_result with
               | Ok () -> Directory_created_requested_mode, None
               | Error failure -> Directory_created_validated, Some failure
             in
             let child_dir =
               match primary_failure, child_sync, parent_sync with
               | None, Directory_sync_succeeded, Directory_sync_succeeded ->
                 Some child_dir
               | ( Some _
                 , ( Directory_sync_not_attempted
                   | Directory_sync_succeeded
                   | Directory_sync_failed _ )
                 , ( Directory_sync_not_attempted
                   | Directory_sync_succeeded
                   | Directory_sync_failed _ ) )
               | ( None
                 , (Directory_sync_not_attempted | Directory_sync_failed _)
                 , ( Directory_sync_not_attempted
                   | Directory_sync_succeeded
                   | Directory_sync_failed _ ) )
               | ( None
                 , Directory_sync_succeeded
                 , (Directory_sync_not_attempted | Directory_sync_failed _) ) ->
                 None
             in
             ( child_dir
             , { component
               ; target_effect
               ; primary_failure
               ; child_sync
               ; parent_sync
               } ))))
;;

let with_created_parent_directories
      ~on_interrupted
      ~permissions
      parent_dir
      missing_parents
      f
  =
  let rec loop created_parents_rev parent_dir missing_parents =
    match missing_parents with
    | [] -> f ~created_parents:(List.rev created_parents_rev) parent_dir
    | component :: rest ->
      Eio.Switch.run @@ fun sw ->
      let child_dir, commit =
        Eio.Cancel.protect (fun () ->
          create_and_commit_directory_component
            ~sw
            ~permissions
            ~parent_dir
            ~component)
      in
      (try Eio.Fiber.check () with
       | Eio.Cancel.Cancelled _ as cancellation ->
         on_interrupted commit;
         raise cancellation);
      (match child_dir with
       | None ->
         Error
           (Content_write_directory
              { failed_commit = commit
              ; created_parents = List.rev created_parents_rev
              })
       | Some child_dir ->
         (try loop (commit :: created_parents_rev) child_dir rest with
          | exception_ ->
            let backtrace = Printexc.get_raw_backtrace () in
            on_interrupted commit;
            Printexc.raise_with_backtrace exception_ backtrace))
  in
  loop [] parent_dir missing_parents
;;

let rec with_deepest_existing_parent
          parent_dir
          traversed_components_rev
          remaining_components
          f
  =
  match remaining_components with
  | [] ->
    f
      ~parent_dir
      ~parent_components:(List.rev traversed_components_rev)
      ~missing_parents:[]
  | component :: rest ->
    Eio.Switch.run @@ fun sw ->
    (match
       try Ok (Eio.Path.open_dir ~sw Eio.Path.(parent_dir / component)) with
       | Eio.Io (Eio.Fs.E (Eio.Fs.Not_found _), _) -> Error `Missing
     with
     | Ok child_dir ->
       with_deepest_existing_parent
         child_dir
         (component :: traversed_components_rev)
         rest
         f
     | Error `Missing ->
       f
         ~parent_dir
         ~parent_components:(List.rev traversed_components_rev)
         ~missing_parents:remaining_components)
;;

let rec with_open_directory_components ~on_missing parent_dir components f =
  match components with
  | [] -> f parent_dir
  | component :: rest ->
    Eio.Switch.run @@ fun sw ->
    (match
       try Ok (Eio.Path.open_dir ~sw Eio.Path.(parent_dir / component)) with
       | Eio.Io (Eio.Fs.E (Eio.Fs.Not_found _), _) -> Error `Missing
     with
     | Error `Missing -> on_missing ()
     | Ok child_dir ->
       with_open_directory_components ~on_missing child_dir rest f)
;;

let rec split_leaf_components = function
  | [] -> None
  | [ leaf ] -> Some ([], leaf)
  | component :: rest ->
    Option.map
      (fun (parent, leaf) -> component :: parent, leaf)
      (split_leaf_components rest)
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
       let target_components =
         Keeper_alerting_path.confined_relative_components confined
       in
       let with_root root_dir =
         let* () =
           Keeper_alerting_path.verify_confined_root_capability confined root_dir
         in
         match split_leaf_components target_components with
         | None -> Error "filesystem target has no writable leaf"
         | Some (parent_components, leaf) ->
           with_deepest_existing_parent
             root_dir
             []
             parent_components
             (fun ~parent_dir ~parent_components ~missing_parents ->
                f
                  ~root_dir
                  ~parent_dir
                  ~parent_components
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
  | Write_failed_data of
      { message : string
      ; data : Yojson.Safe.t
      ; class_ : Tool_result.tool_failure_class
      }

let capability_write_failure_json
      (failure : Fs_compat.capability_write_failure)
  =
  let cause_fields =
    match failure.cause with
    | Fs_compat.Payload_write_failed { bytes_written; _ } ->
      [ "bytes_written", `Int bytes_written ]
    | ( Fs_compat.Invalid_leaf _
      | Fs_compat.Invalid_recovery_target _
      | Fs_compat.Mutation_contended
      | Fs_compat.Posix_descriptor_unavailable
      | Fs_compat.Unexpected_resource_kind _
      | Fs_compat.Resource_identity_unavailable
      | Fs_compat.Resource_identity_changed
      | Fs_compat.Operation_failed _ ) -> []
  in
  `Assoc
    ([ ( "stage"
       , `String (Fs_compat.capability_write_stage_to_string failure.stage) )
     ; ( "cause"
       , `String (Fs_compat.capability_write_cause_to_string failure.cause) )
     ]
     @ cause_fields)
;;

let capability_recovery_failure_json failure =
  `Assoc
    [ ( "phase"
      , `String
          (Fs_compat.capability_recovery_phase_to_string
             (Fs_compat.capability_recovery_failure_phase failure)) )
    ; ( "effect"
      , `String
          (Fs_compat.capability_recovery_effect_to_string
             (Fs_compat.capability_recovery_failure_effect failure)) )
    ; "detail", `String (Fs_compat.capability_recovery_failure_to_string failure)
    ]
;;

let capability_write_primary_failure_json = function
  | Fs_compat.Write_primary_failure failure ->
    `Assoc
      [ "kind", `String "write"
      ; "failure", capability_write_failure_json failure
      ]
  | Fs_compat.Recovery_primary_failure failure ->
    `Assoc
      [ "kind", `String "recovery"
      ; "failure", capability_recovery_failure_json failure
      ]
  | Fs_compat.Recovery_access_primary_failure
      Fs_compat.Recovery_access_not_available ->
    `Assoc
      [ "kind", `String "recovery_access"
      ; "failure", `String "recovery_access_not_available"
      ]
;;

let capability_write_cleanup_failure_json = function
  | Fs_compat.Write_cleanup_failure failure ->
    `Assoc
      [ "kind", `String "write"
      ; "failure", capability_write_failure_json failure
      ]
  | Fs_compat.Recovery_cleanup_failure failure ->
    `Assoc
      [ "kind", `String "recovery"
      ; "failure", capability_recovery_failure_json failure
      ]
;;

let observe_capability_write_failure_backtrace
      ~keeper_name
      ~target
      (failure : Fs_compat.capability_write_failure)
  =
  match failure.Fs_compat.cause with
  | Fs_compat.Operation_failed { exception_; backtrace } ->
    Log.Keeper.error
      ~keeper_name
      "WRITE_AUDIT: filesystem publication operation failed path=%s stage=%s error=%s backtrace=%s"
      target
      (Fs_compat.capability_write_stage_to_string failure.stage)
      (Printexc.to_string exception_)
      (Printexc.raw_backtrace_to_string backtrace)
  | Fs_compat.Payload_write_failed { exception_; backtrace; bytes_written } ->
    Log.Keeper.error
      ~keeper_name
      "WRITE_AUDIT: filesystem payload write failed path=%s stage=%s bytes_written=%d error=%s backtrace=%s"
      target
      (Fs_compat.capability_write_stage_to_string failure.stage)
      bytes_written
      (Printexc.to_string exception_)
      (Printexc.raw_backtrace_to_string backtrace)
  | ( Fs_compat.Invalid_leaf _
    | Fs_compat.Invalid_recovery_target _
    | Fs_compat.Mutation_contended
    | Fs_compat.Posix_descriptor_unavailable
    | Fs_compat.Unexpected_resource_kind _
    | Fs_compat.Resource_identity_unavailable
    | Fs_compat.Resource_identity_changed ) -> ()
;;

let observe_capability_recovery_failure ~keeper_name ~target failure =
  Log.Keeper.error
    ~keeper_name
    "WRITE_AUDIT: filesystem recovery transition failed path=%s phase=%s effect=%s failure=%s"
    target
    (Fs_compat.capability_recovery_phase_to_string
       (Fs_compat.capability_recovery_failure_phase failure))
    (Fs_compat.capability_recovery_effect_to_string
       (Fs_compat.capability_recovery_failure_effect failure))
    (Fs_compat.capability_recovery_failure_to_string failure)
;;

let observe_capability_write_primary_failure ~keeper_name ~target = function
  | Fs_compat.Write_primary_failure failure ->
    observe_capability_write_failure_backtrace ~keeper_name ~target failure
  | Fs_compat.Recovery_primary_failure failure ->
    observe_capability_recovery_failure ~keeper_name ~target failure
  | Fs_compat.Recovery_access_primary_failure
      Fs_compat.Recovery_access_not_available ->
    Log.Keeper.error
      ~keeper_name
      "WRITE_AUDIT: filesystem recovery access unavailable path=%s"
      target
;;

let observe_capability_write_cleanup_failure ~keeper_name ~target = function
  | Fs_compat.Write_cleanup_failure failure ->
    observe_capability_write_failure_backtrace ~keeper_name ~target failure
  | Fs_compat.Recovery_cleanup_failure failure ->
    observe_capability_recovery_failure ~keeper_name ~target failure
;;

let observe_capability_write_error
      ~keeper_name
      ~target
      (error : Fs_compat.capability_write_error)
  =
  observe_capability_write_primary_failure
    ~keeper_name
    ~target
    error.Fs_compat.primary_failure;
  List.iter
    (observe_capability_write_cleanup_failure ~keeper_name ~target)
    error.cleanup_failures
;;

let observe_capability_directory_sync_error
      ~keeper_name
      ~target
      (error : Fs_compat.capability_directory_sync_error)
  =
  observe_capability_write_failure_backtrace
    ~keeper_name
    ~target
    error.failure;
  List.iter
    (observe_capability_write_failure_backtrace ~keeper_name ~target)
    error.cleanup_failures
;;

let created_directory_stage_to_string = function
  | Create_directory -> "create_directory"
  | Inspect_created_directory -> "inspect_created_directory"
  | Acquire_directory_capability -> "acquire_directory_capability"
  | Validate_directory_capability -> "validate_directory_capability"
  | Apply_directory_permissions -> "apply_directory_permissions"
;;

let created_directory_target_effect_to_string = function
  | Directory_unchanged -> "directory_unchanged"
  | Directory_created_validated -> "directory_created_validated"
  | Directory_created_requested_mode -> "directory_created_requested_mode"
  | Directory_state_unknown -> "directory_state_unknown"
;;

let created_directory_failure_cause_to_string = function
  | Directory_posix_descriptor_unavailable -> "POSIX descriptor unavailable"
  | Directory_unexpected_resource_kind kind ->
    Format.asprintf "unexpected resource kind: %a" Eio.File.Stat.pp_kind kind
  | Directory_resource_identity_changed -> "directory resource identity changed"
  | Directory_operation_failed { exception_; _ } -> Printexc.to_string exception_
;;

let created_directory_failure_json failure =
  `Assoc
    [ "stage", `String (created_directory_stage_to_string failure.stage)
    ; "cause", `String (created_directory_failure_cause_to_string failure.cause)
    ]
;;

let created_directory_sync_outcome_json = function
  | Directory_sync_not_attempted -> `Assoc [ "status", `String "not_attempted" ]
  | Directory_sync_succeeded -> `Assoc [ "status", `String "succeeded" ]
  | Directory_sync_failed error ->
    `Assoc
      [ "status", `String "failed"
      ; "failure", capability_write_failure_json error.failure
      ; ( "cleanup_failures"
        , `List (List.map capability_write_failure_json error.cleanup_failures) )
      ]
;;

let created_directory_commit_json commit =
  `Assoc
    [ "component", `String commit.component
    ; ( "target_effect"
      , `String (created_directory_target_effect_to_string commit.target_effect) )
    ; ( "primary_failure"
      , match commit.primary_failure with
        | None -> `Null
        | Some failure -> created_directory_failure_json failure )
    ; "child_sync", created_directory_sync_outcome_json commit.child_sync
    ; "parent_sync", created_directory_sync_outcome_json commit.parent_sync
    ]
;;

let created_parent_effects_json created_parents =
  `List (List.map created_directory_commit_json created_parents)
;;

let capability_write_error_payload
      ~target
      ~created_parents
      (error : Fs_compat.capability_write_error)
  =
  error_json
    ~fields:
      [ "path", `String target
      ; ( "filesystem_write_operation"
        , `String
            (Fs_compat.capability_write_operation_to_string error.operation) )
      ; ( "filesystem_target_effect"
        , `String
            (Fs_compat.capability_write_target_effect_to_string
               error.target_effect) )
      ; ( "filesystem_created_parent_effects"
        , created_parent_effects_json created_parents )
      ; ( "filesystem_primary_failure"
        , capability_write_primary_failure_json error.primary_failure )
      ; ( "filesystem_cleanup_failures"
        , `List
            (List.map
               capability_write_cleanup_failure_json
               error.cleanup_failures) )
      ]
    "Filesystem publication failed; target effect and cleanup outcome are reported explicitly."
;;

let created_directory_commit_payload ~target ~created_parents commit =
  error_json
    ~fields:
      [ "path", `String target
      ; ( "filesystem_created_parent_effects"
        , created_parent_effects_json created_parents )
      ; "filesystem_directory_component", `String commit.component
      ; ( "filesystem_directory_target_effect"
        , `String
            (created_directory_target_effect_to_string commit.target_effect) )
      ; ( "filesystem_directory_primary_failure"
        , match commit.primary_failure with
          | None -> `Null
          | Some failure -> created_directory_failure_json failure )
      ; ( "filesystem_directory_child_sync"
        , created_directory_sync_outcome_json commit.child_sync )
      ; ( "filesystem_directory_parent_sync"
        , created_directory_sync_outcome_json commit.parent_sync )
      ]
    "Filesystem parent directory publication failed; creation effect and durability outcomes are reported explicitly."
;;

let observe_created_directory_failure_backtrace
      ~keeper_name
      ~target
      failure
  =
  match failure.cause with
  | Directory_operation_failed { exception_; backtrace } ->
    Log.Keeper.error
      ~keeper_name
      "WRITE_AUDIT: directory publication operation failed path=%s stage=%s error=%s backtrace=%s"
      target
      (created_directory_stage_to_string failure.stage)
      (Printexc.to_string exception_)
      (Printexc.raw_backtrace_to_string backtrace)
  | ( Directory_posix_descriptor_unavailable
    | Directory_unexpected_resource_kind _
    | Directory_resource_identity_changed ) -> ()
;;

let observe_created_directory_sync_outcome ~keeper_name ~target = function
  | Directory_sync_not_attempted | Directory_sync_succeeded -> ()
  | Directory_sync_failed error ->
    observe_capability_directory_sync_error ~keeper_name ~target error
;;

let observe_created_directory_commit ~keeper_name ~target commit =
  Log.Keeper.error
    ~keeper_name
    "WRITE_AUDIT: directory publication outcome path=%s component=%s target_effect=%s child_sync=%s parent_sync=%s"
    target
    commit.component
    (created_directory_target_effect_to_string commit.target_effect)
    (Yojson.Safe.to_string
       (created_directory_sync_outcome_json commit.child_sync))
    (Yojson.Safe.to_string
       (created_directory_sync_outcome_json commit.parent_sync));
  Option.iter
    (observe_created_directory_failure_backtrace ~keeper_name ~target)
    commit.primary_failure;
  observe_created_directory_sync_outcome
    ~keeper_name
    ~target
    commit.child_sync;
  observe_created_directory_sync_outcome
    ~keeper_name
    ~target
    commit.parent_sync
;;

let append_target_effect_to_string = function
  | Append_target_unchanged -> "target_unchanged"
  | Append_target_extended_complete -> "target_extended_complete"
  | Append_target_extended_partial -> "target_extended_partial"
  | Append_target_extended_detached -> "target_extended_detached"
  | Append_target_state_unknown -> "target_state_unknown"
;;

let capability_append_open_error_kind = function
  | Fs_compat.Capability_append_open_invalid_leaf _ -> "invalid_leaf"
  | Fs_compat.Capability_append_open_missing -> "missing"
  | Fs_compat.Capability_append_open_failed _ -> "operation_failed"
;;

let capability_append_open_error_payload ~target error =
  error_json
    ~fields:
      [ "path", `String target
      ; ( "filesystem_append_open_failure"
        , `Assoc
            [ ( "kind"
              , `String (capability_append_open_error_kind error) )
            ; ( "cause"
              , `String
                  (Fs_compat.capability_append_open_error_to_string error) )
            ] )
      ]
    "Filesystem append capability acquisition failed explicitly."
;;

let observe_capability_append_open_error ~keeper_name ~target error =
  match error with
  | Fs_compat.Capability_append_open_failed { exception_; backtrace } ->
    Log.Keeper.error
      ~keeper_name
      "WRITE_AUDIT: append capability acquisition failed path=%s error=%s backtrace=%s"
      target
      (Printexc.to_string exception_)
      (Printexc.raw_backtrace_to_string backtrace)
  | ( Fs_compat.Capability_append_open_invalid_leaf _
    | Fs_compat.Capability_append_open_missing ) ->
    Log.Keeper.error
      ~keeper_name
      "WRITE_AUDIT: append capability acquisition rejected path=%s kind=%s"
      target
      (capability_append_open_error_kind error)
;;

let append_target_effect outcome =
  match outcome.target_binding with
  | Fs_compat.Capability_append_target_not_checked
    when outcome.bytes_written = 0 -> Append_target_unchanged
  | Fs_compat.Capability_append_target_verified ->
    if outcome.bytes_written = 0
    then Append_target_unchanged
    else if
      outcome.bytes_written = outcome.requested_bytes
      && Option.is_none outcome.write_failure
    then Append_target_extended_complete
    else Append_target_extended_partial
  | Fs_compat.Capability_append_target_changed ->
    if outcome.bytes_written = 0
    then Append_target_state_unknown
    else Append_target_extended_detached
  | ( Fs_compat.Capability_append_target_not_checked
    | Fs_compat.Capability_append_target_check_failed _ ) ->
    Append_target_state_unknown
;;

let append_target_binding_json = function
  | Fs_compat.Capability_append_target_not_checked ->
    `Assoc [ "status", `String "not_checked" ]
  | Fs_compat.Capability_append_target_verified ->
    `Assoc [ "status", `String "verified" ]
  | Fs_compat.Capability_append_target_changed ->
    `Assoc [ "status", `String "changed" ]
  | Fs_compat.Capability_append_target_check_failed { exception_; _ } ->
    `Assoc
      [ "status", `String "check_failed"
      ; "cause", `String (Printexc.to_string exception_)
      ]
;;

let append_write_outcome_payload ~target outcome =
  error_json
    ~fields:
      [ "path", `String target
      ; ( "filesystem_append_target_effect"
        , `String
            (append_target_effect_to_string (append_target_effect outcome)) )
      ; "filesystem_append_requested_bytes", `Int outcome.requested_bytes
      ; "filesystem_append_bytes_written", `Int outcome.bytes_written
      ; ( "filesystem_append_target_binding"
        , append_target_binding_json outcome.target_binding )
      ; ( "filesystem_append_failure"
        , match outcome.write_failure with
          | None -> `Null
          | Some failure ->
            `String (Fs_compat.capability_append_failure_to_string failure) )
      ; ( "filesystem_append_sync_failure"
        , match outcome.sync_failure with
          | None -> `Null
          | Some { exception_; _ } -> `String (Printexc.to_string exception_) )
      ]
    "Filesystem append did not complete normally; exact written bytes and sync outcome are reported explicitly."
;;

let observe_append_write_outcome ~keeper_name ~target outcome =
  Log.Keeper.error
    ~keeper_name
    "WRITE_AUDIT: append publication outcome path=%s requested_bytes=%d bytes_written=%d target_effect=%s failure=%s"
    target
    outcome.requested_bytes
    outcome.bytes_written
    (append_target_effect_to_string (append_target_effect outcome))
    (match outcome.write_failure with
     | None -> "none"
     | Some failure -> Fs_compat.capability_append_failure_to_string failure);
  (match outcome.write_failure with
   | Some
       (Fs_compat.Capability_append_operation_failed
         { exception_; backtrace }) ->
     Log.Keeper.error
       ~keeper_name
       "WRITE_AUDIT: append write failed path=%s error=%s backtrace=%s"
       target
       (Printexc.to_string exception_)
       (Printexc.raw_backtrace_to_string backtrace)
   | ( None
     | Some Fs_compat.Capability_append_posix_descriptor_unavailable
     | Some Fs_compat.Capability_append_mutation_contended ) -> ());
  let observe_operation_failure
        label
        (failure : Fs_compat.capability_append_operation_failure)
    =
    Log.Keeper.error
      ~keeper_name
      "WRITE_AUDIT: append %s failed path=%s error=%s backtrace=%s"
      label
      target
      (Printexc.to_string failure.exception_)
      (Printexc.raw_backtrace_to_string failure.backtrace)
  in
  Option.iter (observe_operation_failure "sync") outcome.sync_failure;
  (match outcome.target_binding with
   | Fs_compat.Capability_append_target_check_failed failure ->
     observe_operation_failure "target identity check" failure
   | ( Fs_compat.Capability_append_target_not_checked
     | Fs_compat.Capability_append_target_verified
     | Fs_compat.Capability_append_target_changed ) -> ())
;;

let file_write_attempt_to_execution = function
  | Write_succeeded payload -> Keeper_tool_execution.success payload
  | Write_failed { payload; class_ } -> Keeper_tool_execution.failure ~class_ payload
  | Write_failed_data { message; data; class_ } ->
    Keeper_tool_execution.failure_data ~class_ ~message data
;;

let publication_recovery_unavailable_attempt unavailable =
  Write_failed_data
    { message =
        Keeper_publication_recovery_availability.unavailable_to_string unavailable
    ; data =
        Keeper_publication_recovery_availability.unavailable_to_yojson unavailable
    ; class_ = Tool_result.Runtime_failure
    }
;;

let handle_file_write_with_outcome
      ~(turn_sandbox_factory : Keeper_sandbox_factory.t option)
      ~(config : Workspace.config)
      ~(meta : Keeper_meta_contract.keeper_meta)
      ~(publication_recovery :
          Keeper_publication_recovery_availability.turn_context)
      ?continuation_channel
      ?gate_context
      ?gate_grant
      ~(args : Yojson.Safe.t)
      ()
  =
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
    | Eio.Cancel.Cancelled
        (Fs_compat.Capability_write_cancelled (reason, cancellation)) as e ->
      let interrupted_primary =
        match cancellation.interrupted_primary_failure with
        | None -> `Null
        | Some failure -> capability_write_primary_failure_json failure
      in
      let interrupted_recovery =
        match cancellation.interrupted_recovery with
        | None -> `Null
        | Some failure -> capability_recovery_failure_json failure
      in
      Log.Keeper.error
        ~keeper_name:meta.name
        "WRITE_AUDIT: filesystem publication cancelled after observable state transition path=%s operation=%s target_effect=%s interrupted_primary=%s interrupted_recovery=%s cleanup_failures=%s reason=%s"
        target
        (Fs_compat.capability_write_operation_to_string cancellation.operation)
        (Fs_compat.capability_write_target_effect_to_string
           cancellation.target_effect)
        (Yojson.Safe.to_string interrupted_primary)
        (Yojson.Safe.to_string interrupted_recovery)
        (Yojson.Safe.to_string
           (`List
               (List.map
                  capability_write_cleanup_failure_json
                  cancellation.cleanup_failures)))
        (Printexc.to_string reason);
      Option.iter
        (observe_capability_write_primary_failure
           ~keeper_name:meta.name
           ~target)
        cancellation.interrupted_primary_failure;
      Option.iter
        (observe_capability_recovery_failure
           ~keeper_name:meta.name
           ~target)
        cancellation.interrupted_recovery;
      List.iter
        (observe_capability_write_cleanup_failure
           ~keeper_name:meta.name
           ~target)
        cancellation.cleanup_failures;
      raise e
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
    let finish_write_result result =
      match result with
    | Error (Content_write_message message) -> Error message
    | Error (Content_write_capability { error; created_parents }) ->
      List.iter
        (observe_created_directory_commit
           ~keeper_name:meta.name
           ~target)
        created_parents;
      observe_capability_write_error ~keeper_name:meta.name ~target error;
      Ok
        (Write_failed
           { payload = capability_write_error_payload ~target ~created_parents error
           ; class_ = Tool_result.Runtime_failure
           })
    | Error (Content_write_directory { failed_commit; created_parents }) ->
      List.iter
        (observe_created_directory_commit
           ~keeper_name:meta.name
           ~target)
        created_parents;
      observe_created_directory_commit
        ~keeper_name:meta.name
        ~target
        failed_commit;
      Ok
        (Write_failed
           { payload =
               created_directory_commit_payload
                 ~target
                 ~created_parents
                 failed_commit
           ; class_ = Tool_result.Runtime_failure
           })
    | Error (Content_write_append outcome) ->
      observe_append_write_outcome
        ~keeper_name:meta.name
        ~target
        outcome;
      Ok
        (Write_failed
           { payload = append_write_outcome_payload ~target outcome
           ; class_ = Tool_result.Runtime_failure
           })
    | Ok () ->
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
    match write with
    | Recovery_independent operation -> finish_write_result (operation ())
    | Recovery_guarded operation ->
      (match
         Keeper_publication_recovery_availability.with_access
           publication_recovery
           operation
       with
       | Ok result -> finish_write_result result
       | Error unavailable ->
         Ok (publication_recovery_unavailable_attempt unavailable))
  in
  let parent_effect_scope ~parent_dir ~parent_components ~missing_parents =
    Keeper_alerting_path.path_effect_parent_scope
      ~parent_components
      ~resource:(Eio.Path.stat ~follow:true parent_dir)
      ~create_missing_parents:missing_parents
      ~created_directory_permissions
    |> Result.map_error Keeper_alerting_path.path_effect_projection_error_to_string
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
        @@ fun ~root_dir:_ ~parent_dir ~parent_components ~missing_parents ~leaf ->
        let* parent =
          parent_effect_scope ~parent_dir ~parent_components ~missing_parents
        in
        let* result_file_permissions =
          if missing_parents = []
          then replacement_file_permissions ~parent_dir ~leaf
          else Ok created_file_permissions
        in
        let* projection =
          make_effect ~parent ~result_file_permissions confined
          |> Result.map_error Keeper_alerting_path.path_effect_projection_error_to_string
        in
        let gate_effect =
          Keeper_alerting_path.atomic_replace_gate_effect projection
        in
        let recovery_target =
          Keeper_alerting_path.atomic_replace_recovery_target projection
        in
        finish_content_write
          ~target
          ~mode_label
          ~gate_effect
          (Recovery_guarded
             (fun publication_recovery_access ->
                with_created_parent_directories
                  ~on_interrupted:
                    (observe_created_directory_commit
                       ~keeper_name:meta.name
                       ~target)
                  ~permissions:created_directory_permissions
                  parent_dir
                  missing_parents
                @@ fun ~created_parents final_parent ->
                Fs_compat.replace_capability_file
                  ~recovery:publication_recovery_access
                  ~parent:final_parent
                  ~target:recovery_target
                  content
                |> Result.map_error (fun error ->
                  Content_write_capability { error; created_parents })))
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
        @@ fun ~root_dir ~parent_dir ~parent_components ~missing_parents ~leaf ->
        let create_missing_entry () =
          let* parent =
            parent_effect_scope ~parent_dir ~parent_components ~missing_parents
          in
          let* gate_effect =
            Keeper_alerting_path.create_entry_exclusive_effect
              ~parent
              ~result_file_permissions:created_file_permissions
              confined
            |> Result.map_error Keeper_alerting_path.path_effect_projection_error_to_string
          in
          finish_content_write
            ~target
            ~mode_label
            ~gate_effect
            (Recovery_independent
               (fun () ->
                  with_created_parent_directories
                    ~on_interrupted:
                      (observe_created_directory_commit
                         ~keeper_name:meta.name
                         ~target)
                    ~permissions:created_directory_permissions
                    parent_dir
                    missing_parents
                  @@ fun ~created_parents final_parent ->
                  Fs_compat.create_capability_file_exclusive
                    ~parent:final_parent
                    ~leaf
                    ~permissions:created_file_permissions
                    content
                  |> Result.map_error (fun error ->
                    Content_write_capability { error; created_parents })))
        in
        if missing_parents <> []
        then create_missing_entry ()
        else
          let endpoint_components =
            Keeper_alerting_path.confined_endpoint_components confined
          in
          (match split_leaf_components endpoint_components with
           | None -> Error "filesystem append endpoint has no writable leaf"
           | Some (endpoint_parent_components, endpoint_leaf) ->
             with_open_directory_components
               ~on_missing:(fun () ->
                 Error "filesystem append endpoint parent does not exist")
               root_dir
               endpoint_parent_components
             @@ fun endpoint_parent_dir ->
             Eio.Switch.run @@ fun sw ->
             (match
                Fs_compat.open_capability_append_file
                  ~sw
                  ~parent:endpoint_parent_dir
                  ~leaf:endpoint_leaf
              with
              | Error Fs_compat.Capability_append_open_missing ->
                create_missing_entry ()
              | Error open_error ->
                observe_capability_append_open_error
                  ~keeper_name:meta.name
                  ~target
                  open_error;
                Ok
                  (Write_failed
                     { payload =
                         capability_append_open_error_payload
                           ~target
                           open_error
                     ; class_ = Tool_result.Runtime_failure
                     })
              | Ok file ->
                let stat = Fs_compat.capability_append_file_stat file in
                if stat.kind <> `Regular_file
                then Error "filesystem append target is not a regular file"
                else
                  let* gate_effect =
                    Keeper_alerting_path.append_pinned_resource_effect
                      confined
                      stat
                    |> Result.map_error
                         Keeper_alerting_path.path_effect_projection_error_to_string
                  in
                  finish_content_write
                    ~target
                    ~mode_label
                    ~gate_effect
                    (Recovery_independent
                       (fun () ->
                          append_capability
                            ~on_cancelled:
                              (observe_append_write_outcome
                                 ~keeper_name:meta.name
                                 ~target)
                            file
                            content))))
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
                let finish_write_result result =
                  match result with
                | Error (Content_write_message message) -> Error message
                | Error (Content_write_capability { error; created_parents }) ->
                  List.iter
                    (observe_created_directory_commit
                       ~keeper_name:meta.name
                       ~target)
                    created_parents;
                  observe_capability_write_error
                    ~keeper_name:meta.name
                    ~target
                    error;
                  Ok
                    (Write_failed
                       { payload =
                           capability_write_error_payload
                             ~target
                             ~created_parents
                             error
                       ; class_ = Tool_result.Runtime_failure
                       })
                | Error
                    (Content_write_directory { failed_commit; created_parents }) ->
                  List.iter
                    (observe_created_directory_commit
                       ~keeper_name:meta.name
                       ~target)
                    created_parents;
                  observe_created_directory_commit
                    ~keeper_name:meta.name
                    ~target
                    failed_commit;
                  Ok
                    (Write_failed
                       { payload =
                           created_directory_commit_payload
                             ~target
                             ~created_parents
                             failed_commit
                       ; class_ = Tool_result.Runtime_failure
                       })
                | Error (Content_write_append outcome) ->
                  observe_append_write_outcome
                    ~keeper_name:meta.name
                    ~target
                    outcome;
                  Ok
                    (Write_failed
                       { payload = append_write_outcome_payload ~target outcome
                       ; class_ = Tool_result.Runtime_failure
                       })
                | Ok () ->
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
                match
                  Keeper_publication_recovery_availability.with_access
                    publication_recovery
                    (fun publication_recovery_access ->
                       write publication_recovery_access updated)
                with
                | Ok result -> finish_write_result result
                | Error unavailable ->
                  Ok (publication_recovery_unavailable_attempt unavailable)
              in
              let patch_current
                    ~parent
                    ~source_resource
                    ~result_file_permissions
                    current
                    write
                =
                let* updated, occurrences =
                  apply_patch ~old_string ~new_string ~replace_all current
                in
                let* projection =
                  Keeper_alerting_path.patch_then_atomic_replace_effect
                    ~parent
                    ~source_resource
                    ~result_file_permissions
                    confined
                  |> Result.map_error
                       Keeper_alerting_path.path_effect_projection_error_to_string
                in
                let gate_effect =
                  Keeper_alerting_path.atomic_replace_gate_effect projection
                in
                let recovery_target =
                  Keeper_alerting_path.atomic_replace_recovery_target projection
                in
                finish_write
                  ~gate_effect
                  ~updated
                  ~occurrences
                  (fun publication_recovery_access updated ->
                     write
                       ~recovery_target
                       publication_recovery_access
                       updated)
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
                @@ fun ~root_dir ~parent_dir ~parent_components ~missing_parents ~leaf ->
                if missing_parents <> []
                then missing_target ()
                else
                  let endpoint_components =
                    Keeper_alerting_path.confined_endpoint_components confined
                  in
                  (match split_leaf_components endpoint_components with
                   | None -> Error "filesystem patch source has no readable leaf"
                   | Some (source_parent_components, source_leaf) ->
                     with_open_directory_components
                       ~on_missing:missing_target
                       root_dir
                       source_parent_components
                     @@ fun source_parent_dir ->
                     Eio.Switch.run @@ fun sw ->
                     (match
                        try
                          Ok
                            (Eio.Path.open_in
                               ~sw
                               Eio.Path.(source_parent_dir / source_leaf))
                        with
                        | Eio.Io (Eio.Fs.E (Eio.Fs.Not_found _), _) ->
                          Error `Missing
                      with
                      | Error `Missing -> missing_target ()
                      | Ok source_file ->
                        let source_resource = Eio.File.stat source_file in
                        if source_resource.kind <> `Regular_file
                        then
                          Error
                            (Fmt.str
                               "filesystem patch target must resolve to a regular file; found %a"
                               Eio.File.Stat.pp_kind
                               source_resource.kind)
                        else
                          let current = load_open_file source_file in
                          let* result_file_permissions =
                            replacement_file_permissions ~parent_dir ~leaf
                          in
                          let* parent =
                            parent_effect_scope
                              ~parent_dir
                              ~parent_components
                              ~missing_parents:[]
                          in
                          patch_current
                            ~parent
                            ~source_resource
                            ~result_file_permissions
                            current
                            (fun ~recovery_target publication_recovery_access updated ->
                               Fs_compat.replace_capability_file
                                 ~recovery:publication_recovery_access
                                 ~parent:parent_dir
                                 ~target:recovery_target
                                 updated
                               |> Result.map_error (fun error ->
                                 Content_write_capability
                                   { error; created_parents = [] }))))
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
      ~meta
      ~publication_recovery
      ?continuation_channel
      ?gate_context
      ?gate_grant
      ~args
      ()
  =
  (handle_file_write_with_outcome
     ~turn_sandbox_factory
     ~config
     ~meta
     ~publication_recovery
     ?continuation_channel
     ?gate_context
     ?gate_grant
     ~args
     ()).raw_output
;;

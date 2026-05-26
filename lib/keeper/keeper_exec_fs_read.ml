(** Keeper_exec_fs_read — fs write mode types, constants, and
    [handle_read_file] extracted from [Agent_tool_filesystem_runtime].
    Patch/edit logic, write validation, and [handle_keeper_fs_edit]
    remain in the parent.
    @since Keeper 500-line decomposition *)

open Keeper_types
open Keeper_exec_shared
open Ide_region_tracker

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
  (** RFC-0006 Phase A.4: read-replace-write for the Provider_a Code
        [EditFile] cognate. Caller supplies [old_string] + [new_string]
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

(** ReadFile max_bytes clamp. [read_file_default_max_bytes] is the
    canonical default; [Tool_shard_limits.read_file_default_max_bytes]
    re-exports it at a leaf module so the tool schema in tool_shard.ml
    can reference the same value without creating a dependency cycle. *)
let read_file_default_max_bytes = Tool_shard_limits.read_file_default_max_bytes

let read_file_min_max_bytes = 512
let read_file_max_max_bytes = 200_000

let handle_read_file
      ~(turn_sandbox_factory : Keeper_sandbox_factory.t option)
      ~(config : Coord.config)
      ~(keeper_name : string)
      ~(args : Yojson.Safe.t)
  =
  with_registry_meta ~keeper_name ~source_layer:"fs_resolver"
  @@ fun meta ->
  let path = Safe_ops.json_string ~default:"" "path" args in
  let max_bytes =
    Safe_ops.json_int ~default:read_file_default_max_bytes "max_bytes" args
    |> fun n -> max read_file_min_max_bytes (min read_file_max_max_bytes n)
  in
  let fallback_dir = keeper_default_read_root ~config ~meta in
  match playground_relative_unless_allowed_root ~config ~meta path with
  | Error e -> error_json e
  | Ok normalized ->
    (match
       Keeper_alerting_path.resolve_keeper_read_path
         ~config
         ~allowed_paths:(keeper_effective_allowed_paths ~meta)
         ~raw_path:normalized
     with
     | Error (Not_found_relative { raw }) ->
       (* Path within root but doesn't exist — use structured error with suggestions *)
       let root = Keeper_alerting_path.project_root_of_config config in
       let target =
         if Filename.is_relative path then Filename.concat root path else path
       in
       missing_file_error_json
         ~config
         ~target
         ~fallback_dir
         ~error:
           (Keeper_alerting_path.rejection_to_user_message (Not_found_relative { raw }))
     | Error rej -> error_json (Keeper_alerting_path.rejection_to_user_message rej)
     | Ok target ->
       (* RFC-0006 Phase B-1: Docker keepers are always contained to their
       playground bundle on the host before any read-side I/O proceeds.
       The resolver-level allowed_paths check is augmented by this
       strict containment so host FS cannot leak through ReadFile
       while keeper_bash is container-isolated. *)
       (match Keeper_sandbox_containment.check_read_target ~config ~meta ~target with
        | Error e -> error_json ~fields:[ "path", `String target ] e
        | Ok () ->
          (* Multi-repository Phase 2: repository-level access restriction.
       If the resolved path is under a registered repository, enforce
       keeper-to-repo mapping.  Paths outside all registered repos are
       allowed (playground general files). *)
          (match
             Keeper_repo_mapping.validate_path_access
               ~keeper_id:meta.name
               ~base_path:(Keeper_alerting_path.project_root_of_config config)
               ~path:target
           with
           | Error msg -> error_json ~fields:[ "path", `String target ] msg
           | Ok () ->
             (* RFC-0006 Phase B-2: sandbox-backed keepers route the actual
       byte read through the backend read runner so the backend mount
       restrictions are the load-bearing isolation. The host containment
       check above remains as defense-in-depth. *)
             if Keeper_sandbox_read_runner.should_route_read ~meta
             then (
               let timeout_sec = Env_config_exec_timeout.timeout_sec ~caller:Fs () in
               match
                 Keeper_sandbox_read_runner.read_file
                   ?turn_sandbox_factory
                   ~config
                   ~meta
                   ~host_path:target
                   ~max_bytes
                   ~timeout_sec
                   ()
               with
               | Error msg -> error_json ~fields:[ "path", `String target ] msg
               | Ok body ->
                 let total = String.length body in
                 let truncated = total >= max_bytes in
                 Yojson.Safe.to_string
                   (`Assoc
                       [ "ok", `Bool true
                       ; "path", `String target
                       ; "bytes", `Int total
                       ; "truncated", `Bool truncated
                       ; "content", `String body
                       ; "via", `String Keeper_sandbox_read_runner.backend_via
                       ]))
             else (
               match Safe_ops.read_file_safe target with
               | Error e when String.starts_with ~prefix:file_not_found_prefix e ->
                 missing_file_error_json ~config ~target ~fallback_dir ~error:e
               | Error e -> error_json ~fields:[ "path", `String target ] e
               | Ok content ->
                 let total = String.length content in
                 let truncated = total > max_bytes in
                 let body =
                   if truncated then String.sub content 0 max_bytes else content
                 in
                 Yojson.Safe.to_string
                   (`Assoc
                       [ "ok", `Bool true
                       ; "path", `String target
                       ; "bytes", `Int total
                       ; "truncated", `Bool truncated
                       ; "content", `String body
                       ])))))
;;

(* RFC-0006 Phase A.4: replace [old] with [new] in [text]. When
   [replace_all=false], requires exactly one occurrence so accidental
   multi-edits are rejected (mirrors Provider_a Edit semantics). *)

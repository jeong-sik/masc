(* Keeper_workspace_read_ops — read-side operation handlers for Grep.

   This module owns structured read/list/search operations so
   the Grep facade stays as the public dispatcher instead of reabsorbing
   read-backend, path-resolution, and host Shell IR details. *)

open Keeper_types
open Keeper_meta_contract
open Keeper_types_profile
open Keeper_tool_shared_runtime
open Keeper_workspace_ops_setup

(* Ripgrep input validation for arguments that can be checked without
   crossing the execution boundary. Regex/glob semantics stay with the
   actual rg invocation so sandboxed keepers do not depend on a host rg
   preflight. *)
let rg_type_name_char = function
  | 'a' .. 'z' | 'A' .. 'Z' | '0' .. '9' | '-' | '_' -> true
  | _ -> false
;;

let validate_rg_type file_type =
  if file_type = "" || String.for_all rg_type_name_char file_type
  then Ok ()
  else
    Error
      (Printf.sprintf
         "invalid ripgrep --type value %S. Type names may contain only letters, \
          digits, hyphens, and underscores."
         file_type)
;;

let validate_rg_inputs ~pattern:_ ~file_type =
  match validate_rg_type file_type with
  | Error _ as e -> e
  | Ok () -> Ok ()
;;

let rg_type_list_max_bytes = 1_000_000

let rg_type_names listing =
  String.split_on_char '\n' listing
  |> List.filter_map (fun line ->
    match String.index_opt line ':' with
    | Some index when index > 0 -> Some (String.sub line 0 index)
    | Some _ | None -> None)
;;

(* The failed rg and this inventory run on the same backend, so custom types
   from that backend's config are included. An incomplete or unavailable
   inventory cannot prove that the caller's type is invalid. *)
let rg_error_class ~status ~file_type ~read_type_list =
  match status with
  | Unix.WEXITED 2 when not (String.equal file_type "") ->
    (match read_type_list () with
     | Some listing when String.length listing < rg_type_list_max_bytes ->
       (match rg_type_names listing with
        | _ :: _ as names when not (List.mem file_type names) -> Tool_result.Policy_rejection
        | [] | _ :: _ -> Tool_result.Runtime_failure)
     | Some _ | None -> Tool_result.Runtime_failure)
  | Unix.WEXITED _ | Unix.WSIGNALED _ | Unix.WSTOPPED _ -> Tool_result.Runtime_failure
;;

let try_handle_with_outcome
      ~(turn_sandbox_factory : Keeper_sandbox_factory.t option)
      ~(config : Workspace.config)
      ~(meta : keeper_meta)
      ~(args : Yojson.Safe.t)
      ~op
      ~raw_path
  =
  let containment_check target =
    Keeper_sandbox_containment.check_read_target ~config ~meta ~target
  in
  let path_error ~class_ e =
    Keeper_tool_execution.failure
      ~class_
      (error_json
         ~fields:[ "ok", `Bool false; "op", `String op; "path", `String raw_path ]
         e)
  in
  let read_target () =
    let keeper_tree_target =
      match Keeper_tool_execute_path.resolve_tool_read_path ~config ~meta ~args with
      | Error e -> Error e
      | Ok target -> Result.map (fun () -> target) (containment_check target)
    in
    match keeper_tree_target with
    | Ok target -> Ok target
    | Error refusal ->
      (* Only what the keeper's own tree refused may be a path under the
         endpoint's declared roots (#38593): the endpoint's own name, which
         the backend reads as itself. [path] and [cwd] are read from [args]
         exactly as [resolve_tool_read_path] reads them. *)
      let arg key = Safe_ops.json_string ~default:"" key args |> String.trim in
      let cwd =
        match arg "cwd" with
        | "" -> None
        | cwd -> Some cwd
      in
      (match
         Keeper_sandbox_remote_lane.declared_endpoint_path_of_args
           ~config ~meta ~path:(arg "path") ~cwd
       with
       | Ok (Some endpoint_path) -> Ok endpoint_path
       | Ok None -> Error refusal
       (* An endpoint that cannot be resolved is the operator's
          configuration, not the caller's path. *)
       | Error endpoint_error ->
         Error
           (Keeper_alerting_path.endpoint_unresolved ~tree_refusal:refusal ~endpoint_error))
  in
  let sandbox_read_error ~target msg =
    error_json ~fields:[ "op", `String op; "path", `String target ] msg
  in
  let run_readonly_in_sandbox ?(ok_exit_codes = [ 0 ]) ~target ~command_argv
      ~max_bytes ~timeout_sec () =
    (* A shared mount makes the host-side existence preflight precise and
       cheap. A tree the endpoint owns does not: the host path is bookkeeping
       only, and existence is authoritative on the endpoint. *)
    if
      Keeper_types_profile_sandbox.tree_location_of_profile meta.sandbox_profile
      = Keeper_types_profile_sandbox.Shared_mount
      && not (Sys.file_exists target)
    then
      Error
        ( Tool_result.Policy_rejection
        , sandbox_read_error ~target
            (Printf.sprintf
               "path_not_found: %s (host path does not exist; list your \
                workspace root to see what is actually there before searching)"
               target) )
    else
      (* An admitted path the backend cannot map, or a backend command that
         failed, is not claimed as the caller's: a declared endpoint path maps
         only through the endpoint's configuration. *)
      match
        Keeper_sandbox_read_runner.container_path_of_host ~config ~meta ~host_path:target
      with
      | Error e -> Error (Tool_result.Runtime_failure, sandbox_read_error ~target e)
      | Ok cpath -> (
          match
            Keeper_sandbox_read_runner.run_command_with_status
              ?turn_sandbox_factory
              ~ok_exit_codes ~config ~meta ~command_argv:(command_argv cpath)
              ~max_bytes ~timeout_sec ()
          with
          | Error msg -> Error (Tool_result.Runtime_failure, sandbox_read_error ~target msg)
          | Ok payload -> Ok payload)
  in
  match op with
  | "rg" ->
    Some
      (let pattern = Safe_ops.json_string ~default:"" "pattern" args |> String.trim in
       let file_type = Safe_ops.json_string ~default:"" "type" args |> String.trim in
       if pattern = ""
       then
         Keeper_tool_execution.failure
           ~class_:Tool_result.Policy_rejection
           (error_json
              ~fields:[ "op", `String op ]
              "pattern is required for rg. Good: pattern='handle_request'. Bad: pattern=''.")
       else (
         match validate_rg_inputs ~pattern ~file_type with
         | Error msg ->
           Keeper_tool_execution.failure
             ~class_:Tool_result.Policy_rejection
             (error_json ~fields:[ "op", `String op ] msg)
         | Ok () -> (
           let limit = shell_readonly_limit args in
           let glob = Safe_ops.json_string ~default:"" "glob" args |> String.trim in
           let rg_in_sandbox target =
               let base_argv = [ "rg"; "-n"; "-m"; string_of_int limit ] in
               let type_argv = if file_type <> "" then [ "--type"; file_type ] else [] in
               let glob_argv = if glob <> "" then [ "--glob"; glob ] else [] in
               (match
                  run_readonly_in_sandbox ~target
                    ~command_argv:(fun cpath ->
                      (* [-e] marks the pattern as a pattern even when it
                         starts with a dash — without it a model-authored
                         leading-dash pattern parses as an rg flag (latent
                         argv-injection-shaped failure; 24h audit #7). *)
                      base_argv @ type_argv @ glob_argv @ [ "-e"; pattern; cpath ])
                    ~ok_exit_codes:[ 0; 1; 2 ]
                    ~max_bytes:1_000_000
                    ~timeout_sec:(Env_config_sandbox.Shell_timeout.timeout_sec ~bucket:Read ())
                    ()
                with
                | Error (class_, response) -> Keeper_tool_execution.failure ~class_ response
                | Ok (st, out) ->
                  let is_ok =
                    match st with
                    | Unix.WEXITED 0 | Unix.WEXITED 1 -> true
                    | _ -> false
                  in
                  let trimmed_out = String.trim out in
                  let error_detail =
                    if is_ok || String.equal trimmed_out ""
                    then []
                    else [ "error_detail", `String trimmed_out ]
                  in
                  let payload =
                    `Assoc
                        ([ "ok", `Bool is_ok
                         ; "op", `String op
                         ; "path", `String target
                         ; "pattern", `String pattern
                         ; "via", `String Keeper_sandbox_read_runner.backend_via
                         ; "status", Keeper_alerting_path.process_status_to_json st
                         ; "matches", (if is_ok then lines_to_json ~limit out else `List [])
                         ]
                         @ error_detail)
                  in
                  if is_ok
                  then Keeper_tool_execution.success_data payload
                  else
                    (* Preserve rg's own error payload. A missing --type can
                       be established from this backend's type inventory;
                       other exit-2 causes stay unclassified as caller errors. *)
                    Keeper_tool_execution.failure
                      ~class_:(rg_error_class ~status:st ~file_type ~read_type_list:(fun () ->
                        match
                          Keeper_sandbox_read_runner.run_command_with_status
                            ?turn_sandbox_factory
                            ~config ~meta ~command_argv:[ "rg"; "--type-list" ]
                            ~max_bytes:rg_type_list_max_bytes
                            ~timeout_sec:(Env_config_sandbox.Shell_timeout.timeout_sec ~bucket:Read ())
                            ()
                        with
                        | Ok (Unix.WEXITED 0, listing) -> Some listing
                        | Ok _ | Error _ -> None))
                      (Yojson.Safe.to_string payload))
           in
           match read_target () with
           | Error refusal ->
             path_error ~class_:refusal.Keeper_alerting_path.failure_class refusal.message
           (* A keeper-tree path and a path under the endpoint's declared
              roots (#38593) are both searched through the backend. *)
           | Ok target -> rg_in_sandbox target)))
  | _ -> None
;;

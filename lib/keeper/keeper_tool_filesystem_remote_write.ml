(** Write and Edit for a tree the endpoint owns.

    The host handler ([Keeper_tool_filesystem_runtime]) writes through Eio
    capabilities on a directory it can open; a tree on an OpenSSH host or in
    a guest's work volume is not a directory this host can open. So the
    bytes go where every command of such a keeper already goes: through
    [masc-exec-shim] over the remote lane, as a [sh] payload with the content
    on stdin, at the path {!Keeper_remote_path} translates the keeper's host
    bookkeeping path to.

    What stays the same as the host handler: the path is resolved and jailed
    in the keeper's host namespace first (the same
    [resolve_keeper_confined_write_path]), the same modes, the same patch, the
    same evidence, the same per-path lease. What differs: there is no Gate
    decision, because the jail admits only the keeper's own playground and
    such writes are internal (the host handler authorizes those without the
    Gate as well); and there is no publication-recovery journal, because the
    replace is [mktemp] + [mv] on the endpoint's own filesystem.

    Failures are typed by the payload's exit code, which the scripts choose,
    never by reading its stderr. *)

open Keeper_meta_contract
open Keeper_tool_shared_runtime

(* [$0] is the script name, [$1] the translated path. The temporary file is
   made beside the target so [mv] is a rename on one filesystem; a replaced
   file keeps its mode, a new one gets 0644 regardless of umask. A payload
   killed between [mktemp] and [mv] leaves [.masc-write.*] beside the
   target; it is named so a person can tell whose it is. *)
let overwrite_script =
  "set -e; d=$(dirname \"$1\"); mkdir -p \"$d\"; t=$(mktemp \"$d/.masc-write.XXXXXX\"); \
   cat > \"$t\"; if [ -e \"$1\" ]; then chmod \"$(stat -c %a \"$1\")\" \"$t\"; else chmod 0644 \"$t\"; fi; \
   mv -f \"$t\" \"$1\""
;;

let append_script = "set -e; d=$(dirname \"$1\"); mkdir -p \"$d\"; cat >> \"$1\""

(* A patch source that is not a regular file exits with this code, chosen
   here, so the handler tells "nothing to patch" from a failed [cat]. *)
let patch_source_missing_exit = 3

let read_source_script =
  Printf.sprintf "if [ -f \"$1\" ]; then cat \"$1\"; else exit %d; fi" patch_source_missing_exit
;;

let script_name = "masc-remote-write"

type content_mode =
  | Replace_whole
  | Append_tail

let write_argv ~mode ~remote_path =
  let script =
    match mode with
    | Replace_whole -> overwrite_script
    | Append_tail -> append_script
  in
  [ "sh"; "-c"; script; script_name; remote_path ]
;;

let read_source_argv ~remote_path = [ "sh"; "-c"; read_source_script; script_name; remote_path ]

let timeout_sec () = Env_config_sandbox.Shell_timeout.timeout_sec ~bucket:Io ()

(* The jail root is the keeper's own playground; a confined path under any
   other root cannot be represented on the endpoint. The host handler sends
   such a path to the Gate; here it is refused, because the remote lane has
   no target for it. *)
let confined_is_keeper_playground ~(config : Workspace.config) ~(meta : keeper_meta) confined =
  let normalized path = Keeper_alerting_path.normalize_path_for_check_stripped path in
  String.equal
    (normalized (Keeper_alerting_path.confined_root confined))
    (normalized (Keeper_sandbox.host_root_abs_of_meta ~config meta))
;;

let describe_status = function
  | Unix.WEXITED code -> Printf.sprintf "exit %d" code
  | Unix.WSIGNALED signal -> Printf.sprintf "signal %d" signal
  | Unix.WSTOPPED signal -> Printf.sprintf "stopped %d" signal
;;

let run ~endpoint ~cwd ~argv ~stdin =
  let runner = Keeper_sandbox_remote.runner ~timeout_sec:(timeout_sec ()) endpoint in
  runner ~on_stdout_chunk:None ~on_stderr_chunk:None ~stdin_content:(Some stdin)
    ~argv ~env:[||] ~cwd:(Some cwd)
;;

let success_payload ~target ~(meta : keeper_meta) fields =
  Yojson.Safe.to_string
    (`Assoc
        ([ "ok", `Bool true; "path", `String target ]
         @ fields
         @ [ "via", `String (Keeper_types_profile_sandbox.sandbox_profile_to_string meta.sandbox_profile) ]))
;;

let handle_with_endpoint
      ~(endpoint : Keeper_sandbox_remote.t)
      ~(config : Workspace.config)
      ~(meta : keeper_meta)
      ~(args : Yojson.Safe.t)
  =
  let path = Safe_ops.json_string ~default:"" "path" args in
  let content = Safe_ops.json_string ~default:"" "content" args in
  let failure ?class_ ~target message =
    Keeper_tool_execution.failure ?class_ (error_json ~fields:[ "path", `String target ] message)
  in
  if String.trim path = ""
  then
    Keeper_tool_execution.failure
      ~class_:Tool_result.Policy_rejection
      (error_json "path is required. Good: path='lib/foo.ml'. Bad: path=''.")
  else
    match Keeper_tool_write_mode.of_args args with
    | Error mode_raw ->
      Keeper_tool_execution.failure
        ~class_:Tool_result.Policy_rejection
        (error_json (Keeper_tool_write_mode.rejection_message mode_raw))
    | Ok mode ->
      let confined_endpoint =
        match mode with
        | Keeper_tool_write_mode.Overwrite -> Keeper_alerting_path.Lexical_entry
        | Append | Patch -> Keeper_alerting_path.Follow_referent
      in
      (match
         resolve_keeper_confined_write_path ~config ~meta ~endpoint:confined_endpoint ~raw_path:path
       with
       | Error message -> Keeper_tool_execution.failure (error_json message)
       | Ok confined ->
         let target = Keeper_alerting_path.confined_host_path confined in
         if not (confined_is_keeper_playground ~config ~meta confined)
         then
           failure ~class_:Tool_result.Policy_rejection ~target
             (Printf.sprintf
                "remote lane writes stay inside the keeper playground; %s resolves under %s"
                target
                (Keeper_alerting_path.confined_root confined))
         else
           let keeper_root = Keeper_sandbox.host_root_abs_of_meta ~config meta in
           (match
              Keeper_remote_path.host_to_remote
                ~base_path:config.base_path
                ~remote_root:(Keeper_sandbox_remote.remote_root endpoint)
                ~keeper:meta.name
                target
            with
            | Error message -> failure ~class_:Tool_result.Policy_rejection ~target message
            | Ok remote_path ->
              let write ~content_mode ~mode_label ~body ~evidence =
                let status, _stdout, stderr =
                  run ~endpoint ~cwd:keeper_root
                    ~argv:(write_argv ~mode:content_mode ~remote_path)
                    ~stdin:body
                in
                match status with
                | Unix.WEXITED 0 ->
                  Log.Keeper.info
                    "WRITE_AUDIT: keeper=%s fs_edit path=%s mode=%s bytes=%d via=remote"
                    meta.name target mode_label (String.length body);
                  let execution =
                    Keeper_tool_execution.success
                      (success_payload ~target ~meta
                         [ "mode", `String mode_label
                         ; "bytes_written", `Int (String.length body)
                         ])
                  in
                  (match evidence with
                   | Some evidence -> Keeper_tool_execution.with_file_change_evidence evidence execution
                   | None -> execution)
                | status ->
                  failure ~class_:Tool_result.Runtime_failure ~target
                    (Printf.sprintf
                       "remote write failed (%s) on endpoint %s: %s"
                       (describe_status status)
                       (Keeper_sandbox_remote.name endpoint)
                       (Exec_policy.truncate_for_log stderr))
              in
              Keeper_external_resource_lease.with_lease
                (Keeper_external_resource_lease.File_path target)
                (fun () ->
                  match mode with
                  | Overwrite ->
                    write ~content_mode:Replace_whole ~mode_label:"overwrite" ~body:content
                      ~evidence:(Some (Keeper_file_change_evidence.written content))
                  | Append ->
                    write ~content_mode:Append_tail ~mode_label:"append" ~body:content
                      ~evidence:None
                  | Patch ->
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
                      let status, current, stderr =
                        run ~endpoint ~cwd:keeper_root ~argv:(read_source_argv ~remote_path) ~stdin:""
                      in
                      (match status with
                       | Unix.WEXITED 0 ->
                         (match
                            Keeper_tool_patch.apply_patch ~old_string ~new_string ~replace_all current
                          with
                          | Error message -> failure ~target message
                          | Ok application ->
                            write ~content_mode:Replace_whole ~mode_label:"patch"
                              ~body:application.updated
                              ~evidence:(Some (Keeper_tool_patch.file_change_evidence application)))
                       | Unix.WEXITED code when code = patch_source_missing_exit ->
                         failure ~class_:Tool_result.Workflow_rejection ~target
                           "patch target file does not exist. Use mode=overwrite to create it."
                       | status ->
                         failure ~class_:Tool_result.Runtime_failure ~target
                           (Printf.sprintf
                              "remote read of the patch source failed (%s) on endpoint %s: %s"
                              (describe_status status)
                              (Keeper_sandbox_remote.name endpoint)
                              (Exec_policy.truncate_for_log stderr))))))
;;

let handle ~turn_sandbox_factory ~(config : Workspace.config) ~(meta : keeper_meta) ~args =
  let cwd = Keeper_sandbox.host_root_abs_of_meta ~config meta in
  match Keeper_sandbox_remote_lane.endpoint ?turn_sandbox_factory ~config ~meta ~cwd () with
  | Error message ->
    Keeper_tool_execution.failure
      ~class_:Tool_result.Dependency_unavailable
      (error_json ~fields:[ "path", `String (Safe_ops.json_string ~default:"" "path" args) ] message)
  | Ok endpoint -> handle_with_endpoint ~endpoint ~config ~meta ~args
;;

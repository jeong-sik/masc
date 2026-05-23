open Keeper_types
open Keeper_exec_shared

let path_exists path =
  try Sys.file_exists path with
  | Sys_error _ -> false
;;

let docker_mount_preflight_details
      ~(config : Coord.config)
      ~(meta : keeper_meta)
      ~image
      ~container_kind
      ~network_label
      ~mount_path
      ~reason
  =
  `Assoc
    [ "event", `String "keeper_docker_mount_preflight_failure"
    ; "mount_path", `String mount_path
    ; "base_path_hash", `String (Keeper_sandbox_runtime.base_path_hash config.base_path)
    ; "keeper", `String meta.name
    ; "image", `String image
    ; "container_kind", `String container_kind
    ; "network", `String network_label
    ; "reason", `String reason
    ]
;;

let credential_preflight_failure_json ~keeper_name ~message =
  Yojson.Safe.to_string
    (`Assoc
       [ "ok", `Bool false
       ; "error", `String "keeper_github_credential_blocked"
       ; "failure_class", `String "workflow_rejection"
       ; "retryable", `Bool false
       ; "semantic_status", `String "blocked"
       ; "blocker", `String "keeper_github_credential"
       ; "keeper", `String keeper_name
       ; "detail", `String message
       ; ( "recovery_hint"
         , `String
             "The keeper GitHub credential bundle is unavailable or stale. \
              Re-materialize the selected bundle via dashboard or gh auth login \
              into that bundle before retrying git/gh through the visible Bash \
              or PR tools." )
       ])
;;

let is_credential_preflight_failure message =
  String_util.contains_substring message "Missing_bundle"
  || String_util.contains_substring message "Invalid_token"
;;


(* ── P12: Network egress policy ───────────────────────── *)

let egress_policy_path ~(config : Coord.config) ~(meta : keeper_meta) =
  let playground = Keeper_sandbox.host_root_abs_of_meta ~config meta in
  Filename.concat playground "egress.json"
;;

let check_egress ~(config : Coord.config) ~(meta : keeper_meta) ~cmd =
  let path = egress_policy_path ~config ~meta in
  let policy = Masc_exec.Egress_policy.of_file path in
  match Masc_exec.Egress_policy.check_command policy cmd with
  | Masc_exec.Egress_policy.Allowed -> None
  | Masc_exec.Egress_policy.Blocked _ as blocked ->
    Some (Masc_exec.Egress_policy.blocked_to_json ~expected_policy_path:path blocked)
;;


let ensure_docker_shell_image_available ~image ~timeout_sec =
  let argv = Keeper_sandbox_runtime.docker_command_argv () @ [ "image"; "inspect"; image ] in
  let status, output =
    Docker_spawn_throttle.with_slot (fun () ->
      Masc_exec.Exec_gate.run_argv_with_status
        ~actor:`System_task_sandbox
        ~raw_source:(String.concat " " argv)
        ~summary:"keeper docker image inspect"
        ~env:(Unix.environment ())
        ~cwd:(Sys.getcwd ())
        ~timeout_sec
        argv)
  in
  if status = Unix.WEXITED 0
  then Ok ()
  else
    Error
      (Printf.sprintf
         "docker_shell_failed: sandbox_image_missing: keeper sandbox image %s is not \
          available locally: %s. Next: Run scripts/build-keeper-sandbox-image.sh to \
          build the default keeper sandbox image, or set \
          MASC_KEEPER_SANDBOX_DOCKER_IMAGE to a locally available image."
         image
         (Exec_policy.truncate_for_log output))
;;


let path_is_directory path =
  try Sys.is_directory path with
  | Sys_error _ -> false
;;

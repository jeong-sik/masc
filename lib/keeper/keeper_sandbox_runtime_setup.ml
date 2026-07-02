(** See .mli for contract.

    Extracted from [Keeper_tool_command_runtime] (RFC-0006 Phase B-3b) so both
    [Keeper_tool_command_runtime] (bash sandbox) and [Keeper_sandbox_read_backend] (read
    sandbox) can preflight the host docker runtime against the
    configured hardening requirements without forming a module
    dependency cycle. *)

let docker_command () =
  match Sys.getenv_opt "MASC_TEST_FAKE_DOCKER_PATH" with
  | Some path when String.trim path <> "" -> path
  | _ ->
    let bin = "docker" in
    (match Sys.getenv_opt "PATH" with
     | None -> bin
     | Some path ->
       let rec loop = function
         | [] -> bin
         | dir :: rest ->
           let dir = if dir = "" then "." else dir in
           let candidate = Filename.concat dir bin in
           (try
              Unix.access candidate [ Unix.X_OK ];
              candidate
            with
            | Unix.Unix_error _ -> loop rest)
       in
       loop (String.split_on_char ':' path))
;;

let docker_command_argv () =
  match Sys.getenv_opt "MASC_TEST_FAKE_DOCKER_PATH" with
  | Some path when String.trim path <> "" -> [ "/bin/sh"; path ]
  | _ -> [ docker_command () ]
;;

let docker_run_pull_never_args () = [ "--pull"; "never" ]

let docker_image_missing_next_action =
  "Run scripts/build-keeper-sandbox-image.sh to build the default keeper sandbox image."
;;

let docker_command_cwd () = Config_dir_resolver.current_working_dir ()

(* RFC-0107 Phase E step 2 — branch on MASC_DOCKER_TRANSPORT env flag here.
   When set to "api", route through [Sandbox.Docker_api] (UDS HTTP) instead
   of forking a [docker] subprocess; the subprocess path stays as the
   transitional fallback. Default "subprocess" until step 2 lands. *)
let run_docker_argv_with_status ~summary ~timeout_sec argv =
  Docker_spawn_throttle.with_slot (fun () ->
    Masc_exec.Exec_gate.run_argv_with_status
      ~actor:`System_sandbox
      ~raw_source:(String.concat " " argv)
      ~summary
      ~env:(Env_keeper_scrub.filter_environment (Unix.environment ()))
      ~cwd:(docker_command_cwd ())
      ~timeout_sec
      argv)
;;

type classified_error =
  { message : string
  ; failure_class : string
  }

let process_status_is_timeout = Keeper_sandbox_runtime_classify.process_status_is_timeout
let lower_contains = Keeper_sandbox_runtime_classify.lower_contains
let output_looks_docker_daemon_unavailable =
  Keeper_sandbox_runtime_classify.output_looks_docker_daemon_unavailable
let output_looks_image_missing = Keeper_sandbox_runtime_classify.output_looks_image_missing
let output_looks_timeout = Keeper_sandbox_runtime_classify.output_looks_timeout
let docker_output_looks_oci_mount_failure =
  Keeper_sandbox_runtime_classify.docker_output_looks_oci_mount_failure
let classify_docker_runtime_failure =
  Keeper_sandbox_runtime_classify.classify_docker_runtime_failure
let classify_image_inspect_failure =
  Keeper_sandbox_runtime_classify.classify_image_inspect_failure
let classify_image_inventory_failure =
  Keeper_sandbox_runtime_classify.classify_image_inventory_failure

let docker_run_looks_daemon_pressure ~status ~output =
  match classify_docker_runtime_failure ~status ~output with
  | "docker_daemon_timeout" | "docker_daemon_unavailable" -> true
  | _ -> false

let docker_info_security_options_with_class ~timeout_sec =
  let argv =
    docker_command_argv () @ [ "info"; "--format"; "{{json .SecurityOptions}}" ]
  in
  let st, out =
    run_docker_argv_with_status
      ~summary:"keeper sandbox docker info"
      ~timeout_sec
      argv
  in
  if st <> Unix.WEXITED 0
  then
    Error
      { message =
          Printf.sprintf
            "docker info failed while validating sandbox runtime: %s"
            (Exec_policy.truncate_for_log out)
      ; failure_class = classify_docker_runtime_failure ~status:st ~output:out
      }
  else (
    try
      match Yojson.Safe.from_string (String.trim out) with
      | `List items ->
        Ok
          (List.filter_map (function `String s -> Some s | _ -> None) items
           |> List.map String.lowercase_ascii)
      | `Null -> Ok []
      | _ ->
        Error
          { message =
              "docker info returned unexpected SecurityOptions payload while validating \
               sandbox runtime"
          ; failure_class = "docker_info_format_error"
          }
    with
    | Yojson.Json_error err ->
      Error
        { message =
            Printf.sprintf "failed to parse docker info SecurityOptions JSON: %s" err
        ; failure_class = "docker_info_format_error"
        })
;;

let docker_info_security_options ~timeout_sec =
  match docker_info_security_options_with_class ~timeout_sec with
  | Ok security_options -> Ok security_options
  | Error classified -> Error classified.message
;;

type required_command_check =
  { command : string
  ; available : bool
  }

type docker_preflight =
  { ok : bool
  ; image : string
  ; docker_runtime_ok : bool
  ; docker_runtime_error : string option
  ; hardening_ok : bool
  ; hardening_error : string option
  ; image_present : bool
  ; image_error : string option
  ; failure_classes : string list
  ; required_commands : required_command_check list
  ; missing_commands : string list
  ; next_actions : string list
  }

(* P2c: literals lifted to Env_config_sandbox.Preflight (#10426 P2c).
   Today the SSOT getters return the same hardcoded values; future env
   wiring (per Env_config_sandbox.Preflight doc) tunes these without
   touching this file. *)
let docker_preflight_min_sec = Env_config_sandbox.Preflight.min_timeout_sec ()
let docker_preflight_max_sec = Env_config_sandbox.Preflight.max_timeout_sec ()

let docker_preflight_timeout ~timeout_sec =
  min docker_preflight_max_sec (max docker_preflight_min_sec timeout_sec)
;;

let required_commands =
  [ "sh"
  ; "bash"
  ; "cat"
  ; "find"
  ; "head"
  ; "tail"
  ; "wc"
  ; "git"
  ; "gh"
  ; "rg"
  ; "tree"
  ; "jq"
  ; "python3"
  ; "node"
  ; "npm"
  ; "make"
  ; "opam"
  ; "dune"
  ; "ssh"
  ]
;;

type cleanup_result =
  { scanned : int
  ; removed : int
  ; errors : string list
  }

let sandbox_component_label_key = "masc.mcp.component"
let sandbox_component_label_value = "keeper-sandbox"
let sandbox_base_path_hash_label_key = "masc.mcp.base_path_hash"
let sandbox_keeper_label_key = "masc.mcp.keeper"
let sandbox_kind_label_key = "masc.mcp.kind"
let sandbox_owner_pid_label_key = "masc.mcp.owner_pid"
let sandbox_started_at_label_key = "masc.mcp.started_at"
let sandbox_network_label_key = "masc.mcp.network"
let sandbox_ttl_sec_label_key = "masc.mcp.ttl_sec"
let sandbox_turn_id_label_key = "masc.mcp.turn_id"

let strip_trailing_slashes = Env_config_core.strip_trailing_slashes

let normalize_base_path_for_hash base_path =
  let abs =
    if Filename.is_relative base_path
    then Filename.concat (Config_dir_resolver.current_working_dir ()) base_path
    else base_path
  in
  strip_trailing_slashes abs
;;

let base_path_hash base_path =
  Digest.to_hex (Digest.string (normalize_base_path_for_hash base_path))
;;

let sanitize_label_value value =
  String.map
    (function
      | ('a' .. 'z' | 'A' .. 'Z' | '0' .. '9' | '_' | '-' | '.') as c -> c
      | _ -> '_')
    value
;;

include Keeper_sandbox_runtime_setup_mount_failure

let docker_label_args
      ?ttl_sec
      ?turn_id
      ~base_path
      ~keeper_name
      ~container_kind
      ~network_label
      ()
  =
  let label key value = [ "--label"; key ^ "=" ^ value ] in
  label sandbox_component_label_key sandbox_component_label_value
  @ label sandbox_base_path_hash_label_key (base_path_hash base_path)
  @ label sandbox_keeper_label_key (sanitize_label_value keeper_name)
  @ label sandbox_kind_label_key (sanitize_label_value container_kind)
  @ label sandbox_owner_pid_label_key (string_of_int (Unix.getpid ()))
  @ label sandbox_started_at_label_key (Printf.sprintf "%.3f" (Unix.gettimeofday ()))
  @ label sandbox_network_label_key (sanitize_label_value network_label)
  @ (match turn_id with
     | Some id -> label sandbox_turn_id_label_key (string_of_int id)
     | None -> [])
  @
  match ttl_sec with
  | Some value when value > 0.0 ->
    label sandbox_ttl_sec_label_key (Printf.sprintf "%.0f" value)
  | _ -> []
;;

let docker_network_args = function
  | Keeper_types_profile_sandbox.Network_none -> [ "--network"; "none" ], "none"
  | Keeper_types_profile_sandbox.Network_inherit ->
    (* Host network — matches the variant name and the docstring on
         [keeper_types_profile.ml:20-24]. Empty args
         (docker default) gives bridge mode (NAT, no host egress) which
         broke `git clone` / `gh push` for keepers running under this
         profile. See #10431. *)
    [ "--network"; "host" ], "inherit"
;;

let docker_nofile_args () =
  let limit = Env_config_sandbox.Hardening.nofile_limit () in
  [ "--ulimit"; Printf.sprintf "nofile=%d:%d" limit limit ]
;;

let container_masc_runtime_base ~container_root:_ = "/tmp/masc-runtime"

let container_masc_dir ~container_root =
  Filename.concat (container_masc_runtime_base ~container_root) Common.masc_dirname
;;

let container_masc_config_dir ~container_root =
  Filename.concat (container_masc_dir ~container_root) "config"
;;

let host_masc_config_dir ~base_path =
  Filename.concat (Common.masc_dir_from_base_path ~base_path) "config"
;;

let docker_masc_config_mount_spec ~base_path ~container_root =
  Printf.sprintf
    "%s:%s:ro"
    (host_masc_config_dir ~base_path)
    (container_masc_config_dir ~container_root)
;;

let docker_masc_config_mount_args ~base_path ~container_root =
  [ "-v"; docker_masc_config_mount_spec ~base_path ~container_root ]
;;

let docker_masc_runtime_env_pairs ~container_root =
  [ Env_config_core.base_path_env_key, container_masc_runtime_base ~container_root
  ; Env_config_core.config_dir_env_key, container_masc_config_dir ~container_root
  ]
;;

let docker_masc_runtime_env_args ~container_root =
  docker_masc_runtime_env_pairs ~container_root
  |> List.concat_map (fun (key, value) -> [ "--env"; key ^ "=" ^ value ])
;;

let docker_user_env_args () =
  [ "--env"
  ; "HOME=/tmp"
  ; "--env"
  ; "USER=keeper"
  ; "--env"
  ; "LOGNAME=keeper"
  ; "--env"
  ; "SHELL=/bin/sh"
  ]
;;

let trim_env_opt key =
  match Sys.getenv_opt key with
  | Some value ->
    let trimmed = String.trim value in
    if trimmed = "" then None else Some trimmed
  | None -> None
;;

let docker_config_host_root ~base_path =
  match trim_env_opt "MASC_CONFIG_DIR" with
  | Some config_root -> config_root
  | None -> Filename.concat (Common.masc_dir_from_base_path ~base_path) "config"
;;

let docker_config_container_root ~container_root =
  container_masc_config_dir ~container_root
;;

let docker_config_available host_config_root =
  try Sys.file_exists host_config_root && Sys.is_directory host_config_root with
  | Sys_error _ -> false
;;

let docker_config_mount_args ~base_path ~container_root =
  let host_config_root = docker_config_host_root ~base_path in
  if not (docker_config_available host_config_root)
  then []
  else
    [ "-v"
    ; host_config_root ^ ":" ^ docker_config_container_root ~container_root ^ ":ro"
    ]
;;

let host_gitconfig_path () =
  match Sys.getenv_opt "HOME" with
  | None -> ""
  | Some home -> Filename.concat home ".gitconfig"
;;

let container_gitconfig_path () = "/tmp/.gitconfig"

let docker_gitconfig_mount_args () =
  let host = host_gitconfig_path () in
  if host = ""
  then []
  else if not (Sys.file_exists host)
  then []
  else [ "-v"; host ^ ":" ^ container_gitconfig_path () ^ ":ro" ]
;;

type workspace_state_mount_kind =
  | Workspace_state_file
  | Workspace_state_dir

let docker_workspace_state_mounts =
  [ Workspace_state_dir, "tasks"
  ; Workspace_state_file, "tasks.json"
  ; Workspace_state_file, "backlog.json"
  ; Workspace_state_file, "board_posts.jsonl"
  ; Workspace_state_file, "board_comments.jsonl"
  ; Workspace_state_file, "board_votes.jsonl"
  ; Workspace_state_file, "board_reactions.jsonl"
  ; Workspace_state_file, "current_task"
  ; Workspace_state_file, "goals.json"
  ; Workspace_state_file, "goal_events.jsonl"
  ; Workspace_state_file, "goal_verifications.json"
  ]
;;

let workspace_state_path_available kind path =
  try
    match kind with
    | Workspace_state_file -> Sys.file_exists path && not (Sys.is_directory path)
    | Workspace_state_dir -> Sys.file_exists path && Sys.is_directory path
  with
  | Sys_error _ -> false
;;

let unique_preserving_order values =
  let rec loop seen acc = function
    | [] -> List.rev acc
    | value :: rest ->
      if List.mem value seen
      then loop seen acc rest
      else loop (value :: seen) (value :: acc) rest
  in
  loop [] [] values
;;

let docker_workspace_state_mount_specs ~base_path ~container_root =
  let host_masc_root = Common.masc_dir_from_base_path ~base_path in
  (* [container_root] is itself a bind-mounted playground. Mounting workspace-state
     files inside it creates nested bind targets that Docker Desktop can resolve
     through /run/host_virtiofs and reject as outside the container rootfs. *)
  let container_masc_root = container_masc_dir ~container_root in
  docker_workspace_state_mounts
  |> List.concat_map (fun (kind, rel_path) ->
    let host_path = Filename.concat host_masc_root rel_path in
    if not (workspace_state_path_available kind host_path)
    then []
    else
      [ Printf.sprintf "%s:%s:ro" host_path (Filename.concat container_masc_root rel_path)
      ])
  |> unique_preserving_order
;;

let docker_workspace_state_mount_args ~base_path ~container_root =
  docker_workspace_state_mount_specs ~base_path ~container_root
  |> List.concat_map (fun spec -> [ "-v"; spec ])
;;

let docker_config_env_args ~base_path ~container_root =
  let host_config_root = docker_config_host_root ~base_path in
  if not (docker_config_available host_config_root)
  then []
  else
    let container_config_root = docker_config_container_root ~container_root in
    let container_base_path = container_masc_runtime_base ~container_root in
    [ "--env"
    ; "MASC_BASE_PATH=" ^ container_base_path
    ; "--env"
    ; "MASC_BASE_PATH_INPUT=" ^ container_base_path
    ; "--env"
    ; "MASC_CONFIG_DIR=" ^ container_config_root
    ]
;;

let docker_sandbox_env_args ~base_path ~container_root =
  docker_user_env_args () @ docker_config_env_args ~base_path ~container_root
;;

let docker_identity_dir ~host_root = Filename.concat host_root ".docker-identity"

let docker_user_identity_mount_args ~host_root ~uid ~gid =
  let dir = docker_identity_dir ~host_root in
  let passwd_path = Filename.concat dir "passwd" in
  let group_path = Filename.concat dir "group" in
  let passwd =
    Printf.sprintf
      "root:x:0:0:root:/root:/bin/sh\nkeeper:x:%d:%d:MASC Keeper:/tmp:/bin/sh\n"
      uid
      gid
  in
  let group = Printf.sprintf "root:x:0:\nkeeper:x:%d:\n" gid in
  try
    Fs_compat.mkdir_p dir;
    match Fs_compat.save_file_atomic passwd_path passwd with
    | Error err -> Error (Printf.sprintf "failed to write docker passwd file: %s" err)
    | Ok () ->
      (match Fs_compat.save_file_atomic group_path group with
       | Error err -> Error (Printf.sprintf "failed to write docker group file: %s" err)
       | Ok () ->
         Ok [ "-v"; passwd_path ^ ":/etc/passwd:ro"; "-v"; group_path ^ ":/etc/group:ro" ])
  with
  | Sys_error err | Unix.Unix_error (_, _, err) ->
    Error (Printf.sprintf "failed to prepare docker user identity: %s" err)
;;

let is_path_boundary_after text idx =
  idx >= String.length text
  ||
  match text.[idx] with
  | '/' | '\'' | '"' | ' ' | '\t' | '\n' | '\r' | ';' | '&' | '|' | ')' | '(' | ':' ->
    true
  | _ -> false
;;

let rewrite_host_root_to_container_root ~host_root ~container_root text =
  let host_root = strip_trailing_slashes host_root in
  let container_root = strip_trailing_slashes container_root in
  let needle_len = String.length host_root in
  if needle_len = 0 || not (String_util.contains_substring text host_root)
  then text
  else (
    let text_len = String.length text in
    let buf = Buffer.create text_len in
    let rec loop i =
      if i >= text_len
      then ()
      else if
        i + needle_len <= text_len
        && String.sub text i needle_len = host_root
        && is_path_boundary_after text (i + needle_len)
      then (
        Buffer.add_string buf container_root;
        loop (i + needle_len))
      else (
        Buffer.add_char buf text.[i];
        loop (i + 1))
    in
    loop 0;
    Buffer.contents buf)
;;

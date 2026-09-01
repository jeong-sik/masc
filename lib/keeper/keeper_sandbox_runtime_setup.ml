(** See .mli for contract.

    Shared by [Keeper_tool_execute_runtime] and
    [Keeper_sandbox_read_backend] so both execution and read paths can
    preflight the host docker runtime against the
    configured hardening requirements without forming a module
    dependency cycle. *)


(* A test that forgets MASC_TEST_FAKE_DOCKER_PATH does not fail; it finds the
   operator's docker on PATH and speaks to the real daemon. On 2026-08-29 that
   left ten persistent containers behind, named for a base_path in /tmp whose
   owner pid was already gone -- outside every sweep's scope, because a
   persistent container surviving its owner is the normal state between server
   restarts, and no teardown owns a temp workspace nobody will open again.

   Same shape as the #9903 base-path guard: the unknown case here is "a test
   that did not say which docker it wants", and resolving that to the live one
   is the most expensive reading available. Refuse instead, and say what to
   set. *)
let fake_docker_configured () =
  Option.is_some (Env_config_core.fake_docker_path_opt ())
;;

let refuse_real_daemon_under_test ~what =
  if Env_config_core.running_under_test_executable ()
     && not (fake_docker_configured ())
  then (
    let allowed = Env_config_core.real_docker_allowed_under_test () in
    if not allowed
    then
      failwith
        (Printf.sprintf
           "test isolation breach: test executable %S tried to %s on the host \
            docker daemon without MASC_TEST_FAKE_DOCKER_PATH. A container it \
            starts is named for this test's temp base_path, which no sweep or \
            teardown owns -- a persistent container outliving its owner pid is \
            the normal state between server restarts, so nothing reclaims it \
            and it stays there. Point the test at a fake docker, or set %s=1 \
            to use the real daemon on purpose (not recommended)."
           (Filename.basename Sys.executable_name)
           what
           Env_config_core.test_allow_real_docker_env))
;;

let docker_command () =
  match Env_config_core.fake_docker_path_opt () with
  | Some path -> path
  | None ->
    let bin = "docker" in
    (match Sys.getenv_opt "PATH" with
     | None -> bin
     | Some path ->
       let rec loop = function
         | [] -> bin
         | dir :: rest when String.equal dir "" -> loop rest
         | dir :: rest ->
           let candidate = Filename.concat dir bin in
           (try
              Unix.access candidate [ Unix.X_OK ];
              candidate
            with
            | Unix.Unix_error _ -> loop rest)
       in
       loop (Executable_path.split_search_path path))
;;

let docker_command_argv () =
  match Env_config_core.fake_docker_path_opt () with
  | Some path -> [ "/bin/sh"; path ]
  | None -> [ docker_command () ]
;;

(* Removing a sandbox container also removes the anonymous volumes it owns.
   The sandbox image declares VOLUME ["/tmp/keeper-creds"], so Docker mints a
   fresh anonymous volume per container; a [docker rm] without [-v] leaves it
   behind unnamed and unreferenced. Orphans accumulate in the daemon metadata
   index until plain commands like [docker ps] time out -- 9,563 observed in
   production, then 4,795 again on 2026-09-01, because only one of the five
   removal sites carried the flag. [-v] lives in the argv so a removal site
   cannot omit it. *)
let docker_remove_argv container =
  docker_command_argv () @ [ "rm"; "-f"; "-v"; container ]
;;

let docker_run_pull_never_args () = [ "--pull"; "never" ]

let docker_image_inspect_next_action =
  "Inspect the configured Docker image and daemon using the exact command output above."
;;

let docker_command_cwd () = Config_dir_resolver.current_working_dir ()

(* RFC-0107 Phase E step 2 — branch on MASC_DOCKER_TRANSPORT env flag here.
   When set to "api", route through [Sandbox.Docker_api] (UDS HTTP) instead
   of forking a [docker] subprocess; the subprocess path stays as the
   transitional fallback. Default "subprocess" until step 2 lands. *)
let run_docker_argv_with_status ?timeout_sec argv =
  Fd_accountant.observe ~kind:Fd_accountant.Docker_spawn (fun () ->
    Process_eio.run_argv_with_status
      ~env:(Env_keeper_scrub.filter_environment (Unix.environment ()))
      ~cwd:(docker_command_cwd ())
      ?timeout_sec
      argv)
;;

type classified_error =
  { message : string
  ; failure_class : Keeper_sandbox_runtime_classify.docker_failure_class
  }

let process_status_is_timeout = Keeper_sandbox_runtime_classify.process_status_is_timeout
let classify_docker_info_failure = Keeper_sandbox_runtime_classify.classify_docker_info_failure
let classify_image_inspect_failure =
  Keeper_sandbox_runtime_classify.classify_image_inspect_failure
let docker_info_security_options_with_class_optional ?timeout_sec () =
  let argv =
    docker_command_argv () @ [ "info"; "--format"; "{{json .SecurityOptions}}" ]
  in
  let st, out =
    run_docker_argv_with_status
      ?timeout_sec
      argv
  in
  if st <> Unix.WEXITED 0
  then
    Error
      { message =
          Printf.sprintf
            "docker info failed while validating sandbox runtime: %s"
            (Exec_policy.truncate_for_log out)
      ; failure_class = classify_docker_info_failure ~status:st
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
          ; failure_class = Docker_info_format_error
          }
    with
    | Yojson.Json_error err ->
      Error
        { message =
            Printf.sprintf "failed to parse docker info SecurityOptions JSON: %s" err
        ; failure_class = Docker_info_format_error
        })
;;

let docker_info_security_options_with_class ~timeout_sec =
  docker_info_security_options_with_class_optional ~timeout_sec ()
;;

let docker_info_security_options_optional ?timeout_sec () =
  match docker_info_security_options_with_class_optional ?timeout_sec () with
  | Ok security_options -> Ok security_options
  | Error classified -> Error classified.message
;;

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
  ; next_actions : string list
  }

(* P2c: literals lifted to Env_config_sandbox.Preflight (#10426 P2c).
   Today the SSOT getters return the same hardcoded values; future env
   wiring (per Env_config_sandbox.Preflight doc) tunes these without
   touching this file. *)
type cleanup_result =
  { scanned : int
  ; removed : int
  ; already_absent : int
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

(* Values of the [masc.mcp.kind] label. A turn container lives for one turn and
   is torn down with it; a oneshot container lives for one command. A persistent
   container is keeper-lifetime: adopted across turns and server restarts, and
   removed only when the keeper itself is removed. *)
let turn_container_kind = "turn"
let persistent_container_kind = "persistent"

(* The pid is stamped on a container as [masc.mcp.owner_pid] and supplied again
   by any filter that selects those containers, so both sides must read it from
   one place. A second reader would diverge the moment the two ran in different
   processes, and would select nothing while looking like it had. *)

(* DET-OK: the boundary itself. Callers take the pid as an argument. *)
let current_owner_pid () = Unix.getpid ()

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
  @ label sandbox_owner_pid_label_key (string_of_int (current_owner_pid ()))
  @ label sandbox_started_at_label_key (Printf.sprintf "%.3f" (Unix.gettimeofday ()))
  @ label sandbox_network_label_key (sanitize_label_value network_label)
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
         (docker default) gives bridge mode rather than the requested host
         network namespace. *)
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

(* A sandbox has no terminal, so a git that wants to prompt must fail
   immediately instead of hanging the call. Which credentials git can use is
   not this module's knowledge: the identity snapshot carries its own
   credential-helper wiring, derived from the hosts it is logged into
   ([Keeper_github_identity.write_git_credential_config], task-847). *)
let docker_git_credential_env_args () =
  [ "--env"; "GIT_TERMINAL_PROMPT=0" ]
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

type workspace_state_mount_kind =
  | Workspace_state_file
  | Workspace_state_dir

(* Why a path is allowed inside a keeper container.

   This is provenance, not inspection. A content scan for secrets was tried
   first and it cannot do this job: a Slack bot token and a task id have the
   same shape ([xoxb-1234-5678-abc] against [sk-342-verify-...]), so a loose
   matcher reported twelve task ids from the live backlog and a matcher tightened
   to fix that stopped seeing Slack tokens at all. Neither length nor character
   class separates them, and a threshold tuned until today's data passes is a
   heuristic standing where a boundary belongs.

   What can be stated is where a file comes from. Every path below holds a store
   MASC itself writes, in a schema MASC owns. That is checkable by reading the
   writer, and it does not decay.

   The variants are the gate. [.masc] also holds [official-clients/], which is
   the provider CLI's private HOME carrying its OAuth token and login keychain,
   and [traces/], which writes authorization headers out verbatim. Neither is
   board, task or goal state, so neither can be added here without a new variant
   -- and a new variant is a design decision a reviewer sees, where one more line
   in a list of paths is not. *)
type mount_warrant =
  | Board_store
  | Task_store
  | Goal_store

let mount_warrant_to_string = function
  | Board_store -> "board_store"
  | Task_store -> "task_store"
  | Goal_store -> "goal_store"
;;

let docker_workspace_state_mounts =
  [ Task_store, Workspace_state_dir, "tasks"
  ; Task_store, Workspace_state_file, "tasks.json"
  ; Task_store, Workspace_state_file, "backlog.json"
  ; Task_store, Workspace_state_file, "current_task"
  ; Board_store, Workspace_state_file, "board_posts.jsonl"
  ; Board_store, Workspace_state_file, "board_comments.jsonl"
  ; Board_store, Workspace_state_file, "board_votes.jsonl"
  ; Board_store, Workspace_state_file, "board_reactions.jsonl"
  ; Goal_store, Workspace_state_file, "goals.json"
  ; Goal_store, Workspace_state_file, "goal_events.jsonl"
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
  (* Cluster-qualified on the host, default-cluster inside. The files below are
     the board, task and goal stores, and Board_paths resolves those through
     [masc_root_dir_from ~cluster_name] — so under a non-default
     MASC_CLUSTER_NAME the host copies live in .masc/clusters/<name>/ and a
     mount rooted at .masc/ carried a different set of files than the workspace
     was reading (#28953, same class as the vote_log_path repair in #28934).

     The container side stays unqualified on purpose: nothing passes
     MASC_CLUSTER_NAME into the container, so it resolves the default cluster,
     and the mount hands it the host's active cluster state at that path. *)
  let host_masc_root =
    Workspace_utils.masc_root_dir_from
      ~base_path
      ~cluster_name:(Env_config_core.cluster_name ())
  in
  (* [container_root] is itself a bind-mounted playground. Mounting workspace-state
     files inside it creates nested bind targets that Docker Desktop can resolve
     through /run/host_virtiofs and reject as outside the container rootfs. *)
  let container_masc_root = container_masc_dir ~container_root in
  docker_workspace_state_mounts
  |> List.concat_map (fun (_warrant, kind, rel_path) ->
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

(* The stores this container was actually given, named by warrant. A keeper that
   cannot reach a path can otherwise only report the failure; this says what it
   does have, and a trace of the turn carries the same answer. Projection, not
   authority -- the mounts above decide, this reports. *)
let docker_mounted_stores_env_args ~base_path ~container_root =
  let warranted =
    docker_workspace_state_mount_specs ~base_path ~container_root
    |> List.length
  in
  if warranted = 0
  then []
  else begin
    let names =
      docker_workspace_state_mounts
      |> List.map (fun (warrant, _kind, _rel) -> mount_warrant_to_string warrant)
      |> List.sort_uniq String.compare
      |> String.concat ","
    in
    [ "-e"; "MASC_KEEPER_MOUNTED_STORES=" ^ names ]
  end
;;

let docker_sandbox_env_args ~base_path ~container_root =
  docker_user_env_args ()
  @ docker_git_credential_env_args ()
  @ docker_config_env_args ~base_path ~container_root
  @ docker_mounted_stores_env_args ~base_path ~container_root
;;

(* Which env a keeper's exec carries, by lane. An env may name only what
   was mounted, and the two lanes are given different mounts: the microvm
   guest has config alone, so it takes the config env alone. It needs that
   one -- the config mount lands at the runtime base, outside the playground
   the guest works in, so nothing reaches it by walking up from the working
   directory. *)
let sandbox_exec_env_args ~microvm ~base_path ~container_root =
  if microvm
  then docker_config_env_args ~base_path ~container_root
  else docker_sandbox_env_args ~base_path ~container_root
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

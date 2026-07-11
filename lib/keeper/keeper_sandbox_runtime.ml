(** See .mli for contract.

    Extracted from [Keeper_tool_command_runtime] (RFC-0006 Phase B-3b) so both
    [Keeper_tool_command_runtime] (bash sandbox) and [Keeper_sandbox_read_backend] (read
    sandbox) can preflight the host docker runtime against the
    configured hardening requirements without forming a module
    dependency cycle. *)

(* Docker command infrastructure, error classification, preflight checks,
   label constants, mount/config helpers, identity mounts, and path
   rewriting — extracted to [Keeper_sandbox_runtime_setup]
   (godfile decomp). *)

include Keeper_sandbox_runtime_setup

type inspected_container =
  { owner_pid : int option
  ; started_at : float option
  ; running : bool option
  ; ttl_sec : float option
  }

type live_container =
  { id : string
  ; name : string
  ; image : string
  ; status : string
  ; running : bool option
  ; created_at : string option
  ; keeper_name : string option
  ; container_kind : string option
  ; network_label : string option
  ; owner_pid : int option
  ; started_at : float option
  ; ttl_sec : float option
  }

type stop_result =
  { matched : int
  ; removed : int
  ; errors : string list
  }

type cleanup_inspect_outcome =
  | Cleanup_inspected of inspected_container
  | Cleanup_inspect_already_absent

type cleanup_remove_outcome =
  | Cleanup_removed
  | Cleanup_remove_already_absent

(* #10488: previously used [String.trim] which strips ALL trailing
   whitespace including [\t]. Docker inspect templates emit tab-
   separated fields and a trailing-empty-field shows up as [...\t].
   [String.trim] silently dropped the trailing tab, collapsing 4
   tab-separated fields into 3 and breaking the exact-match parser
   below. Strip only the line-terminator [\r] so trailing-empty
   tab-separated fields survive. *)
let nonempty_lines out =
  out
  |> String.split_on_char '\n'
  |> List.map String_util.strip_trailing_cr
  |> List.filter (fun line -> line <> "")
;;

let int_opt text =
  try Some (int_of_string (String.trim text)) with
  | Failure _ -> None
;;

let float_opt text =
  try Some (float_of_string (String.trim text)) with
  | Failure _ -> None
;;

let bool_opt text =
  match String.lowercase_ascii (String.trim text) with
  | "true" -> Some true
  | "false" -> Some false
  | _ -> None
;;

let string_opt text =
  match String.trim text with
  | "" | "<no value>" -> None
  | value -> Some value
;;

let strip_leading_slash text =
  let text = String.trim text in
  if String.length text > 0 && text.[0] = '/'
  then String.sub text 1 (String.length text - 1)
  else text
;;

(* #10488: accept both 4-field (current schema, with [ttl_sec]
   label) and 3-field (legacy containers spawned before the
   [sandbox_ttl_sec] label was introduced) payloads.  Without this
   fallback, a single legacy container in the fleet produces a
   sustained 4.6%-of-events log spam loop because the 5-minute
   cleanup pass keeps re-attempting [parse_inspect_line] and
   keeps failing with [Error].  Treating [ttl_sec=None] is
   equivalent to "no TTL configured" — cleanup then falls back to
   the running-state / owner-pid heuristics, which is the correct
   semantics for a label-less container. *)
let parse_inspect_line line =
  (* docker inspect --format emits a trailing empty field as either
     ["<no value>"] (template default) or omits the trailing tab when the
     ttl_sec label is unset on the container.  Both 4-field (ttl_sec
     present) and 3-field (ttl_sec missing) shapes are valid; treat the
     missing case as [ttl_sec = None] instead of failing the cleanup
     pass with a parse error.  Without this fallback the 5-minute
     cleanup loop emits "errors=2" on every cycle for any container
     created without a ttl_sec label, which produced the 138 consecutive
     parse-error cycles observed on 2026-04-26. *)
  match String.split_on_char '\t' line with
  | [ owner_pid; started_at; running; ttl_sec ] ->
    Ok
      { owner_pid = int_opt owner_pid
      ; started_at = float_opt started_at
      ; running = bool_opt running
      ; ttl_sec = float_opt ttl_sec
      }
  | [ owner_pid; started_at; running ] ->
    Ok
      { owner_pid = int_opt owner_pid
      ; started_at = float_opt started_at
      ; running = bool_opt running
      ; ttl_sec = None
      }
  | _ ->
    Error
      (Printf.sprintf
         "unexpected docker inspect cleanup payload: %s"
         (Exec_policy.truncate_for_log line))
;;

let parse_live_container_line line =
  match String.split_on_char '\t' line with
  | [ id
    ; name
    ; image
    ; status
    ; running
    ; created_at
    ; keeper_name
    ; container_kind
    ; network_label
    ; owner_pid
    ; started_at
    ; ttl_sec
    ] ->
    Ok
      { id = String.trim id
      ; name = strip_leading_slash name
      ; image = String.trim image
      ; status = String.trim status
      ; running = bool_opt running
      ; created_at = string_opt created_at
      ; keeper_name = string_opt keeper_name
      ; container_kind = string_opt container_kind
      ; network_label = string_opt network_label
      ; owner_pid = int_opt owner_pid
      ; started_at = float_opt started_at
      ; ttl_sec = float_opt ttl_sec
      }
  | _ ->
    Error
      (Printf.sprintf
         "unexpected docker inspect container payload: %s"
         (Exec_policy.truncate_for_log line))
;;

let pid_alive pid =
  if pid <= 0
  then false
  else (
    try
      Unix.kill pid 0;
      true
    with
    | Unix.Unix_error (Unix.ESRCH, _, _) -> false
    | Unix.Unix_error (Unix.EPERM, _, _) -> true
    | Unix.Unix_error _ -> false)
;;

let should_remove_container ~now ~max_age_sec (inspected : inspected_container) =
  let stopped =
    match inspected.running with
    | Some false -> true
    | Some true | None -> false
  in
  let owner_dead =
    match inspected.owner_pid with
    | Some pid -> not (pid_alive pid)
    | None -> false
  in
  let age_limit =
    match inspected.ttl_sec with
    | Some ttl when ttl > 0.0 -> min max_age_sec ttl
    | _ -> max_age_sec
  in
  let expired =
    match inspected.started_at with
    | Some started_at -> now -. started_at > age_limit
    | None -> false
  in
  stopped || owner_dead || expired
;;

let inspect_cleanup_container ~container_id ~timeout_sec =
  let format =
    "{{ index .Config.Labels \""
    ^ sandbox_owner_pid_label_key
    ^ "\" }}\t{{ index .Config.Labels \""
    ^ sandbox_started_at_label_key
    ^ "\" }}\t{{ .State.Running }}\t{{ index .Config.Labels \""
    ^ sandbox_ttl_sec_label_key
    ^ "\" }}"
  in
  let argv = docker_command_argv () @ [ "inspect"; "--format"; format; container_id ] in
  let st, out =
    run_docker_argv_with_status
      ~summary:"keeper sandbox docker inspect cleanup"
      ~timeout_sec
      argv
  in
  if st <> Unix.WEXITED 0
  then (
    match Keeper_sandbox_runtime_classify.classify_container_reference_failure out with
    | Keeper_sandbox_runtime_classify.Container_absent ->
      Ok Cleanup_inspect_already_absent
    | Keeper_sandbox_runtime_classify.Container_not_running
    | Keeper_sandbox_runtime_classify.Container_reference_error ->
      Error
        (Printf.sprintf
           "docker inspect failed for cleanup container %s: %s"
           container_id
           (Exec_policy.truncate_for_log out)))
  else (
    match nonempty_lines out with
    | line :: _ ->
      Result.map (fun inspected -> Cleanup_inspected inspected) (parse_inspect_line line)
    | [] ->
      Error
        (Printf.sprintf
           "docker inspect returned no cleanup metadata for container %s"
           container_id))
;;

let remove_cleanup_container ~container_id ~timeout_sec =
  (* -v also removes the container's anonymous volumes. Without it the
     per-turn sandbox volumes accumulate in the docker daemon's metadata
     index (9563 volumes observed in production), starving even simple
     commands like `docker ps` until they time out. Keeper sandbox volumes
     are per-turn/ephemeral, so -v is safe here. *)
  let argv = docker_command_argv () @ [ "rm"; "-f"; "-v"; container_id ] in
  let st, out =
    run_docker_argv_with_status
      ~summary:"keeper sandbox docker rm -v cleanup"
      ~timeout_sec
      argv
  in
  if st = Unix.WEXITED 0
  then Ok Cleanup_removed
  else (
    match Keeper_sandbox_runtime_classify.classify_container_reference_failure out with
    | Keeper_sandbox_runtime_classify.Container_absent ->
      Ok Cleanup_remove_already_absent
    | Keeper_sandbox_runtime_classify.Container_not_running
    | Keeper_sandbox_runtime_classify.Container_reference_error ->
      Error
        (Printf.sprintf
           "docker rm -fv failed for cleanup container %s: %s"
           container_id
           (Exec_policy.truncate_for_log out)))
;;

let cleanup_stale_containers
      ?(now = Unix.gettimeofday ())
      ?(max_age_sec = Env_config_sandbox.Cleanup.stale_after_sec ())
      ~base_path
      ~timeout_sec
      ()
  =
  try
    let argv =
      docker_command_argv ()
      @ [ "ps"
        ; "-aq"
        ; "--filter"
        ; "label=" ^ sandbox_component_label_key ^ "=" ^ sandbox_component_label_value
        ; "--filter"
        ; "label=" ^ sandbox_base_path_hash_label_key ^ "=" ^ base_path_hash base_path
        ]
    in
    let st, out =
      run_docker_argv_with_status
        ~summary:"keeper sandbox docker ps cleanup"
        ~timeout_sec
        argv
    in
    if st <> Unix.WEXITED 0
    then
      { scanned = 0
      ; removed = 0
      ; already_absent = 0
      ; errors =
          [ Printf.sprintf
              "docker ps failed during keeper sandbox cleanup: %s"
              (Exec_policy.truncate_for_log out)
          ]
      }
    else (
      let container_ids = nonempty_lines out in
      let scanned = List.length container_ids in
      let removed, already_absent, errors =
        List.fold_left
          (fun (removed, already_absent, errors) container_id ->
             match inspect_cleanup_container ~container_id ~timeout_sec with
             | Error err -> removed, already_absent, err :: errors
             | Ok Cleanup_inspect_already_absent ->
               removed, already_absent + 1, errors
             | Ok (Cleanup_inspected inspected) ->
               if should_remove_container ~now ~max_age_sec inspected
               then (
                 match remove_cleanup_container ~container_id ~timeout_sec with
                 | Ok Cleanup_removed -> removed + 1, already_absent, errors
                 | Ok Cleanup_remove_already_absent ->
                   removed, already_absent + 1, errors
                 | Error err -> removed, already_absent, err :: errors)
               else removed, already_absent, errors)
          (0, 0, [])
          container_ids
      in
      { scanned; removed; already_absent; errors = List.rev errors })
  with
  | Eio.Cancel.Cancelled _ as exn -> raise exn
  | exn ->
    { scanned = 0
    ; removed = 0
    ; already_absent = 0
    ; errors =
        [ Printf.sprintf "keeper sandbox cleanup failed: %s" (Printexc.to_string exn) ]
    }
;;

let docker_filter_args ?keeper_name ?container_kind ~base_path () =
  let label_filter key value = [ "--filter"; "label=" ^ key ^ "=" ^ value ] in
  label_filter sandbox_component_label_key sandbox_component_label_value
  @ label_filter sandbox_base_path_hash_label_key (base_path_hash base_path)
  @ (match keeper_name with
     | Some name when String.trim name <> "" ->
       label_filter sandbox_keeper_label_key (sanitize_label_value name)
     | _ -> [])
  @
  match container_kind with
  | Some kind when String.trim kind <> "" ->
    label_filter sandbox_kind_label_key (sanitize_label_value kind)
  | _ -> []
;;

let list_container_ids ?keeper_name ?container_kind ~base_path ~timeout_sec () =
  try
    let argv =
      docker_command_argv ()
      @ [ "ps"; "-aq" ]
      @ docker_filter_args ?keeper_name ?container_kind ~base_path ()
    in
    let st, out =
      run_docker_argv_with_status
        ~summary:"keeper sandbox docker ps list"
        ~timeout_sec
        argv
    in
    if st = Unix.WEXITED 0
    then Ok (nonempty_lines out)
    else
      Error
        (Printf.sprintf
           "docker ps failed while listing keeper sandbox containers: %s"
           (Exec_policy.truncate_for_log out))
  with
  | Eio.Cancel.Cancelled _ as exn -> raise exn
  | exn ->
    Error
      (Printf.sprintf
         "keeper sandbox container listing failed: %s"
         (Printexc.to_string exn))
;;

let live_inspect_format =
  "{{ .Id }}\t{{ .Name }}\t{{ .Config.Image }}\t{{ .State.Status }}\t{{ .State.Running \
   }}\t{{ .Created }}\t{{ index .Config.Labels \""
  ^ sandbox_keeper_label_key
  ^ "\" }}\t{{ index .Config.Labels \""
  ^ sandbox_kind_label_key
  ^ "\" }}\t{{ index .Config.Labels \""
  ^ sandbox_network_label_key
  ^ "\" }}\t{{ index .Config.Labels \""
  ^ sandbox_owner_pid_label_key
  ^ "\" }}\t{{ index .Config.Labels \""
  ^ sandbox_started_at_label_key
  ^ "\" }}\t{{ index .Config.Labels \""
  ^ sandbox_ttl_sec_label_key
  ^ "\" }}"
;;

let list_containers ?keeper_name ?container_kind ~base_path ~timeout_sec () =
  match list_container_ids ?keeper_name ?container_kind ~base_path ~timeout_sec () with
  | Error _ as err -> err
  | Ok [] -> Ok []
  | Ok ids ->
    let argv =
      docker_command_argv () @ [ "inspect"; "--format"; live_inspect_format ] @ ids
    in
    let st, out =
      run_docker_argv_with_status
        ~summary:"keeper sandbox docker inspect live"
        ~timeout_sec
        argv
    in
    if st <> Unix.WEXITED 0
    then
      Error
        (Printf.sprintf
           "docker inspect failed while listing keeper sandbox containers: %s"
           (Exec_policy.truncate_for_log out))
    else (
      let parsed = nonempty_lines out |> List.map parse_live_container_line in
      let errors =
        parsed
        |> List.filter_map (function
          | Error err -> Some err
          | Ok _ -> None)
      in
      if errors <> []
      then Error (String.concat "; " errors)
      else
        Ok
          (parsed
           |> List.filter_map (function
             | Ok item -> Some item
             | Error _ -> None)))
;;

let option_string_field name = function
  | Some value -> name, `String value
  | None -> name, `Null
;;

let option_float_field name = function
  | Some value -> name, `Float value
  | None -> name, `Null
;;

let option_int_field name = function
  | Some value -> name, `Int value
  | None -> name, `Null
;;

let option_bool_field name = function
  | Some value -> name, `Bool value
  | None -> name, `Null
;;

let live_container_to_yojson (c : live_container) =
  `Assoc
    [ "id", `String c.id
    ; "name", `String c.name
    ; "image", `String c.image
    ; "status", `String c.status
    ; option_bool_field "running" c.running
    ; option_string_field "created_at" c.created_at
    ; option_string_field "keeper_name" c.keeper_name
    ; option_string_field "container_kind" c.container_kind
    ; option_string_field "network_label" c.network_label
    ; option_int_field "owner_pid" c.owner_pid
    ; option_float_field "started_at" c.started_at
    ; option_float_field "ttl_sec" c.ttl_sec
    ]
;;

let stop_containers ?keeper_name ?container_kind ~base_path ~timeout_sec () =
  match list_container_ids ?keeper_name ?container_kind ~base_path ~timeout_sec () with
  | Error err -> { matched = 0; removed = 0; errors = [ err ] }
  | Ok ids ->
    let removed, errors =
      List.fold_left
        (fun (removed, errors) container_id ->
           match remove_cleanup_container ~container_id ~timeout_sec with
           | Ok Cleanup_removed | Ok Cleanup_remove_already_absent ->
             removed + 1, errors
           | Error err -> removed, err :: errors)
        (0, [])
        ids
    in
    { matched = List.length ids; removed; errors = List.rev errors }
;;

(* [last_cleanup_at] gates concurrent cleanup sweeps. Previous implementation
   was [ref 0.0] with non-atomic check-then-write: under 64 concurrent turn
   starts, multiple fibers passed the [now -. !last_cleanup_at < interval]
   gate before any of them advanced the timestamp, fanning out N parallel
   [docker ps + inspect × N + rm × M] sweeps. Each sweep itself spawns docker
   subprocesses outside [Docker_spawn_throttle], so the duplication is what
   ENFILE storm scenarios amplify the hardest.
   [Atomic.t float] + [Atomic.compare_and_set] means exactly one fiber wins
   the gate per [interval] window; losers see [None] and skip silently. *)
let last_cleanup_at : float Atomic.t = Atomic.make 0.0
let cleanup_failure_backoff_until : float Atomic.t = Atomic.make 0.0
let cleanup_failure_backoff_sec = 1800.0

let reset_last_cleanup_for_tests () =
  Atomic.set last_cleanup_at 0.0;
  Atomic.set cleanup_failure_backoff_until 0.0

let maybe_cleanup_stale_containers ?(now = Unix.gettimeofday ()) ~base_path
    ~timeout_sec () =
  if not (Env_config_sandbox.Cleanup.enabled ())
  then None
  else (
    let backoff_until = Atomic.get cleanup_failure_backoff_until in
    if now < backoff_until
    then None
    else
    let interval = Env_config_sandbox.Cleanup.interval_sec () in
    let prev = Atomic.get last_cleanup_at in
    if now -. prev < interval
    then None
    else if Atomic.compare_and_set last_cleanup_at prev now
    then (
      let result = cleanup_stale_containers ~now ~base_path ~timeout_sec () in
      if result.errors <> [] then
        Atomic.set cleanup_failure_backoff_until
          (now +. cleanup_failure_backoff_sec);
      Some result)
    else None)
;;

let docker_image_present_with_class ~image ~timeout_sec =
  if String.trim image = ""
  then
    Error
      { message = "keeper sandbox docker image is not configured"
      ; failure_class = Image_config_missing
      }
  else (
    let argv = docker_command_argv () @ [ "image"; "inspect"; image ] in
    let st, out =
      run_docker_argv_with_status
        ~summary:"keeper sandbox docker image inspect"
        ~timeout_sec
        argv
    in
    if st = Unix.WEXITED 0
    then Ok ()
    else
      Error
        { message =
            Printf.sprintf
              "keeper sandbox image %s is not available locally: %s"
              image
              (Exec_policy.truncate_for_log out)
        ; failure_class = classify_image_inspect_failure ~status:st ~output:out
        })
;;

let docker_image_present ~image ~timeout_sec =
  match docker_image_present_with_class ~image ~timeout_sec with
  | Ok () -> Ok ()
  | Error classified -> Error classified.message
;;

let ensure_keeper_sandbox_image_present_with_class ~image ~timeout_sec =
  match docker_image_present_with_class ~image ~timeout_sec with
  | Ok () -> Ok ()
  | Error classified ->
    Error
      { classified with
        message =
          Printf.sprintf
            "%s. Next: %s"
            classified.message
            docker_image_missing_next_action
      }
;;

let ensure_keeper_sandbox_image_present ~image ~timeout_sec =
  match ensure_keeper_sandbox_image_present_with_class ~image ~timeout_sec with
  | Ok () -> Ok ()
  | Error classified -> Error classified.message
;;

let docker_image_preflight_error_code (failure : classified_error) =
  match failure.failure_class with
  | Image_missing -> "image_not_found"
  | failure_class -> Keeper_sandbox_runtime_classify.docker_failure_class_to_string failure_class
;;

let docker_image_preflight_failure_message ~prefix failure =
  Printf.sprintf
    "%s: %s: %s"
    prefix
    (docker_image_preflight_error_code failure)
    failure.message
;;

let docker_image_required_commands_with_class ~image ~timeout_sec =
  let script =
    let quoted = List.map Filename.quote required_commands |> String.concat " " in
    Printf.sprintf
      "missing=''; for cmd in %s; do if ! command -v \"$cmd\" >/dev/null 2>&1; then \
       missing=\"$missing$cmd\\n\"; fi; done; printf '%%s' \"$missing\""
      quoted
  in
  let argv =
    docker_command_argv ()
    @ [ "run"; "--rm" ]
    @ docker_run_pull_never_args ()
    @ [ "--network"; "none"; "--entrypoint"; "sh"; image; "-lc"; script ]
  in
  let st, out =
    run_docker_argv_with_status
      ~summary:"keeper sandbox docker run required commands"
      ~timeout_sec
      argv
  in
  if st = Unix.WEXITED 0
  then (
    let missing =
      out
      |> String.split_on_char '\n'
      |> List.map String.trim
      |> List.filter (fun item -> item <> "")
    in
    Ok missing)
  else
    Error
      { message =
          Printf.sprintf
            "failed to inspect keeper sandbox image commands: %s"
            (Exec_policy.truncate_for_log out)
      ; failure_class = classify_image_inventory_failure ~status:st ~output:out
      }
;;

let docker_image_required_commands ~image ~timeout_sec =
  match docker_image_required_commands_with_class ~image ~timeout_sec with
  | Ok missing_commands -> Ok missing_commands
  | Error classified -> Error classified.message
;;

let docker_preflight_to_yojson (preflight : docker_preflight) =
  `Assoc
    [ "backend", `String "docker"
    ; "status", `String (if preflight.ok then "ok" else "error")
    ; "ok", `Bool preflight.ok
    ; "image", `String preflight.image
    ; "docker_runtime_ok", `Bool preflight.docker_runtime_ok
    ; Json_util.string_opt_field "docker_runtime_error" preflight.docker_runtime_error
    ; "hardening_ok", `Bool preflight.hardening_ok
    ; Json_util.string_opt_field "hardening_error" preflight.hardening_error
    ; "image_present", `Bool preflight.image_present
    ; Json_util.string_opt_field "image_error" preflight.image_error
    ; ( "failure_classes"
      , `List
          (List.map
             (fun failure_class -> `String failure_class)
             preflight.failure_classes) )
    ; ( "required_commands"
      , `List
          (List.map
             (fun item ->
                `Assoc
                  [ "command", `String item.command; "available", `Bool item.available ])
             preflight.required_commands) )
    ; ( "missing_commands"
      , `List (List.map (fun command -> `String command) preflight.missing_commands) )
    ; ( "next_actions"
      , `List (List.map (fun action -> `String action) preflight.next_actions) )
    ]
;;

let docker_preflight_failure_message (preflight : docker_preflight) =
  let reasons =
    [ preflight.docker_runtime_error
    ; preflight.hardening_error
    ; preflight.image_error
    ; (if preflight.missing_commands = []
       then None
       else
         Some
           (Printf.sprintf
              "keeper sandbox image is missing required commands: %s"
              (String.concat ", " preflight.missing_commands)))
    ]
    |> List.filter_map (fun item -> item)
    |> List.filter (fun s -> s <> "")
    |> Json_util.dedupe_keep_order
  in
  let next_actions =
    match preflight.next_actions with
    | [] -> ""
    | actions -> " Next: " ^ String.concat " " actions
  in
  Printf.sprintf
    "Docker sandbox preflight failed: %s.%s"
    (String.concat "; " reasons)
    next_actions
;;

let ensure_keeper_sandbox_runtime ~timeout_sec =
  let seccomp_profile =
    String.trim (Env_config_sandbox.Hardening.seccomp_profile ())
  in
  let require_rootless = Env_config_sandbox.Hardening.require_rootless () in
  let require_userns = Env_config_sandbox.Hardening.require_userns () in
  let seccomp_args =
    if seccomp_profile = ""
    then Ok []
    else if Sys.file_exists seccomp_profile
    then Ok [ "--security-opt"; "seccomp=" ^ seccomp_profile ]
    else Error (Printf.sprintf "sandbox seccomp profile not found: %s" seccomp_profile)
  in
  match seccomp_args with
  | Error _ as err -> err
  | Ok seccomp_args ->
    if (not require_rootless) && not require_userns
    then Ok seccomp_args
    else (
      match
        docker_info_security_options ~timeout_sec:(docker_preflight_timeout ~timeout_sec)
      with
      | Error _ as err -> err
      | Ok security_options ->
        let has needle =
          List.exists
            (fun option_text -> String_util.contains_substring option_text needle)
            security_options
        in
        if require_rootless && not (has "rootless")
        then
          Error
            "sandbox runtime requires Docker rootless mode (set \
             MASC_KEEPER_SANDBOX_REQUIRE_ROOTLESS=false to disable this check)"
        else if require_userns && not (has "userns")
        then
          Error
            "sandbox runtime requires Docker userns support (set \
             MASC_KEEPER_SANDBOX_REQUIRE_USERNS=false to disable this check)"
        else Ok seccomp_args)
;;

let docker_preflight ~timeout_sec () =
  if not (Env_config_sandbox.Preflight.enabled ())
  then None
  else (
    let timeout_sec = docker_preflight_timeout ~timeout_sec in
    let image = Env_config_sandbox.Runtime.docker_image () in
    let docker_runtime_ok, docker_runtime_error, docker_runtime_failure_class =
      match docker_info_security_options_with_class ~timeout_sec with
      | Ok _ -> true, None, None
      | Error classified ->
        false, Some classified.message, Some classified.failure_class
    in
    let hardening_ok, hardening_error =
      match ensure_keeper_sandbox_runtime ~timeout_sec with
      | Ok _ -> true, None
      | Error message -> false, Some message
    in
    let image_present, image_error, image_failure_class =
      match docker_image_present_with_class ~image ~timeout_sec with
      | Ok () -> true, None, None
      | Error classified ->
        false, Some classified.message, Some classified.failure_class
    in
    let missing_commands, command_error, command_failure_class =
      if not image_present
      then [], None, None
      else (
        match docker_image_required_commands_with_class ~image ~timeout_sec with
        | Ok missing -> missing, None, None
        | Error classified ->
          [], Some classified.message, Some classified.failure_class)
    in
    let required_commands =
      List.map
        (fun command -> { command; available = not (List.mem command missing_commands) })
        required_commands
    in
    let next_actions =
      [ (if not docker_runtime_ok
         then
           Some "Ensure Docker is installed and the daemon is reachable from this shell."
         else None)
      ; (if (not image_present) || missing_commands <> []
         then Some docker_image_missing_next_action
         else None)
      ; (if not hardening_ok
         then
           Some
             "Fix the keeper sandbox hardening configuration \
              (seccomp/rootless/userns) and rerun sandbox diagnostics."
         else None)
      ]
      |> List.filter_map (fun action -> action)
      |> List.filter (fun s -> s <> "")
      |> Json_util.dedupe_keep_order
    in
    let image_error =
      match image_error, command_error with
      | Some message, None -> Some message
      | None, Some message -> Some message
      | Some message, Some _ -> Some message
      | None, None -> None
    in
    let failure_classes =
      [ docker_runtime_failure_class
      ; image_failure_class
      ; command_failure_class
      ; (if hardening_ok then None else Some Docker_hardening_error)
      ; (if missing_commands = [] then None else Some Image_required_command_missing)
      ]
      |> List.filter_map (fun item -> item)
      |> List.map Keeper_sandbox_runtime_classify.docker_failure_class_to_string
      |> List.filter (fun s -> s <> "")
      |> Json_util.dedupe_keep_order
    in
    Some
      { ok =
          docker_runtime_ok
          && hardening_ok
          && image_present
          && command_error = None
          && missing_commands = []
      ; image
      ; docker_runtime_ok
      ; docker_runtime_error
      ; hardening_ok
      ; hardening_error
      ; image_present
      ; image_error
      ; failure_classes
      ; required_commands
      ; missing_commands
      ; next_actions
      })
;;

(* Preflight result cache. POST /api/v1/keepers/<name>/boot was hitting
   the 12s HTTP timeout because every boot re-ran [ensure_keeper_sandbox_runtime]
   plus [ensure_keeper_sandbox_image_present] inline — docker daemon ping
   + image presence probe. Docker daemon state and the resolved image
   presence change on minute scale, so caching the Ok result for 10s
   collapses bursts (cluster start, dashboard "boot" button retries) into
   one probe.

   Errors are NOT cached: surface immediately and re-probe on the next
   call so an operator fixing docker between boot attempts sees the new
   state without waiting for cache expiry. *)
let preflight_cache_ttl = 10.0

let preflight_cache_result : (float * (unit, string) result) Atomic.t =
  Atomic.make (0.0, Ok ())

let preflight_cache_lookup ~now =
  let ts, result = Atomic.get preflight_cache_result in
  if ts > 0.0 && now -. ts < preflight_cache_ttl
  then Some result
  else None
;;

let ensure_keeper_startup_preflight ~timeout_sec ~sandbox_profile =
  match sandbox_profile with
  | Keeper_types_profile_sandbox.Local -> Ok ()
  | Keeper_types_profile_sandbox.Docker ->
    if not (Env_config_sandbox.Preflight.enabled ())
    then Ok ()
    else (
      let now = Unix.gettimeofday () in
      match preflight_cache_lookup ~now with
      | Some cached -> cached
      | None ->
        let timeout_sec = docker_preflight_timeout ~timeout_sec in
        let image = Env_config_sandbox.Runtime.docker_image () in
        let result =
          match ensure_keeper_sandbox_runtime ~timeout_sec with
          | Error message ->
            Error
              (Printf.sprintf "Docker sandbox startup preflight failed: %s" message)
          | Ok _ ->
            (match ensure_keeper_sandbox_image_present ~image ~timeout_sec with
             | Ok () -> Ok ()
             | Error message ->
               Error
                 (Printf.sprintf
                    "Docker sandbox startup preflight failed: %s"
                    message))
        in
        (match result with
         | Ok () -> Atomic.set preflight_cache_result (now, result)
         | Error _ -> ());
        result)
;;

module For_testing = struct
  let nonempty_lines = nonempty_lines

  (* Project the internal [inspected_container] record onto a tuple so
     the test does not need a re-exported type. Order:
     (owner_pid, started_at, running, ttl_sec). *)
  let parse_inspect_line line =
    parse_inspect_line line
    |> Result.map (fun (ic : inspected_container) ->
      ic.owner_pid, ic.started_at, ic.running, ic.ttl_sec)
  ;;
end

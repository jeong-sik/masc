(** See .mli for contract.

    Shared by [Keeper_tool_execute_runtime] and
    [Keeper_sandbox_read_backend] so both execution and read paths can
    preflight the host docker runtime against the
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
  ; container_kind : string option
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
  ; cpus : int option
  ; memory_bytes : int option
  ; hostname : string option
  ; ipv4_address : string option
  ; ipv6_address : string option
  ; gateway : string option
  }

type cleanup_remove_outcome =
  | Cleanup_removed
  | Cleanup_remove_already_absent

type cleanup_container_presence =
  | Cleanup_container_present
  | Cleanup_container_absent

type stop_result =
  { matched : int
  ; removed : int
  ; errors : string list
  }

type docker_container_state =
  | Docker_container_running
  | Docker_container_stopped
  | Docker_container_absent

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

let invalid_cleanup_field ~field ~value =
  Error
    (Printf.sprintf
       "invalid docker inspect cleanup field %s=%S"
       field
       (Exec_policy.truncate_for_log value))
;;

let required_positive_int ~field text =
  match int_opt text with
  | Some value when value > 0 -> Ok (Some value)
  | None | Some _ -> invalid_cleanup_field ~field ~value:text
;;

let required_positive_float ~field text =
  match float_opt text with
  | Some value when Float.is_finite value && value > 0.0 -> Ok (Some value)
  | None | Some _ -> invalid_cleanup_field ~field ~value:text
;;

let required_bool ~field text =
  match bool_opt text with
  | Some value -> Ok (Some value)
  | None -> invalid_cleanup_field ~field ~value:text
;;

let optional_positive_float ~field text =
  match string_opt text with
  | None -> Ok None
  | Some value -> required_positive_float ~field value
;;

let strip_leading_slash text =
  let text = String.trim text in
  if String.length text > 0 && text.[0] = '/'
  then String.sub text 1 (String.length text - 1)
  else text
;;

let parse_inspect_line line =
  (* docker inspect --format emits a trailing empty field as either
     ["<no value>"] or an empty final field when a label is unset.
     [nonempty_lines] preserves that trailing tab, so every current
     cleanup payload has exactly five fields. *)
  match String.split_on_char '\t' line with
  | [ owner_pid; started_at; running; ttl_sec; container_kind ] ->
    let ( let* ) = Result.bind in
    let* owner_pid = required_positive_int ~field:"owner_pid" owner_pid in
    let* started_at = required_positive_float ~field:"started_at" started_at in
    let* running = required_bool ~field:"running" running in
    let* ttl_sec = optional_positive_float ~field:"ttl_sec" ttl_sec in
    Ok
      { owner_pid
      ; started_at
      ; running
      ; ttl_sec
      ; container_kind = string_opt container_kind
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
      ; cpus = None
      ; memory_bytes = None
      ; hostname = None
      ; ipv4_address = None
      ; ipv6_address = None
      ; gateway = None
      }
  | _ ->
    Error
      (Printf.sprintf
         "unexpected docker inspect container payload: %s"
         (Exec_policy.truncate_for_log line))
;;

let parse_json_container_name line =
  match Yojson.Safe.from_string line with
  | `String name -> Ok name
  | payload ->
    Error
      (Printf.sprintf
         "unexpected docker container-name inventory payload: %s"
         (Yojson.Safe.to_string payload))
  | exception Yojson.Json_error detail ->
    Error
      (Printf.sprintf
         "invalid docker container-name inventory payload: %s"
         detail)
;;

let probe_container_name_presence ~container_name ?timeout_sec () =
  let argv =
    docker_command_argv ()
    @ [ "ps"
      ; "-a"
      ; "--no-trunc"
      ; "--filter"
      ; "name=" ^ container_name
      ; "--format"
      ; "{{json .Names}}"
      ]
  in
  let st, out =
    run_docker_argv_with_status
      ?timeout_sec
      argv
  in
  if st <> Unix.WEXITED 0
  then
    Error
      (Printf.sprintf
         "docker container-name presence probe failed for %s: %s"
         container_name
         (Exec_policy.truncate_for_log out))
  else
    let rec parse_names = function
      | [] -> Ok false
      | line :: rest ->
        (match parse_json_container_name line with
         | Ok name when String.equal name container_name -> Ok true
         | Ok _ -> parse_names rest
         | Error _ as error -> error)
    in
    parse_names (nonempty_lines out)
;;

let probe_container_state_optional ~container_name ?timeout_sec () =
  let argv =
    docker_command_argv ()
    @ [ "inspect"; "--format"; "{{json .State.Running}}"; container_name ]
  in
  let st, out =
    run_docker_argv_with_status
      ?timeout_sec
      argv
  in
  if st = Unix.WEXITED 0
  then (
    match nonempty_lines out with
    | [ line ] ->
      (match Yojson.Safe.from_string line with
       | `Bool true -> Ok Docker_container_running
       | `Bool false -> Ok Docker_container_stopped
       | payload ->
         Error
           (Printf.sprintf
              "unexpected docker container state payload for %s: %s"
              container_name
              (Yojson.Safe.to_string payload))
       | exception Yojson.Json_error detail ->
         Error
           (Printf.sprintf
              "invalid docker container state payload for %s: %s"
              container_name
              detail))
    | lines ->
      Error
        (Printf.sprintf
           "docker container state probe for %s returned %d payloads"
           container_name
           (List.length lines)))
  else
    let inspect_failure =
      Printf.sprintf
        "docker inspect state probe failed for %s: %s"
        container_name
        (Exec_policy.truncate_for_log out)
    in
    match probe_container_name_presence ~container_name ?timeout_sec () with
    | Ok false -> Ok Docker_container_absent
    | Ok true -> Error inspect_failure
    | Error inventory_failure ->
      Error (inspect_failure ^ "; " ^ inventory_failure)
;;

let probe_container_state ~container_name ~timeout_sec =
  probe_container_state_optional ~container_name ~timeout_sec ()
;;

let docker_filter_args ?keeper_name ?container_kind ?owner_pid ~base_path () =
  let label_filter key value = [ "--filter"; "label=" ^ key ^ "=" ^ value ] in
  label_filter sandbox_component_label_key sandbox_component_label_value
  @ label_filter sandbox_base_path_hash_label_key (base_path_hash base_path)
  @ (match keeper_name with
     | Some name when String.trim name <> "" ->
       label_filter sandbox_keeper_label_key (sanitize_label_value name)
     | _ -> [])
  @ (match container_kind with
     | Some kind when String.trim kind <> "" ->
       label_filter sandbox_kind_label_key (sanitize_label_value kind)
     | _ -> [])
  @ (match owner_pid with
     | Some pid -> label_filter sandbox_owner_pid_label_key (string_of_int pid)
     | None -> [])
;;

let list_container_ids
      ?keeper_name ?container_kind ?owner_pid ~base_path ~timeout_sec ()
  =
  try
    let argv =
      docker_command_argv ()
      @ [ "ps"; "-aq"; "--no-trunc" ]
      @ docker_filter_args ?keeper_name ?container_kind ?owner_pid ~base_path ()
    in
    let st, out =
      run_docker_argv_with_status
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

let probe_cleanup_container_presence ~container_id ~timeout_sec =
  (* Docker CLI stderr is human-readable and not a stable control protocol.
     Re-read the machine-oriented ID inventory after a failed inspect/remove;
     exact ID absence proves the cleanup race without matching error prose. *)
  let argv =
    docker_command_argv ()
    @ [ "ps"; "-aq"; "--no-trunc"; "--filter"; "id=" ^ container_id ]
  in
  let st, out =
    run_docker_argv_with_status
      ~timeout_sec
      argv
  in
  if st <> Unix.WEXITED 0
  then
    Error
      (Printf.sprintf
         "docker container presence probe failed for %s: %s"
         container_id
         (Exec_policy.truncate_for_log out))
  else if List.exists (String.equal container_id) (nonempty_lines out)
  then Ok Cleanup_container_present
  else Ok Cleanup_container_absent
;;

let cleanup_failure_or_absent
      ~container_id
      ~timeout_sec
      ~failure
      ~already_absent
  =
  match probe_cleanup_container_presence ~container_id ~timeout_sec with
  | Ok Cleanup_container_absent -> Ok already_absent
  | Ok Cleanup_container_present -> Error failure
  | Error probe_error -> Error (failure ^ "; " ^ probe_error)
;;

let remove_cleanup_container ~container_id ~timeout_sec =
  let argv = docker_remove_argv container_id in
  let st, out =
    run_docker_argv_with_status
      ~timeout_sec
      argv
  in
  if st = Unix.WEXITED 0
  then Ok Cleanup_removed
  else
    cleanup_failure_or_absent
      ~container_id
      ~timeout_sec
      ~failure:
        (Printf.sprintf
           "docker rm -fv failed for cleanup container %s: %s"
           container_id
           (Exec_policy.truncate_for_log out))
      ~already_absent:Cleanup_remove_already_absent
;;

(* The keeper-lifetime Docker containers of one keeper, removed at shutdown
   finalization -- the only point that knows the keeper is gone for good
   rather than between turns. Listed by label rather than by name: the
   network mode is part of the container name, and a container wired to a
   network config the keeper no longer uses must go with the keeper all the
   same. *)
let remove_persistent_containers ~keeper_name ~base_path ~timeout_sec () =
  match
    list_container_ids
      ~keeper_name
      ~container_kind:persistent_container_kind
      ~base_path
      ~timeout_sec
      ()
  with
  | Error _ as err -> err
  | Ok [] -> Ok ()
  | Ok ids ->
    let errors =
      List.filter_map
        (fun container_id ->
           match remove_cleanup_container ~container_id ~timeout_sec with
           | Ok Cleanup_removed | Ok Cleanup_remove_already_absent -> None
           | Error err -> Some err)
        ids
    in
    (match errors with
     | [] -> Ok ()
     | errors -> Error (String.concat "; " errors))
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
    ; option_int_field "cpus" c.cpus
    ; option_int_field "memory_bytes" c.memory_bytes
    ; option_string_field "hostname" c.hostname
    ; option_string_field "ipv4_address" c.ipv4_address
    ; option_string_field "ipv6_address" c.ipv6_address
    ; option_string_field "gateway" c.gateway
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
   [docker ps + inspect × N + rm × M] sweeps. The atomic timestamp prevents
   duplicate cleanup work while Docker spawn accounting remains observation-only.
   [Atomic.t float] + [Atomic.compare_and_set] means exactly one fiber wins
   the gate per [interval] window; losers see [None] and skip silently. *)
let docker_image_present_with_class_optional ~image ?timeout_sec () =
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
        ?timeout_sec
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
        ; failure_class = classify_image_inspect_failure ~status:st
        })
;;

let docker_image_present_with_class ~image ~timeout_sec =
  docker_image_present_with_class_optional ~image ~timeout_sec ()
;;

let docker_image_present_optional ~image ?timeout_sec () =
  match docker_image_present_with_class_optional ~image ?timeout_sec () with
  | Ok () -> Ok ()
  | Error classified -> Error classified.message
;;

let docker_image_present ~image ~timeout_sec =
  docker_image_present_optional ~image ~timeout_sec ()
;;

let ensure_keeper_sandbox_image_present_with_class_optional
      ~image
      ?timeout_sec
      ()
  =
  match docker_image_present_with_class_optional ~image ?timeout_sec () with
  | Ok () -> Ok ()
  | Error classified ->
    Error
      { classified with
        message =
          Printf.sprintf
            "%s. Next: %s"
            classified.message
            docker_image_inspect_next_action
      }
;;

let ensure_keeper_sandbox_image_present_with_class ~image ~timeout_sec =
  ensure_keeper_sandbox_image_present_with_class_optional
    ~image ~timeout_sec ()
;;

let ensure_keeper_sandbox_image_present_optional ~image ?timeout_sec () =
  match
    ensure_keeper_sandbox_image_present_with_class_optional
      ~image ?timeout_sec ()
  with
  | Ok () -> Ok ()
  | Error classified -> Error classified.message
;;

let ensure_keeper_sandbox_image_present ~image ~timeout_sec =
  ensure_keeper_sandbox_image_present_optional ~image ~timeout_sec ()
;;

let docker_image_preflight_error_code (failure : classified_error) =
  Keeper_sandbox_runtime_classify.docker_failure_class_to_string failure.failure_class
;;

let docker_image_preflight_failure_message ~prefix failure =
  Printf.sprintf
    "%s: %s: %s"
    prefix
    (docker_image_preflight_error_code failure)
    failure.message
;;

let image_preflight_start_error (failure : classified_error) =
  docker_image_preflight_failure_message
    ~prefix:"docker_container_start_failed"
    failure
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
    ; ( "next_actions"
      , `List (List.map (fun action -> `String action) preflight.next_actions) )
    ]
;;

let ensure_keeper_sandbox_runtime_optional ?timeout_sec () =
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
        docker_info_security_options_optional ?timeout_sec ()
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

let ensure_keeper_sandbox_runtime ~timeout_sec =
  ensure_keeper_sandbox_runtime_optional ~timeout_sec ()
;;

let docker_preflight ~timeout_sec () =
  if not (Env_config_sandbox.Preflight.enabled ())
  then None
  else (
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
    let next_actions =
      [ (if not docker_runtime_ok
         then
           Some "Ensure Docker is installed and the daemon is reachable from this shell."
         else None)
      ; (if not image_present
         then Some docker_image_inspect_next_action
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
    let failure_classes =
      [ docker_runtime_failure_class
      ; image_failure_class
      ; (if hardening_ok then None else Some Docker_hardening_error)
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
      ; image
      ; docker_runtime_ok
      ; docker_runtime_error
      ; hardening_ok
      ; hardening_error
      ; image_present
      ; image_error
      ; failure_classes
      ; next_actions
      })
;;

module For_testing = struct
  let nonempty_lines = nonempty_lines

  (* Project the internal [inspected_container] record onto a tuple so
     the test does not need a re-exported type. Order:
     (owner_pid, started_at, running, ttl_sec, container_kind). *)
  let parse_inspect_line line =
    parse_inspect_line line
    |> Result.map (fun (ic : inspected_container) ->
      ic.owner_pid, ic.started_at, ic.running, ic.ttl_sec, ic.container_kind)
  ;;
end

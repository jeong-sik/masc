type kind =
  | Docker_spawn
  | Provider_http
  | Provider_cli
  | Sandbox_exec
  | Log_writer

type resource_error =
  | Process_fd_exhausted
  | System_fd_exhausted
  | Storage_space_exhausted

let all_kinds = [ Docker_spawn; Provider_http; Provider_cli; Sandbox_exec; Log_writer ]

let all_resource_errors =
  [ Process_fd_exhausted; System_fd_exhausted; Storage_space_exhausted ]
;;

let kind_to_string = function
  | Docker_spawn -> "docker_spawn"
  | Provider_http -> "provider_http"
  | Provider_cli -> "provider_cli"
  | Sandbox_exec -> "sandbox_exec"
  | Log_writer -> "log_writer"
;;

let kind_of_string = function
  | "docker_spawn" -> Some Docker_spawn
  | "provider_http" -> Some Provider_http
  | "provider_cli" -> Some Provider_cli
  | "sandbox_exec" -> Some Sandbox_exec
  | "log_writer" -> Some Log_writer
  | _ -> None
;;

let resource_error_to_string = function
  | Process_fd_exhausted -> "process_fd_exhausted"
  | System_fd_exhausted -> "system_fd_exhausted"
  | Storage_space_exhausted -> "storage_space_exhausted"
;;

let resource_error_of_exn = function
  | Unix.Unix_error (Unix.EMFILE, _, _) -> Some Process_fd_exhausted
  | Unix.Unix_error (Unix.ENFILE, _, _) -> Some System_fd_exhausted
  | Unix.Unix_error (Unix.ENOSPC, _, _) -> Some Storage_space_exhausted
  | _ -> None
;;

type observers =
  { nofile_soft_limit : unit -> int option
  ; on_resource_error : kind:kind -> resource_error -> exn -> unit
  }

let default_resource_error_observer ~kind error exn =
  Printf.eprintf
    "fd_accountant: resource error kind=%s error=%s exception=%s\n%!"
    (kind_to_string kind)
    (resource_error_to_string error)
    (Printexc.to_string exn)
;;

let observers =
  Atomic.make
    { nofile_soft_limit = (fun () -> None)
    ; on_resource_error = default_resource_error_observer
    }
;;

let install_observers ~nofile_soft_limit ~on_resource_error =
  Atomic.set observers { nofile_soft_limit; on_resource_error }
;;

type kind_state = { active : int Atomic.t }

let states =
  List.map (fun kind -> kind, { active = Atomic.make 0 }) all_kinds
;;

let state_of kind = List.assoc kind states
let active_count ~kind = Atomic.get (state_of kind).active

let resource_error_counts =
  List.concat_map
    (fun kind ->
      List.map
        (fun error -> (kind, error), Atomic.make 0)
        all_resource_errors)
    all_kinds
;;

let resource_error_counter ~kind error =
  List.assoc (kind, error) resource_error_counts
;;

let resource_error_count ~kind error =
  Atomic.get (resource_error_counter ~kind error)
;;

let report_typed_resource_error ~kind exn =
  match resource_error_of_exn exn with
  | None -> ()
  | Some error ->
    Atomic.incr (resource_error_counter ~kind error);
    let observer = (Atomic.get observers).on_resource_error in
    (match observer ~kind error exn with
     | () -> ()
     | exception observer_exn ->
       Printf.eprintf
         "fd_accountant: resource-error observer failed kind=%s error=%s \
          observer_exception=%s original_exception=%s\n%!"
         (kind_to_string kind)
         (resource_error_to_string error)
         (Printexc.to_string observer_exn)
         (Printexc.to_string exn))
;;

let observe ~kind f =
  let active = (state_of kind).active in
  Atomic.incr active;
  Fun.protect
    ~finally:(fun () -> Atomic.decr active)
    (fun () ->
       try f () with
       | exn ->
         report_typed_resource_error ~kind exn;
         raise exn)
;;

let acquire_lifetime_observation ~kind () =
  let active = (state_of kind).active in
  Atomic.incr active;
  let released = Atomic.make false in
  fun () ->
    if Atomic.compare_and_set released false true then Atomic.decr active
;;

let install_dated_jsonl_log_writer_observer () =
  Dated_jsonl.set_append_guard (fun f -> observe ~kind:Log_writer f)
;;

let install_process_eio_sandbox_exec_observer () =
  Process_eio.set_spawn_guard
    { Process_eio.run = (fun f -> observe ~kind:Sandbox_exec f) }
;;

let install_with_process_sandbox_exec_observer () =
  With_process.set_process_guard
    { With_process.run = (fun f -> observe ~kind:Sandbox_exec f) }
;;

let install_bg_sandbox_exec_observer () =
  Bg_task.set_lifetime_guard
    { Bg_task.acquire =
        (fun () -> acquire_lifetime_observation ~kind:Sandbox_exec ())
    }
;;

let () =
  install_dated_jsonl_log_writer_observer ();
  install_process_eio_sandbox_exec_observer ();
  install_with_process_sandbox_exec_observer ();
  install_bg_sandbox_exec_observer ()
;;

let read_fd_open () =
  let rec first_observable = function
    | [] -> None
    | dir :: rest ->
      (match Sys.readdir dir with
       | entries -> Some (Array.length entries)
       | exception Sys_error _ | exception Unix.Unix_error _ ->
         first_observable rest)
  in
  first_observable [ "/dev/fd"; "/proc/self/fd"; "/proc/self/task/self/fd" ]
;;

let read_fd_limit () =
  (Atomic.get observers).nofile_soft_limit ()
;;

type snapshot =
  { per_kind : (kind * int) list
  ; resource_errors : (kind * resource_error * int) list
  ; fd_open : int option
  ; fd_limit : int option
  }

let fd_snapshot () =
  { per_kind = List.map (fun kind -> kind, active_count ~kind) all_kinds
  ; resource_errors =
      List.concat_map
        (fun kind ->
          List.map
            (fun error -> kind, error, resource_error_count ~kind error)
            all_resource_errors)
        all_kinds
  ; fd_open = read_fd_open ()
  ; fd_limit = read_fd_limit ()
  }
;;

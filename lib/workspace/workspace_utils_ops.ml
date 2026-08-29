open Masc_domain
open Workspace_utils_backend_setup
open Workspace_utils_paths_backend
open Result.Syntax


let validate_agent_name name =
  let+ _ = Validation.Id_shape.validate name in
  name

let validate_task_id id =
  let+ _ = Validation.Task_id.validate id in
  id

let validate_file_path path =
  (* Delegate to Validation module for consistent security checks *)
  (* Additional length check for file paths *)
  let* () =
    if String.length path > 500 then Error "File path too long (max 500 chars)"
    else Ok ()
  in
  let* () =
    if String_util.contains_substring path "<" || String_util.contains_substring path ">" then
      Error "Invalid characters in path (security)"
    else Ok ()
  in
  Validation.Safe_path.validate_relative path

(* ============================================ *)
(* Sanitization helpers                         *)
(* ============================================ *)

let safe_filename = Common.safe_filename

(* ============================================ *)
(* Result-returning validators                  *)
(* ============================================ *)

let validate_agent_name_r name : (string, masc_error) result =
  (* Delegate to Validation module, convert error type *)
  Validation.Id_shape.validate name
  |> Result.map (fun _ -> name)
  |> Result.map_error (fun msg -> Agent (Agent_error.InvalidName msg))

let validate_task_id_r id : (string, masc_error) result =
  (* Delegate to Validation module, convert error type *)
  Validation.Task_id.validate id
  |> Result.map (fun _ -> id)
  |> Result.map_error (fun msg -> Task (Task_error.InvalidId msg))

(* ============================================ *)
(* Ensure initialized                           *)
(* ============================================ *)

(* Typed marker for the not-initialized case.

   Before: [ensure_initialized] raised [Invalid_argument "MASC not
   initialized. Use masc_init first."], and four downstream catch
   sites recovered the case via [Printexc.to_string +
   contains_casefold ... "masc not initialized"]. That was the
   RFC-0088 §"String/Substring 분류기" anti-pattern in cross-module
   form — a prose string round-tripped through the exception slot
   to carry semantic information.

   Registering a printer keeps existing telemetry/log paths that
   format the exception via [Printexc.to_string] unchanged. *)
exception Not_initialized

let () =
  Printexc.register_printer (function
    | Not_initialized -> Some "MASC not initialized."
    | _ -> None)

let ensure_initialized config =
  if not (is_initialized config) then raise Not_initialized

(* ============================================ *)
(* File I/O helpers                             *)
(* ============================================ *)

let mkdir_p path =
  Fs_compat.mkdir_p path

let read_json_local path =
  (* Treat blank/empty files as an empty object, consistent with
     [read_json_root] below. A blank JSON is a legitimate state for
     placeholders or newly-created agent metadata files, and does not
     warrant a WARN log line. *)
  match Safe_ops.read_file_safe path with
  | Error msg ->
    Log.Misc.warn "[read_json_local] %s" msg;
    `Assoc []
  | Ok content ->
    let trimmed = String.trim content in
    if trimmed = "" then `Assoc []
    else match Safe_ops.parse_json_safe ~context:path trimmed with
      | Ok json -> json
      | Error msg ->
        Log.Misc.warn "[read_json_local] %s" msg;
        `Assoc []

let read_json_local_result path =
  Safe_ops.read_json_file_safe path

type read_json_error =
  | Json_read_exn of exn
  | Json_read_error of string

let parse_json_content_result ~context content =
  let trimmed = String.trim content in
  if trimmed = "" then Ok (`Assoc [])
  else Safe_ops.parse_json_safe ~context trimmed

let read_json_local_result_exn path =
  try
    let* () =
      if Sys.file_exists path then Ok ()
      else Error (Json_read_error (Printf.sprintf "File not found: %s" path))
    in
    parse_json_content_result ~context:path (Fs_compat.load_file path)
    |> Result.map_error (fun msg -> Json_read_error msg)
  with
  | Eio.Cancel.Cancelled _ as e -> raise e
  | exn -> Error (Json_read_exn exn)

let json_to_pretty_utf8 json =
  json |> Safe_ops.sanitize_json_utf8 |> Yojson.Safe.pretty_to_string

let write_json_local path json =
  try
    mkdir_p (Filename.dirname path);
    let content = json_to_pretty_utf8 json in
    Fs_compat.save_file_atomic path content
  with
  | Eio.Cancel.Cancelled _ as exn -> raise exn
  | exn -> Error (Printexc.to_string exn)

(* Root-scoped JSON helpers for shared root metadata. *)
let read_json_root config path =
  match root_key_of_path config path with
  | Some key -> begin
      match config.backend with
      | FileSystem _ when Sys.file_exists path -> read_json_local path
      | Memory _ | FileSystem _ ->
      match backend_get config ~key with
      | Ok (Some content) ->
          (let trimmed = String.trim content in
           if trimmed = "" then `Assoc []
           else match Safe_ops.parse_json_safe ~context:"read_json_root" trimmed with
           | Ok json -> json
           | Error msg ->
             Log.Misc.warn "[read_json_root] %s" msg;
             `Assoc [])
      | Ok None -> `Assoc []
      | Error e ->
        Log.Misc.warn "[read_json_root] backend_get failed for %s: %s" key (Backend_types.show_error e);
        `Assoc []
    end
  | None -> read_json_local path

let write_json_root config path json =
  match root_key_of_path config path with
  | Some key ->
      let content = json_to_pretty_utf8 json in
      backend_set config ~key ~value:content
      |> Result.iter_error (fun e ->
           Log.Misc.warn "write_json_root backend_set failed for %s: %s" key (Backend_types.show_error e));
      (* Dual-write: mirror to local filesystem so PG-timeout fallback reads fresh data *)
      write_json_local path json
      |> Result.iter_error (fun msg ->
           Log.Misc.warn "write_json_root: local mirror write failed for %s: %s" path msg)
  | None ->
      write_json_local path json
      |> Result.iter_error (fun msg ->
           Log.Misc.warn "write_json_root: local write failed for %s: %s" path msg)

let path_exists_root config path =
  match root_key_of_path config path with
  | Some key ->
      (match config.backend with
       | FileSystem _ -> Sys.file_exists path || backend_exists config ~key
       | Memory _ -> backend_exists config ~key)
  | None -> Sys.file_exists path

let read_json config path =
  match key_of_path config path with
  | Some key -> begin
      match config.backend with
      | FileSystem _ when Sys.file_exists path -> read_json_local path
      | Memory _ | FileSystem _ ->
      match backend_get config ~key with
      | Ok (Some content) ->
          (let trimmed = String.trim content in
           if trimmed = "" then `Assoc []
           else match Safe_ops.parse_json_safe ~context:"read_json" trimmed with
           | Ok json -> json
           | Error msg ->
             Log.Misc.warn "[read_json] %s" msg;
             `Assoc [])
      | Ok None -> `Assoc []
      | Error e ->
        Log.Misc.warn "[read_json] backend_get failed for %s: %s" key (Backend_types.show_error e);
        `Assoc []
    end
  | None -> read_json_local path

let read_json_result config path =
  match key_of_path config path with
  | Some key -> begin
      match config.backend with
      | FileSystem _ when Sys.file_exists path -> read_json_local_result path
      | Memory _ | FileSystem _ ->
          let* content_opt =
            backend_get config ~key
            |> Result.map_error (fun e ->
                 Printf.sprintf
                   "[read_json_result] backend_get failed for %s: %s"
                   key
                   (Backend_types.show_error e))
          in
          (match content_opt with
           | Some content -> parse_json_content_result ~context:"read_json_result" content
           | None -> Ok (`Assoc []))
    end
  | None -> read_json_local_result path

let read_text config path =
  match key_of_path config path with
  | Some key ->
      backend_get config ~key
      |> Result.fold
           ~ok:(function
             | Some content ->
               Safe_ops.repair_utf8_text ~surface:"workspace_text" ~path content
             | None -> "")
           ~error:(fun e ->
             Log.Misc.warn "[read_text] backend_get failed for %s: %s" key (Backend_types.show_error e);
             "")
  | None ->
      if Fs_compat.file_exists path then
        Fs_compat.load_file path
        |> Safe_ops.repair_utf8_text ~surface:"workspace_text" ~path
      else ""

let should_dual_write_local (config : config) =
  match config.backend with
  | FileSystem _ -> false
  | Memory _ -> true

type write_json_commit = { mirror_error : string option }

let write_json_commit_result config path json =
  match key_of_path config path with
  | Some key ->
      let content = json_to_pretty_utf8 json in
      (match backend_set config ~key ~value:content with
       | Error error ->
         Error
           (Printf.sprintf
              "backend_set failed for %s: %s"
              key
              (Backend_types.show_error error))
       | Ok () ->
         let mirror_error =
           if should_dual_write_local config
           then
             match write_json_local path json with
             | Ok () -> None
             | Error message ->
               Some
                 (Printf.sprintf
                    "local mirror write failed for %s: %s"
                    path
                    message)
           else None
         in
         Ok { mirror_error })
  | None ->
      write_json_local path json
      |> Result.map_error (fun msg ->
           Printf.sprintf "local write failed for %s: %s" path msg)
      |> Result.map (fun () -> { mirror_error = None })

let write_json_result config path json =
  match write_json_commit_result config path json with
  | Error message -> Error message
  | Ok { mirror_error = None } -> Ok ()
  | Ok { mirror_error = Some message } -> Error message

let write_json config path json =
  match write_json_result config path json with
  | Ok () -> ()
  | Error msg ->
      Log.Misc.warn "write_json failed for %s: %s"
        (match key_of_path config path with
         | Some key -> key
         | None -> path)
        msg

let write_text_local path content =
  mkdir_p (Filename.dirname path);
  let tmp_path = path ^ ".tmp" in
  try
    Fs_compat.save_file tmp_path content;
    Unix.rename tmp_path path;
    Ok ()
  with
  | Eio.Cancel.Cancelled _ as e -> raise e
  | e -> Error (Printexc.to_string e)

let write_text config path content =
  match key_of_path config path with
  | Some key ->
      backend_set config ~key ~value:content
      |> Result.iter_error (fun e ->
           Log.Misc.warn "write_text backend_set failed for %s: %s" key
             (Backend_types.show_error e));
      if should_dual_write_local config then
        (* Keep a plaintext mirror for non-filesystem backends so local fallback reads stay fresh. *)
        write_text_local path content
        |> Result.iter_error (fun msg ->
             Log.Misc.warn "write_text: local mirror write failed for %s: %s" path msg)
  | None ->
      write_text_local path content
      |> Result.iter_error (fun msg ->
           Log.Misc.warn "write_text: local write failed for %s: %s" path msg)

let delete_path config path =
  match key_of_path config path with
  | Some key ->
      backend_delete config ~key
      |> Result.fold
           ~ok:(fun _ ->
             if should_dual_write_local config then try Sys.remove path with Sys_error _ -> ())
           ~error:(fun e ->
             Log.Misc.error "delete_path: backend_delete failed for %s: %s" key
               (Backend_types.show_error e))
  | None -> if Sys.file_exists path then Sys.remove path

let path_exists config path =
  match key_of_path config path with
  | Some key ->
      (match config.backend with
       | FileSystem _ -> Sys.file_exists path || backend_exists config ~key
       | Memory _ -> backend_exists config ~key)
  | None -> Sys.file_exists path

let read_json_opt config path =
  match key_of_path config path with
  | Some key -> (
      backend_get config ~key
      |> Result.fold
           ~ok:(function
             | Some content ->
                 let trimmed = String.trim content in
                 if trimmed = "" then None
                 else
                   Safe_ops.parse_json_safe ~context:"read_json_opt" trimmed
                   |> Result.fold
                        ~ok:(fun json -> Some json)
                        ~error:(fun msg ->
                          Log.Misc.warn "[read_json_opt] %s" msg;
                          None)
             | None -> None)
           ~error:(fun e ->
             Log.Misc.warn "[read_json_opt] backend_get failed for %s: %s" key (Backend_types.show_error e);
             None))
  | None ->
      if Sys.file_exists path then Some (read_json_local path)
      else None

let is_fd_pressure_exn exn =
  match System_error_class.classify_exn exn with
  | System_error_class.Fd_exhaustion -> true
  | System_error_class.Disk_exhaustion
  | System_error_class.Permission_denied
  | System_error_class.Connection_refused
  | System_error_class.Timeout
  | System_error_class.Other _ -> false
;;

type read_agent_error =
  | Agent_fd_pressure of exn
  | Agent_read_error of string

let read_agent_json_from_backend config key =
  let* content_opt =
    backend_get config ~key
    |> Result.map_error (fun e ->
         Json_read_error
           (Printf.sprintf
              "[read_agent] backend_get failed for %s: %s"
              key
              (Backend_types.show_error e)))
  in
  match content_opt with
  | Some content ->
      parse_json_content_result ~context:"read_agent" content
      |> Result.map_error (fun msg -> Json_read_error msg)
  | None -> Ok (`Assoc [])

let read_agent_json_result config path =
  match key_of_path config path with
  | Some key ->
      (match config.backend with
       | FileSystem _ ->
           let* exists =
             try Ok (Sys.file_exists path) with
             | Eio.Cancel.Cancelled _ as e -> raise e
             | exn -> Error (Json_read_exn exn)
           in
           if exists then read_json_local_result_exn path
           else read_agent_json_from_backend config key
       | Memory _ -> read_agent_json_from_backend config key)
  | None -> read_json_local_result_exn path

let read_agent_result config path =
  let* json =
    read_agent_json_result config path
    |> Result.map_error (function
         | Json_read_exn exn when is_fd_pressure_exn exn -> Agent_fd_pressure exn
         | Json_read_exn exn -> Agent_read_error (Printexc.to_string exn)
         | Json_read_error msg -> Agent_read_error msg)
  in
  Masc_domain.agent_of_yojson json
  |> Result.map_error (fun msg -> Agent_read_error msg)

let read_agent config path =
  read_agent_result config path
  |> Result.map_error (function
       | Agent_fd_pressure exn ->
           let detail = Printexc.to_string exn in
           "fd_pressure_io: " ^ detail
       | Agent_read_error msg -> msg)

(* ============================================ *)
(* File locking                                 *)
(* ============================================ *)

let sleep_lock_retry ?clock delay =
  match clock with
  | Some clock -> Eio.Time.sleep clock delay
  | None -> Time_compat.sleep delay

(* Per-domain RNG for backoff jitter.  [Random.State.t] is NOT
   cross-domain safe, so each domain keeps its own seed.  Cf. the
   [nickname_rng] precedent in [lib/workspace/nickname.ml]; here we use
   [Domain.DLS] instead of an Eio mutex because the lock-acquire path
   may run from non-Eio contexts (Time_compat.sleep branch). *)
let backoff_rng_key : Random.State.t Domain.DLS.key =
  Domain.DLS.new_key Random.State.make_self_init

(* "Full jitter" backoff (Marc Brooker, AWS Architecture Blog,
   "Exponential Backoff And Jitter", 2015): sleep ∈ [0, delay]
   while [delay] still doubles up to the cap on every miss.

   Pre-fix, all 17 fleet actors (16 keepers + orchestrator GC) hit
   the [tasks:.backlog] file lock with the SAME deterministic backoff
   sequence (0.05, 0.1, 0.2, 0.4, 0.5, 0.5, …).  When they collided
   they re-collided exactly one tick later, so 50 retries decayed
   into 50 contention spikes instead of 50 independent attempts —
   #9645 reports the orchestrator giving up after the budget was
   exhausted.  Full jitter desynchronises the herd: two actors that
   collide at attempt N pick different sleeps in [0, current_delay],
   so attempt N+1 is staggered. *)
let backoff_with_jitter delay =
  if delay <= 0.0 then delay
  else
    let st = Domain.DLS.get backoff_rng_key in
    Random.State.float st delay

let with_distributed_lock ?clock config key f =
  let owner = config.backend_config.node_id in
  let ttl_seconds = config.lock_expiry_minutes * 60 in
  let rec acquire attempts delay =
    if attempts <= 0 then false
    else
      match backend_acquire_lock config ~key ~ttl_seconds ~owner with
      | Ok true -> true
      | Ok false | Error _ ->
          sleep_lock_retry ?clock (backoff_with_jitter delay);
          acquire (attempts - 1) (Float.min 0.5 (delay *. 2.0))
  in
  if acquire 50 0.05 then
    Common.protect ~module_name:"workspace_utils" ~finally_label:"finalizer"
      ~finally:(fun () ->
        backend_release_lock config ~key ~owner
        |> Result.iter_error (fun e ->
             let msg =
               match e with
               | Backend_types.ConnectionFailed s | NotFound s
               | IOError s | BackendNotSupported s | InvalidKey s
               | AlreadyExists s -> s
             in
             Log.Workspace.warn "lock release failed for %s: %s" key msg))
      f
  else begin
    (* #9645: surface lock acquire exhaustion as a fleet-wide
       metric.  Hook is wired by [lib/workspace.ml] at startup. *)
    (Atomic.get Workspace_hooks.distributed_lock_acquire_failed_fn)
      ~key ~attempts:50;
    invalid_arg
      (Printf.sprintf
         "Failed to acquire distributed lock for key: %s (50 attempts exhausted)"
         key)
  end

let with_distributed_lock_r ?clock config key f : ('a, masc_error) result =
  let owner = config.backend_config.node_id in
  let ttl_seconds = config.lock_expiry_minutes * 60 in
  let rec acquire attempts delay =
    if attempts <= 0 then false
    else
      match backend_acquire_lock config ~key ~ttl_seconds ~owner with
      | Ok true -> true
      | Ok false | Error _ ->
          sleep_lock_retry ?clock (backoff_with_jitter delay);
          acquire (attempts - 1) (Float.min 0.5 (delay *. 2.0))
  in
  if acquire 50 0.05 then
    Common.protect ~module_name:"workspace_utils" ~finally_label:"finalizer"
      ~finally:(fun () ->
        backend_release_lock config ~key ~owner
        |> Result.iter_error (fun e ->
             let msg =
               match e with
               | Backend_types.ConnectionFailed s | NotFound s
               | IOError s | BackendNotSupported s | InvalidKey s
               | AlreadyExists s -> s
             in
             Log.Workspace.warn "lock release failed for %s: %s" key msg))
      (fun () -> Ok (f ()))
  else begin
    (* #9645: see [with_distributed_lock] above.
       #18472 follow-up: surface as typed [LockContention] instead of
       [IoError msg], so callers dispatch on the variant instead of
       substring-matching "transient contention" (RFC-0088
       "String/Substring 분류기" anti-pattern removal). *)
    (Atomic.get Workspace_hooks.distributed_lock_acquire_failed_fn)
      ~key ~attempts:50;
    Error (System (System_error.LockContention { key; attempts = 50 }))
  end

let with_file_lock_impl ?clock config path f =
  match key_of_path config path with
  | None ->
      (* Fix 2: Use cooperative Eio.Mutex instead of blocking Unix.lockf.
         Single-process assumption (MASC runs as one process). *)
      File_lock_eio.with_lock path f
  | Some key -> (
      match config.backend with
      | Memory _ ->
          (* Memory backend is single-process but still multi-fiber.
             Serialize same-path updates cooperatively to avoid read-modify-write
             races in append/readback helpers. *)
          File_lock_eio.with_mutex path f
      | FileSystem _ ->
          with_distributed_lock ?clock config key f)

let with_file_lock config path f =
  with_file_lock_impl ?clock:(Eio_context.get_clock_opt ()) config path f

let with_file_lock_r_impl ?clock config path f : ('a, masc_error) result =
  match key_of_path config path with
  | None ->
      (* Fix 2: Cooperative lock — same as with_file_lock *)
      File_lock_eio.with_lock path (fun () -> Ok (f ()))
  | Some key -> (
      match config.backend with
      | Memory _ -> File_lock_eio.with_mutex path (fun () -> Ok (f ()))
      | FileSystem _ ->
          with_distributed_lock_r ?clock config key f)

let with_file_lock_r config path f : ('a, masc_error) result =
  with_file_lock_r_impl ?clock:(Eio_context.get_clock_opt ()) config path f

(* ============================================ *)
(* Event logging                                *)
(* ============================================ *)

let log_event config event_json =
  let events_dir = Filename.concat (masc_dir config) "events" in
  mkdir_p events_dir;

  (* Two gmtime calls used to pick the month and the day, so a midnight
     between them filed the last day of one month under the next one's
     directory. [Jsonl_writer] runs one call behind both (#27143). *)
  let dated = Jsonl_writer.dated_path_now ~base_dir:events_dir in
  let month_dir = Filename.concat events_dir dated.Jsonl_writer.month_dir in
  mkdir_p month_dir;
  let log_file = dated.Jsonl_writer.path in

  Fs_compat.append_file log_file (Yojson.Safe.to_string event_json ^ "\n")

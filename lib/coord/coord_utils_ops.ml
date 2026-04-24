open Types
open Coord_utils_backend_setup
open Coord_utils_paths_backend

let contains_substring = String_util.contains_substring

let validate_agent_name name =
  (* Delegate to Validation module for consistent security checks *)
  Validation.Agent_id.validate name

let validate_task_id id =
  (* Delegate to Validation module for consistent security checks *)
  Validation.Task_id.validate id

let validate_room_id room_id =
  let room_id = String.trim room_id in
  if room_id = "" then Error "Coord id cannot be empty"
  else if String.length room_id > 128 then Error "Coord id too long (max 128 chars)"
  else if room_id = "." || room_id = ".." then Error "Coord id cannot be '.' or '..'"
  else if contains_substring room_id "/" || contains_substring room_id "\\" then
    Error "Coord id cannot contain path separators"
  else if contains_substring room_id ".." then
    Error "Coord id cannot contain traversal segments"
  else if not (Re.execp (Re.compile (Re.(whole_string (rep1 (alt [rg 'A' 'Z'; rg 'a' 'z'; rg '0' '9'; char '.'; char '_'; char '-']))))) room_id) then
    Error "Coord id may only contain letters, digits, dot, underscore, and hyphen"
  else Ok room_id

let validate_file_path path =
  (* Delegate to Validation module for consistent security checks *)
  (* Additional length check for file paths *)
  if String.length path > 500 then Error "File path too long (max 500 chars)"
  else if contains_substring path "<" || contains_substring path ">" then
    Error "Invalid characters in path (security)"
  else Validation.Safe_path.validate_relative path

(* ============================================ *)
(* Sanitization helpers                         *)
(* ============================================ *)

let sanitize_html str =
  let buf = Buffer.create (String.length str) in
  String.iter (fun c ->
    match c with
    | '<' -> Buffer.add_string buf "&lt;"
    | '>' -> Buffer.add_string buf "&gt;"
    | '&' -> Buffer.add_string buf "&amp;"
    | '"' -> Buffer.add_string buf "&quot;"
    | '\'' -> Buffer.add_string buf "&#x27;"
    | _ -> Buffer.add_char buf c
  ) str;
  Buffer.contents buf

let sanitize_agent_name = sanitize_html
let sanitize_message = sanitize_html

let safe_filename name =
  let buf = Buffer.create (String.length name * 3) in
  String.iter (fun c ->
    let c_lower = Char.lowercase_ascii c in
    let valid =
      (c_lower >= 'a' && c_lower <= 'z') ||
      (c_lower >= '0' && c_lower <= '9') ||
      c_lower = '.' || c_lower = '_' || c_lower = '-'
    in
    if valid then
      Buffer.add_char buf c_lower
    else
      Buffer.add_string buf (Printf.sprintf "_%02x" (Char.code c))
  ) name;
  Buffer.contents buf

(* ============================================ *)
(* Result-returning validators                  *)
(* ============================================ *)

let validate_agent_name_r name : (string, masc_error) result =
  (* Delegate to Validation module, convert error type *)
  match Validation.Agent_id.validate name with
  | Ok _ -> Ok name
  | Error msg -> Error (InvalidAgentName msg)

let validate_task_id_r id : (string, masc_error) result =
  (* Delegate to Validation module, convert error type *)
  match Validation.Task_id.validate id with
  | Ok _ -> Ok id
  | Error msg -> Error (InvalidTaskId msg)

let validate_file_path_r path : (string, masc_error) result =
  (* Delegate to Validation module, convert error type *)
  if String.length path > 500 then Error (InvalidFilePath "too long (max 500 chars)")
  else if contains_substring path "<" || contains_substring path ">" then
    Error (InvalidFilePath "invalid characters (security)")
  else match Validation.Safe_path.validate_relative path with
  | Ok _ -> Ok path
  | Error msg -> Error (InvalidFilePath msg)

(* ============================================ *)
(* Ensure initialized                           *)
(* ============================================ *)

let ensure_initialized config =
  if not (is_initialized config) then
    invalid_arg "MASC not initialized. Use masc_init first."

let ensure_initialized_r config : (unit, masc_error) result =
  if is_initialized config then Ok ()
  else Error NotInitialized

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

let write_json_local path json =
  mkdir_p (Filename.dirname path);
  let content = Yojson.Safe.pretty_to_string json in
  Fs_compat.save_file_atomic path content

(* Root-scoped JSON helpers for shared room registry/current_room metadata. *)
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
      let content = Yojson.Safe.pretty_to_string json in
      (match backend_set config ~key ~value:content with
       | Ok () -> ()
       | Error e -> Log.Misc.warn "write_json_root backend_set failed for %s: %s" key (Backend_types.show_error e));
      (* Dual-write: mirror to local filesystem so PG-timeout fallback reads fresh data *)
      (match write_json_local path json with
       | Ok () -> ()
       | Error msg ->
         Log.Misc.warn "write_json_root: local mirror write failed for %s: %s"
           path msg)
  | None ->
      (match write_json_local path json with
       | Ok () -> ()
       | Error msg ->
         Log.Misc.warn "write_json_root: local write failed for %s: %s"
           path msg)

let delete_path_root config path =
  match root_key_of_path config path with
  | Some key ->
    (match backend_delete config ~key with
     | Ok _ ->
       (try Sys.remove path with Sys_error _ -> ())
     | Error e -> Log.Misc.error "delete_path_root: backend_delete failed for %s: %s" key (Backend_types.show_error e))
  | None -> if Sys.file_exists path then Sys.remove path

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
  let parse_backend_json ~context content =
    let trimmed = String.trim content in
    if trimmed = "" then Ok (`Assoc [])
    else Safe_ops.parse_json_safe ~context trimmed
  in
  match key_of_path config path with
  | Some key -> begin
      match config.backend with
      | FileSystem _ when Sys.file_exists path -> read_json_local_result path
      | Memory _ | FileSystem _ ->
      match backend_get config ~key with
      | Ok (Some content) ->
          parse_backend_json ~context:"read_json_result" content
      | Ok None -> Ok (`Assoc [])
      | Error e ->
          Error
            (Printf.sprintf
               "[read_json_result] backend_get failed for %s: %s"
               key
               (Backend_types.show_error e))
    end
  | None -> read_json_local_result path

let read_text config path =
  match key_of_path config path with
  | Some key -> begin
      match backend_get config ~key with
      | Ok (Some content) -> content
      | Ok None -> ""
      | Error e ->
        Log.Misc.warn "[read_text] backend_get failed for %s: %s" key (Backend_types.show_error e);
        ""
    end
  | None ->
      if Fs_compat.file_exists path then Fs_compat.load_file path
      else ""

let should_dual_write_local (config : config) =
  match config.backend with
  | FileSystem _ -> false
  | Memory _ -> true

let write_json config path json =
  match key_of_path config path with
  | Some key ->
      let content = Yojson.Safe.pretty_to_string json in
      (match backend_set config ~key ~value:content with
       | Ok () -> ()
       | Error e -> Log.Misc.warn "write_json backend_set failed for %s: %s" key (Backend_types.show_error e));
      if should_dual_write_local config then
        (* Keep a plaintext mirror for non-filesystem backends so local fallback reads stay fresh. *)
        (match write_json_local path json with
         | Ok () -> ()
         | Error msg ->
           Log.Misc.warn "write_json: local mirror write failed for %s: %s"
             path msg)
  | None -> (
      match write_json_local path json with
      | Ok () -> ()
      | Error msg ->
        Log.Misc.warn "write_json: local write failed for %s: %s" path msg)

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
      (match backend_set config ~key ~value:content with
       | Ok () -> ()
       | Error e ->
           Log.Misc.warn "write_text backend_set failed for %s: %s" key
             (Backend_types.show_error e));
      if should_dual_write_local config then
        (* Keep a plaintext mirror for non-filesystem backends so local fallback reads stay fresh. *)
        (match write_text_local path content with
         | Ok () -> ()
         | Error msg ->
           Log.Misc.warn "write_text: local mirror write failed for %s: %s"
             path msg)
  | None -> (
      match write_text_local path content with
      | Ok () -> ()
      | Error msg ->
        Log.Misc.warn "write_text: local write failed for %s: %s" path msg)

let delete_path config path =
  match key_of_path config path with
  | Some key ->
    (match backend_delete config ~key with
     | Ok _ ->
       if should_dual_write_local config then
         (try Sys.remove path with Sys_error _ -> ())
     | Error e -> Log.Misc.error "delete_path: backend_delete failed for %s: %s" key (Backend_types.show_error e))
  | None -> if Sys.file_exists path then Sys.remove path

let path_exists config path =
  match key_of_path config path with
  | Some key ->
      (match config.backend with
       | FileSystem _ -> Sys.file_exists path || backend_exists config ~key
       | Memory _ -> backend_exists config ~key)
  | None -> Sys.file_exists path

let append_text config path content =
  match key_of_path config path with
  | Some key ->
      let existing =
        match backend_get config ~key with
        | Ok (Some value) -> value
        | Ok None -> ""
        | Error e ->
          Log.Misc.warn "[append_text] backend_get failed for %s: %s" key (Backend_types.show_error e);
          ""
      in
      (match backend_set config ~key ~value:(existing ^ content) with
       | Ok () -> ()
       | Error e ->
           Log.Misc.warn "append_text backend_set failed for %s: %s" key
             (Backend_types.show_error e))
  | None ->
      mkdir_p (Filename.dirname path);
      Fs_compat.append_file path content

let read_json_opt config path =
  match key_of_path config path with
  | Some key -> (
      match backend_get config ~key with
      | Ok (Some content) ->
          let trimmed = String.trim content in
          if trimmed = "" then None
          else (
            match Safe_ops.parse_json_safe ~context:"read_json_opt" trimmed with
            | Ok json -> Some json
            | Error msg ->
              Log.Misc.warn "[read_json_opt] %s" msg;
              None)
      | Ok None -> None
      | Error e ->
        Log.Misc.warn "[read_json_opt] backend_get failed for %s: %s" key (Backend_types.show_error e);
        None)
  | None ->
      if Sys.file_exists path then Some (read_json_local path)
      else None

let agent_json_needs_repair = function
  | `Assoc fields -> (
      match List.assoc_opt "last_seen" fields with
      | Some (`Int _ | `Float _) -> true
      | _ -> false)
  | _ -> false

let read_agent_with_repair config path =
  let json = read_json config path in
  match Types.agent_of_yojson json with
  | Ok agent as ok ->
      if agent_json_needs_repair json then (
        Log.Coord.warn
          "agent state repair: repaired agent JSON and rewrote canonical state for %s"
          path;
        write_json config path (Types.agent_to_yojson agent));
      ok
  | Error _ as error -> error

(* ============================================ *)
(* File locking                                 *)
(* ============================================ *)

let sleep_lock_retry ?clock delay =
  match clock with
  | Some clock -> Eio.Time.sleep clock delay
  | None -> Time_compat.sleep delay

let with_distributed_lock ?clock config _path key f =
  let owner = config.backend_config.node_id in
  let ttl_seconds = config.lock_expiry_minutes * 60 in
  let rec acquire attempts delay =
    if attempts <= 0 then false
    else
      match backend_acquire_lock config ~key ~ttl_seconds ~owner with
      | Ok true -> true
      | _ ->
          sleep_lock_retry ?clock delay;
          acquire (attempts - 1) (Float.min 0.5 (delay *. 2.0))
  in
  if acquire 50 0.05 then
    Common.protect ~module_name:"room_utils" ~finally_label:"finalizer"
      ~finally:(fun () ->
        match backend_release_lock config ~key ~owner with
        | Ok _ -> ()
        | Error e ->
            let msg =
              match e with
              | Backend_types.ConnectionFailed s | NotFound s
              | IOError s | BackendNotSupported s | InvalidKey s
              | AlreadyExists s -> s
            in
            Log.Coord.warn "lock release failed for %s: %s" key msg)
      f
  else
    invalid_arg
      (Printf.sprintf
         "Failed to acquire distributed lock for key: %s (50 attempts exhausted)"
         key)

let with_distributed_lock_r ?clock config path key f : ('a, masc_error) result =
  let owner = config.backend_config.node_id in
  let ttl_seconds = config.lock_expiry_minutes * 60 in
  let rec acquire attempts delay =
    if attempts <= 0 then false
    else
      match backend_acquire_lock config ~key ~ttl_seconds ~owner with
      | Ok true -> true
      | _ ->
          sleep_lock_retry ?clock delay;
          acquire (attempts - 1) (Float.min 0.5 (delay *. 2.0))
  in
  if acquire 50 0.05 then
    Common.protect ~module_name:"room_utils" ~finally_label:"finalizer"
      ~finally:(fun () ->
        match backend_release_lock config ~key ~owner with
        | Ok _ -> ()
        | Error e ->
            let msg =
              match e with
              | Backend_types.ConnectionFailed s | NotFound s
              | IOError s | BackendNotSupported s | InvalidKey s
              | AlreadyExists s -> s
            in
            Log.Coord.warn "lock release failed for %s: %s" key msg)
      (fun () -> Ok (f ()))
  else
    Error
      (IoError
         (Printf.sprintf "Failed to acquire distributed lock for %s"
            path))

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
          with_distributed_lock ?clock config path key f)

let with_file_lock_eio ~clock config path f =
  with_file_lock_impl ~clock config path f

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
          with_distributed_lock_r ?clock config path key f)

let with_file_lock_r_eio ~clock config path f : ('a, masc_error) result =
  with_file_lock_r_impl ~clock config path f

let with_file_lock_r config path f : ('a, masc_error) result =
  with_file_lock_r_impl ?clock:(Eio_context.get_clock_opt ()) config path f

(* ============================================ *)
(* Event logging                                *)
(* ============================================ *)

let log_event config event_json =
  let events_dir = Filename.concat (masc_dir config) "events" in
  mkdir_p events_dir;

  let today =
    let open Unix in
    let tm = gmtime (gettimeofday ()) in
    Printf.sprintf "%04d-%02d" (tm.tm_year + 1900) (tm.tm_mon + 1)
  in
  let month_dir = Filename.concat events_dir today in
  mkdir_p month_dir;

  let day =
    let open Unix in
    let tm = gmtime (gettimeofday ()) in
    Printf.sprintf "%02d.jsonl" tm.tm_mday
  in
  let log_file = Filename.concat month_dir day in

  Fs_compat.append_file log_file (event_json ^ "\n")

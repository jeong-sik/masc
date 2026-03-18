open Types
open Room_utils_backend_setup
open Room_utils_paths_backend

let validate_agent_name name =
  (* Delegate to Validation module for consistent security checks *)
  Validation.Agent_id.validate name

let validate_task_id id =
  (* Delegate to Validation module for consistent security checks *)
  Validation.Task_id.validate id

let contains_substring haystack needle =
  let needle_len = String.length needle in
  let haystack_len = String.length haystack in
  if needle_len > haystack_len then false
  else
    let rec check i =
      if i > haystack_len - needle_len then false
      else if String.sub haystack i needle_len = needle then true
      else check (i + 1)
    in
    check 0

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
    let valid =
      (c >= 'a' && c <= 'z') ||
      (c >= 'A' && c <= 'Z') ||
      (c >= '0' && c <= '9') ||
      c = '.' || c = '_' || c = '-'
    in
    if valid then
      Buffer.add_char buf c
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
  match Safe_ops.read_json_file_safe path with
  | Ok json -> json
  | Error _ -> `Assoc []

let write_json_local path json =
  mkdir_p (Filename.dirname path);
  let content = Yojson.Safe.pretty_to_string json in
  let tmp_path = path ^ ".tmp" in
  Fs_compat.save_file tmp_path content;
  Unix.rename tmp_path path

(* Root-scoped JSON helpers for shared room registry/current_room metadata. *)
let read_json_root config path =
  match root_key_of_path config path with
  | Some key -> begin
      match backend_get config ~key with
      | Ok (Some content) ->
          (let trimmed = String.trim content in
           if trimmed = "" then `Assoc []
           else match Safe_ops.parse_json_safe ~context:"read_json_root" trimmed with
           | Ok json -> json
           | Error _ -> `Assoc [])
      | Ok None -> `Assoc []
      | Error _ -> `Assoc []
    end
  | None -> read_json_local path

let write_json_root config path json =
  match root_key_of_path config path with
  | Some key ->
      let content = Yojson.Safe.pretty_to_string json in
      let _ = backend_set config ~key ~value:content in
      ()
  | None -> write_json_local path json

let delete_path_root config path =
  match root_key_of_path config path with
  | Some key ->
    (match backend_delete config ~key with
     | Ok _ -> ()
     | Error e -> Log.Misc.error "delete_path_root: backend_delete failed for %s: %s" key (Backend.show_error e))
  | None -> if Sys.file_exists path then Sys.remove path

let path_exists_root config path =
  match root_key_of_path config path with
  | Some key -> backend_exists config ~key
  | None -> Sys.file_exists path

let read_json config path =
  match key_of_path config path with
  | Some key -> begin
      match backend_get config ~key with
      | Ok (Some content) ->
          (let trimmed = String.trim content in
           if trimmed = "" then `Assoc []
           else match Safe_ops.parse_json_safe ~context:"read_json_root" trimmed with
           | Ok json -> json
           | Error _ -> `Assoc [])
      | Ok None -> `Assoc []
      | Error _ -> `Assoc []
    end
  | None -> read_json_local path

let write_json config path json =
  match key_of_path config path with
  | Some key ->
      let content = Yojson.Safe.pretty_to_string json in
      let _ = backend_set config ~key ~value:content in
      ()
  | None -> write_json_local path json

let delete_path config path =
  match key_of_path config path with
  | Some key ->
    (match backend_delete config ~key with
     | Ok _ -> ()
     | Error e -> Log.Misc.error "delete_path: backend_delete failed for %s: %s" key (Backend.show_error e))
  | None -> if Sys.file_exists path then Sys.remove path

let path_exists config path =
  match key_of_path config path with
  | Some key -> backend_exists config ~key
  | None -> Sys.file_exists path

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
            | Error _ -> None)
      | Ok None -> None
      | Error _ -> None)
  | None ->
      if Sys.file_exists path then Some (read_json_local path)
      else None

(* ============================================ *)
(* File locking                                 *)
(* ============================================ *)

let with_file_lock config path f =
  match key_of_path config path with
  | None ->
      (* Fix 2: Use cooperative Eio.Mutex instead of blocking Unix.lockf.
         Single-process assumption (MASC runs as one process). *)
      File_lock_eio.with_lock path f
  | Some key ->
      let owner = config.backend_config.node_id in
      let ttl_seconds = config.lock_expiry_minutes * 60 in
      let rec acquire attempts =
        if attempts <= 0 then false
        else
          match backend_acquire_lock config ~key ~ttl_seconds ~owner with
          | Ok true -> true
          | _ ->
              Time_compat.sleep 0.05;
              acquire (attempts - 1)
      in
      if acquire 100 then
        Common.protect ~module_name:"room_utils" ~finally_label:"finalizer"
          ~finally:(fun () -> ignore (backend_release_lock config ~key ~owner))
          f
      else
        invalid_arg (Printf.sprintf "Failed to acquire distributed lock for key: %s (100 attempts exhausted)" key)

let with_file_lock_r config path f : ('a, masc_error) result =
  match key_of_path config path with
  | None ->
      (* Fix 2: Cooperative lock — same as with_file_lock *)
      File_lock_eio.with_lock path (fun () -> Ok (f ()))
  | Some key ->
      let owner = config.backend_config.node_id in
      let ttl_seconds = config.lock_expiry_minutes * 60 in
      let rec acquire attempts =
        if attempts <= 0 then false
        else
          match backend_acquire_lock config ~key ~ttl_seconds ~owner with
          | Ok true -> true
          | _ -> Time_compat.sleep 0.05; acquire (attempts - 1)
      in
      if acquire 100 then
        Common.protect ~module_name:"room_utils" ~finally_label:"finalizer"
          ~finally:(fun () -> ignore (backend_release_lock config ~key ~owner))
          (fun () -> Ok (f ()))
      else
        Error (IoError (Printf.sprintf "Failed to acquire distributed lock for %s" path))

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

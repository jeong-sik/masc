(** Backend_types - Shared types for Backend modules.

    Extracted to avoid circular dependency between
    Backend and Backend_pg.

    This module is the single source of truth for error types, config,
    and shared utilities used by all _eio backend implementations.
*)

(* ============================================ *)
(* Error Types                                  *)
(* ============================================ *)

type error =
  | NotFound of string
  | AlreadyExists of string
  | IOError of string
  | InvalidKey of string
  | ConnectionFailed of string
  | BackendNotSupported of string
[@@deriving show]

type 'a result = ('a, error) Stdlib.result

(* ============================================ *)
(* Backend Type                                 *)
(* ============================================ *)

type backend_type =
  | Memory
  | FileSystem
  | PostgresNative
[@@deriving show, eq]

(* ============================================ *)
(* Health Result                                *)
(* ============================================ *)

type health_result = {
  latency_ms: float;
  is_healthy: bool;
}

(* ============================================ *)
(* Config                                       *)
(* ============================================ *)

type config = {
  backend_type: backend_type;
  base_path: string;
  postgres_url: string option;
  node_id: string;
  cluster_name: string;
  pubsub_max_messages: int;
}

(** Get pubsub max messages from env or default *)
let pubsub_max_messages_from_env () =
  match Sys.getenv_opt "MASC_PUBSUB_MAX_MESSAGES" with
  | Some s -> Safe_ops.int_of_string_with_default ~default:1000 s
  | None -> 1000

let generate_node_id () =
  let hostname = try Unix.gethostname () with Unix.Unix_error _ -> "unknown" in
  let pid = Unix.getpid () in
  let hash = Hashtbl.hash (Unix.gettimeofday ()) land 0xFFFF in
  Printf.sprintf "%s-%d-%04x" hostname pid hash

let default_config = {
  backend_type = FileSystem;
  base_path = ".masc";
  postgres_url = None;
  node_id = generate_node_id ();
  cluster_name = "default";
  pubsub_max_messages = pubsub_max_messages_from_env ();
}

(* ============================================ *)
(* Status & Pool Statistics                     *)
(* ============================================ *)

let get_status config : Yojson.Safe.t =
  let backend_str = match config.backend_type with
    | Memory -> "memory"
    | FileSystem -> "filesystem"
    | PostgresNative -> "postgres_native"
  in
  `Assoc [
    ("backend_type", `String backend_str);
    ("base_path", `String config.base_path);
    ("node_id", `String config.node_id);
    ("cluster_name", `String config.cluster_name);
    ("postgres_url", match config.postgres_url with Some u -> `String u | None -> `Null);
  ]

type pool_stats = {
  max_size: int;
  pool_count: int;
  shared_pool_injected: bool;
}

let pool_stats_to_yojson (s : pool_stats) : Yojson.Safe.t =
  `Assoc [
    ("max_size", `Int s.max_size);
    ("pool_count", `Int s.pool_count);
    ("shared_pool_injected", `Bool s.shared_pool_injected);
  ]

let configured_max_pool_size () =
  match Sys.getenv_opt "MASC_PG_POOL_SIZE" with
  | Some s -> (try int_of_string s with Failure _ -> 5)
  | None -> 5

(* ============================================ *)
(* Safety Utilities                             *)
(* ============================================ *)

(** Validate TTL to prevent invalid durations.
    Returns sanitized TTL (minimum 1, maximum 86400 = 24h) *)
let validate_ttl ttl_seconds =
  if ttl_seconds <= 0 then 1
  else if ttl_seconds > 86400 then 86400
  else ttl_seconds

(** Safely parse JSON lock file, returning None on any error.
    Also removes corrupted files to allow recovery. *)
let safe_parse_lock_json file_path =
  if not (Sys.file_exists file_path) then None
  else
    try
      let content = In_channel.with_open_text file_path In_channel.input_all in
      if String.length content = 0 then begin
        Safe_ops.remove_file_logged ~context:"backend_lock" file_path;
        None
      end else
        let json = Yojson.Safe.from_string content in
        let open Yojson.Safe.Util in
        let parse_float_field field =
          match json |> member field with
          | `Float f -> Some f
          | `Int i -> Some (float_of_int i)
          | `Intlit s -> float_of_string_opt s
          | `String s -> float_of_string_opt s
          | _ -> None
        in
        let parse_string_field field =
          match json |> member field with
          | `String s -> Some s
          | _ -> None
        in
        match parse_string_field "owner", parse_float_field "expires_at" with
        | Some own, Some exp -> Some (own, exp)
        | _ ->
            Safe_ops.remove_file_logged ~context:"backend_lock" file_path;
            None
    with
    | _ ->
        Safe_ops.remove_file_logged ~context:"backend_lock" file_path;
        None

(** Acquire exclusive file lock using Unix.lockf.
    Returns true if lock acquired, false if would block. *)
let acquire_flock fd =
  try
    Unix.lockf fd Unix.F_TLOCK 0;
    true
  with
  | Unix.Unix_error (Unix.EAGAIN, _, _)
  | Unix.Unix_error (Unix.EACCES, _, _) -> false
  | _ -> false

(** Release file lock *)
let release_flock fd =
  try Unix.lockf fd Unix.F_ULOCK 0
  with Unix.Unix_error (err, _, _) ->
    Log.Misc.error "Failed to release flock: %s" (Unix.error_message err)

(* ============================================ *)
(* In-Memory Pub/Sub (shared by Memory + FS)    *)
(* ============================================ *)

module Pubsub_mem = struct
  type t = {
    subscribers: (string, (string -> unit) list) Hashtbl.t;
  }

  let create () = { subscribers = Hashtbl.create 16 }

  let publish t ~channel ~message =
    match Hashtbl.find_opt t.subscribers channel with
    | None -> Ok 0
    | Some callbacks ->
        List.iter (fun cb ->
          try cb message with Eio.Cancel.Cancelled _ as e -> raise e | exn ->
            Log.Backend.warn "subscriber callback failed: %s" (Printexc.to_string exn)
        ) callbacks;
        Ok (List.length callbacks)

  let subscribe t ~channel ~callback =
    let existing = match Hashtbl.find_opt t.subscribers channel with
      | Some cbs -> cbs | None -> []
    in
    Hashtbl.replace t.subscribers channel (callback :: existing);
    Ok ()
end

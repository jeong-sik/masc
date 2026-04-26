(** Backend_types - Shared types for Backend modules.

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
[@@deriving show, eq]

(* ============================================ *)
(* Health Result                                *)
(* ============================================ *)

type health_result =
  { latency_ms : float
  ; is_healthy : bool
  }

(* ============================================ *)
(* Config                                       *)
(* ============================================ *)

type config =
  { backend_type : backend_type
  ; base_path : string
  ; node_id : string
  ; cluster_name : string
  ; pubsub_max_messages : int
  }

let pubsub_max_messages_from_env () = 1000

let generate_node_id () =
  let hostname =
    try Unix.gethostname () with
    | Unix.Unix_error _ -> "unknown"
  in
  let pid = Unix.getpid () in
  let hash = Hashtbl.hash (Unix.gettimeofday ()) land 0xFFFF in
  Printf.sprintf "%s-%d-%04x" hostname pid hash
;;

let default_config =
  { backend_type = FileSystem
  ; base_path = Common.masc_dirname
  ; node_id = generate_node_id ()
  ; cluster_name = "default"
  ; pubsub_max_messages = pubsub_max_messages_from_env ()
  }
;;

(* ============================================ *)
(* Status                                        *)
(* ============================================ *)

let get_status config : Yojson.Safe.t =
  let backend_str =
    match config.backend_type with
    | Memory -> "memory"
    | FileSystem -> "filesystem"
  in
  `Assoc
    [ "backend_type", `String backend_str
    ; "base_path", `String config.base_path
    ; "node_id", `String config.node_id
    ; "cluster_name", `String config.cluster_name
    ]
;;

(* ============================================ *)
(* Safety Utilities                             *)
(* ============================================ *)

(** Validate TTL to prevent invalid durations.
    Returns sanitized TTL (minimum 1, maximum 86400 = 24h) *)
let validate_ttl ttl_seconds =
  if ttl_seconds <= 0
  then 1
  else if ttl_seconds > Masc_time_constants.day_int
  then Masc_time_constants.day_int
  else ttl_seconds
;;

(** Acquire exclusive file lock using Unix.lockf.
    Returns true if lock acquired, false if would block. *)
let acquire_flock fd =
  try
    Unix.lockf fd Unix.F_TLOCK 0;
    true
  with
  | Unix.Unix_error (Unix.EAGAIN, _, _) | Unix.Unix_error (Unix.EACCES, _, _) -> false
  | _ -> false
;;

(** Release file lock *)
let release_flock fd =
  try Unix.lockf fd Unix.F_ULOCK 0 with
  | Unix.Unix_error (err, _, _) ->
    Log.Misc.error "Failed to release flock: %s" (Unix.error_message err)
;;

(* ============================================ *)
(* In-Memory Pub/Sub (shared by Memory + FS)    *)
(* ============================================ *)

module Pubsub_mem = struct
  type t = { subscribers : (string, (string -> unit) list) Hashtbl.t }

  let create () = { subscribers = Hashtbl.create 16 }

  let publish t ~channel ~message =
    match Hashtbl.find_opt t.subscribers channel with
    | None -> Ok 0
    | Some callbacks ->
      List.iter
        (fun cb ->
           try cb message with
           | Eio.Cancel.Cancelled _ as e -> raise e
           | exn ->
             Log.Backend.warn "subscriber callback failed: %s" (Printexc.to_string exn))
        callbacks;
      Ok (List.length callbacks)
  ;;

  let subscribe t ~channel ~callback =
    let existing =
      match Hashtbl.find_opt t.subscribers channel with
      | Some cbs -> cbs
      | None -> []
    in
    Hashtbl.replace t.subscribers channel (callback :: existing);
    Ok ()
  ;;
end

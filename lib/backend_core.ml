(** Backend Module - Storage abstraction for MASC (Memory/FileSystem/PostgreSQL) *)

(* ============================================ *)
(* Backend Types                                *)
(* ============================================ *)

type backend_type =
  | Memory
  | FileSystem
  | PostgresNative  (* Eio-native PostgreSQL via caqti-eio *)
[@@deriving show, eq]

type error =
  | ConnectionFailed of string
  | KeyNotFound of string
  | OperationFailed of string
  | BackendNotSupported of string
  | InvalidKey of string
[@@deriving show]

type config = {
  backend_type: backend_type;
  base_path: string;
  postgres_url: string option;  (* PostgreSQL connection URL for PostgresNative backend *)
  node_id: string;
  cluster_name: string;
  pubsub_max_messages: int;     (* Max messages per channel before LTRIM, default: 1000 *)
}

(** Get pubsub max messages from env or default *)
let pubsub_max_messages_from_env () =
  match Sys.getenv_opt "MASC_PUBSUB_MAX_MESSAGES" with
  | Some s -> Safe_ops.int_of_string_with_default ~default:1000 s
  | None -> 1000

let generate_node_id () =
  let hostname = try Unix.gethostname () with Unix.Unix_error _ -> "unknown" in
  let pid = Unix.getpid () in
  let rand = Random.int 10000 in
  Printf.sprintf "%s-%d-%04d" hostname pid rand

let default_config = {
  backend_type = FileSystem;
  base_path = ".masc";
  postgres_url = None;
  node_id = generate_node_id ();
  cluster_name = "default";
  pubsub_max_messages = pubsub_max_messages_from_env ();
}

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

(* ============================================ *)
(* Backend Interface                            *)
(* ============================================ *)

module type BACKEND = sig
  type t

  val create : config -> (t, error) result
  val close : t -> unit

  (* Basic KV operations *)
  val get : t -> key:string -> (string option, error) result
  val set : t -> key:string -> value:string -> (unit, error) result
  val delete : t -> key:string -> (bool, error) result
  val exists : t -> key:string -> bool

  (* List operations *)
  val list_keys : t -> prefix:string -> (string list, error) result
  val get_all : t -> prefix:string -> ((string * string) list, error) result

  (* Atomic operations *)
  val set_if_not_exists : t -> key:string -> value:string -> (bool, error) result
  val compare_and_swap : t -> key:string -> expected:string -> value:string -> (bool, error) result

  (* Distributed locking *)
  val acquire_lock : t -> key:string -> ttl_seconds:int -> owner:string -> (bool, error) result
  val release_lock : t -> key:string -> owner:string -> (bool, error) result
  val extend_lock : t -> key:string -> ttl_seconds:int -> owner:string -> (bool, error) result

  (* Pub/Sub (optional, not all backends support) *)
  val publish : t -> channel:string -> message:string -> (int, error) result
  val subscribe : t -> channel:string -> callback:(string -> unit) -> (unit, error) result

  (* Health check *)
  val health_check : t -> (bool, error) result
end

(* ============================================ *)
(* Safety Utilities                             *)
(* ============================================ *)
(* NOTE: validate_key is defined locally in each backend module.
   These utilities are for cross-cutting concerns. *)

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
        (* Empty file is corrupted - remove it *)
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
        (* Corrupted JSON file - remove it to allow recovery *)
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
          try cb message with _ -> ()
        ) callbacks;
        Ok (List.length callbacks)

  let subscribe t ~channel ~callback =
    let existing = match Hashtbl.find_opt t.subscribers channel with
      | Some cbs -> cbs | None -> []
    in
    Hashtbl.replace t.subscribers channel (callback :: existing);
    Ok ()
end

(* ============================================ *)
(* Memory Backend (In-Process)                  *)
(* ============================================ *)

module MemoryBackend : BACKEND = struct
  type lock_info = {
    owner: string;
    expires_at: float;
  }

  type t = {
    data: (string, string) Hashtbl.t;
    locks: (string, lock_info) Hashtbl.t;
    pubsub: Pubsub_mem.t;
    mutex: Eio.Mutex.t;
  }

  let stdlib_mutex = Stdlib.Mutex.create ()

  let with_lock t f =
    match
      Eio.Mutex.use_rw ~protect:true t.mutex (fun () -> f ())
    with
    | result -> result
    | exception Effect.Unhandled _ ->
        Stdlib.Mutex.lock stdlib_mutex;
        Fun.protect ~finally:(fun () -> Stdlib.Mutex.unlock stdlib_mutex) f

  let create (_cfg : config) : (t, error) result =
    Ok {
      data = Hashtbl.create 1000;
      locks = Hashtbl.create 100;
      pubsub = Pubsub_mem.create ();
      mutex = Eio.Mutex.create ();
    }

  let close _t = ()

  let get t ~key =
    with_lock t (fun () ->
      Ok (Hashtbl.find_opt t.data key)
    )

  let set t ~key ~value =
    with_lock t (fun () ->
      Hashtbl.replace t.data key value;
      Ok ()
    )

  let delete t ~key =
    with_lock t (fun () ->
      let existed = Hashtbl.mem t.data key in
      Hashtbl.remove t.data key;
      Ok existed
    )

  let exists t ~key =
    with_lock t (fun () ->
      Hashtbl.mem t.data key
    )

  let list_keys t ~prefix =
    with_lock t (fun () ->
      let keys = Hashtbl.fold (fun k _ acc ->
        if String.length k >= String.length prefix &&
           String.sub k 0 (String.length prefix) = prefix
        then k :: acc
        else acc
      ) t.data [] in
      Ok (List.sort compare keys)
    )

  let get_all t ~prefix =
    with_lock t (fun () ->
      let pairs = Hashtbl.fold (fun k v acc ->
        if String.length k >= String.length prefix &&
           String.sub k 0 (String.length prefix) = prefix
        then (k, v) :: acc
        else acc
      ) t.data [] in
      Ok (List.sort (fun (a, _) (b, _) -> compare a b) pairs)
    )

  let set_if_not_exists t ~key ~value =
    with_lock t (fun () ->
      if Hashtbl.mem t.data key then
        Ok false
      else begin
        Hashtbl.add t.data key value;
        Ok true
      end
    )

  let compare_and_swap t ~key ~expected ~value =
    with_lock t (fun () ->
      match Hashtbl.find_opt t.data key with
      | Some current when current = expected ->
          Hashtbl.replace t.data key value;
          Ok true
      | _ ->
          Ok false
    )

  let acquire_lock t ~key ~ttl_seconds ~owner =
    with_lock t (fun () ->
      let now = Time_compat.now () in
      match Hashtbl.find_opt t.locks key with
      | Some lock when lock.expires_at > now && lock.owner <> owner ->
          Ok false  (* Locked by someone else *)
      | _ ->
          let expires_at = now +. float_of_int ttl_seconds in
          Hashtbl.replace t.locks key { owner; expires_at };
          Ok true
    )

  let release_lock t ~key ~owner =
    with_lock t (fun () ->
      match Hashtbl.find_opt t.locks key with
      | Some lock when lock.owner = owner ->
          Hashtbl.remove t.locks key;
          Ok true
      | _ ->
          Ok false
    )

  let extend_lock t ~key ~ttl_seconds ~owner =
    with_lock t (fun () ->
      match Hashtbl.find_opt t.locks key with
      | Some lock when lock.owner = owner ->
          let expires_at = Time_compat.now () +. float_of_int ttl_seconds in
          Hashtbl.replace t.locks key { lock with expires_at };
          Ok true
      | _ ->
          Ok false
    )

  let publish t ~channel ~message =
    with_lock t (fun () -> Pubsub_mem.publish t.pubsub ~channel ~message)

  let subscribe t ~channel ~callback =
    with_lock t (fun () -> Pubsub_mem.subscribe t.pubsub ~channel ~callback)

  let health_check _t = Ok true
end

(* ============================================ *)
(* FileSystem Backend                           *)
(* ============================================ *)


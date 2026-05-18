(** In-memory backend implementation used by tests and local ephemeral state. *)

open Backend_types

type t = {
  data: (string, string) Hashtbl.t;
  mutex: Eio.Mutex.t;
}

(** Eio_guard-based dual-mode mutex for pre/post Eio runtime.
    Skips locking when Eio runtime is not yet active (e.g. unit tests). *)
let with_lock t f = Eio_guard.with_mutex t.mutex f

let create () = {
  data = Hashtbl.create 64;
  mutex = Eio.Mutex.create ();
}

(* Shared instances keyed by base_path; ensures multiple configs for the
   same directory share state (matching FileSystem backend semantics).
   Used by tests that create multiple Coord.default_config for one tmpdir. *)
let shared_instances : (string, t) Hashtbl.t = Hashtbl.create 8

let get_or_create ~base_path =
  match Hashtbl.find_opt shared_instances base_path with
  | Some t -> t
  | None ->
    let t = create () in
    Hashtbl.replace shared_instances base_path t;
    t

let get t key =
  with_lock t (fun () ->
    match Hashtbl.find_opt t.data key with
    | Some v -> Ok v
    | None -> Error (NotFound key))

let set t key value =
  with_lock t (fun () ->
    Hashtbl.replace t.data key value;
    Ok ())

let exists t key =
  with_lock t (fun () ->
    Hashtbl.mem t.data key)

let delete t key =
  with_lock t (fun () ->
    if Hashtbl.mem t.data key
    then (
      Hashtbl.remove t.data key;
      Ok ())
    else Error (NotFound key))

let list_keys t ~prefix =
  with_lock t (fun () ->
    let keys =
      Hashtbl.fold
        (fun k _ acc -> if String.starts_with k ~prefix then k :: acc else acc)
        t.data
        []
    in
    Ok keys)

let get_all t ~prefix =
  with_lock t (fun () ->
    let pairs =
      Hashtbl.fold
        (fun k v acc -> if String.starts_with ~prefix k then (k, v) :: acc else acc)
        t.data
        []
    in
    Ok pairs)

let set_if_not_exists t key value =
  with_lock t (fun () ->
    if Hashtbl.mem t.data key
    then Ok false
    else (
      Hashtbl.replace t.data key value;
      Ok true))

let clear t =
  with_lock t (fun () ->
    Hashtbl.clear t.data)

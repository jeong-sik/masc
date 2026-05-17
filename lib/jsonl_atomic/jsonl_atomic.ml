(** RFC-0107: in-process atomic JSONL append writer. *)

type t = {
  path : string;
  mutex : Eio.Mutex.t;
  sink : Eio.File.rw_ty Eio.Resource.t;
  mutable closed : bool;
}

(* Per-path Eio.Mutex registry. Keyed by absolute or canonical path
   string. Two writers for the same path share the same mutex; the
   sink (fd) is per-writer. *)
let mutex_registry : (string, Eio.Mutex.t) Hashtbl.t = Hashtbl.create 16
let mutex_registry_mu = Stdlib.Mutex.create ()

let get_or_create_mutex path =
  Stdlib.Mutex.lock mutex_registry_mu;
  Fun.protect
    ~finally:(fun () -> Stdlib.Mutex.unlock mutex_registry_mu)
    (fun () ->
      match Hashtbl.find_opt mutex_registry path with
      | Some m -> m
      | None ->
        let m = Eio.Mutex.create () in
        Hashtbl.add mutex_registry path m;
        m)

(* Recursive mkdir. Pure Unix to avoid Fs_compat dependency cycle
   (Fs_compat may transition to use Jsonl_atomic later). *)
let rec mkdir_p_unix dir =
  if dir = "" || dir = "." || dir = "/" then ()
  else
    try Unix.mkdir dir 0o755
    with
    | Unix.Unix_error (Unix.EEXIST, _, _) -> ()
    | Unix.Unix_error (Unix.ENOENT, _, _) ->
      mkdir_p_unix (Filename.dirname dir);
      (try Unix.mkdir dir 0o755 with
       | Unix.Unix_error (Unix.EEXIST, _, _) -> ())

let open_writer ~sw ~fs ~path =
  let dir = Filename.dirname path in
  if dir <> "" && dir <> "." && dir <> "/" then mkdir_p_unix dir;
  let eio_path = Eio.Path.(fs / path) in
  let sink =
    Eio.Path.open_out
      ~sw
      ~append:true
      ~create:(`If_missing 0o644)
      eio_path
  in
  {
    path;
    mutex = get_or_create_mutex path;
    sink;
    closed = false;
  }

let append t json =
  if t.closed then Error (`Io "writer closed")
  else
    Eio.Mutex.use_ro t.mutex (fun () ->
      try
        let line = Yojson.Safe.to_string json ^ "\n" in
        Eio.Flow.copy_string line t.sink;
        Ok ()
      with
      | Eio.Io _ as exn -> Error (`Io (Printexc.to_string exn))
      | exn -> Error (`Io (Printexc.to_string exn)))

let close t =
  if not t.closed then begin
    t.closed <- true;
    (* Eio.Resource.close releases the fd. Idempotent on the resource
       side too, but we guard with [t.closed] for cheap short-circuit. *)
    try Eio.Resource.close t.sink with _ -> ()
  end

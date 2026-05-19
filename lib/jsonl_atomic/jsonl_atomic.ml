(** RFC-0107: in-process atomic JSONL append writer. *)

type t = {
  path : string;
  mutex : Eio.Mutex.t;
  sink : Eio.File.rw_ty Eio.Resource.t;
  mutable closed : bool;
}

(* Per-path Eio.Mutex registry. Keyed by the *canonicalized* path so
   that two writers naming the same file through different spellings
   (e.g. ["logs/out.jsonl"] vs ["./logs/out.jsonl"], or with
   intervening ["a/../b"] segments) share the same mutex. The sink
   (fd) is per-writer. *)
let mutex_registry : (string, Eio.Mutex.t) Hashtbl.t = Hashtbl.create 16
let mutex_registry_mu = Stdlib.Mutex.create ()

(* Resolve ["." ] and [".."] segments without requiring file existence
   (so [open_writer] can canonicalize before the file is created).
   Relative paths are anchored at the process cwd at call time. This
   collapses the common spelling variants flagged by Codex review of
   PR #15906; symlink resolution is intentionally out of scope (would
   need [realpath] which fails on missing paths). *)
let canonicalize_path path =
  let absolute =
    if Filename.is_relative path
    then Filename.concat (Sys.getcwd ()) path
    else path
  in
  let parts = String.split_on_char '/' absolute in
  let acc =
    List.fold_left
      (fun acc seg ->
        match seg, acc with
        | "", [] -> [""] (* preserve leading "/" *)
        | "", _ -> acc (* squash "//" *)
        | ".", _ -> acc
        | "..", _ :: tl -> tl
        | "..", [] -> []
        | s, _ -> s :: acc)
      []
      parts
  in
  let joined = String.concat "/" (List.rev acc) in
  if joined = "" then "/" else joined

let get_or_create_mutex key =
  Stdlib.Mutex.lock mutex_registry_mu;
  Fun.protect
    ~finally:(fun () -> Stdlib.Mutex.unlock mutex_registry_mu)
    (fun () ->
      match Hashtbl.find_opt mutex_registry key with
      | Some m -> m
      | None ->
        let m = Eio.Mutex.create () in
        Hashtbl.add mutex_registry key m;
        m)

let warn_io_failure ~op ~path exn =
  Log.warn ~ctx:"jsonl_atomic" "%s failed for %s: %s" op path (Printexc.to_string exn)

let open_writer ~sw ~fs ~path =
  (* Create parent directories *within the provided fs root* — using
     [Eio.Path.mkdirs] on the fs-scoped path matches how [open_out]
     below resolves the same path. The previous [Unix.mkdir] sibling
     resolved against process cwd, which is wrong for scoped fs
     handles (flagged by Codex review of PR #15906). *)
  let dir = Filename.dirname path in
  if dir <> "" && dir <> "." && dir <> "/" then begin
    let eio_dir = Eio.Path.(fs / dir) in
    try Eio.Path.mkdirs ~exists_ok:true ~perm:0o755 eio_dir with
    | Eio.Cancel.Cancelled _ as exn -> raise exn
    | exn -> warn_io_failure ~op:"mkdirs" ~path:dir exn
  end;
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
    mutex = get_or_create_mutex (canonicalize_path path);
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
    try Eio.Resource.close t.sink with
    | Eio.Cancel.Cancelled _ as exn -> raise exn
    | exn -> warn_io_failure ~op:"close" ~path:t.path exn
  end

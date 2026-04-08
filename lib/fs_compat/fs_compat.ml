(** Filesystem Compatibility Layer - Eio-native I/O with fallback

    Provides a unified filesystem API for gradual migration from
    blocking Unix I/O to Eio.Path operations.

    Usage:
    1. At server startup: [Fs_compat.set_fs (Eio.Stdenv.fs env)]
    2. In code: [Fs_compat.load_file path] instead of [open_in ...]

    When fs is not set (non-Eio contexts), falls back to blocking Unix I/O.
    This allows incremental migration without changing all call sites at once.

    @since 2026-02 - Keeper Emergent Identity v2.0
*)

(** Global fs — WORM Atomic (write-once at startup, read from any domain).
    Using Atomic.t is required for OCaml 5 multi-domain safety:
    Executor_pool workers run on a separate domain and read this value. *)
let global_fs : Eio.Fs.dir_ty Eio.Path.t option Atomic.t = Atomic.make None

(** Set the global Eio filesystem. Call once at server startup.
    @param fs The Eio fs from [Eio.Stdenv.fs env] *)
let set_fs fs =
  Atomic.set global_fs (Some fs)

(** Clear the global fs (testing/shutdown only — not called in production).
    Safe because test runners and shutdown are single-fiber sequential. *)
let clear_fs () =
  Atomic.set global_fs None

let get_fs_opt () =
  Atomic.get global_fs

(** Check if Eio fs is available *)
let has_fs () =
  Option.is_some (Atomic.get global_fs)

(** Normalize [Eio.Io] to [Sys_error] so callers only need one catch.
    Eio operations raise [Eio.Io _] on permission errors, missing files, etc.
    Stdlib I/O already raises [Sys_error], so wrapping only the Eio branch
    keeps the exception contract uniform. *)
let with_io ~path f =
  try f ()
  with Eio.Io _ as e ->
    raise (Sys_error (Printf.sprintf "%s: %s" path (Printexc.to_string e)))

let with_fs_or_fallback ~path ~fallback f =
  match Atomic.get global_fs with
  | Some fs -> (
      try with_io ~path (fun () -> f fs)
      with Stdlib.Effect.Unhandled _ -> fallback ())
  | None -> fallback ()

let load_file_unix (path : string) : string =
  let ic = open_in path in
  Fun.protect ~finally:(fun () -> close_in ic) (fun () ->
    let len = in_channel_length ic in
    really_input_string ic len
  )

let save_file_unix (path : string) (content : string) : unit =
  let oc = open_out path in
  Fun.protect ~finally:(fun () -> close_out oc) (fun () ->
    output_string oc content
  )

let append_file_unix (path : string) (content : string) : unit =
  let oc = open_out_gen [Open_append; Open_creat] 0o644 path in
  Fun.protect ~finally:(fun () -> close_out oc) (fun () ->
    output_string oc content
  )

let mkdir_p_unix (path : string) : unit =
  let rec ensure_dir (p : string) : unit =
    if p = "" || p = "." || p = "/" then ()
    else if Sys.file_exists p then ()
    else begin
      ensure_dir (Filename.dirname p);
      try Unix.mkdir p 0o755 with Unix.Unix_error (Unix.EEXIST, _, _) -> ()
    end
  in
  ensure_dir path

(** Load entire file contents as string.
    Eio-native when available, fallback to Unix.
    @raises Sys_error on all I/O failures. Eio.Io is normalized internally. *)
let load_file (path : string) : string =
  with_fs_or_fallback ~path ~fallback:(fun () -> load_file_unix path) (fun fs ->
      let eio_path = Eio.Path.(fs / path) in
      Eio.Path.load eio_path)

(** Save string to file (overwrite).
    Eio-native when available, fallback to Unix.
    @raises Sys_error on all I/O failures. Eio.Io is normalized internally. *)
let save_file (path : string) (content : string) : unit =
  with_fs_or_fallback ~path ~fallback:(fun () -> save_file_unix path content) (fun fs ->
      let eio_path = Eio.Path.(fs / path) in
      Eio.Path.save ~create:(`Or_truncate 0o644) eio_path content)

let save_file_atomic (path : string) (content : string) : (unit, string) result =
  let dir = Filename.dirname path in
  let tmp = Filename.temp_file ~temp_dir:dir ".atomic_" ".tmp" in
  try
    save_file tmp content;
    Sys.rename tmp path;
    Ok ()
  with
  | Eio.Cancel.Cancelled _ as e ->
    (try Sys.remove tmp with Sys_error _ -> ());
    raise e
  | exn ->
    (try Sys.remove tmp with Sys_error _ -> ());
    Error (Printf.sprintf "save_file_atomic %s: %s" path (Printexc.to_string exn))

(** Append string to file.
    Eio-native when available, fallback to Unix.
    @raises Sys_error on all I/O failures. Eio.Io is normalized internally. *)
let append_file (path : string) (content : string) : unit =
  with_fs_or_fallback ~path ~fallback:(fun () -> append_file_unix path content) (fun fs ->
      let eio_path = Eio.Path.(fs / path) in
      Eio.Path.save ~append:true ~create:(`If_missing 0o644) eio_path content)

(** Check if file exists.
    Uses Sys.file_exists (works in both Eio and non-Eio contexts). *)
let file_exists (path : string) : bool =
  Sys.file_exists path

(** Create directory recursively if not exists.
    @raises Sys_error on all I/O failures. Eio.Io is normalized internally. *)
let mkdir_p (path : string) : unit =
  with_fs_or_fallback ~path ~fallback:(fun () -> mkdir_p_unix path) (fun fs ->
      let eio_path = Eio.Path.(fs / path) in
      Eio.Path.mkdirs ~exists_ok:true ~perm:0o755 eio_path)

(** Load JSONL file as list of JSON values.
    Filters out malformed lines. *)
let load_jsonl (path : string) : Yojson.Safe.t list =
  if not (file_exists path) then []
  else
    let content = load_file path in
    String.split_on_char '\n' content
    |> List.filter (fun line -> String.length (String.trim line) > 0)
    |> List.filter_map (fun line ->
        try Some (Yojson.Safe.from_string line)
        with Yojson.Json_error _ -> None)

(** Append JSON value as line to JSONL file. *)
let append_jsonl (path : string) (json : Yojson.Safe.t) : unit =
  let dir = Filename.dirname path in
  mkdir_p dir;
  let line = Yojson.Safe.to_string json ^ "\n" in
  append_file path line

(* ================================================================ *)
(* Storage Backend Abstraction                                      *)
(* ================================================================ *)

type backend_kind =
  | Local
  | Remote of string

type backend = {
  kind : backend_kind;
  base_path : string;
}

let create_backend ?(kind = Local) ~base_path () =
  { kind; base_path }

let backend_base_path (b : backend) =
  b.base_path

let backend_kind_to_string = function
  | Local -> "local"
  | Remote url -> Printf.sprintf "remote(%s)" url

let default_backend ~base_path =
  { kind = Local; base_path }

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

(* #9921: defense-in-depth write-boundary guard.

   [Env_config_core.base_path_prod_guard] stops HOME fallback during path
   resolution.  This stops writes when the resolved path nevertheless
   points under HOME — any code that caches a stale [base_path ()] result
   or builds a HOME-relative path directly hits this gate before the
   write lands on the production ledger.

   The prod ledger observed 106 test-pattern rows
   ([hot-voter-*], [flipper], [same-voter], [judge]) written pre-#9920.
   This guard prevents regression if any new code path slips past the
   resolution guard.

   Active only for test executables (basename starts with [test_]).
   Escape hatch [MASC_TEST_ALLOW_HOME_BASE_PATH=1] matches
   [base_path_prod_guard] for the rare test that legitimately writes
   under HOME.  Reads remain unguarded — this is about preventing
   silent corruption, not restricting observability. *)
exception Test_isolation_breach of string

let test_exec_home_guard ~op path =
  let basename =
    Sys.executable_name |> Filename.basename |> String.lowercase_ascii
  in
  let is_test_exec =
    String.length basename >= 5 && String.sub basename 0 5 = "test_"
  in
  if not is_test_exec then ()
  else
    let allow =
      match Sys.getenv_opt "MASC_TEST_ALLOW_HOME_BASE_PATH" with
      | Some v ->
          let v = String.lowercase_ascii (String.trim v) in
          v = "1" || v = "true" || v = "yes"
      | None -> false
    in
    if allow then ()
    else
      match Sys.getenv_opt "HOME" with
      | None | Some "" -> ()
      | Some home ->
          let home_norm =
            let trimmed = String.trim home in
            let len = String.length trimmed in
            if len > 1 && trimmed.[len - 1] = '/' then
              String.sub trimmed 0 (len - 1)
            else
              trimmed
          in
          let home_len = String.length home_norm in
          if home_len > 0
             && String.length path >= home_len
             && String.sub path 0 home_len = home_norm then
            raise (Test_isolation_breach
              (Printf.sprintf
                 "#9921 %s blocked under HOME=%S (path=%S) in test executable %S. \
                  MASC_BASE_PATH override did not apply — fix the test setup or \
                  set MASC_TEST_ALLOW_HOME_BASE_PATH=1."
                 op home_norm path
                 (Filename.basename Sys.executable_name)))

let with_fs_or_fallback ~path ~fallback f =
  match Atomic.get global_fs with
  | Some fs -> (
      try with_io ~path (fun () -> f fs)
      with Stdlib.Effect.Unhandled _ -> fallback ())
  | None -> fallback ()

let load_file_unix (path : string) : string =
  let ic = open_in path in
  Fun.protect ~finally:(fun () -> close_in_noerr ic) (fun () ->
    let len = in_channel_length ic in
    really_input_string ic len
  )

let save_file_unix (path : string) (content : string) : unit =
  let oc = open_out path in
  Fun.protect ~finally:(fun () -> close_out_noerr oc) (fun () ->
    output_string oc content
  )

let append_file_unix (path : string) (content : string) : unit =
  let oc = open_out_gen [Open_append; Open_creat] 0o644 path in
  Fun.protect ~finally:(fun () -> close_out_noerr oc) (fun () ->
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
  test_exec_home_guard ~op:"save_file" path;
  with_fs_or_fallback ~path ~fallback:(fun () -> save_file_unix path content) (fun fs ->
      let eio_path = Eio.Path.(fs / path) in
      Eio.Path.save ~create:(`Or_truncate 0o644) eio_path content)

(* Durable atomic write: tmp → fsync(tmp) → rename → fsync(parent dir).
   Without the fsync pair, a crash between the rename and the kernel's
   dirty-page flush can leave the target truncated or zero-length — exactly
   what we observed on backlog.json after an abrupt shutdown (2026-04-18). *)
let fsync_path path =
  let fd = Unix.openfile path [ Unix.O_RDONLY ] 0 in
  Fun.protect
    ~finally:(fun () -> try Unix.close fd with Eio.Cancel.Cancelled _ as e -> raise e | exn -> Printf.eprintf "[fs_compat] fsync_path close failed: %s\n%!" (Printexc.to_string exn))
    (fun () ->
      try Unix.fsync fd
      with Unix.Unix_error ((Unix.EINVAL | Unix.EOPNOTSUPP), _, _) ->
        (* Some filesystems (tmpfs on some kernels) reject fsync. The data
           is still durable to the extent the underlying FS offers. *)
        ())

let save_file_atomic (path : string) (content : string) : (unit, string) result =
  let dir = Filename.dirname path in
  let tmp = Filename.temp_file ~temp_dir:dir ".atomic_" ".tmp" in
  try
    save_file tmp content;
    fsync_path tmp;
    Sys.rename tmp path;
    (try fsync_path dir with Unix.Unix_error _ -> ());
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
  test_exec_home_guard ~op:"append_file" path;
  with_fs_or_fallback ~path ~fallback:(fun () -> append_file_unix path content) (fun fs ->
      let eio_path = Eio.Path.(fs / path) in
      Eio.Path.save ~append:true ~create:(`If_missing 0o644) eio_path content)

(** Check if file exists.
    Uses Sys.file_exists (works in both Eio and non-Eio contexts). *)
let file_exists (path : string) : bool =
  with_fs_or_fallback ~path ~fallback:(fun () -> Sys.file_exists path) (fun fs ->
    try
      let _ = Eio.Path.stat ~follow:true Eio.Path.(fs / path) in true
    with Eio.Io _ -> false)

let file_size (path : string) : int option =
  with_fs_or_fallback ~path
    ~fallback:(fun () -> try Some (Unix.stat path).st_size with Unix.Unix_error _ -> None)
    (fun _fs ->
      try Some (Eio_unix.run_in_systhread (fun () -> (Unix.stat path).st_size))
      with Unix.Unix_error _ -> None)

let file_mtime (path : string) : float option =
  with_fs_or_fallback ~path
    ~fallback:(fun () -> try Some (Unix.stat path).st_mtime with Unix.Unix_error _ -> None)
    (fun _fs ->
      try Some (Eio_unix.run_in_systhread (fun () -> (Unix.stat path).st_mtime))
      with Unix.Unix_error _ -> None)


let rename (src : string) (dst : string) : unit =
  with_fs_or_fallback ~path:src ~fallback:(fun () -> Sys.rename src dst) (fun fs ->
    Eio.Path.rename Eio.Path.(fs / src) Eio.Path.(fs / dst))

let rmdir (path : string) : unit =
  with_fs_or_fallback ~path ~fallback:(fun () -> Unix.rmdir path) (fun fs ->
    Eio.Path.rmdir Eio.Path.(fs / path))

let realpath (path : string) : string =
  with_fs_or_fallback ~path
    ~fallback:(fun () -> Unix.realpath path)
    (fun _fs ->
      Eio_unix.run_in_systhread (fun () -> Unix.realpath path))

(** Create directory recursively if not exists.
    @raises Sys_error on all I/O failures. Eio.Io is normalized internally. *)
let mkdir_p (path : string) : unit =
  test_exec_home_guard ~op:"mkdir_p" path;
  with_fs_or_fallback ~path ~fallback:(fun () -> mkdir_p_unix path) (fun fs ->
      let eio_path = Eio.Path.(fs / path) in
      Eio.Path.mkdirs ~exists_ok:true ~perm:0o755 eio_path)

(** Parse pre-read string lines as JSONL.
    Use when lines come from [Keeper_memory.read_file_tail_lines] or
    other non-file sources.  Logs malformed lines with [source] tag. *)
let parse_jsonl_lines ~(source : string) (lines : string list)
    : Yojson.Safe.t list * int =
  let malformed = ref 0 in
  let parsed =
    List.filter_map (fun line ->
      let trimmed = String.trim line in
      if trimmed = "" then None
      else
        match Yojson.Safe.from_string trimmed with
        | json -> Some json
        | exception Yojson.Json_error msg ->
            incr malformed;
            Printf.eprintf "[fs_compat] malformed JSONL (%s): %s\n%!" source msg;
            None
    ) lines
  in
  (parsed, !malformed)

(** Load JSONL file, returning parsed values and count of malformed lines.
    Delegates to [parse_jsonl_lines] for the actual parsing. *)
let load_jsonl_diagnostics (path : string) : Yojson.Safe.t list * int =
  if not (file_exists path) then ([], 0)
  else
    let content = load_file path in
    let lines = String.split_on_char '\n' content in
    parse_jsonl_lines ~source:(Filename.basename path) lines

(** Load JSONL file as list of JSON values.
    Malformed lines are logged and dropped. *)
let load_jsonl (path : string) : Yojson.Safe.t list =
  fst (load_jsonl_diagnostics path)

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

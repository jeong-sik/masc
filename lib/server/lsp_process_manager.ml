(** LSP Process Manager — spawn and manage language server processes.

    Handles the lifecycle of LSP server child processes:
    - Spawn via [Eio.Process] with stdin/stdout pipes
    - LSP JSON-RPC framing: [Content-Length] header parsing on stdout
    - Structured cleanup via [Eio.Switch]
    - Per-language command resolution *)

type lsp_process =
  { lang_id : string
  ; proc : Eio_unix.Process.ty Eio.Std.r
  ; stdin_w : [ Eio.Flow.sink_ty | Eio.Resource.close_ty ] Eio.Std.r
  ; stdout_r : [ Eio.Flow.source_ty | Eio.Resource.close_ty ] Eio.Std.r
  ; stderr_r : [ Eio.Flow.source_ty | Eio.Resource.close_ty ] Eio.Std.r
  ; mutable next_id : int
  }

type spawn_error =
  | Command_not_found of string
  | Startup_timeout of string
  | Process_error of string

let pp_spawn_error fmt = function
  | Command_not_found cmd -> Fmt.pf fmt "LSP server not found: %s" cmd
  | Startup_timeout lang -> Fmt.pf fmt "LSP server startup timeout for %s" lang
  | Process_error msg -> Fmt.pf fmt "LSP process error: %s" msg
;;

(** Language → command mapping. Returns [(executable, argv)] or [None]. *)
let command_for_lang lang_id =
  match lang_id with
  | "ocaml" -> Some ("ocamllsp", [ "ocamllsp" ])
  | "typescript" | "javascript" ->
    Some ("typescript-language-server", [ "typescript-language-server"; "--stdio" ])
  | "python" -> Some ("pylsp", [ "pylsp" ])
  | "rust" -> Some ("rust-analyzer", [ "rust-analyzer" ])
  | "go" -> Some ("gopls", [ "gopls" ])
  | _ -> None
;;

(** Detect language from file extension. *)
let lang_of_path file_path =
  let ext =
    try Filename.extension file_path |> String.lowercase_ascii with
    | exn ->
      Log.Server.warn
        "lsp_process_manager: Filename.extension failed for %s: %s"
        file_path
        (Printexc.to_string exn);
      ""
  in
  match ext with
  | ".ml" | ".mli" -> "ocaml"
  | ".ts" | ".tsx" -> "typescript"
  | ".js" | ".jsx" -> "javascript"
  | ".py" -> "python"
  | ".rs" -> "rust"
  | ".go" -> "go"
  | _ -> "unknown"
;;

(** Check that an executable exists on [PATH]. *)
let command_exists cmd =
  Executable_path.path_has_executable cmd
;;

(** Allocate a fresh JSON-RPC request ID for this process. *)
let alloc_id (proc : lsp_process) : int =
  let id = proc.next_id in
  proc.next_id <- id + 1;
  id
;;

(** Write a JSON-RPC message to the process stdin with Content-Length framing.

    LSP spec: messages are framed as
    {[ Content-Length: <N>\r\n\r\n<payload> ]} *)
let write_message (proc : lsp_process) (json : string) =
  let payload = Bytes.unsafe_of_string json in
  let header = Printf.sprintf "Content-Length: %d\r\n\r\n" (Bytes.length payload) in
  Eio.Flow.copy_string header proc.stdin_w;
  Eio.Flow.copy_string json proc.stdin_w
;;

(** Read exactly [n] bytes from a flow into a string. *)
let read_exact (flow : [ Eio.Flow.source_ty | Eio.Resource.close_ty ] Eio.Std.r) n =
  let buf = Cstruct.create n in
  Eio.Flow.read_exact flow buf;
  Cstruct.to_string buf
;;

(** Read a single header line (terminated by [\r\n]) from the flow.
    Returns the line content without the trailing [\r\n]. *)
let read_header_line (flow : [ Eio.Flow.source_ty | Eio.Resource.close_ty ] Eio.Std.r) =
  let buf = Buffer.create 64 in
  let rec loop prev =
    let ch = Cstruct.create 1 in
    Eio.Flow.read_exact flow ch;
    let c = Cstruct.get ch 0 in
    if c = '\n' && prev = '\r'
    then (
      let s = Buffer.contents buf in
      let len = String.length s in
      if len > 0 && String.get s (len - 1) = '\r' then String.sub s 0 (len - 1) else s)
    else (
      Buffer.add_char buf c;
      loop c)
  in
  loop '\000'
;;

(** Parse [Content-Length] value from a header line.
    Returns [Some n] if the header matches, [None] otherwise. *)
type content_length_parse_error =
  | Invalid_content_length of { raw : string }
  | Negative_content_length of { value : int }

let content_length_parse_error_to_string = function
  | Invalid_content_length { raw } ->
    Printf.sprintf "invalid Content-Length %S" raw
  | Negative_content_length { value } ->
    Printf.sprintf "negative Content-Length %d" value

let parse_content_length_result line =
  let prefix = "Content-Length: " in
  if String.starts_with ~prefix line
  then (
    let raw =
      String.sub line (String.length prefix) (String.length line - String.length prefix)
    in
    match int_of_string_opt (String.trim raw) with
    | Some n when n >= 0 -> Ok (Some n)
    | Some n -> Error (Negative_content_length { value = n })
    | None -> Error (Invalid_content_length { raw }))
  else Ok None
;;

let parse_content_length line =
  match parse_content_length_result line with
  | Ok value -> value
  | Error error ->
    Log.Server.warn
      "lsp_process_manager: %s"
      (content_length_parse_error_to_string error);
    None
;;

(** Read one complete LSP message from stdout.

    Reads headers until empty line, then reads [Content-Length] bytes.
    Returns the JSON payload string. *)
let read_message (flow : [ Eio.Flow.source_ty | Eio.Resource.close_ty ] Eio.Std.r) =
  let rec read_headers content_length =
    let line = read_header_line flow in
    if String.length line = 0
    then (
      (* Empty line signals end of headers *)
      match content_length with
      | Some n -> read_exact flow n
      | None ->
        (* No Content-Length found; protocol violation.
              Return empty string so caller can detect and handle. *)
        "")
    else (
      let len = parse_content_length line in
      read_headers
        (match len with
         | Some n -> Some n
         | None -> content_length))
  in
  read_headers None
;;

(** Spawn an LSP server process for the given language.

    The process is bound to [sw] — when the switch is turned off,
    the process is terminated automatically via [on_release]. *)
let spawn ~sw ~lang_id ~workspace_root (proc_mgr : Eio_unix.Process.mgr_ty Eio.Resource.t)
  : (lsp_process, spawn_error) result
  =
  match command_for_lang lang_id with
  | None -> Error (Command_not_found lang_id)
  | Some (cmd, argv) ->
    if not (command_exists cmd)
    then Error (Command_not_found cmd)
    else (
      try
        let stdin_r, stdin_w = Eio.Process.pipe ~sw proc_mgr in
        let stdout_r, stdout_w = Eio.Process.pipe ~sw proc_mgr in
        let stderr_r, stderr_w = Eio.Process.pipe ~sw proc_mgr in
        let proc =
          Eio.Process.spawn
            ~sw
            proc_mgr
            ~stdin:stdin_r
            ~stdout:stdout_w
            ~stderr:stderr_w
            argv
        in
        Eio.Flow.close stdin_r;
        Eio.Flow.close stdout_w;
        Eio.Flow.close stderr_w;
        Eio.Switch.on_release sw (fun () ->
          try Eio.Process.signal proc Sys.sigterm with
          | exn ->
            Log.Server.debug
              "LSP process signal failed for %s: %s"
              lang_id
              (Printexc.to_string exn));
        (* Drain stderr to a log — prevents pipe stall *)
        Eio.Fiber.fork ~sw (fun () ->
          let buf = Buffer.create 256 in
          try
            while true do
              let line = read_header_line stderr_r in
              Buffer.add_string buf line;
              Buffer.add_char buf '\n';
              if Buffer.length buf > 4096
              then (
                Log.Server.debug "LSP %s stderr: %s" lang_id (Buffer.contents buf);
                Buffer.clear buf)
            done
          with
          | Eio.Cancel.Cancelled _ as e -> raise e
          | exn ->
            Log.Server.debug
              "LSP %s stderr reader ended: %s"
              lang_id
              (Printexc.to_string exn));
        Ok { lang_id; proc; stdin_w; stdout_r; stderr_r; next_id = 1 }
      with
      | Eio.Cancel.Cancelled _ as e -> raise e
      | exn -> Error (Process_error (Printexc.to_string exn)))
;;

(** Tear down a spawned LSP process whose initialization failed or that is
    being evicted. [spawn] binds the child, its 3 pipe FDs ([stdin_w],
    [stdout_r], [stderr_r]), the stderr-drain fiber, and (via
    [Lsp_message_router.start_response_reader]) the response-reader fiber to the
    caller's [~sw] — which the gRPC proxy scopes to the SERVER lifetime. Without
    this teardown a failed [initialize] orphans the proc + 3 pipe FDs + 2 reader
    fibers on that switch until server shutdown, and the next request re-spawns
    (RFC-0261 / issue #21546).

    Mechanism: closing [stdin_w], [stdout_r], and [stderr_r] releases all three
    FDs the record holds — every pipe FD bound to the switch. (Fiber exit on EOF
    is NOT FD release: signalling the child makes the drain fiber reach EOF and
    exit, but its [stderr_r] FD stays bound to the switch until explicitly
    closed.) Closing [stdout_r] also makes [Lsp_message_router.read_message]
    raise so the response-reader fiber exits; closing [stderr_r] ends the
    stderr-drain fiber's read. [Eio.Process.signal ... sigterm] stops the child.
    All operations are non-blocking, so this is safe to call while holding the
    spawn mutex. Each is best-effort and logs at debug on failure;
    [Eio.Cancel.Cancelled] is re-raised so cancellation still propagates. *)
let shutdown (proc : lsp_process) =
  let quietly what f =
    try f () with
    | Eio.Cancel.Cancelled _ as e -> raise e
    | exn ->
      Log.Server.debug
        "LSP shutdown for %s: %s failed: %s"
        proc.lang_id
        what
        (Printexc.to_string exn)
  in
  quietly "signal" (fun () -> Eio.Process.signal proc.proc Sys.sigterm);
  quietly "stdin_w close" (fun () -> Eio.Flow.close proc.stdin_w);
  quietly "stdout_r close" (fun () -> Eio.Flow.close proc.stdout_r);
  quietly "stderr_r close" (fun () -> Eio.Flow.close proc.stderr_r)
;;

type key = Enter | Up | Down | Tab | Eof
type input = Text of string | Key of key
type error = Already_running | Not_found | Not_running | Input_pending | Invalid_input
  | Cancelled | Transport_failed | Process_failed of int | Interpreter_missing
type command = Input of input | Cancel
type phase = Preparing | Running | Observing | Closed
type t = {
  id : string; workspace : string; actor : string; mutable account_key : string;
  commands : command Eio.Stream.t; phase : phase Atomic.t;
  input_pending : bool Atomic.t; cancel_requested : bool Atomic.t;
  pipe_input_closed : bool Atomic.t; terminal : bool Atomic.t;
}

let error_message = function
  | Already_running -> "A login is already running for this account."
  | Not_found -> "This login session is not available in this workspace."
  | Not_running -> "This login session no longer accepts input."
  | Input_pending -> "The previous login input has not been consumed yet."
  | Invalid_input -> "Choose text or a supported login key."
  | Cancelled -> "Login was cancelled. Saved credentials may still need verification."
  | Transport_failed -> "The login process could not be observed. Check the account before retrying."
  | Process_failed code -> Printf.sprintf "The official login process exited with status %d." code
  | Interpreter_missing ->
    "Login needs Python 3. Reinstall the complete MASC release to restore its bundled Python, or install Python 3 and retry."

let input_of_json = function
  | `Assoc fields when List.length fields = 2 ->
    (match List.assoc_opt "kind" fields, List.assoc_opt "text" fields,
           List.assoc_opt "key" fields with
     | Some (`String "text"), Some (`String text), None
       when String.length text <= 65536 (* One transport input frame, not a session budget. *)
         && String_util.is_valid_utf8 text
         && not (String.exists (function '\000'..'\031' | '\127' -> true | _ -> false) text) -> Ok (Text text)
     | Some (`String "key"), None, Some (`String key) ->
       (match key with
        | "enter" -> Ok (Key Enter) | "up" -> Ok (Key Up) | "down" -> Ok (Key Down)
        | "tab" -> Ok (Key Tab) | "eof" -> Ok (Key Eof) | _ -> Error Invalid_input)
     | _ -> Error Invalid_input)
  | _ -> Error Invalid_input

let id t = t.id
let registry = Hashtbl.create 8
let mutex = Mutex.create ()
let locked f = Mutex.lock mutex; Fun.protect ~finally:(fun () -> Mutex.unlock mutex) f
let with_session ~workspace ~actor ~account_key f =
  let workspace = Unix.realpath workspace in
  let reserved = locked (fun () ->
    if Hashtbl.fold (fun _ t busy -> busy || String.equal account_key t.account_key) registry false
    then Error Already_running
    else
      let t = {id = Auth.generate_token (); workspace; actor; account_key;
        commands = Eio.Stream.create max_int; phase = Atomic.make Preparing;
        input_pending = Atomic.make false; cancel_requested = Atomic.make false;
        pipe_input_closed = Atomic.make false; terminal = Atomic.make false} in
      Hashtbl.add registry t.id t; Ok t) in
  match reserved with
  | Error _ as failure -> failure
  | Ok t ->
    Fun.protect ~finally:(fun () ->
      Atomic.set t.phase Closed;
      locked (fun () -> Hashtbl.remove registry t.id)) (fun () -> f t)

let bind_account t ~account_key = locked (fun () ->
  if Hashtbl.fold (fun _ other busy -> busy || (other != t && String.equal other.account_key account_key)) registry false
  then Error Already_running else (t.account_key <- account_key; Ok ()))

let is_active ~workspace ~actor ~login_id =
  let workspace = Unix.realpath workspace in
  locked (fun () -> match Hashtbl.find_opt registry login_id with
    | Some t when String.equal workspace t.workspace && String.equal actor t.actor ->
      (match Atomic.get t.phase with Preparing | Running | Observing -> true | Closed -> false)
    | Some _ | None -> false)

let monitor t ~env ~is_closed f =
  Eio.Fiber.first (fun () -> Ok (f ())) (fun () ->
    while not (Atomic.get t.cancel_requested) && not (is_closed ()) do
      Eio.Time.sleep (Eio.Stdenv.clock env) 0.1
    done;
    Error Cancelled)

let enqueue ~workspace ~actor ~login_id command =
  let workspace = Unix.realpath workspace in
  let found = locked (fun () -> Hashtbl.find_opt registry login_id) in
  match found with
  | Some t when String.equal workspace t.workspace && String.equal actor t.actor ->
    (match command, Atomic.get t.phase with
     | Cancel, (Preparing | Running | Observing) -> Atomic.set t.cancel_requested true; Ok ()
     | Cancel, Closed | Input _, (Preparing | Observing | Closed) -> Error Not_running
     | Input _, Running ->
       if Atomic.get t.cancel_requested || Atomic.get t.pipe_input_closed then Error Not_running
       else if not (Atomic.compare_and_set t.input_pending false true) then Error Input_pending
       else (
         (match command with
          | Input (Key Eof) when not (Atomic.get t.terminal) -> Atomic.set t.pipe_input_closed true
          | Input (Text _ | Key _) | Cancel -> ());
         Eio.Stream.add t.commands command; Ok ()))
  | Some _ | None -> Error Not_found
let submit ~workspace ~actor ~login_id input = enqueue ~workspace ~actor ~login_id (Input input)
let cancel ~workspace ~actor ~login_id = enqueue ~workspace ~actor ~login_id Cancel

let command_json = function
  | Cancel -> `Assoc ["kind", `String "cancel"]
  | Input (Text text) -> `Assoc ["kind", `String "text"; "text", `String text]
  | Input (Key key) ->
    let key = match key with Enter -> "enter" | Up -> "up" | Down -> "down" | Tab -> "tab" | Eof -> "eof" in
    `Assoc ["kind", `String "key"; "key", `String key]

let executable path =
  try Unix.access path [Unix.X_OK]; true with Unix.Unix_error _ -> false
;;

(* Portable releases have no python3 on PATH; the release's bundled
   interpreter beside the server binary runs the helper there. *)
let python ~binary =
  let bundled = Filename.concat (Filename.dirname binary) "python/bin/python3" in
  if executable bundled then Some bundled
  else
    Option.bind (Env_config_core.raw_value_opt "PATH") (fun path ->
      String.split_on_char ':' path
      |> List.filter (fun directory -> directory <> "")
      |> List.find_map (fun directory ->
        let candidate = Filename.concat directory "python3" in
        if executable candidate then Some candidate else None))
;;

let run_with interpreter t ~env ~child_env ~cwd ~argv ~terminal ~is_closed ~on_ready ~on_input_ready ~on_output =
  let clock = Eio.Stdenv.clock env in
  Atomic.set t.terminal terminal;
  let run_child () = Eio.Switch.run (fun sw ->
    let mgr = Posix_spawn_process_mgr.foreground_mgr ~clock
      ~grace_seconds:Process_eio.child_exit_grace_seconds in
    let stdin_r, stdin_w = Eio.Process.pipe ~sw mgr in
    let stdout_r, stdout_w = Eio.Process.pipe ~sw mgr in
    let stderr_r, stderr_w = Eio.Process.pipe ~sw mgr in
    let _proc = Eio.Process.spawn ~sw mgr ~env:child_env
      ~cwd:Eio.Path.(Eio.Stdenv.fs env / cwd)
      ~stdin:stdin_r ~stdout:stdout_w ~stderr:stderr_w
      ([interpreter; "-I"; "-B"; "-c"; Embedded_account_login.script;
        (if terminal then "pty" else "pipe")] @ argv) in
    Eio.Flow.close stdin_r; Eio.Flow.close stdout_w; Eio.Flow.close stderr_w;
    (* Close only: a release-hook await can deadlock after Eio cancels its
       reaper daemon. The foreground manager owns TERM, grace and protected
       reaping; the helper handles TERM and kills its native child group. *)
    Eio.Switch.on_release sw (fun () ->
      Atomic.set t.phase Observing;
      Eio.Flow.close stdin_w);
    Eio.Fiber.fork_daemon ~sw (fun () ->
      let buffer = Cstruct.create 4096 in
      (* See helper protocol: stderr is drained for liveness; only typed stdout frames are exposed. *)
      (try while true do ignore (Eio.Flow.single_read stderr_r buffer) done
       with End_of_file -> ()); `Stop_daemon);
    Eio.Fiber.fork_daemon ~sw (fun () ->
      let rec send () =
        let command = Eio.Stream.take t.commands in
        Eio.Flow.copy_string (Yojson.Safe.to_string (command_json command) ^ "\n") stdin_w;
        match command with Cancel -> `Stop_daemon | Input _ -> send () in
      send ());
    Atomic.set t.phase Running;
    on_ready ();
    (* The helper reads at most 64 KiB per chunk; JSON escaping expands one
       byte at most sixfold. This is a wire-frame bound, never a login budget. *)
    let reader = Eio.Buf_read.of_flow ~max_size:(6 * 65536 + 1024) stdout_r in
    let rec receive () =
      let json = Yojson.Safe.from_string (Eio.Buf_read.line reader) in
      match json with
      | `Assoc fields ->
        (match List.assoc_opt "event" fields with
         | Some (`String "output") ->
           (match List.assoc_opt "stream" fields, List.assoc_opt "text" fields with
            | Some (`String (("stdout" | "stderr" | "terminal") as stream)), Some (`String text) ->
              on_output stream text; receive ()
            | _ -> Error Transport_failed)
         | Some (`String "input_ready") ->
           Atomic.set t.input_pending false; on_input_ready (); receive ()
         | Some (`String "exited") ->
           (match List.assoc_opt "code" fields with
            | Some (`Int 0) -> Ok () | Some (`Int code) -> Error (Process_failed code)
            | _ -> Error Transport_failed)
         | Some (`String "cancelled") -> Error Cancelled
         | Some (`String "transport_error") -> Error Transport_failed
         | _ -> Error Transport_failed)
      | _ -> Error Transport_failed in
    let result = receive () in
    Atomic.set t.phase Observing;
    result) in
  try Eio.Fiber.first run_child (fun () ->
    while not (Atomic.get t.cancel_requested) && not (is_closed ()) do
      (* Observe peer lifetime even while a provider waits silently for input. *)
      Eio.Time.sleep clock 0.1
    done;
    Error Cancelled)
  with
  | Eio.Cancel.Cancelled _ as exn -> raise exn
  | Unix.Unix_error _ | Sys_error _ | Eio.Io _ | End_of_file
  | Yojson.Json_error _ | Eio.Buf_read.Buffer_limit_exceeded -> Error Transport_failed
;;

let run t ~env ~child_env ~cwd ~argv ~terminal ~is_closed ~on_ready ~on_input_ready ~on_output =
  let binary =
    try Unix.realpath Sys.executable_name with Unix.Unix_error _ | Sys_error _ -> Sys.executable_name
  in
  match python ~binary with
  | None -> Error Interpreter_missing
  | Some interpreter ->
    run_with interpreter t ~env ~child_env ~cwd ~argv ~terminal ~is_closed ~on_ready ~on_input_ready ~on_output

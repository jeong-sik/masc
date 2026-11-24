type key = Enter | Up | Down | Tab | Eof
type input = Text of string | Key of key
type error = Already_running | Not_found | Not_running | Input_pending | Invalid_input
  | Cancelled | Transport_failed | Process_failed of int | Interpreter_missing
  | Completion_failed of string
type pipe = Stdout | Stderr
type output = Piped of pipe * string | Screen of string
type auth_hint =
  | Auth_url of { url : string }
  | Device_code of
      { code : string
      ; verification_uri : string option
      }
type command = Input of input | Cancel
type phase = Preparing | Running | Observing | Closed
type actor = Agent of string | Person of string
let same_actor left right = match left, right with
  | Agent left, Agent right | Person left, Person right -> String.equal left right
  | Agent _, Person _ | Person _, Agent _ -> false
type t = {
  id : string; workspace : string; actor : actor; mutable account_key : string;
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
  | Completion_failed detail -> detail

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
    | Some t when String.equal workspace t.workspace && same_actor actor t.actor ->
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
  | Some t when String.equal workspace t.workspace && same_actor actor t.actor ->
    (match command, Atomic.get t.phase with
     | Cancel, (Preparing | Running | Observing) -> Atomic.set t.cancel_requested true; Ok ()
     | Cancel, Closed | Input _, (Preparing | Observing | Closed) -> Error Not_running
     | Input _, Running ->
       if Atomic.get t.cancel_requested || Atomic.get t.pipe_input_closed then Error Not_running
       else if not (Atomic.compare_and_set t.input_pending false true) then Error Input_pending
       else (
         (match command with
          | Input (Key Eof) when not (Atomic.get t.terminal) -> Atomic.set t.pipe_input_closed true
          | Input (Text _ | Key (Enter | Up | Down | Tab | Eof)) | Cancel -> ());
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
      (* The helper changes cwd to the Keeper workspace. A relative entry
         would name a different executable there than the one checked here. *)
      |> List.filter (fun directory ->
        directory <> "" && not (Filename.is_relative directory))
      |> List.find_map (fun directory ->
        let candidate = Filename.concat directory "python3" in
        if executable candidate then Some candidate else None))
;;

(* 80 x 24 is the VT100's screen and the window xterm and macOS Terminal open
   with. The helper gives the PTY this size, so the program lays out the
   screen this module reads. *)
let screen_rows = 24
let screen_cols = 80

(* A full-screen login redraws in place: it moves the cursor up and writes
   over what it drew. Only a terminal's screen shows what the program meant.
   This terminal answers nothing, because the helper writes only the
   person's input to the program, so it models no extension a reply would
   announce. It keeps no scrollback: only the screen is sent, and agy draws
   its login on the alternate screen, which has none. *)
let terminal_screen () =
  Vte.create ~extensions:[] ~scrollback:0 ~rows:screen_rows ~cols:screen_cols ()

(* The rows down to the last one that shows text, each with its SGR styles
   and OSC 8 hyperlinks, one per line. A row the terminal wrapped goes on in the next row, so it
   keeps its trailing spaces and joins the next row without a line break:
   an address longer than the screen stays one line. *)
let screen_text screen =
  let row = Matrix_grid.create ~width:(Vte.cols screen) ~height:1 () in
  let rec last y = if y < 0 || Vte.text screen y <> "" then y else last (y - 1) in
  let last = last (Vte.rows screen - 1) in
  let buffer = Buffer.create (Vte.rows screen * Vte.cols screen) in
  for y = 0 to last do
    Vte.blit_row screen y row ~y:0;
    let wrapped = Vte.wrapped screen y in
    Buffer.add_string buffer (Matrix_grid.to_ansi ~trim:(not wrapped) row);
    if y < last && not wrapped then Buffer.add_char buffer '\n'
  done;
  Buffer.contents buffer

let strip_ansi text =
  let len = String.length text in
  let buf = Buffer.create len in
  let rec skip_csi i =
    if i >= len then len
    else
      let c = text.[i] in
      if c >= '@' && c <= '~' then i + 1 else skip_csi (i + 1)
  in
  let rec skip_st i =
    if i >= len then len
    else if Char.equal text.[i] '\027' && i + 1 < len && Char.equal text.[i + 1] '\\' then i + 2
    else skip_st (i + 1)
  in
  let rec skip_osc i =
    if i >= len then len
    else if Char.equal text.[i] '\007' then i + 1
    else if Char.equal text.[i] '\027' && i + 1 < len && Char.equal text.[i + 1] '\\' then i + 2
    else skip_osc (i + 1)
  in
  let rec loop i =
    if i >= len then ()
    else if Char.equal text.[i] '\027' then
      if i + 1 >= len then ()
      else
        match text.[i + 1] with
        | '[' -> loop (skip_csi (i + 2))
        | ']' -> loop (skip_osc (i + 2))
        | 'P' | 'X' | '^' | '_' -> loop (skip_st (i + 2))
        | '(' | ')' | '*' | '+' -> loop (min len (i + 3))
        | _ -> loop (i + 2)
    else (
      Buffer.add_char buf text.[i];
      loop (i + 1))
  in
  loop 0;
  Buffer.contents buf

let https_prefix = "https://"

let is_url_body_char c =
  c >= '!' && c <= '~'
  && not
       (Char.equal c '<' || Char.equal c '>' || Char.equal c '"'
        || Char.equal c '\'' || Char.equal c '`')

let is_valid_host_char c =
  (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9')
  || Char.equal c '.' || Char.equal c '-' || Char.equal c ':'

let count_char s target =
  let n = ref 0 in
  String.iter (fun c -> if Char.equal c target then incr n) s;
  !n

let trim_trailing_url_punct s =
  let rec trim stop =
    if stop <= String.length https_prefix then String.sub s 0 stop
    else
      match s.[stop - 1] with
      | '.' | ',' | ';' | ':' | '!' | '\'' | '"' | '>' | ']' | '}' -> trim (stop - 1)
      | ')' ->
        let candidate = String.sub s 0 stop in
        if count_char candidate ')' > count_char candidate '(' then trim (stop - 1) else candidate
      | _ -> String.sub s 0 stop
  in
  trim (String.length s)

let normalize_https_url raw =
  let candidate = String.trim raw |> trim_trailing_url_punct in
  if not (String.starts_with ~prefix:https_prefix candidate)
     || not (String.for_all is_url_body_char candidate)
  then None
  else
    let uri = Uri.of_string candidate in
    match Uri.scheme uri, Uri.host uri with
    | Some scheme, Some host
      when String.equal scheme "https"
           && String.length host > 0
           && String.for_all is_valid_host_char host
           && (String.contains host '.'
               || String.equal (String.lowercase_ascii host) "localhost") ->
      Some candidate
    | Some _, Some _ | Some _, None | None, Some _ | None, None -> None

let extract_osc8_urls raw =
  let len = String.length raw in
  let rec find_terminator i =
    if i >= len then len, len
    else if Char.equal raw.[i] '\007' then i, i + 1
    else if Char.equal raw.[i] '\027' && i + 1 < len && Char.equal raw.[i + 1] '\\' then i, i + 2
    else find_terminator (i + 1)
  in
  let rec scan i acc =
    if i + 4 >= len then List.rev acc
    else if
      Char.equal raw.[i] '\027'
      && Char.equal raw.[i + 1] ']'
      && Char.equal raw.[i + 2] '8'
      && Char.equal raw.[i + 3] ';'
    then
      let term_start, next_i = find_terminator (i + 4) in
      let payload = String.sub raw (i + 4) (term_start - (i + 4)) in
      let acc =
        match String.index_opt payload ';' with
        | None -> acc
        | Some sep ->
          let uri_part = String.sub payload (sep + 1) (String.length payload - sep - 1) in
          (match normalize_https_url uri_part with
           | Some url -> url :: acc
           | None -> acc)
      in
      scan next_i acc
    else scan (i + 1) acc
  in
  scan 0 []

let prefix_at s ~pos ~prefix =
  let plen = String.length prefix in
  if pos + plen > String.length s then false
  else
    let rec cmp k =
      if k = plen then true
      else if Char.equal s.[pos + k] prefix.[k] then cmp (k + 1)
      else false
    in
    cmp 0

let extract_https_urls_from_plain plain =
  let len = String.length plain in
  let plen = String.length https_prefix in
  let rec scan_end j = if j < len && is_url_body_char plain.[j] then scan_end (j + 1) else j in
  let rec loop i acc =
    if i + plen > len then List.rev acc
    else if prefix_at plain ~pos:i ~prefix:https_prefix then
      let stop = scan_end (i + plen) in
      let raw = String.sub plain i (stop - i) in
      let acc =
        match normalize_https_url raw with
        | Some url -> url :: acc
        | None -> acc
      in
      loop (max (i + plen) stop) acc
    else loop (i + 1) acc
  in
  loop 0 []

let is_token_separator c =
  let code = Char.code c in
  code <= 32 || code >= 127

let is_wrapper_punct = function
  | '(' | ')' | '[' | ']' | '{' | '}' | '"' | '\'' | '`' | ',' | '.' | ';' | ':' | '!' | '?' ->
    true
  | _ -> false

let trim_wrapper_punct s =
  let len = String.length s in
  let rec left i = if i < len && is_wrapper_punct s.[i] then left (i + 1) else i in
  let l = left 0 in
  let rec right j = if j > l && is_wrapper_punct s.[j - 1] then right (j - 1) else j in
  let r = right len in
  String.sub s l (r - l)

let is_upper_letter c = c >= 'A' && c <= 'Z'
let is_upper_alnum c = is_upper_letter c || (c >= '0' && c <= '9')

let is_device_code token =
  match String.split_on_char '-' token with
  | [ left; right ] ->
    let l_len = String.length left in
    let r_len = String.length right in
    l_len = 4 && (r_len = 4 || r_len = 5)
    && String.for_all is_upper_alnum left
    && String.for_all is_upper_alnum right
    && (String.exists is_upper_letter left || String.exists is_upper_letter right)
  | [] | [ _ ] | _ :: _ :: _ :: _ -> false

let extract_device_codes_from_plain plain =
  let len = String.length plain in
  let rec skip_sep i = if i < len && is_token_separator plain.[i] then skip_sep (i + 1) else i in
  let rec take_tok i =
    if i < len && not (is_token_separator plain.[i]) then take_tok (i + 1) else i
  in
  let rec loop i acc =
    let start = skip_sep i in
    if start >= len then List.rev acc
    else
      let stop = take_tok start in
      let raw = String.sub plain start (stop - start) in
      let acc =
        if String_util.contains_substring raw "://" then acc
        else
          let cleaned = trim_wrapper_punct raw in
          if is_device_code cleaned then cleaned :: acc else acc
      in
      loop stop acc
  in
  loop 0 []

let dedup_strings items =
  let seen = Hashtbl.create 4 in
  List.filter
    (fun item ->
      if Hashtbl.mem seen item then false
      else (
        Hashtbl.add seen item ();
        true))
    items

let extract_urls_and_codes raw =
  let plain = strip_ansi raw in
  let urls = dedup_strings (extract_osc8_urls raw @ extract_https_urls_from_plain plain) in
  let codes = dedup_strings (extract_device_codes_from_plain plain) in
  urls, codes

let extract_auth_hints raw =
  let urls, codes = extract_urls_and_codes raw in
  let verification_uri =
    match urls with
    | first :: _ -> Some first
    | [] -> None
  in
  List.map (fun url -> Auth_url { url }) urls
  @ List.map (fun code -> Device_code { code; verification_uri }) codes

let max_pipe_hint_buffer = 65536

let run_with interpreter t ~saved_login ~on_auth_hint ~env ~child_env ~cwd ~argv ~terminal ~is_closed ~on_ready ~on_input_ready ~on_output =
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
      ([interpreter; "-I"; "-B"; "-c"; Embedded_account_login.script]
       @ (if terminal then ["pty"; string_of_int screen_rows; string_of_int screen_cols] else ["pipe"])
       @ argv) in
    Eio.Flow.close stdin_r; Eio.Flow.close stdout_w; Eio.Flow.close stderr_w;
    (* Close only: a release-hook await can deadlock after Eio cancels its
       reaper daemon. The foreground manager owns TERM, grace and protected
       reaping; the helper handles TERM and kills its native child group. *)
    Eio.Switch.on_release sw (fun () ->
      Atomic.set t.phase Observing;
      Eio.Flow.close stdin_w);
    let completion, completed = Eio.Promise.create () in
    let completion_found = Atomic.make false in
    let check_saved_login () =
      if Atomic.get completion_found then true else
      match saved_login with
      | None -> false
      | Some check ->
        (match check () with
         | Ok false -> Atomic.get completion_found
         | (Ok true | Error _) as result ->
           if Atomic.compare_and_set completion_found false true then (
             Atomic.set t.phase Observing;
             Eio.Promise.resolve completed
               (result |> Result.map (fun _ -> ())
                |> Result.map_error (fun detail -> Completion_failed detail)));
           true) in
    Eio.Fiber.fork_daemon ~sw (fun () ->
      let buffer = Cstruct.create 4096 in
      (* See helper protocol: stderr is drained for liveness; only typed stdout frames are exposed. *)
      (try while true do ignore (Eio.Flow.single_read stderr_r buffer) done
       with End_of_file -> ()); `Stop_daemon);
    Eio.Fiber.fork_daemon ~sw (fun () ->
      let rec send () =
        let command = Eio.Stream.take t.commands in
        match command with
        | Input _ when check_saved_login () -> `Stop_daemon
        | Cancel | Input _ ->
          Eio.Flow.copy_string (Yojson.Safe.to_string (command_json command) ^ "\n") stdin_w;
          (match command with Cancel -> `Stop_daemon | Input _ -> send ()) in
      send ());
    Atomic.set t.phase Running;
    on_ready ();
    (match saved_login with
     | None -> ()
     | Some _ -> Eio.Fiber.fork_daemon ~sw (fun () ->
         (* The sign-in can finish in the browser without terminal output or
            another key. This interval observes it; it never expires a login. *)
         let rec watch () =
           Eio.Time.sleep clock 0.1;
           if check_saved_login () then `Stop_daemon else watch () in
         watch ()));
    (* The helper reads at most 64 KiB per chunk; JSON escaping expands one
       byte at most sixfold. This is a wire-frame bound, never a login budget. *)
    let reader = Eio.Buf_read.of_flow ~max_size:(6 * 65536 + 1024) stdout_r in
    let screen = if terminal then Some (terminal_screen ()) else None in
    let emit_hints =
      match on_auth_hint with
      | None -> fun _ -> ()
      | Some on_auth_hint ->
        let seen_urls = Hashtbl.create 4 in
        let seen_codes = Hashtbl.create 4 in
        let last_auth_url = ref None in
        fun raw ->
          let urls, codes = extract_urls_and_codes raw in
          List.iter
            (fun url ->
              if not (Hashtbl.mem seen_urls url) then (
                Hashtbl.add seen_urls url ();
                last_auth_url := Some url;
                on_auth_hint (Auth_url { url })))
            urls;
          List.iter
            (fun code ->
              if not (Hashtbl.mem seen_codes code) then (
                Hashtbl.add seen_codes code ();
                on_auth_hint (Device_code { code; verification_uri = !last_auth_url })))
            codes
    in
    let stdout_hint_buf = Buffer.create 256 in
    let stderr_hint_buf = Buffer.create 256 in
    let feed_pipe_hints buf text =
      if Option.is_some on_auth_hint then (
        Buffer.add_string buf text;
        let content = Buffer.contents buf in
        match String.rindex_opt content '\n' with
        | Some nl ->
          let completed = String.sub content 0 (nl + 1) in
          let tail = String.sub content (nl + 1) (String.length content - nl - 1) in
          Buffer.clear buf;
          if String.length tail <= max_pipe_hint_buffer then Buffer.add_string buf tail;
          emit_hints completed;
          let tlen = String.length tail in
          if tlen > 0 && is_token_separator tail.[tlen - 1] then emit_hints tail
        | None ->
          let clen = String.length content in
          if clen > max_pipe_hint_buffer then (
            Buffer.clear buf;
            emit_hints content)
          else if clen > 0 && is_token_separator content.[clen - 1] then
            emit_hints content)
    in
    let flush_pipe_hints () =
      let flush buf =
        if Buffer.length buf > 0 then (
          let pending = Buffer.contents buf in
          Buffer.clear buf;
          emit_hints pending)
      in
      flush stdout_hint_buf;
      flush stderr_hint_buf
    in
    let draw screen text =
      (* Replies are dropped: see [terminal_screen]. So are requests to the
         host (bell, notification, clipboard), which nothing here performs;
         kept, each would stay in [screen] for the rest of the login. *)
      ignore (Vte.feed_string screen text);
      Vte.clear_requests screen;
      (* A cursor move or a new pen alone changes no row, so nothing new shows. *)
      let changed = Vte.dirty_rows screen <> [] in
      Vte.clear_dirty screen;
      if changed then (
        let rendered = screen_text screen in
        on_output (Screen rendered);
        emit_hints rendered) in
    let rec receive () =
      let json = Yojson.Safe.from_string (Eio.Buf_read.line reader) in
      match json with
      | `Assoc fields ->
        (match List.assoc_opt "event" fields with
         | Some (`String "output") ->
           (match List.assoc_opt "stream" fields, List.assoc_opt "text" fields, screen with
            | Some (`String "stdout"), Some (`String text), None ->
              on_output (Piped (Stdout, text));
              feed_pipe_hints stdout_hint_buf text;
              receive ()
            | Some (`String "stderr"), Some (`String text), None ->
              on_output (Piped (Stderr, text));
              feed_pipe_hints stderr_hint_buf text;
              receive ()
            | Some (`String "terminal"), Some (`String text), Some screen -> draw screen text; receive ()
            | _ -> Error Transport_failed)
         | Some (`String "input_ready") ->
           flush_pipe_hints ();
           Atomic.set t.input_pending false; on_input_ready (); receive ()
         | Some (`String "exited") ->
           flush_pipe_hints ();
           (match List.assoc_opt "code" fields with
            | Some (`Int 0) -> Ok () | Some (`Int code) -> Error (Process_failed code)
            | _ -> Error Transport_failed)
         | Some (`String "cancelled") -> Error Cancelled
         | Some (`String "transport_error") -> Error Transport_failed
         | _ -> Error Transport_failed)
      | _ -> Error Transport_failed in
    let result = Eio.Fiber.first receive (fun () -> Eio.Promise.await completion) in
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

let run ?saved_login ?on_auth_hint t ~env ~child_env ~cwd ~argv ~terminal ~is_closed ~on_ready ~on_input_ready ~on_output =
  let binary =
    try Unix.realpath Sys.executable_name with Unix.Unix_error _ | Sys_error _ -> Sys.executable_name
  in
  match python ~binary with
  | None -> Error Interpreter_missing
  | Some interpreter ->
    run_with interpreter t ~saved_login ~on_auth_hint ~env ~child_env ~cwd ~argv ~terminal ~is_closed ~on_ready ~on_input_ready ~on_output

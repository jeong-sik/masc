module Clock = Masc_tui_core.Clock
module Say = Masc_tui_core.Say

let default_timeout_s = 2.0

type error =
  | No_reader of { tried : string list }
  | No_image of { reader : string }
  | Unreadable of { reader : string; detail : string }

type reader = {
  name : string;
  build : dest:string -> string;
  argv : dest:string -> string array;
  stdout_to_dest : bool;
}

let reader_name reader = reader.name
let reader_command reader ~dest = reader.build ~dest

let applescript_string path =
  let buf = Buffer.create (String.length path + 8) in
  Buffer.add_char buf '"';
  String.iter
    (fun c ->
      match c with
      | '"' | '\\' ->
          Buffer.add_char buf '\\';
          Buffer.add_char buf c
      | c -> Buffer.add_char buf c)
    path;
  Buffer.add_char buf '"';
  Buffer.contents buf

let quiet_stderr = "2>/dev/null"

let osascript =
  let script_lines ~dest =
    let literal = applescript_string dest in
    [
      "set png to (the clipboard as «class PNGf»)";
      "set f to open for access POSIX file " ^ literal
      ^ " with write permission";
      "set eof of f to 0";
      "write png to f";
      "close access f";
    ]
  in
  {
    name = "osascript";
    build =
      (fun ~dest ->
        let args =
          List.map (fun line -> "-e " ^ Filename.quote line) (script_lines ~dest)
        in
        String.concat " " (("osascript" :: args) @ [ quiet_stderr ]));
    argv =
      (fun ~dest ->
        let pairs =
          List.concat_map (fun line -> [ "-e"; line ]) (script_lines ~dest)
        in
        Array.of_list ("osascript" :: pairs));
    stdout_to_dest = false;
  }

let wl_paste =
  {
    name = "wl-paste";
    build =
      (fun ~dest ->
        String.concat " "
          [
            "wl-paste";
            "--type";
            "image/png";
            ">";
            Filename.quote dest;
            quiet_stderr;
          ]);
    argv = (fun ~dest:_ -> [| "wl-paste"; "--type"; "image/png" |]);
    stdout_to_dest = true;
  }

let xclip =
  {
    name = "xclip";
    build =
      (fun ~dest ->
        String.concat " "
          [
            "xclip";
            "-selection";
            "clipboard";
            "-t";
            "image/png";
            "-o";
            ">";
            Filename.quote dest;
            quiet_stderr;
          ]);
    argv =
      (fun ~dest:_ ->
        [| "xclip"; "-selection"; "clipboard"; "-t"; "image/png"; "-o" |]);
    stdout_to_dest = true;
  }

let readers = [ osascript; wl_paste; xclip ]

let find_executable name =
  match Sys.getenv_opt "PATH" with
  | None -> None
  | Some path ->
      String.split_on_char ':' path
      |> List.find_map (fun dir ->
             if String.equal dir "" then None
             else
               let candidate = Filename.concat dir name in
               match Unix.stat candidate with
               | st when st.Unix.st_kind = Unix.S_REG -> (
                   match Unix.access candidate [ Unix.X_OK ] with
                   | () -> Some candidate
                   | exception Unix.Unix_error _ -> None)
               | _ -> None
               | exception Unix.Unix_error _ -> None)

let executable_exists name = Option.is_some (find_executable name)

let safe_close_fd fd =
  match Unix.close fd with
  | () -> ()
  | exception Unix.Unix_error _ -> ()

let kill_and_reap pid =
  (match Unix.kill pid Sys.sigkill with
   | () -> ()
   | exception Unix.Unix_error _ -> ());
  let rec reap () =
    match Unix.waitpid [] pid with
    | _, _ -> ()
    | exception Unix.Unix_error (Unix.EINTR, _, _) -> reap ()
    | exception Unix.Unix_error _ -> ()
  in
  reap ()

let merged_env overrides =
  if overrides = [] then None
  else
    let base = Unix.environment () |> Array.to_list in
    let keys = List.map fst overrides in
    let kept =
      List.filter
        (fun entry ->
          match String.index_opt entry '=' with
          | Some i ->
              let k = String.sub entry 0 i in
              not (List.exists (String.equal k) keys)
          | None -> true)
        base
    in
    let added = List.map (fun (k, v) -> k ^ "=" ^ v) overrides in
    Some (Array.of_list (kept @ added))

type process_outcome =
  | Exited of Unix.process_status
  | Timed_out
  | Cancelled
  | Spawn_error of string

let run_process_bounded ~timeout_s ~cancelled ~prog ~argv ?(env_overrides = [])
    ~stdin_path ~stdout_path () =
  if cancelled () then Cancelled
  else
    let timeout_s =
      if Float.is_finite timeout_s && timeout_s > 0.0 then timeout_s
      else default_timeout_s
    in
    let with_fd path flags fn =
      let fd = Unix.openfile path flags 0o600 in
      Fun.protect ~finally:(fun () -> safe_close_fd fd) (fun () -> fn fd)
    in
    let spawn () =
      let in_path = match stdin_path with Some p -> p | None -> "/dev/null" in
      let out_path, out_flags =
        match stdout_path with
        | Some p -> (p, [ Unix.O_WRONLY; Unix.O_CREAT; Unix.O_TRUNC; Unix.O_CLOEXEC ])
        | None -> ("/dev/null", [ Unix.O_WRONLY; Unix.O_CLOEXEC ])
      in
      with_fd in_path [ Unix.O_RDONLY; Unix.O_CLOEXEC ] (fun stdin_fd ->
          with_fd out_path out_flags (fun stdout_fd ->
              with_fd "/dev/null" [ Unix.O_WRONLY; Unix.O_CLOEXEC ]
                (fun stderr_fd ->
                  match merged_env env_overrides with
                  | Some env ->
                      Unix.create_process_env prog argv env stdin_fd stdout_fd
                        stderr_fd
                  | None ->
                      Unix.create_process prog argv stdin_fd stdout_fd stderr_fd)))
    in
    match spawn () with
    | exception Unix.Unix_error (err, fn, _) ->
        Spawn_error (Printf.sprintf "%s: %s" fn (Unix.error_message err))
    | pid ->
        let deadline = Clock.Mono.after_s (Clock.Mono.now ()) timeout_s in
        let rec wait poll_s =
          if cancelled () then begin
            kill_and_reap pid;
            Cancelled
          end
          else
            match Unix.waitpid [ Unix.WNOHANG ] pid with
            | 0, _ ->
                let remaining =
                  Clock.Mono.seconds_since deadline ~since:(Clock.Mono.now ())
                in
                if remaining <= 0.0 then begin
                  kill_and_reap pid;
                  Timed_out
                end
                else begin
                  Unix.sleepf (Float.min poll_s remaining);
                  wait (Float.min 0.025 (poll_s *. 1.5))
                end
            | _, (Unix.WSTOPPED _ as status) ->
                kill_and_reap pid;
                Exited status
            | _, ((Unix.WEXITED _ | Unix.WSIGNALED _) as status) -> Exited status
            | exception Unix.Unix_error (Unix.EINTR, _, _) -> wait poll_s
            | exception Unix.Unix_error (Unix.ECHILD, _, _) ->
                Exited (Unix.WEXITED 0)
            | exception Unix.Unix_error (err, fn, _) ->
                kill_and_reap pid;
                Spawn_error (Printf.sprintf "%s: %s" fn (Unix.error_message err))
        in
        (try wait 0.005 with
         | Eio.Cancel.Cancelled _ as ex ->
             Eio.Cancel.protect (fun () -> kill_and_reap pid);
             raise ex
         | ex ->
             kill_and_reap pid;
             raise ex)

let read_all path =
  match open_in_bin path with
  | exception Sys_error detail -> Error detail
  | channel ->
      Fun.protect
        ~finally:(fun () -> close_in_noerr channel)
        (fun () ->
          match really_input_string channel (in_channel_length channel) with
          | bytes -> Ok bytes
          | exception End_of_file -> Error "the file ended early while reading"
          | exception Sys_error detail -> Error detail)

let read_image ?(timeout_s = default_timeout_s) ?(cancelled = fun () -> false) () =
  if cancelled () then
    Error (Unreadable { reader = "clipboard"; detail = "cancelled" })
  else
  let installed =
    List.filter_map
      (fun reader ->
        Option.map (fun prog -> (reader, prog)) (find_executable reader.name))
      readers
  in
  match installed with
  | [] -> Error (No_reader { tried = List.map reader_name readers })
  | _ :: _ ->
      let dest = Filename.temp_file "masc-tui-clipboard" ".img" in
      Fun.protect
        ~finally:(fun () ->
          match Sys.remove dest with
          | () -> ()
          | exception Sys_error _ -> ())
        (fun () ->
          let rec attempt reported = function
            | [] ->
                Error
                  (match reported with
                   | Some error -> error
                   | None -> No_reader { tried = List.map reader_name readers })
            | (reader, prog) :: rest -> (
                let keep error =
                  let first_err =
                    match reported with Some prev -> prev | None -> error
                  in
                  attempt (Some first_err) rest
                in
                let stdout_path =
                  if reader.stdout_to_dest then Some dest else None
                in
                match
                  run_process_bounded ~timeout_s ~cancelled ~prog
                    ~argv:(reader.argv ~dest) ~stdin_path:None ~stdout_path ()
                with
                | Exited (Unix.WEXITED 0) -> (
                    match read_all dest with
                    | Ok bytes when String.length bytes > 0 -> Ok bytes
                    | Ok _ ->
                        keep
                          (Unreadable
                             {
                               reader = reader.name;
                               detail = "the reader wrote no bytes";
                             })
                    | Error detail ->
                        keep (Unreadable { reader = reader.name; detail }))
                | Exited (Unix.WEXITED _) -> keep (No_image { reader = reader.name })
                | Exited (Unix.WSIGNALED signal) ->
                    keep
                      (Unreadable
                         {
                           reader = reader.name;
                           detail = Printf.sprintf "killed by signal %d" signal;
                         })
                | Exited (Unix.WSTOPPED signal) ->
                    keep
                      (Unreadable
                         {
                           reader = reader.name;
                           detail = Printf.sprintf "stopped by signal %d" signal;
                         })
                | Timed_out ->
                    keep
                      (Unreadable
                         {
                           reader = reader.name;
                           detail = Printf.sprintf "timed out after %.1fs" timeout_s;
                         })
                | Cancelled ->
                    Error
                      (Unreadable { reader = reader.name; detail = "cancelled" })
                | Spawn_error detail ->
                    keep (Unreadable { reader = reader.name; detail }))
          in
          attempt None installed)

let error_to_string = function
  | No_reader { tried } ->
      Printf.sprintf "no clipboard reader found (looked for %s)"
        (String.concat ", " tried)
  | No_image { reader } ->
      Printf.sprintf "the clipboard holds no image (%s)" reader
  | Unreadable { reader; detail } ->
      Printf.sprintf "%s could not read the clipboard image: %s" reader detail

type writer = {
  writer_name : string;
  env_overrides : (string * string) list;
  args : string list;
}

let writer_name writer = writer.writer_name

let writer_reading_stdin ?(env_overrides = []) name args =
  { writer_name = name; env_overrides; args }

let writers =
  [
    writer_reading_stdin ~env_overrides:[ ("LC_ALL", "en_US.UTF-8") ] "pbcopy" [];
    writer_reading_stdin "wl-copy" [];
    writer_reading_stdin "xclip" [ "-selection"; "clipboard"; "-in" ];
  ]

type copy_session =
  | Local
  | Multiplexed
  | Remote

let copy_session getenv =
  match getenv "SSH_CONNECTION", getenv "SSH_TTY", getenv "TMUX" with
  | Some _, _, _ | _, Some _, _ -> Remote
  | None, None, Some _ -> Multiplexed
  | None, None, None -> Local

type copy_route =
  | Through_tools of {
      first : writer;
      rest : writer list;
      also_terminal : bool;
    }
  | Terminal_only

let copy_route session ~installed =
  let tools ~also_terminal =
    match List.filter (fun w -> installed w.writer_name) writers with
    | [] -> Terminal_only
    | first :: rest -> Through_tools { first; rest; also_terminal }
  in
  match session with
  | Remote -> Terminal_only
  | Local -> tools ~also_terminal:false
  | Multiplexed -> tools ~also_terminal:true

type terminal_reason =
  | Not_tried
  | Tools_failed of string * string list
  | Not_staged of string

type copy_outcome =
  | Copied_by of string
  | Copied_by_and_sent_to_terminal of string
  | Sent_to_terminal of terminal_reason

let osc52_sequence ?(in_tmux = false) text =
  let encoded = Base64.encode_string text in
  if in_tmux then
    Printf.sprintf "\x1bPtmux;\x1b\x1b]52;c;%s\x07\x1b\\" encoded
  else Printf.sprintf "\x1b]52;c;%s\x1b\\" encoded

let stage text =
  match Filename.temp_file "masc-tui-copy" ".txt" with
  | exception Sys_error detail -> Error detail
  | source -> (
      match
        Out_channel.with_open_bin source (fun channel ->
            Out_channel.output_string channel text)
      with
      | () -> Ok source
      | exception Sys_error detail ->
          (match Sys.remove source with
           | () -> ()
           | exception Sys_error _ -> ());
          Error detail)

let run_writer ~timeout_s ~cancelled writer ~source =
  if cancelled () then `Cancelled
  else
    match find_executable writer.writer_name with
    | None -> `Failed
    | Some prog -> (
        let argv = Array.of_list (writer.writer_name :: writer.args) in
        match
          run_process_bounded ~timeout_s ~cancelled ~prog ~argv
            ~env_overrides:writer.env_overrides ~stdin_path:(Some source)
            ~stdout_path:None ()
        with
        | Exited (Unix.WEXITED 0) -> `Ok
        | Cancelled -> `Cancelled
        | Exited (Unix.WEXITED _ | Unix.WSIGNALED _ | Unix.WSTOPPED _)
        | Timed_out | Spawn_error _ ->
            `Failed)

let copy_text ?(timeout_s = default_timeout_s) ?(cancelled = fun () -> false)
    session ~write_osc52 text =
  let send reason =
    if not (cancelled ()) then write_osc52 text;
    Sent_to_terminal reason
  in
  if cancelled () then Sent_to_terminal Not_tried
  else
    match copy_route session ~installed:executable_exists with
    | Terminal_only -> send Not_tried
    | Through_tools { first; rest; also_terminal } -> (
        match stage text with
        | Error detail -> send (Not_staged detail)
        | Ok source ->
            Fun.protect
              ~finally:(fun () ->
                match Sys.remove source with
                | () -> ()
                | exception Sys_error _ -> ())
              (fun () ->
                let copied writer =
                  if also_terminal && not (cancelled ()) then begin
                    write_osc52 text;
                    Copied_by_and_sent_to_terminal writer.writer_name
                  end
                  else Copied_by writer.writer_name
                in
                let rec attempt failed = function
                  | [] ->
                      send
                        (Tools_failed
                           (first.writer_name, List.rev_map writer_name failed))
                  | writer :: later -> (
                      match run_writer ~timeout_s ~cancelled writer ~source with
                      | `Ok -> copied writer
                      | `Cancelled ->
                          Sent_to_terminal
                            (Tools_failed
                               ( first.writer_name
                               , List.rev_map writer_name (writer :: failed) ))
                      | `Failed -> attempt (writer :: failed) later)
                in
                match run_writer ~timeout_s ~cancelled first ~source with
                | `Ok -> copied first
                | `Cancelled ->
                    Sent_to_terminal (Tools_failed (first.writer_name, []))
                | `Failed -> attempt [] rest))

let osc52_unconfirmed = "sent to the terminal as OSC 52 (unconfirmed)"

let copy_outcome_text = function
  | Copied_by tool -> Printf.sprintf "copied with %s" tool
  | Copied_by_and_sent_to_terminal tool ->
      Printf.sprintf "copied with %s and sent to the terminal as OSC 52" tool
  | Sent_to_terminal Not_tried -> osc52_unconfirmed
  | Sent_to_terminal (Tools_failed (first, later)) ->
      Printf.sprintf "%s after %s failed" osc52_unconfirmed
        (String.concat ", " (first :: later))
  | Sent_to_terminal (Not_staged detail) ->
      Printf.sprintf
        "%s; the text could not be written out for a clipboard tool: %s"
        osc52_unconfirmed detail

let copy_outcome_text_korean = function
  | Copied_by tool -> Printf.sprintf "복사했습니다 (%s)" tool
  | Copied_by_and_sent_to_terminal tool ->
      Printf.sprintf "복사했고 터미널에도 OSC 52로 보냈습니다 (%s)" tool
  | Sent_to_terminal Not_tried -> "OSC 52로 보냈습니다 (터미널 지원은 확인 못 함)"
  | Sent_to_terminal (Tools_failed (first, later)) ->
      Printf.sprintf
        "OSC 52로 보냈습니다 (터미널 지원은 확인 못 함, 실패한 도구: %s)"
        (String.concat ", " (first :: later))
  | Sent_to_terminal (Not_staged detail) ->
      Printf.sprintf
        "OSC 52로 보냈습니다 (터미널 지원은 확인 못 함, 복사 도구에 넘길 파일을 못 씀: %s)"
        detail

let copy_outcome_say outcome =
  Say.make ~ko:(copy_outcome_text_korean outcome) ~en:(copy_outcome_text outcome)

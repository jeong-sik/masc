module Say = Masc_tui_core.Say

type error =
  | No_reader of { tried : string list }
  | No_image of { reader : string }
  | Unreadable of { reader : string; detail : string }

type reader = {
  name : string;
  build : dest:string -> string;
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
  {
    name = "osascript";
    build =
      (fun ~dest ->
        let literal = applescript_string dest in
        String.concat " "
          [
            "osascript";
            "-e " ^ Filename.quote "set png to (the clipboard as «class PNGf»)";
            "-e "
            ^ Filename.quote
                ("set f to open for access POSIX file " ^ literal
               ^ " with write permission");
            "-e " ^ Filename.quote "set eof of f to 0";
            "-e " ^ Filename.quote "write png to f";
            "-e " ^ Filename.quote "close access f";
            quiet_stderr;
          ]);
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
  }

let readers = [ osascript; wl_paste; xclip ]

let executable_exists name =
  match Sys.getenv_opt "PATH" with
  | None -> false
  | Some path ->
      String.split_on_char ':' path
      |> List.exists (fun dir ->
             if String.equal dir "" then false
             else
               let candidate = Filename.concat dir name in
               match Unix.access candidate [ Unix.X_OK ] with
               | () -> true
               | exception Unix.Unix_error _ -> false)

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

let read_image () =
  match List.filter (fun reader -> executable_exists reader.name) readers with
  | [] -> Error (No_reader { tried = List.map reader_name readers })
  | installed ->
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
            | reader :: rest -> (
                let keep error =
                  let first_err =
                    match reported with Some prev -> prev | None -> error
                  in
                  attempt (Some first_err) rest
                in
                match Unix.system (reader.build ~dest) with
                | Unix.WEXITED 0 -> (
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
                | Unix.WEXITED _ -> keep (No_image { reader = reader.name })
                | Unix.WSIGNALED signal ->
                    keep
                      (Unreadable
                         {
                           reader = reader.name;
                           detail = Printf.sprintf "killed by signal %d" signal;
                         })
                | Unix.WSTOPPED signal ->
                    keep
                      (Unreadable
                         {
                           reader = reader.name;
                           detail = Printf.sprintf "stopped by signal %d" signal;
                         }))
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
  command : source:string -> string;
}

let writer_name writer = writer.writer_name

let writer_reading_stdin ?(environment = []) name args =
  {
    writer_name = name;
    command =
      (fun ~source ->
        String.concat " "
          (environment @ (name :: args)
           @ [ "<"; Filename.quote source; ">/dev/null"; quiet_stderr ]));
  }

let writers =
  [
    writer_reading_stdin ~environment:[ "LC_ALL=en_US.UTF-8" ] "pbcopy" [];
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

let ran_cleanly writer ~source =
  match Unix.system (writer.command ~source) with
  | Unix.WEXITED 0 -> true
  | Unix.WEXITED _ | Unix.WSIGNALED _ | Unix.WSTOPPED _ -> false
  | exception Unix.Unix_error _ -> false

let copy_text session ~write_osc52 text =
  let send reason =
    write_osc52 text;
    Sent_to_terminal reason
  in
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
                if also_terminal then begin
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
                | writer :: later ->
                    if ran_cleanly writer ~source then copied writer
                    else attempt (writer :: failed) later
              in
              if ran_cleanly first ~source then copied first else attempt [] rest))

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

(** See {!Masc_tui_clipboard} (.mli) for the contract. *)

type error =
  | No_reader of { tried : string list }
  | No_image of { reader : string }
  | Unreadable of { reader : string; detail : string }

(* A reader is named by its executable and knows how to put the clipboard's
   image into a file this process opens afterwards. Bytes go through a file
   rather than the child's stdout because the macOS reader has no stdout form:
   AppleScript writes clipboard data to a file handle. *)
type reader =
  { name : string
  ; build : dest:string -> string
  }

let reader_name reader = reader.name
let reader_command reader ~dest = reader.build ~dest

(* AppleScript string syntax, which is not the shell's: backslash and double
   quote are the escapes, and the whole literal is then quoted again for the
   shell by the caller. A temp path with a quote in it would otherwise end the
   AppleScript string early and the script would fail with a syntax error the
   operator cannot act on. *)
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
;;

(* The child's stderr is kept off this terminal. It is a frame being drawn, and
   ColorSync writes to stderr while converting some clipboard images ("Error
   creating a JP2 color space: falling back to sRGB") -- a line that lands
   between two frames leaves the screen no longer what the frame presenter
   believes it wrote. The exit status carries the outcome, so nothing is lost
   by not reading it. *)
let quiet_stderr = "2>/dev/null"

let osascript =
  { name = "osascript"
  ; build =
      (fun ~dest ->
        let literal = applescript_string dest in
        String.concat
          " "
          [ "osascript"
          ; "-e " ^ Filename.quote "set png to (the clipboard as «class PNGf»)"
          ; "-e "
            ^ Filename.quote
                ("set f to open for access POSIX file " ^ literal
                 ^ " with write permission")
            (* The temp file already exists and has a length. Without this the
               write starts at offset 0 and leaves any tail behind it, so a
               second smaller image would arrive with the first one's end
               stuck to it. *)
          ; "-e " ^ Filename.quote "set eof of f to 0"
          ; "-e " ^ Filename.quote "write png to f"
          ; "-e " ^ Filename.quote "close access f"
          ; quiet_stderr
          ])
  }
;;

let wl_paste =
  { name = "wl-paste"
  ; build =
      (fun ~dest ->
        String.concat
          " "
          [ "wl-paste"; "--type"; "image/png"; ">"; Filename.quote dest; quiet_stderr ])
  }
;;

let xclip =
  { name = "xclip"
  ; build =
      (fun ~dest ->
        String.concat
          " "
          [ "xclip"
          ; "-selection"
          ; "clipboard"
          ; "-t"
          ; "image/png"
          ; "-o"
          ; ">"
          ; Filename.quote dest
          ; quiet_stderr
          ])
  }
;;

(* macOS first because its reader is part of the system and cannot be the
   wrong one for the session; the two Linux readers can both be installed
   while only one of them sees the running desktop's clipboard. *)
let readers = [ osascript; wl_paste; xclip ]

let executable_exists name =
  match Sys.getenv_opt "PATH" with
  | None -> false
  | Some path ->
    String.split_on_char ':' path
    |> List.exists (fun dir ->
      if String.equal dir ""
      then false
      else (
        let candidate = Filename.concat dir name in
        match Unix.access candidate [ Unix.X_OK ] with
        | () -> true
        | exception Unix.Unix_error _ -> false))
;;

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
;;

let read_image () =
  match List.filter (fun reader -> executable_exists reader.name) readers with
  | [] -> Error (No_reader { tried = List.map reader_name readers })
  | installed ->
    let dest = Filename.temp_file "masc-tui-clipboard" ".img" in
    Fun.protect
      ~finally:(fun () -> try Sys.remove dest with Sys_error _ -> ())
      (fun () ->
        (* [reported] keeps the first reader's answer. A later reader that is
           installed but blind to this session's clipboard says "no image" too,
           and reporting the last one would name whichever reader happens to be
           at the end of the list instead of the one that could have worked. *)
        let rec attempt reported = function
          | [] ->
            Error
              (match reported with
               | Some error -> error
               | None ->
                 (* [installed] is non-empty, so the walk sets [reported] on
                    its first step. Answering with the list this searched keeps
                    the impossible branch honest rather than inventing a
                    reader name. *)
                 No_reader { tried = List.map reader_name readers })
          | reader :: rest ->
            let keep error =
              attempt (Some (Option.value reported ~default:error)) rest
            in
            (match Unix.system (reader.build ~dest) with
             | Unix.WEXITED 0 ->
               (match read_all dest with
                | Ok bytes when String.length bytes > 0 -> Ok bytes
                | Ok _ ->
                  (* Exit 0 with an empty file: the reader had the selection
                     but nothing in it. Distinct from a non-zero exit, which is
                     the reader saying the clipboard holds no image at all. *)
                  keep
                    (Unreadable
                       { reader = reader.name; detail = "the reader wrote no bytes" })
                | Error detail -> keep (Unreadable { reader = reader.name; detail }))
             | Unix.WEXITED _ -> keep (No_image { reader = reader.name })
             | Unix.WSIGNALED signal ->
               keep
                 (Unreadable
                    { reader = reader.name
                    ; detail = Printf.sprintf "killed by signal %d" signal
                    })
             | Unix.WSTOPPED signal ->
               keep
                 (Unreadable
                    { reader = reader.name
                    ; detail = Printf.sprintf "stopped by signal %d" signal
                    }))
        in
        attempt None installed)
;;

let error_to_string = function
  | No_reader { tried } ->
    Printf.sprintf
      "no clipboard reader found (looked for %s)"
      (String.concat ", " tried)
  | No_image { reader } -> Printf.sprintf "the clipboard holds no image (%s)" reader
  | Unreadable { reader; detail } ->
    Printf.sprintf "%s could not read the clipboard image: %s" reader detail
;;

(* Text goes the other way through a desktop tool that reads its stdin. The
   text is handed over as a file rather than a pipe: a tool that exits before
   reading all of it would leave this process writing into a closed pipe, and
   SIGPIPE would end the TUI. *)
type writer =
  { writer_name : string
  ; command : source:string -> string
  }

let writer_name writer = writer.writer_name

let writer_reading_stdin name args =
  { writer_name = name
  ; command =
      (fun ~source ->
        String.concat " "
          ((name :: args) @ [ "<"; Filename.quote source; ">/dev/null"; quiet_stderr ]))
  }

(* macOS first for the reason the readers put it first. *)
let writers =
  [ writer_reading_stdin "pbcopy" []
  ; writer_reading_stdin "wl-copy" []
  ; writer_reading_stdin "xclip" [ "-selection"; "clipboard"; "-in" ]
  ]

type copy_session = Local | Remote

(* Over SSH the desktop tools on this host fill this host's clipboard, not the
   one the operator pastes from; only the terminal can reach that one. *)
let copy_session getenv =
  match getenv "SSH_CONNECTION", getenv "SSH_TTY" with
  | None, None -> Local
  | Some _, _ | _, Some _ -> Remote

type copy_route =
  | Through_tools of writer list
  | Terminal_only

let copy_route session ~installed =
  match session with
  | Remote -> Terminal_only
  | Local -> (
      match List.filter (fun writer -> installed writer.writer_name) writers with
      | [] -> Terminal_only
      | tools -> Through_tools tools)

type copy_outcome =
  | Copied_by of string
  | Sent_to_terminal of { failed : string list }

let write_through writer text =
  let source = Filename.temp_file "masc-tui-copy" ".txt" in
  Fun.protect
    ~finally:(fun () -> try Sys.remove source with Sys_error _ -> ())
    (fun () ->
      match
        Out_channel.with_open_bin source (fun channel -> Out_channel.output_string channel text)
      with
      | exception Sys_error _ -> false
      | () -> (
          match Unix.system (writer.command ~source) with
          | Unix.WEXITED 0 -> true
          | Unix.WEXITED _ | Unix.WSIGNALED _ | Unix.WSTOPPED _ -> false))

let copy_text session ~write_osc52 text =
  let send_to_terminal failed =
    write_osc52 text;
    Sent_to_terminal { failed = List.rev failed }
  in
  match copy_route session ~installed:executable_exists with
  | Terminal_only -> send_to_terminal []
  | Through_tools tools ->
      let rec attempt failed = function
        | [] -> send_to_terminal failed
        | writer :: rest ->
            if write_through writer text then Copied_by writer.writer_name
            else attempt (writer.writer_name :: failed) rest
      in
      attempt [] tools

let copy_outcome_text = function
  | Copied_by tool -> Printf.sprintf "copied with %s" tool
  | Sent_to_terminal { failed = [] } -> "sent to the terminal as OSC 52 (unconfirmed)"
  | Sent_to_terminal { failed } ->
      Printf.sprintf "sent to the terminal as OSC 52 (unconfirmed) after %s failed"
        (String.concat ", " failed)

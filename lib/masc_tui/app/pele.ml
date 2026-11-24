module Clock = Masc_tui_core.Clock
module Palette = Masc_tui_term.Palette

type format =
  | Mermaid
  | Svg
  | Graph

type scene = {
  format : format;
  source : string;
  max_width : int;
  font_size : int;
  now_ms : int64;
  colors : (string * string) option;
}

type crop = {
  left : float;
  top : float;
  right : float;
  bottom : float;
}

type raster = {
  width : int;
  height : int;
  crop : crop option;
}

type ending =
  | Exited of Unix.process_status
  | Killed_at_deadline
  | Cancelled

type runner = input:string -> output:string -> errors:string -> ending

type response =
  | Confirmed of string
  | Unconfirmed

let protocol_version = 1
let protocol_receipt = Printf.sprintf "masc-pele-protocol:%d" protocol_version
let default_timeout_s = 10.0

let hex_of_rgb rgb =
  Printf.sprintf "#%02x%02x%02x" (Palette.red rgb) (Palette.green rgb)
    (Palette.blue rgb)

let colors_of_palette palette =
  (hex_of_rgb (Palette.foreground palette), hex_of_rgb (Palette.background palette))

let read_response ~pixels path =
  let frame = protocol_receipt ^ "\n" in
  In_channel.with_open_bin path (fun input ->
      match really_input_string input (String.length frame) with
      | receipt when String.equal receipt frame ->
          Confirmed (if pixels then In_channel.input_all input else "")
      | _ -> Unconfirmed
      | exception End_of_file -> Unconfirmed)

let unconfirmed_error detail =
  let hint =
    "Pele helper did not confirm a compatible rendering protocol; install it from the TUI source with scripts/install-pele.sh"
  in
  if String.equal detail "" then hint else hint ^ ": " ^ detail

let scene ~format ~max_width ~font_size ~now_ms ~colors source =
  { format; source; max_width; font_size; now_ms; colors }

let is_regular_executable path =
  try
    let st = Unix.stat path in
    match st.Unix.st_kind with
    | Unix.S_REG ->
        Unix.access path [ Unix.X_OK ];
        true
    | Unix.S_DIR | Unix.S_CHR | Unix.S_BLK | Unix.S_LNK | Unix.S_FIFO
    | Unix.S_SOCK ->
        false
  with Unix.Unix_error _ -> false

let resolve_executable ?(getenv = Sys.getenv_opt)
    ?(executable_name = Sys.executable_name) executable =
  if String.equal (String.trim executable) "" || String.contains executable '/'
  then executable
  else
    let from_path =
      match getenv "PATH" with
      | None -> None
      | Some path_env ->
          String.split_on_char ':' path_env
          |> List.find_map (fun dir ->
                 if String.equal dir "" then None
                 else
                   let candidate = Filename.concat dir executable in
                   if is_regular_executable candidate then Some candidate
                   else None)
    in
    match from_path with
    | Some found -> found
    | None -> (
        let sibling =
          if
            String.equal (String.trim executable_name) ""
            || Filename.is_implicit executable_name
          then None
          else
            let candidate =
              Filename.concat (Filename.dirname executable_name) executable
            in
            if is_regular_executable candidate then Some candidate else None
        in
        match sibling with
        | Some found -> found
        | None -> (
            match getenv "HOME" with
            | Some home when not (String.equal (String.trim home) "") ->
                let candidate =
                  Filename.concat
                    (Filename.concat (Filename.concat home ".local") "bin")
                    executable
                in
                if is_regular_executable candidate then candidate
                else executable
            | Some _ | None -> executable))

let command_runner ?(executable = "masc-pele") ~run ~input ~output ~errors =
  run
    (Printf.sprintf "%s < %s > %s 2> %s" (Filename.quote executable)
       (Filename.quote input) (Filename.quote output) (Filename.quote errors))

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

let safe_close_fd fd =
  match Unix.close fd with
  | () -> ()
  | exception Unix.Unix_error _ -> ()

let process_runner ?(executable = "masc-pele") ?(timeout_s = default_timeout_s)
    ?clock ?(cancelled = fun () -> false) () ~input ~output ~errors =
  if cancelled () then Cancelled
  else
    let resolved = resolve_executable executable in
    let with_file path flags fn =
      let descriptor = Unix.openfile path flags 0o600 in
      Fun.protect ~finally:(fun () -> safe_close_fd descriptor) (fun () -> fn descriptor)
    in
    let pid =
      with_file input [ Unix.O_RDONLY; Unix.O_CLOEXEC ] (fun stdin_fd ->
          with_file output [ Unix.O_WRONLY; Unix.O_TRUNC; Unix.O_CLOEXEC ]
            (fun stdout_fd ->
              with_file errors [ Unix.O_WRONLY; Unix.O_TRUNC; Unix.O_CLOEXEC ]
                (fun stderr_fd ->
                  Unix.create_process resolved [| resolved |] stdin_fd
                    stdout_fd stderr_fd)))
    in
    let timeout_s =
      if Float.is_finite timeout_s && timeout_s > 0.0 then timeout_s
      else default_timeout_s
    in
    let deadline = Clock.Mono.after_s (Clock.Mono.now ()) timeout_s in
    let sleep_step step_s =
      match clock with
      | Some clk -> Eio.Time.sleep clk step_s
      | None -> Unix.sleepf step_s
    in
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
              Killed_at_deadline
            end
            else begin
              sleep_step (Float.min poll_s remaining);
              wait (Float.min 0.025 (poll_s *. 1.5))
            end
        | _, (Unix.WSTOPPED _ as status) ->
            kill_and_reap pid;
            Exited status
        | _, ((Unix.WEXITED _ | Unix.WSIGNALED _) as status) -> Exited status
        | exception Unix.Unix_error (Unix.EINTR, _, _) -> wait poll_s
    in
    try wait 0.005 with
    | Eio.Cancel.Cancelled _ as ex ->
        Eio.Cancel.protect (fun () -> kill_and_reap pid);
        raise ex
    | ex ->
        kill_and_reap pid;
        raise ex

let render ~cache_dir ?timeout_s ?clock ?(cancelled = fun () -> false) ?raster
    ?runner { format; source; max_width; font_size; now_ms; colors } =
  if cancelled () then Error "Pele was cancelled"
  else
  let run_helper =
    match runner with
    | Some r -> r
    | None -> process_runner ?timeout_s ?clock ~cancelled ()
  in
  let paths = ref [] in
  let temporary suffix =
    let path = Filename.temp_file ~temp_dir:cache_dir "pele-" suffix in
    paths := path :: !paths;
    path
  in
  let cleanup () =
    List.iter
      (fun path -> try Sys.remove path with Sys_error _ -> ())
      !paths
  in
  let max_stderr_bytes = 2048 in
  let read_diagnostic path =
    let raw, truncated =
      In_channel.with_open_bin path (fun ch ->
          let buf = Bytes.create (max_stderr_bytes + 1) in
          let rec fill off =
            if off >= Bytes.length buf then (off, true)
            else
              match In_channel.input ch buf off (Bytes.length buf - off) with
              | 0 -> (off, false)
              | n -> fill (off + n)
          in
          let len, trunc = fill 0 in
          let keep = Int.min len max_stderr_bytes in
          (Bytes.sub_string buf 0 keep, trunc || len > max_stderr_bytes))
    in
    let collapsed = Buffer.create (String.length raw) in
    String.iter
      (function
        | '\n' | '\r' | '\t' -> Buffer.add_char collapsed ' '
        | ch -> Buffer.add_char collapsed ch)
      raw;
    let clean =
      String.trim
        (Masc_tui_term.Grapheme.sanitize_controls (Buffer.contents collapsed))
    in
    if truncated then if String.equal clean "" then "…" else clean ^ "…"
    else clean
  in
  Fun.protect ~finally:cleanup (fun () ->
      try
        let input = temporary ".json" in
        let output = temporary ".png" in
        let errors = temporary ".err" in
        let format_str =
          match format with
          | Mermaid -> "mermaid"
          | Svg -> "svg"
          | Graph -> "graph"
        in
        let fields =
          [
            ("protocol", `Int protocol_version);
            ("format", `String format_str);
            ("source", `String source);
            ("maxWidth", `Int max_width);
            ("fontSize", `Int font_size);
            ("now", `Intlit (Int64.to_string now_ms));
          ]
        in
        let fields =
          match raster with
          | None -> fields
          | Some { width; height; crop } ->
              let geometry =
                [ ("width", `Int width); ("height", `Int height) ]
              in
              let geometry =
                match crop with
                | None -> geometry
                | Some { left; top; right; bottom } ->
                    ( "crop",
                      `Assoc
                        [
                          ("left", `Float left);
                          ("top", `Float top);
                          ("right", `Float right);
                          ("bottom", `Float bottom);
                        ] )
                    :: geometry
              in
              ("raster", `Assoc geometry) :: fields
        in
        let fields =
          match colors with
          | None -> fields
          | Some (foreground, background) ->
              ( "colors",
                `Assoc
                  [
                    ("foreground", `String foreground);
                    ("background", `String background);
                  ] )
              :: fields
        in
        Out_channel.with_open_bin input (fun channel ->
            Yojson.Safe.to_channel channel (`Assoc fields));
        match run_helper ~input ~output ~errors with
        | Exited (Unix.WEXITED code) -> (
            match code, read_response ~pixels:(code = 0) output with
            | 0, Confirmed png ->
                if String.length png = 0 then Error "Pele produced no image"
                else Ok png
            | 0, Unconfirmed -> Error (unconfirmed_error "")
            | code, Confirmed _ ->
                let detail = read_diagnostic errors in
                if String.equal detail "" then
                  Error (Printf.sprintf "Pele exited %d" code)
                else Error (Printf.sprintf "Pele exited %d: %s" code detail)
            | code, Unconfirmed ->
                let detail = read_diagnostic errors in
                let detail =
                  if String.equal detail "" then Printf.sprintf "exit %d" code
                  else Printf.sprintf "exit %d: %s" code detail
                in
                Error (unconfirmed_error detail))
        | Exited (Unix.WSIGNALED signal | Unix.WSTOPPED signal) ->
            Error (Printf.sprintf "Pele ended on signal %d" signal)
        | Killed_at_deadline -> Error "Pele was killed at its deadline"
        | Cancelled -> Error "Pele was cancelled"
      with
      | Eio.Cancel.Cancelled _ as ex -> raise ex
      | Unix.Unix_error (Unix.ENOENT, "create_process", _) ->
          Error "masc-pele is not installed; run scripts/install-pele.sh"
      | Unix.Unix_error (error, _, _) -> Error (Unix.error_message error)
      | Sys_error detail -> Error detail)

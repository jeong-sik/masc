type format = Mermaid | Svg
type scene = { format : format; source : string; max_width : int;
  font_size : int; now_ms : int64; colors : (string * string) option }
type crop = { left : float; top : float; right : float; bottom : float }
type raster = { width : int; height : int; crop : crop option }
type runner = input:string -> output:string -> errors:string -> Unix.process_status
type response = Confirmed of string | Unconfirmed
let protocol_version = 1
let protocol_receipt = Printf.sprintf "masc-pele-protocol:%d" protocol_version

let read_response ~pixels path =
  let frame = protocol_receipt ^ "\n" in
  In_channel.with_open_bin path (fun input ->
    match really_input_string input (String.length frame) with
    | receipt when String.equal receipt frame ->
        Confirmed (if pixels then In_channel.input_all input else "")
    | _ -> Unconfirmed
    | exception End_of_file -> Unconfirmed)

let unconfirmed_error detail =
  let hint = "Pele helper did not confirm a compatible rendering protocol; install it from the TUI source with scripts/install-pele.sh" in
  if String.equal detail "" then hint else hint ^ ": " ^ detail

let scene ~format ~max_width ~font_size ~now_ms ~colors source =
  {format;source;max_width;font_size;now_ms;colors}

let command_runner ~run ~input ~output ~errors =
  run (Printf.sprintf "masc-pele < %s > %s 2> %s"
    (Filename.quote input) (Filename.quote output) (Filename.quote errors))

let default_runner ~input ~output ~errors =
  let with_file path flags fn =
    let descriptor = Unix.openfile path flags 0o600 in
    Fun.protect ~finally:(fun () -> Unix.close descriptor) (fun () -> fn descriptor) in
  let pid = with_file input [Unix.O_RDONLY] (fun stdin ->
    with_file output [Unix.O_WRONLY; Unix.O_TRUNC] (fun stdout ->
      with_file errors [Unix.O_WRONLY; Unix.O_TRUNC] (fun stderr ->
        Unix.create_process "masc-pele" [|"masc-pele"|] stdin stdout stderr))) in
  let rec wait () = match Unix.waitpid [] pid with
    | _, status -> status
    | exception Unix.Unix_error (Unix.EINTR, _, _) -> wait () in
  wait ()

let render ~cache_dir ?raster ?(runner=default_runner) {format;source;max_width;font_size;now_ms;colors} =
  let paths = ref [] in
  let temporary suffix =
    let path = Filename.temp_file ~temp_dir:cache_dir "pele-" suffix in
    paths := path :: !paths;
    path in
  let cleanup () = List.iter (fun path ->
    try Sys.remove path with Sys_error _ -> ()) !paths in
  let read path = In_channel.with_open_bin path In_channel.input_all in
  Fun.protect ~finally:cleanup (fun () ->
    try
      let input = temporary ".json" in
      let output = temporary ".png" in
      let errors = temporary ".err" in
      let fields = ["protocol", `Int protocol_version;
                    "format", `String (match format with Mermaid -> "mermaid" | Svg -> "svg");
                    "source", `String source; "maxWidth", `Int max_width;
                    "fontSize", `Int font_size; "now", `Intlit (Int64.to_string now_ms)] in
      let fields = match raster with
        | None -> fields
        | Some {width;height;crop} ->
            let geometry = ["width", `Int width; "height", `Int height] in
            let geometry = match crop with
              | None -> geometry
              | Some {left;top;right;bottom} ->
                  ("crop", `Assoc ["left", `Float left; "top", `Float top;
                    "right", `Float right; "bottom", `Float bottom]) :: geometry in
            ("raster", `Assoc geometry) :: fields in
      let fields = match colors with
        | None -> fields
        | Some (foreground, background) ->
            ("colors", `Assoc ["foreground", `String foreground;
                              "background", `String background]) :: fields in
      Out_channel.with_open_bin input (fun channel ->
        Yojson.Safe.to_channel channel (`Assoc fields));
      match runner ~input ~output ~errors with
      | Unix.WEXITED code ->
          (match code, read_response ~pixels:(code = 0) output with
           | 0, Confirmed png ->
               if String.length png = 0 then Error "Pele produced no image" else Ok png
           | 0, Unconfirmed -> Error (unconfirmed_error "")
           | code, Confirmed _ ->
               Error (Printf.sprintf "Pele exited %d: %s" code (String.trim (read errors)))
           | code, Unconfirmed ->
               let detail = String.trim (read errors) in
               let detail = if String.equal detail "" then Printf.sprintf "exit %d" code
                 else Printf.sprintf "exit %d: %s" code detail in
               Error (unconfirmed_error detail))
      | Unix.WSIGNALED signal | Unix.WSTOPPED signal ->
          Error (Printf.sprintf "Pele ended on signal %d" signal)
    with
    | Unix.Unix_error (Unix.ENOENT, "create_process", _) ->
        Error "masc-pele is not installed; run scripts/install-pele.sh"
    | Unix.Unix_error (error, _, _) -> Error (Unix.error_message error)
    | Sys_error detail -> Error detail)

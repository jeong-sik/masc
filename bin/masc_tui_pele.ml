type format = Mermaid | Svg

let render ~format ~cache_dir ~max_width ~colors source =
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
      let fields = ["format", `String (match format with Mermaid -> "mermaid" | Svg -> "svg");
                    "source", `String source; "maxWidth", `Int max_width] in
      let fields = match colors with
        | None -> fields
        | Some (foreground, background) ->
            ("colors", `Assoc ["foreground", `String foreground;
                              "background", `String background]) :: fields in
      Out_channel.with_open_bin input (fun channel ->
        Yojson.Safe.to_channel channel (`Assoc fields));
      let with_file path flags fn =
        let descriptor = Unix.openfile path flags 0o600 in
        Fun.protect ~finally:(fun () -> Unix.close descriptor)
          (fun () -> fn descriptor) in
      let pid = with_file input [Unix.O_RDONLY] (fun stdin ->
        with_file output [Unix.O_WRONLY; Unix.O_TRUNC] (fun stdout ->
          with_file errors [Unix.O_WRONLY; Unix.O_TRUNC] (fun stderr ->
            Unix.create_process "masc-pele" [|"masc-pele"|] stdin stdout stderr))) in
      let rec wait () =
        match Unix.waitpid [] pid with
        | _, status -> status
        | exception Unix.Unix_error (Unix.EINTR, _, _) -> wait () in
      match wait () with
      | Unix.WEXITED 0 ->
          let png = read output in
          if String.length png = 0 then Error "Pele produced no image" else Ok png
      | Unix.WEXITED code ->
          Error (Printf.sprintf "Pele exited %d: %s" code (String.trim (read errors)))
      | Unix.WSIGNALED signal | Unix.WSTOPPED signal ->
          Error (Printf.sprintf "Pele ended on signal %d" signal)
    with
    | Unix.Unix_error (Unix.ENOENT, "create_process", _) ->
        Error "masc-pele is not installed; run scripts/install-pele.sh"
    | Unix.Unix_error (error, _, _) -> Error (Unix.error_message error)
    | Sys_error detail -> Error detail)

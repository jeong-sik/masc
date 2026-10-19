let executable = "masc-alphatex"

let program () =
  let path = match Sys.getenv_opt "PATH" with Some path -> path | None -> "" in
  String.split_on_char ':' path
  |> List.filter_map (fun directory ->
       let candidate = Filename.concat directory executable in
       match Unix.access candidate [Unix.X_OK] with
       | () when not (Sys.is_directory candidate) -> Some candidate
       | () -> None
       | exception Unix.Unix_error _ -> None)
  |> List.find_opt (fun _ -> true)

let available () = Option.is_some (program ())

let run_child ~restore ~reenter executable args =
  match
    Fun.protect ~finally:reenter (fun () ->
      restore ();
      let child = Unix.create_process executable (Array.of_list (executable :: args))
        Unix.stdin Unix.stdout Unix.stderr in
      let rec wait () =
        match Unix.waitpid [] child with
        | _, status -> status
        | exception Unix.Unix_error (Unix.EINTR, _, _) -> wait () in
      match wait () with
      | Unix.WEXITED 0 -> Ok ()
      | Unix.WEXITED code -> Error (Printf.sprintf "music viewer exited %d" code)
      | Unix.WSIGNALED signal | Unix.WSTOPPED signal ->
          Error (Printf.sprintf "music viewer ended on signal %d" signal))
  with
  | result -> result
  | exception ((Unix.Unix_error _ | Sys_error _) as failure) ->
      Error (Printexc.to_string failure)

let launch_music ~restore ~reenter ~project_root ~session_root ~soundfont =
  match program () with
  | None -> Error "masc-alphatex is not installed; run scripts/install-alphatex.sh"
  | Some executable ->
      let args = ["--music"; "--project-root"; project_root; "--session-root"; session_root]
        @ (match soundfont with Some path -> ["--soundfont"; path] | None -> []) in
      run_child ~restore ~reenter executable args

let launch ~restore ~reenter ~sources ~index ~cell_pixels:(cell_width, cell_height)
    ~soundfont =
  match program () with
  | None -> Error "masc-alphatex is not installed; run scripts/install-alphatex.sh"
  | Some executable ->
    let snapshot = Filename.temp_file "masc-score-" ".json" in
    let remove_snapshot () =
      match Sys.remove snapshot with
      | () -> ()
      | exception Sys_error _ -> () in
    Fun.protect ~finally:remove_snapshot (fun () ->
      let run () =
        let channel = open_out_bin snapshot in
        Fun.protect ~finally:(fun () -> close_out_noerr channel) (fun () ->
          Yojson.Safe.to_channel channel
            (`Assoc ["sources", `List (List.map (fun source -> `String source) sources)]));
        let args = ["--bundle"; snapshot; "--index"; string_of_int index;
          "--cell-width"; string_of_int cell_width; "--cell-height"; string_of_int cell_height]
          @ (match soundfont with Some path -> ["--soundfont"; path] | None -> []) in
        run_child ~restore ~reenter executable args in
      match run () with
      | result -> result
      | exception ((Unix.Unix_error _ | Sys_error _) as failure) ->
          Error (Printexc.to_string failure))

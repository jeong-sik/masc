let known_sidecars = [ "discord"; "slack"; "telegram"; "imessage"; "cli" ]

let sidecar_dir = function
  | "discord" -> Some "sidecars/discord-bot"
  | "slack" -> Some "sidecars/slack-bot"
  | "telegram" -> Some "sidecars/telegram-bot"
  | "imessage" -> Some "sidecars/imessage-bot"
  | "cli" -> Some "sidecars/cli-connector"
  | _ -> None

let known_summary = String.concat "|" known_sidecars

let aggregate_exit_code rcs =
  let normalise rc = if rc < 0 || rc > 2 then 2 else rc in
  List.fold_left (fun acc rc -> max acc (normalise rc)) 0 rcs

let python_bin () =
  Sys.getenv_opt "MASC_PYTHON" |> Option.value ~default:"python3"

let capture_sidecar_json name =
  match sidecar_dir name with
  | None -> Error (Printf.sprintf "unknown sidecar: %s" name)
  | Some rel_dir ->
    let abs_dir =
      if Filename.is_relative rel_dir
      then Filename.concat (Sys.getcwd ()) rel_dir
      else rel_dir
    in
    if not (Sys.file_exists abs_dir)
    then Error (Printf.sprintf "sidecar directory not found: %s" abs_dir)
    else begin
      let prev = Sys.getcwd () in
      Sys.chdir abs_dir;
      let result =
        try
          let python = python_bin () in
          let buf, status =
            With_process.with_process_args_in
              python
              [| python; "-m"; "src"; "doctor"; "--json" |]
              With_process.drain_to_buffer
          in
          let rc =
            match status with
            | Unix.WEXITED n -> n
            | Unix.WSIGNALED _ | Unix.WSTOPPED _ -> 2
          in
          Ok (Buffer.contents buf, rc)
        with e -> Error (Printexc.to_string e)
      in
      Sys.chdir prev;
      result
    end

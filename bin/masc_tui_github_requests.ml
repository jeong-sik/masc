(** GitHub device-flow streaming and token-save request execution. *)

open Masc_tui_types
open Masc_tui_async_protocol

(* The device-flow login, streamed. gh prints the one-time code on its
   own output, which the server forwards redacted; every data line lands
   in the GitHub tab as it arrives so the operator can read the code and
   finish in the browser. When the stream ends the tab re-reads the
   identity observation, which is the fact the login was for. *)
let launch_login state ~host ~deliver keeper_name =
  let port = state.port in
  (* Read once, at the key press: ticking another scope while the device flow
     waits on the browser must not change what this login asked for. *)
  let scopes = state.github_login_scopes in
  let run () =
    match Eio_context.get_clock_opt () with
    | None ->
      deliver (Github_login_finished (keeper_name, Error "Eio clock is unavailable"))
    | Some clock ->
      let reader = Masc_tui_sse_lines.create () in
      let flush_lines chunk =
        let lines =
          Masc_tui_sse_lines.feed reader chunk
          |> List.filter_map (fun line ->
            let line = String.trim line in
            if String.length line > 6 && String.sub line 0 6 = "data: "
            then (
              let payload = String.sub line 6 (String.length line - 6) in
              match Yojson.Safe.from_string payload with
              | `Assoc fields ->
                (match List.assoc_opt "text" fields with
                 | Some (`String text) -> Some (String.split_on_char '\n' text)
                 | _ ->
                   (match List.assoc_opt "message" fields with
                    | Some (`String message) -> Some [ "error: " ^ message ]
                    | _ -> Some [ payload ]))
              | _ | (exception Yojson.Json_error _) -> Some [ payload ])
            else None)
          |> List.concat
          |> List.map Masc.Tui_terminal_text.sanitize_terminal_text
          |> List.filter (fun line -> String.trim line <> "")
        in
        if lines <> [] then deliver (Github_login_lines (keeper_name, lines))
      in
      let result =
        try
          Masc_tui_http.post_keeper_github_login_streaming
            ~clock
            ~host
            ~port
            ~keeper_name
            ~scopes
            ~on_chunk:flush_lines
        with
        | Eio.Cancel.Cancelled _ as exn -> raise exn
        | exn -> Error (Printexc.to_string exn)
      in
      deliver (Github_login_finished (keeper_name, result))
  in
  match Eio_context.get_switch_opt () with
  | Some sw ->
    Eio.Fiber.fork_daemon ~sw (fun () ->
      run ();
      `Stop_daemon)
  | None ->
    deliver (Github_login_finished (keeper_name, Error "Eio switch is unavailable"))
;;

let launch_token_save state ~host ~deliver keeper_name token =
  let port = state.port in
  let run () =
    let result =
      try Masc_tui_http.post_keeper_github_token ~host ~port ~keeper_name ~token () with
      | Eio.Cancel.Cancelled _ as exn -> raise exn
      | exn -> Error (Printexc.to_string exn)
    in
    deliver (Github_token_saved (keeper_name, result))
  in
  match Eio_context.get_switch_opt () with
  | Some sw ->
    Eio.Fiber.fork_daemon ~sw (fun () ->
      run ();
      `Stop_daemon)
  | None -> deliver (Github_token_saved (keeper_name, Error "Eio switch is unavailable"))
;;

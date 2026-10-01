(** Identity view, provider change and OAuth request execution. *)

open Masc_tui_types
open Masc_tui_async_protocol

let launch_github_view state ~host ~deliver keeper_name =
  let request = mark_detail_read_started state ~tab:Detail_github ~keeper:keeper_name in
  let port = state.port in
  Masc_tui_async_read.launch
    ~deliver:(fun result -> deliver (Github_identity_view_loaded (request, result)))
    (fun () -> Masc_tui_loader.load_keeper_github_identity_view ~host ~port ~keeper_name)
;;

let launch_view state ~host ~deliver keeper_name =
  let request = mark_detail_read_started state ~tab:Detail_identity ~keeper:keeper_name in
  let port = state.port in
  Masc_tui_async_read.launch
    ~deliver:(fun result -> deliver (Identity_providers_loaded (request, result)))
    (fun () -> Masc_tui_loader.load_identity_providers ~host ~port ~keeper_name)
;;

(* Throw or clear one attached service's switch. Off keeps the token and
   catalog; the keeper's turns stop being handed that provider's tools. *)
let launch_switch state ~host ~deliver ~keeper_name ~provider_id ~enabled =
  let port = state.port in
  let run () =
    let result =
      try
        Masc_tui_http.post_identity_switch ~host ~port ~keeper_name ~provider_id ~enabled
      with
      | Eio.Cancel.Cancelled _ as exn -> raise exn
      | exn -> Error (Printexc.to_string exn)
    in
    deliver (Identity_switch_set (keeper_name, provider_id, enabled, result))
  in
  match Eio_context.get_switch_opt () with
  | Some sw ->
    Eio.Fiber.fork_daemon ~sw (fun () ->
      run ();
      `Stop_daemon)
  | None ->
    deliver
      (Identity_switch_set
         (keeper_name, provider_id, enabled, Error "Eio switch is unavailable"))
;;

(* Recording an app the operator made. Answers on the same notice line a
   failed attempt uses -- what an operator wants after pressing save is one
   sentence saying whether it took, in the place they are already reading. *)
let launch_app_save state ~host ~deliver ~(form : Masc_tui_identity_model.identity_app_form) =
  let port = state.port in
  let provider_id = form.Masc_tui_identity_model.iaf_provider in
  let client_id = form.Masc_tui_identity_model.iaf_client_id in
  let client_secret = form.Masc_tui_identity_model.iaf_client_secret in
  let scopes = form.Masc_tui_identity_model.iaf_scopes in
  let run () =
    let result =
      try
        match
          Masc_tui_http.post_keeper_oauth_client
            ~host
            ~port
            ~provider_id
            ~client_id
            ~client_secret
            ~scopes
        with
        | Error err -> Error err
        | Ok json ->
          Masc.Tui_decode.decode_oauth_client_saved json
          |> Result.map_error (fun detail ->
            "app recorded, but the reply could not be read: " ^ detail)
      with
      | Eio.Cancel.Cancelled _ as exn -> raise exn
      | exn -> Error (Printexc.to_string exn)
    in
    deliver (Identity_app_saved (provider_id, result))
  in
  match Eio_context.get_switch_opt () with
  | Some sw ->
    Eio.Fiber.fork_daemon ~sw (fun () ->
      run ();
      `Stop_daemon)
  | None -> deliver (Identity_app_saved (provider_id, Error "Eio switch is unavailable"))
;;

(* Begin a login. The answer is a URL the operator has to open; nothing is
   written to the keeper until the browser comes back to the server. *)
let launch_login state ~host ~deliver ~keeper_name ~provider_id ~label =
  let port = state.port in
  let run () =
    let result =
      try
        match
          Masc_tui_http.post_keeper_oauth_login ~host ~port ~keeper_name ~provider_id
        with
        | Error err -> Masc_tui_identity_model.Login_failed err
        | Ok json ->
          (match json with
           | `Assoc fields ->
             (match List.assoc_opt "attached" fields with
              | Some (`Bool true) ->
                let msg =
                  match List.assoc_opt "message" fields with
                  | Some (`String m) -> m
                  | _ -> label ^ ": credentials attached."
                in
                deliver (Identity_refreshed (keeper_name, Ok ()));
                Masc_tui_identity_model.Login_attached msg
              | _ ->
                (match List.assoc_opt "authorize_url" fields with
                 | Some (`String url) ->
                   let provider_id =
                     match List.assoc_opt "provider" fields with
                     | Some (`String id) -> id
                     | Some _ | None -> provider_id
                   in
                   (* Opened here, on this fiber, because the URL is about
                           nine hundred characters and a pane truncates it -- an
                           operator cannot select what is not on screen. It is
                           still printed below, wrapped, for the machine that has
                           no opener. *)
                   (match Masc_tui_browser.open_url url with
                    | Ok _ | Error _ -> ());
                   Masc_tui_identity_model.Login_started { provider_id; label; url }
                 | Some _ | None ->
                   Masc_tui_identity_model.Login_failed
                     "the server answered without an authorize_url"))
           | _ ->
             Masc_tui_identity_model.Login_failed
               "the server answered with something this cannot read")
      with
      | Eio.Cancel.Cancelled _ as exn -> raise exn
      | exn -> Masc_tui_identity_model.Login_failed (Printexc.to_string exn)
    in
    deliver (Identity_login_started (keeper_name, result))
  in
  match Eio_context.get_switch_opt () with
  | Some sw ->
    Eio.Fiber.fork_daemon ~sw (fun () ->
      run ();
      `Stop_daemon)
  | None ->
    deliver
      (Identity_login_started
         (keeper_name, Masc_tui_identity_model.Login_failed "Eio switch is unavailable"))
;;

(* Ask every attached service again what tools it has. An operator action
   rather than a timer: a stale catalog is visible and fixable, while a timer
   is a network call nobody asked for. *)
let launch_refresh state ~host ~deliver ~keeper_name ~provider_ids =
  let port = state.port in
  let run () =
    let result =
      try
        List.fold_left
          (fun acc provider_id ->
             match acc with
             | Error _ as err -> err
             | Ok () ->
               (match
                  Masc_tui_http.post_keeper_identity_refresh
                    ~host
                    ~port
                    ~keeper_name
                    ~provider_id
                with
                | Ok _ -> Ok ()
                | Error err -> Error (provider_id ^ ": " ^ err)))
          (Ok ())
          provider_ids
      with
      | Eio.Cancel.Cancelled _ as exn -> raise exn
      | exn -> Error (Printexc.to_string exn)
    in
    deliver (Identity_refreshed (keeper_name, result))
  in
  match Eio_context.get_switch_opt () with
  | Some sw ->
    Eio.Fiber.fork_daemon ~sw (fun () ->
      run ();
      `Stop_daemon)
  | None -> deliver (Identity_refreshed (keeper_name, Error "Eio switch is unavailable"))
;;

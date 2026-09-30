(** Identity response transitions on the UI state owner fiber. *)

open Masc_tui_types

let github_view_loaded (state : state) request result =
  let keeper_name = request.drr_keeper in
  let current = Masc_tui_types.finish_detail_read state request in
  let still_selected =
    match List.nth_opt state.keepers state.keeper_cursor with
    | Some keeper -> String.equal keeper.k_name keeper_name
    | None -> false
  in
  if current && still_selected
  then (
    match result with
    | Ok lines ->
      state.github_identity_view <- Some (keeper_name, lines);
      state.github_identity_view_error <- None
    | Error detail -> state.github_identity_view_error <- Some detail)
;;

let switch_set (state : state) ~keeper_name ~provider_id ~enabled ~report ~refresh result =
  match result with
  | Ok () ->
    report
      "system"
      (Printf.sprintf
         "%s: %s switched %s"
         keeper_name
         provider_id
         (if enabled then "on" else "off"));
    (* Re-read rather than patch what is on screen: the switch the
              server just wrote is the answer. *)
    refresh keeper_name
  | Error detail ->
    state.identity_attempt_error
    <- Some (Masc_tui_identity_model.Notice_bad, Printf.sprintf "switch %s: %s" provider_id detail)
;;

let providers_loaded (state : state) request result =
  let keeper_name = request.drr_keeper in
  let current = Masc_tui_types.finish_detail_read state request in
  let still_selected =
    match List.nth_opt state.keepers state.keeper_cursor with
    | Some keeper -> String.equal keeper.k_name keeper_name
    | None -> false
  in
  if current && still_selected
  then (
    match result with
    | Ok providers ->
      state.identity_view <- Some (keeper_name, providers);
      state.identity_view_error <- None;
      (* The login this TUI started has landed once the service it was
               for reports tools. Clearing it is what stops the tick from
               asking again -- a poll with no end condition is a poll that
               runs for the life of the process. *)
      (match state.identity_login with
       | Some login when Masc_tui_identity_model.identity_login_landed ~providers ~login ->
         state.identity_login <- None
       | Some _ | None -> ())
    | Error detail -> state.identity_view_error <- Some detail)
;;

let login_started (state : state) ~keeper_name result =
  match result with
  | Masc_tui_identity_model.Login_started { provider_id; label; url } ->
    state.identity_login
    <- Some
         { ils_keeper = keeper_name
         ; ils_provider = provider_id
         ; ils_label = label
         ; ils_url = url
         };
    state.identity_attempt_error <- None
  (* Shown on the tab rather than swallowed: the operator pressed a key
         and has to learn that nothing is going to open. Beside the list
         rather than instead of it -- one provider refusing is not a reason
         to take the others off the screen, and the message that matters
         most here is the one telling them what to do about it. *)
  | Masc_tui_identity_model.Login_attached msg ->
    state.identity_attempt_error <- Some (Masc_tui_identity_model.Notice_ok, msg)
  | Masc_tui_identity_model.Login_failed detail ->
    state.identity_attempt_error <- Some (Masc_tui_identity_model.Notice_bad, detail)
;;

let app_saved (state : state) ~provider_id result =
  state.identity_attempt_error
  <- Some
       (match result with
        | Ok 0 ->
          ( Masc_tui_identity_model.Notice_ok
          , Printf.sprintf
              "%s: app recorded. No scopes given, so the service's own list is what will \
               be asked for."
              provider_id )
        | Ok count ->
          ( Masc_tui_identity_model.Notice_ok
          , Printf.sprintf
              "%s: app recorded, asking for %d scope%s."
              provider_id
              count
              (if count = 1 then "" else "s") )
        | Error detail ->
          Masc_tui_identity_model.Notice_bad, Printf.sprintf "%s: %s" provider_id detail)
;;

let refreshed (state : state) ~keeper_name ~refresh result =
  match result with
  (* Re-read rather than patch what is on screen: the catalog the server
         just wrote is the answer, and building a second copy of it here is
         how the two come to disagree. *)
  | Ok () ->
    state.identity_view <- None;
    state.identity_view_error <- None;
    refresh keeper_name
  | Error detail -> state.identity_view_error <- Some detail
;;

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
  if current && still_selected && server_authority_ready state
  then (
    match result with
    | Ok lines ->
      state.github_identity_view <- Some (keeper_name, lines);
      state.github_identity_view_error <- None
    | Error detail -> state.github_identity_view_error <- Some detail)
;;

let switch_set
      (state : state)
      ~keeper_name
      ~provider_id
      ~enabled
      ~report
      ~refresh
      ~notice
      result
  =
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
    if keeper_detail_target_matches state keeper_name then refresh keeper_name
  | Error detail ->
    notice
      ~keeper_name:(Some keeper_name)
      ( Masc_tui_identity_model.Notice_bad
      , Printf.sprintf "switch %s: %s" provider_id detail )
;;

let providers_loaded (state : state) request result =
  let keeper_name = request.drr_keeper in
  let current = Masc_tui_types.finish_detail_read state request in
  if current
  then (
    match result with
    | Ok providers ->
      retire_identity_logins state ~keeper_name ~providers;
      forget_identity_login_expectations state ~keeper_name ~providers
    | Error _ -> ());
  if current && keeper_detail_target_matches state keeper_name
  then (
    match result with
    | Ok providers ->
      state.identity_view <- Some (keeper_name, providers);
      state.identity_view_error <- None
    | Error detail -> state.identity_view_error <- Some detail)
;;

let login_started (state : state) request ~report ~notice result =
  let keeper_name = request.ilr_keeper in
  let current = finish_identity_login_request state request in
  if current
  then (
    match result with
    | Masc_tui_identity_model.Login_started { provider_id; label; url } ->
      remember_identity_login
        state
        { ils_keeper = keeper_name
        ; ils_provider = provider_id
        ; ils_label = label
        ; ils_url = url
        };
      (match state.server_identity with
       | Some origin -> remember_identity_login_expectation state
           { ile_origin = origin; ile_keeper = keeper_name; ile_provider = provider_id }
       | None -> ());
      if keeper_detail_target_matches state keeper_name
      then state.identity_attempt_error <- None;
      report "system" (Printf.sprintf "%s: %s login started" keeper_name provider_id)
    | Masc_tui_identity_model.Login_attached msg ->
      forget_identity_login state ~keeper_name ~provider_id:request.ilr_provider;
      notice ~keeper_name:(Some keeper_name) (Masc_tui_identity_model.Notice_ok, msg)
    | Masc_tui_identity_model.Login_failed detail ->
      notice ~keeper_name:(Some keeper_name) (Masc_tui_identity_model.Notice_bad, detail))
  else
    report
      "system"
      (Printf.sprintf
         "%s: previous %s login response received; newer attempt retained"
         keeper_name
         request.ilr_provider)
;;

let app_saved ~keeper_name ~provider_id ~notice result =
  notice
    ~keeper_name
    (match result with
     | Ok 0 ->
       ( Masc_tui_identity_model.Notice_ok
       , Printf.sprintf
           "%s: app recorded. No scopes given, so the service's own list is what will be \
            asked for."
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

let refreshed (state : state) ~keeper_name ~refresh ~report result =
  (* The action still completed for its original Keeper. A delayed result
         cannot clear the reading or file its error under a new selection. *)
  if keeper_detail_target_matches state keeper_name
  then (
    match result with
    | Ok () ->
      state.identity_view <- None;
      state.identity_view_error <- None;
      refresh keeper_name
    | Error detail -> state.identity_view_error <- Some detail)
  else
    report
      "system"
      (match result with
       | Ok () -> Printf.sprintf "%s: identity refreshed" keeper_name
       | Error detail ->
         Printf.sprintf "%s: identity refresh failed: %s" keeper_name detail)
;;

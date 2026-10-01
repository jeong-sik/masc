(** Identity key and paste transitions on the UI owner fiber. Request and
    scroll effects are supplied by the caller. *)

open Masc_tui_types

(* The query the list is showing, which is the empty one whenever the filter
   is not open. Asked here so the renderer, the cursor and the keys all read
   the same list. *)
let current_query (state : state) = Option.value state.identity_filter ~default:""

let app_form_key (state : state) ~save key =
  match state.identity_app_form with
  | None -> ()
  | Some form ->
    let set text =
      state.identity_app_form
      <- Some
           (match form.Masc_tui_identity_model.iaf_field with
            | Masc_tui_identity_model.App_client_id ->
              { form with Masc_tui_identity_model.iaf_client_id = text }
            | Masc_tui_identity_model.App_client_secret ->
              { form with Masc_tui_identity_model.iaf_client_secret = text }
            | Masc_tui_identity_model.App_scopes ->
              { form with Masc_tui_identity_model.iaf_scopes = text })
    in
    let current =
      match form.Masc_tui_identity_model.iaf_field with
      | Masc_tui_identity_model.App_client_id ->
        form.Masc_tui_identity_model.iaf_client_id
      | Masc_tui_identity_model.App_client_secret ->
        form.Masc_tui_identity_model.iaf_client_secret
      | Masc_tui_identity_model.App_scopes -> form.Masc_tui_identity_model.iaf_scopes
    in
    (match key with
     | "esc" -> state.identity_app_form <- None
     | "\127" | "\b" -> set (Masc_tui_message_layout.drop_last_utf8_scalar current)
     | "\r" | "\n" ->
       (match form.Masc_tui_identity_model.iaf_field with
        | Masc_tui_identity_model.App_client_id ->
          state.identity_app_form
          <- Some
               { form with
                 Masc_tui_identity_model.iaf_field =
                   Masc_tui_identity_model.App_client_secret
               }
        | Masc_tui_identity_model.App_client_secret ->
          state.identity_app_form
          <- Some
               { form with
                 Masc_tui_identity_model.iaf_field = Masc_tui_identity_model.App_scopes
               }
        | Masc_tui_identity_model.App_scopes ->
          save ~form;
          state.identity_app_form <- None)
     | s
       when (String.length s = 1 && Char.code s.[0] >= 32)
            || (String.length s > 1 && Char.code s.[0] >= 0x80) -> set (current ^ s)
     | _ -> ())
;;

let toggle (state : state) ~switch ~report =
  match selected_keeper state, state.identity_view with
  | Some keeper, Some (stamp, providers) when String.equal stamp keeper.k_name ->
    (match
       Masc_tui_identity_model.identity_cursor_provider
         ~query:(current_query state)
         ~providers
         state.identity_cursor
     with
     | Some (provider_id, _) ->
       let row =
         List.find_map
           (function
             | Masc_tui_identity_model.Identity_declared
                 { idp_id; idp_tools; idp_enabled; idp_switch_problem; _ }
               when String.equal idp_id provider_id ->
               Some (idp_tools, idp_enabled, idp_switch_problem)
             | Masc_tui_identity_model.Identity_declared _
             | Masc_tui_identity_model.Identity_unreadable _ -> None)
           providers
       in
       (match row with
        | Some (Some _, enabled, None) ->
          state.identity_attempt_error <- None;
          switch ~keeper_name:keeper.k_name ~provider_id ~enabled:(enabled = Some false)
        | Some (Some _, _, Some problem) ->
          state.identity_attempt_error
          <- Some
               (Masc_tui_identity_model.Notice_bad, "switch store unreadable: " ^ problem)
        | Some (None, _, _) | None ->
          report "system" "connect it first; the switch is for an attached service")
     | None -> ())
  | Some _, (Some _ | None) | None, _ -> ()
;;

let open_app_form (state : state) =
  match selected_keeper state, state.identity_view with
  | Some keeper, Some (stamp, providers) when String.equal stamp keeper.k_name ->
    (match
       Masc_tui_identity_model.identity_cursor_provider
         ~query:(current_query state)
         ~providers
         state.identity_cursor
     with
     | Some (provider_id, label) ->
       state.identity_attempt_error <- None;
       state.identity_app_form
       <- Some
            { Masc_tui_identity_model.iaf_provider = provider_id
            ; iaf_label = label
            ; iaf_field = Masc_tui_identity_model.App_client_id
            ; iaf_client_id = ""
            ; iaf_client_secret = ""
            ; iaf_scopes = ""
            }
     | None -> ())
  | Some _, (Some _ | None) | None, _ -> ()
;;

let filter_key (state : state) ~move_cursor ~login key =
  let query = Option.value state.identity_filter ~default:"" in
  let narrow text =
    state.identity_filter <- Some text;
    (* Back to the top: the row the cursor was on may not be in the
       shorter list, and keeping the index would move the marker to
       whatever happens to sit there now. *)
    state.identity_cursor <- 0
  in
  match key with
  | "esc" -> state.identity_filter <- None
  | "up" -> move_cursor ~delta:(-1)
  | "down" -> move_cursor ~delta:1
  | "\127" | "\b" ->
    if String.equal query ""
    then state.identity_filter <- None
    else narrow (Masc_tui_message_layout.drop_last_utf8_scalar query)
  | "\r" | "\n" ->
    (match selected_keeper state, state.identity_view with
     | Some keeper, Some (stamp, providers) when String.equal stamp keeper.k_name ->
       (match
          Masc_tui_identity_model.identity_cursor_provider
            ~query:(current_query state)
            ~providers
            state.identity_cursor
        with
        | Some (provider_id, label) ->
          state.identity_login <- None;
          state.identity_attempt_error <- None;
          login ~keeper_name:keeper.k_name ~provider_id ~label
        | None -> ())
     | Some _, (Some _ | None) | None, _ -> ())
  | s
    when (String.length s = 1 && Char.code s.[0] >= 32)
         || (String.length s > 1 && Char.code s.[0] >= 0x80) -> narrow (query ^ s)
  | _ -> ()
;;

let start_numbered (state : state) ~login ~index =
  let wanted = index in
  match selected_keeper state, state.identity_view with
  | Some keeper, Some (stamp, providers) when String.equal stamp keeper.k_name ->
    (match
       List.nth_opt
         (Masc_tui_identity_model.identity_connectable
            ~query:(current_query state)
            providers)
         wanted
     with
     | Some (provider_id, label) ->
       (* Left where the operator pressed, so the marker and the
             arrows carry on from the row they just started. *)
       state.identity_cursor <- wanted;
       state.identity_login <- None;
       state.identity_attempt_error <- None;
       login ~keeper_name:keeper.k_name ~provider_id ~label
     | None -> ())
  | Some _, (Some _ | None) | None, _ -> ()
;;

let refresh_attached (state : state) ~refresh =
  match selected_keeper state, state.identity_view with
  | Some keeper, Some (stamp, providers) when String.equal stamp keeper.k_name ->
    let attached =
      List.filter_map
        (function
          | Masc_tui_identity_model.Identity_declared { idp_id; idp_tools = Some _; _ } ->
            Some idp_id
          | Masc_tui_identity_model.Identity_declared _
          | Masc_tui_identity_model.Identity_unreadable _ -> None)
        providers
    in
    if attached <> [] then refresh ~keeper_name:keeper.k_name ~provider_ids:attached
  | Some _, (Some _ | None) | None, _ -> ()
;;

let start_cursor (state : state) ~login =
  match selected_keeper state, state.identity_view with
  | Some keeper, Some (stamp, providers) when String.equal stamp keeper.k_name ->
    (match
       Masc_tui_identity_model.identity_cursor_provider
         ~query:(current_query state)
         ~providers
         state.identity_cursor
     with
     | Some (provider_id, label) ->
       state.identity_login <- None;
       state.identity_attempt_error <- None;
       login ~keeper_name:keeper.k_name ~provider_id ~label
     | None -> ())
  | Some _, (Some _ | None) | None, _ -> ()
;;

let paste_form (state : state) text =
  Option.iter
    (fun form ->
       state.identity_app_form
       <- Some
            (match form.Masc_tui_identity_model.iaf_field with
             | Masc_tui_identity_model.App_client_id ->
               { form with
                 Masc_tui_identity_model.iaf_client_id =
                   form.Masc_tui_identity_model.iaf_client_id ^ text
               }
             | Masc_tui_identity_model.App_client_secret ->
               { form with
                 Masc_tui_identity_model.iaf_client_secret =
                   form.Masc_tui_identity_model.iaf_client_secret ^ text
               }
             | Masc_tui_identity_model.App_scopes ->
               { form with
                 Masc_tui_identity_model.iaf_scopes =
                   form.Masc_tui_identity_model.iaf_scopes ^ text
               }))
    state.identity_app_form
;;

let paste_filter (state : state) text =
  state.identity_filter <- Some (Option.value state.identity_filter ~default:"" ^ text);
  state.identity_cursor <- 0
;;

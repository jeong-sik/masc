(** GitHub authentication input and response transitions on the UI owner fiber.
    Request, reporting and refresh effects are supplied by the caller. *)

open Masc_tui_types
open Masc_tui_ansi

let login_lines (state : state) ~keeper_name lines =
  (* Append under the stamped view; a login for another keeper than the
     one on screen still lands on its own stamp. *)
  let existing =
    match state.github_identity_view with
    | Some (stamp, lines_before) when String.equal stamp keeper_name -> lines_before
    | Some _ | None -> [ "# github login" ]
  in
  state.github_identity_view <- Some (keeper_name, existing @ lines);
  state.github_identity_view_error <- None
;;

let login_finished ~keeper_name ~report ~refresh result =
  (match result with
   | Ok () -> report "system" (keeper_name ^ ": github login stream ended")
   | Error detail -> report "error" (keeper_name ^ ": github login: " ^ detail));
  refresh keeper_name
;;

let token_saved (state : state) ~keeper_name ~report ~refresh result =
  (match result with
   | Ok json ->
     report "system" (keeper_name ^ ": github token saved");
     state.github_token_save_status
     <- Some (Theme.ok () ^ "✓ Token saved successfully" ^ Ansi.reset);
     state.github_identity_view
     <- Some
          ( keeper_name
          , Masc_tui_github_identity.view_lines
              ~sanitize:Masc.Tui_terminal_text.sanitize_terminal_text
              json );
     state.github_identity_view_error <- None
   | Error detail ->
     report "error" (keeper_name ^ ": github token save: " ^ detail);
     state.github_token_save_status
     <- Some (Theme.bad () ^ "✗ Token save failed: " ^ detail ^ Ansi.reset));
  refresh keeper_name
;;

let token_key (state : state) ~save key =
  let draft = Option.value state.github_token_input ~default:"" in
  match key with
  | "esc" -> state.github_token_input <- None
  | "\127" | "\b" ->
    state.github_token_input <- Some (Masc_tui_message_layout.drop_last_utf8_scalar draft)
  | "\r" | "\n" ->
    (match selected_keeper state with
     | Some keeper ->
       let token = String.trim draft in
       state.github_token_input <- None;
       if not (String.equal token "")
       then (
         state.github_token_save_status
         <- Some (Ansi.dim ^ "Saving GitHub token…" ^ Ansi.reset);
         save keeper.k_name token)
     | None -> state.github_token_input <- None)
  | s
    when (String.length s = 1 && Char.code s.[0] >= 32)
         || (String.length s > 1 && Char.code s.[0] >= 0x80) ->
    state.github_token_input <- Some (draft ^ s)
  | _ -> ()
;;

let paste_token (state : state) text =
  let current = Option.value state.github_token_input ~default:"" in
  state.github_token_input <- Some (current ^ text)
;;

let start_login (state : state) ~login =
  match selected_keeper state with
  | Some keeper ->
    let asked =
      match state.github_login_scopes with
      | [] -> "gh's default scopes"
      | scopes ->
        "+"
        ^ String.concat
            ", +"
            (List.map Masc.Keeper_github_identity.login_scope_to_string scopes)
    in
    state.github_identity_view
    <- Some
         ( keeper.k_name
         , [ "# github login"
           ; "(starting gh device flow with " ^ asked ^ "\xe2\x80\xa6)"
           ] );
    login keeper.k_name
  | None -> ()
;;

let toggle_scope (state : state) ~index =
  (* The digit the tab printed beside the scope. Both sides index
     [all_login_scopes], so what the screen numbered and what this
     ticks are the same list. *)
  match List.nth_opt Masc.Keeper_github_identity.all_login_scopes index with
  | Some scope ->
    state.github_login_scopes
    <- (if List.mem scope state.github_login_scopes
        then List.filter (fun s -> s <> scope) state.github_login_scopes
        else scope :: state.github_login_scopes)
  | None -> ()
;;

let open_token (state : state) =
  state.github_token_input <- Some "";
  state.github_token_save_status <- None
;;

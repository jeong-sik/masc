(** Identity pane rows from an immutable reading of its UI inputs. *)

open Masc_tui_ansi

type view =
  { keeper_name : string
  ; providers : Masc_tui_identity_model.identity_provider list
  ; filter : string option
  ; cursor : int
  ; logins : Masc_tui_identity_model.identity_login_started list
  ; attempt_error : (Masc_tui_identity_model.identity_notice_kind * string) option
  ; app_form : Masc_tui_identity_model.identity_app_form option
  ; callback : Masc_tui_identity_model.identity_callback option
  ; order : Masc_tui_identity_model.identity_order
  ; show : Masc_tui_identity_model.identity_show
  }

type drawn =
  { rows : string list
  ; cursor_row : int option
  }

(* The Identity tab's body. Numbering comes from
   [Masc_tui_identity_model.identity_connectable], which is also what the key handler
   indexes, so the number on screen and the provider a keypress starts are
   the same list. *)
let draw ~cols (view : view) =
  let providers = view.providers in
  (* Everything on this pane reads the filtered list: the rows drawn, the
     number beside each one, and the row the marker is on. A screen that
     numbered the whole set while the keys acted on a subset would start the
     wrong service. *)
  let listing : Masc_tui_identity_model.identity_listing =
    { query = Option.value view.filter ~default:""; order = view.order; show = view.show }
  in
  let connectable = Masc_tui_identity_model.identity_connectable ~listing providers in
  let cursor =
    Masc_tui_identity_model.identity_cursor_clamped ~listing ~providers view.cursor
  in
  let tools_of id =
    List.find_map
      (function
        | Masc_tui_identity_model.Identity_declared { idp_id; idp_tools; _ }
          when String.equal idp_id id -> Some idp_tools
        | Masc_tui_identity_model.Identity_declared _
        | Masc_tui_identity_model.Identity_unreadable _ -> None)
      providers
    |> Option.join
  in
  (* Which other Keepers hold this one. Shown on both states: on an attached
     row it says the coverage, and on an unattached one it says the service
     is already in use somewhere, which is the row an operator is most likely
     to have lost track of. *)
  let also_on id =
    List.find_map
      (function
        | Masc_tui_identity_model.Identity_declared { idp_id; idp_also_on; _ }
          when String.equal idp_id id -> Some idp_also_on
        | Masc_tui_identity_model.Identity_declared _
        | Masc_tui_identity_model.Identity_unreadable _ -> None)
      providers
    |> Option.value ~default:[]
  in
  (* Whether an app the operator made is on file. Said on the row because it
     changes what Enter does: with an app the login uses it, without one a
     service that registers no client refuses until one is entered. *)
  let app_of id =
    List.find_map
      (function
        | Masc_tui_identity_model.Identity_declared { idp_id; idp_app; _ }
          when String.equal idp_id id -> idp_app
        | Masc_tui_identity_model.Identity_declared _
        | Masc_tui_identity_model.Identity_unreadable _ -> None)
      providers
  in
  let callback_of id =
    List.find_map
      (function
        | Masc_tui_identity_model.Identity_declared { idp_id; idp_callback; _ }
          when String.equal idp_id id -> idp_callback
        | Masc_tui_identity_model.Identity_declared _
        | Masc_tui_identity_model.Identity_unreadable _ -> None)
      providers
  in
  let numbered =
    List.mapi
      (fun index (id, label) ->
         (* Attached-and-offering-nothing is a third state. Reading it as "not
           attached" would tell an operator to consent again for no reason.
           The reading itself is [Masc_tui_identity_model.identity_row_state], which
           is also what the summary above the list counts, so the line and
           the rows cannot disagree about what this Keeper holds. *)
         let state = Masc_tui_identity_model.identity_row_state ~providers ~id in
         let held = Masc_tui_identity_model.identity_attached state in
         (* The mark says held or not before any word does; an unheld row
            needs no word at all. *)
         let mark, row_state =
           match state with
           | Masc_tui_identity_model.Identity_not_attached ->
             Ansi.dim ^ "\xe2\x97\x8b" ^ Ansi.reset, ""
           | Identity_attached_without_tools ->
             ( Theme.warn () ^ "\xe2\x97\x8f" ^ Ansi.reset
             , Theme.warn () ^ "attached, no tools" ^ Ansi.reset )
           | Identity_switch_unreadable ->
             ( Theme.bad () ^ "\xe2\x97\x8f" ^ Ansi.reset
             , Theme.bad () ^ "switch unreadable" ^ Ansi.reset )
           | Identity_switched_off ->
             Theme.warn () ^ "\xe2\x97\x8f" ^ Ansi.reset, Theme.warn () ^ "off" ^ Ansi.reset
           | Identity_attached tools ->
             ( Theme.ok () ^ "\xe2\x97\x8f" ^ Ansi.reset
             , Printf.sprintf
                 "%s%s%s"
                 (Theme.ok ())
                 (Masc_tui_message_layout.count_noun tools "tool")
                 Ansi.reset )
         in
         (* The row the arrows are on is marked rather than merely numbered:
           past nine the number is no longer a key an operator can press,
           and the marker is what says which one enter would start. *)
         let here = index = cursor in
         let marker = if here then Theme.ok () ^ ">" ^ Ansi.reset else " " in
         (* Padded before it is emphasised: the escape codes are characters
           to a width specifier and nothing on screen, so padding afterwards
           shortens the column by however long the codes are. *)
         let padded = Printf.sprintf "%-24s" (Terminal_text.single_line label) in
         let shown =
           if here then Ansi.bold ^ padded ^ Ansi.reset
           else if held then padded
           else Ansi.dim ^ padded ^ Ansi.reset
         in
         let elsewhere =
           match also_on id with
           | [] -> ""
           | names -> Ansi.dim ^ "  · also " ^ String.concat ", " names ^ Ansi.reset
         in
         let app =
           match app_of id with
           | Some Masc_tui_identity_model.App_on_file ->
             Ansi.dim ^ "  · your app" ^ Ansi.reset
           | Some (Masc_tui_identity_model.App_problem _) ->
             Theme.bad () ^ "  · app unreadable" ^ Ansi.reset
           | Some Masc_tui_identity_model.App_none | None -> ""
         in
         (* A service that takes only a loopback redirect sends the browser
            back to 127.0.0.1, so the browser has to run on this machine. *)
         let own_callback =
           match callback_of id with
           | Some
               (Masc_tui_identity_model.Loopback_row
                  (Masc_tui_identity_model.Callback_url _)) ->
             Ansi.dim ^ "  · loopback callback" ^ Ansi.reset
           | Some
               (Masc_tui_identity_model.Loopback_row
                  (Masc_tui_identity_model.Callback_unknown _)) ->
             Theme.bad () ^ "  · loopback callback unavailable" ^ Ansi.reset
           | Some Masc_tui_identity_model.Row_callback_unreadable ->
             Theme.bad () ^ "  · callback unreadable" ^ Ansi.reset
           | None -> ""
         in
         ( index
         , held
         , Printf.sprintf "%s %2d %s %s %s%s%s%s" marker (index + 1) mark shown row_state
             app own_callback elsewhere ))
      connectable
  in
  (* Attached first puts a blank row between the services this Keeper holds
     and the rest, so the split is read from the layout. Each entry keeps the
     index it numbers, which is how the cursor's row is found below. *)
  let listed =
    match view.order with
    | Masc_tui_identity_model.Identity_declared_order ->
      List.map (fun (index, _, line) -> Some index, line) numbered
    | Masc_tui_identity_model.Identity_attached_first ->
      let rec place previous = function
        | [] -> []
        | (index, held, line) :: rest ->
          let gap =
            match previous with
            | Some true when not held -> [ None, "" ]
            | Some _ | None -> []
          in
          gap @ ((Some index, line) :: place (Some held) rest)
      in
      place None numbered
  in
  let numbered = List.map snd listed in
  let attached_tool_lines =
    connectable
    |> List.concat_map (fun (id, _) ->
      match tools_of id with
      | None | Some [] -> []
      | Some names ->
        ""
        :: (Ansi.dim ^ "  " ^ Terminal_text.single_line id ^ Ansi.reset)
        :: List.map (fun name -> "    " ^ Terminal_text.single_line name) names)
  in
  let rejected =
    List.filter_map
      (function
        | Masc_tui_identity_model.Identity_declared _ -> None
        | Masc_tui_identity_model.Identity_unreadable { idp_id; idp_problem } ->
          Some
            (Printf.sprintf
               "  -  %s  %s%s%s"
               (Terminal_text.single_line idp_id)
               (Theme.bad ())
               (Terminal_text.single_line idp_problem)
               Ansi.reset))
      providers
  in
  let started =
    Masc_tui_identity_model.identity_started_rows ~cols ~keeper_name:view.keeper_name
      view.logins
  in
  (* The callback the server will name, coloured as a fact when it is known
     and as a problem when it is not: a login cannot start without it. *)
  let callback =
    let server = Masc_tui_identity_model.identity_server_callback_rows view.callback in
    let server =
      match view.callback with
      | Some (Masc_tui_identity_model.Callback_url _) ->
        List.map (fun line -> Ansi.dim ^ line ^ Ansi.reset) server
      | Some (Masc_tui_identity_model.Callback_unknown _) ->
        List.map (fun line -> Theme.bad () ^ line ^ Ansi.reset) server
      | None -> server
    in
    server
    @ List.map
        (fun line -> Ansi.dim ^ line ^ Ansi.reset)
        (Masc_tui_identity_model.identity_loopback_callback_rows providers)
  in
  (* What one attempt answered. Wrapped, because the message that matters
     most here is the long one: a provider that registers no client says what
     to make and where to put it, and a single truncated line is the half of
     that sentence an operator cannot act on. *)
  (* Built by the shared function and only coloured here: the key handler
     counts these rows to know where the list starts, and two places wrapping
     the same text at their own idea of the width would disagree. *)
  let attempt_kind = Option.map fst view.attempt_error in
  let attempt =
    Masc_tui_identity_model.identity_notice
      ~cols
      (Option.map
         (fun (kind, text) -> kind, Terminal_text.single_line text)
         view.attempt_error)
  in
  (* Green when it worked and red when it did not. One line reports both, and
     drawing a recorded app in the colour of a refusal is a report that reads
     as its own opposite. *)
  let attempt =
    let body =
      match attempt_kind with
      | Some Masc_tui_identity_model.Notice_ok -> Theme.ok ()
      | Some Masc_tui_identity_model.Notice_bad | None -> Theme.bad ()
    in
    List.mapi
      (fun index line ->
         if line = ""
         then line
         else if index = List.length attempt - 1
         then Ansi.dim ^ line ^ Ansi.reset
         else body ^ line ^ Ansi.reset)
      attempt
  in
  (* The query, and what it left. Shown even when it matches nothing --
     otherwise an empty pane is indistinguishable from a service list that
     failed to load. *)
  let filter_rows =
    List.map
      (fun line -> if line = "" then line else Theme.ok () ^ line ^ Ansi.reset)
      (Masc_tui_identity_model.identity_filter_rows ~providers ~listing view.filter)
  in
  let preamble () =
    Masc_tui_identity_model.identity_preamble
      ~summary:(Masc_tui_identity_model.identity_summary ~providers ~listing)
      ~callback
      ~notice:
        (attempt
         @ started
         @ Masc_tui_identity_model.identity_app_form_rows view.app_form
         @ filter_rows)
  in
  let narrowed_by_view =
    match view.show with
    | Masc_tui_identity_model.Identity_show_all -> false
    | Identity_show_attached | Identity_show_not_attached -> true
  in
  if numbered = [] && rejected = [] && view.filter <> None
  then
    { rows =
        preamble ()
        @ [ Ansi.dim ^ "  Nothing here matches. esc to see them all." ^ Ansi.reset ]
    ; cursor_row = None
    }
  else if numbered = [] && rejected = [] && narrowed_by_view
  then
    { rows =
        preamble ()
        @ [ Ansi.dim ^ "  Nothing in this view. v to see the others." ^ Ansi.reset ]
    ; cursor_row = None
    }
  else if numbered = [] && rejected = []
  then
    { rows = [ Ansi.dim ^ "  Nothing is declared under config/identity/." ^ Ansi.reset ]
    ; cursor_row = None
    }
  else
    let preamble = preamble () in
    (* The row the marker is drawn on, counted from the rows built here
       rather than restated by whoever scrolls the pane. *)
    let cursor_row =
      let rec position row = function
        | [] -> None
        | (Some index, _) :: _ when index = cursor -> Some (List.length preamble + row)
        | (Some _, _) :: rest | (None, _) :: rest -> position (row + 1) rest
      in
      position 0 listed
    in
    { rows = preamble @ numbered @ rejected @ attached_tool_lines; cursor_row }
;;

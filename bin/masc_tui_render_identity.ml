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
  }

(* The Identity tab's body. Numbering comes from
   [Masc_tui_identity_model.identity_connectable], which is also what the key handler
   indexes, so the number on screen and the provider a keypress starts are
   the same list. *)
let lines ~cols (view : view) =
  let providers = view.providers in
  (* Everything on this pane reads the filtered list: the rows drawn, the
     number beside each one, and the row the marker is on. A screen that
     numbered the whole set while the keys acted on a subset would start the
     wrong service. *)
  let query = Option.value view.filter ~default:"" in
  let connectable = Masc_tui_identity_model.identity_connectable ~query providers in
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
  let numbered =
    List.mapi
      (fun index (id, label) ->
         (* Attached-and-offering-nothing is a third state. Reading it as "not
           attached" would tell an operator to consent again for no reason.
           The reading itself is [Masc_tui_identity_model.identity_row_state], which
           is also what the summary above the list counts, so the line and
           the rows cannot disagree about what this Keeper holds. *)
         let row_state =
           match Masc_tui_identity_model.identity_row_state ~providers ~id with
           | Masc_tui_identity_model.Identity_not_attached ->
             Ansi.dim ^ "not attached" ^ Ansi.reset
           | Identity_attached_without_tools ->
             Ansi.dim ^ "attached, no tools" ^ Ansi.reset
           | Identity_switch_unreadable -> Theme.bad () ^ "switch unreadable" ^ Ansi.reset
           | Identity_switched_off -> Theme.warn () ^ "off" ^ Ansi.reset
           | Identity_attached tools ->
             Printf.sprintf
               "%s%s%s"
               (Theme.ok ())
               (Masc_tui_message_layout.count_noun tools "tool")
               Ansi.reset
         in
         (* The row the arrows are on is marked rather than merely numbered:
           past nine the number is no longer a key an operator can press,
           and the marker is what says which one enter would start. *)
         let here =
           index
           = Masc_tui_identity_model.identity_cursor_clamped ~query ~providers view.cursor
         in
         let marker = if here then Theme.ok () ^ ">" ^ Ansi.reset else " " in
         (* Padded before it is emphasised: the escape codes are characters
           to a width specifier and nothing on screen, so padding afterwards
           shortens the column by however long the codes are. *)
         let padded = Printf.sprintf "%-24s" (Terminal_text.single_line label) in
         let shown = if here then Ansi.bold ^ padded ^ Ansi.reset else padded in
         let elsewhere =
           match also_on id with
           | [] -> ""
           | names -> Ansi.dim ^ "  · also " ^ String.concat ", " names ^ Ansi.reset
         in
         Printf.sprintf "%s %2d  %s %s%s" marker (index + 1) shown row_state elsewhere)
      connectable
  in
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
    List.concat_map
      (fun (login : Masc_tui_identity_model.identity_login_started) ->
         (* Wrapped, not truncated. The URL is about nine hundred characters
           and a pane cuts it at its own width; a cut URL cannot be selected
           or copied, so the login stopped there. The TUI opens it as well --
           this is what is left when the machine has no opener. *)
         let url = Terminal_text.single_line login.ils_url in
         let width = max 20 (cols - 6) in
         let rec fold at acc =
           if at >= String.length url
           then List.rev acc
           else (
             let take = min width (String.length url - at) in
             fold (at + take) (("    " ^ String.sub url at take) :: acc))
         in
         (""
          :: (Ansi.bold
              ^ "  A browser should have opened to consent as "
              ^ Terminal_text.single_line login.ils_label
              ^ "."
              ^ Ansi.reset)
          :: (Ansi.dim ^ "  If it did not, the URL is here:" ^ Ansi.reset)
          :: fold 0 [])
         @ [ Ansi.dim
             ^ "  Nothing is written to this keeper until you come back."
             ^ Ansi.reset
           ])
      (List.filter
         (fun (login : Masc_tui_identity_model.identity_login_started) ->
            String.equal login.ils_keeper view.keeper_name)
         view.logins)
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
      (Masc_tui_identity_model.identity_filter_rows ~providers view.filter)
  in
  if numbered = [] && rejected = [] && view.filter <> None
  then
    Masc_tui_identity_model.identity_preamble
      ~summary:(Masc_tui_identity_model.identity_summary ~providers ~query)
      ~notice:
        (attempt
         @ started
         @ Masc_tui_identity_model.identity_app_form_rows view.app_form
         @ filter_rows)
    @ [ Ansi.dim ^ "  Nothing here matches. esc to see them all." ^ Ansi.reset ]
  else if numbered = [] && rejected = []
  then [ Ansi.dim ^ "  Nothing is declared under config/identity/." ^ Ansi.reset ]
  else
    Masc_tui_identity_model.identity_preamble
      ~summary:(Masc_tui_identity_model.identity_summary ~providers ~query)
      ~notice:
        (attempt
         @ started
         @ Masc_tui_identity_model.identity_app_form_rows view.app_form
         @ filter_rows)
    @ numbered
    @ rejected
    @ attached_tool_lines
;;

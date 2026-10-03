(** Identity data and pure projections shared by input, rendering, and responses. *)

(** One line of the Identity tab. A declaration nobody can read is carried
    rather than dropped: an operator who came looking for a provider needs to
    see why it is not on offer, not a shorter list. *)
type identity_provider =
  | Identity_declared of
      { idp_id : string
      ; idp_label : string
      ; idp_tools : string list option
        (** What this service currently offers this Keeper, or [None] when it
            was never attached. An empty list is a third fact -- attached and
            offering nothing -- and reading it as "not attached" would tell an
            operator to consent again for no reason. *)
      ; idp_also_on : string list
        (** Which other Keepers hold this one. A Keeper attaches on its own
            account -- the client is shared, the token is not -- so this is
            the one question a single Keeper's tab cannot answer for itself,
            and answering it by opening each Keeper in turn is how an
            operator loses track of which account went where. *)
      ; idp_enabled : bool option
        (** The on/off switch on an attached row. [None] when the row is not
            attached or the switch store could not be read; the render must
            not show a guess for either. *)
      ; idp_switch_problem : string option
        (** Why the switch state is unknown, when it is. *)
      }
  | Identity_unreadable of
      { idp_id : string
      ; idp_problem : string
      }

(** Whether a query names this provider.

    Both the label and the id, because they diverge and an operator knows
    whichever one they know: the screen says "Google Sheets" and the tool
    names say "googlesheets_". Matching one would make the other a query
    that finds nothing while the row is right there. *)
let identity_names ~query (id, label) =
  Masc_tui_pick_list.lowercase_contains ~needle:query label
  || Masc_tui_pick_list.lowercase_contains ~needle:query id
;;

(** The providers a key can act on, in the order the screen numbers them.
    Both the renderer and the key handler read this, so the number an
    operator sees and the provider a keypress starts cannot drift apart. *)
let identity_connectable ?(query = "") providers =
  List.filter_map
    (function
      | Identity_declared { idp_id; idp_label; _ } ->
        if identity_names ~query (idp_id, idp_label)
        then Some (idp_id, idp_label)
        else None
      | Identity_unreadable _ -> None)
    providers
;;

(** What the Identity pane says about one service.

    The rows and the summary above them read this one function, so the line
    and the list cannot disagree about what this Keeper holds. *)
type identity_row_state =
  | Identity_not_attached
  | Identity_attached_without_tools
  | Identity_switch_unreadable
  | Identity_switched_off
  | Identity_attached of int (** how many tools it offers *)

(* The pane's precedence: a service offering nothing says so whatever its
   switch says, then a switch that cannot be read outranks the switch's
   value, which outranks the tool count -- a service an operator turned off
   hands this Keeper nothing, however many tools its catalog names. *)
let identity_row_state ~providers ~id =
  let readings =
    List.find_map
      (function
        | Identity_declared { idp_id; idp_tools; idp_enabled; idp_switch_problem; _ }
          when String.equal idp_id id -> Some (idp_tools, idp_enabled, idp_switch_problem)
        | Identity_declared _ | Identity_unreadable _ -> None)
      providers
  in
  match readings with
  | None | Some (None, _, _) -> Identity_not_attached
  | Some (Some [], _, _) -> Identity_attached_without_tools
  | Some (Some _, _, Some _) -> Identity_switch_unreadable
  | Some (Some _, Some false, None) -> Identity_switched_off
  | Some (Some tools, (Some true | None), None) -> Identity_attached (List.length tools)
;;

(** The line above the provider list: how many services it draws, out of how
    many this Keeper has, and what the drawn ones report. The states a row
    already spells one by one are summed here only where one holds: a pane of
    nothing but unattached services says so by having no tally to print. *)
let identity_summary ~providers ~query =
  let shown = identity_connectable ~query providers in
  let total = List.length (identity_connectable ~query:"" providers) in
  let states = List.map (fun (id, _) -> identity_row_state ~providers ~id) shown in
  let count wanted = List.length (List.filter (fun state -> state = wanted) states) in
  let attached =
    List.length
      (List.filter
         (function
           | Identity_attached _ -> true
           | _ -> false)
         states)
  in
  let parts =
    List.filter_map
      (fun (label, n) ->
         if n > 0 then Some (Masc_tui_message_layout.count_noun n label) else None)
      [ "attached", attached
      ; "switched off", count Identity_switched_off
      ; "attached with no tools", count Identity_attached_without_tools
      ; "with an unreadable switch", count Identity_switch_unreadable
      ]
  in
  let drawn = List.length shown in
  let head =
    if drawn = total
    then Masc_tui_message_layout.count_noun total "service"
    else
      Printf.sprintf "%d of %s" drawn (Masc_tui_message_layout.count_noun total "service")
  in
  match parts with
  | [] -> "  " ^ head
  | parts -> "  " ^ head ^ " \xc2\xb7 " ^ String.concat " \xc2\xb7 " parts
;;

(** A pasted value flattened to one line, for a field that holds one.

    Control bytes become a space and runs of space collapse, because a scope
    list copied out of a browser arrives with the newlines that separated
    it and a secret carries the one that ended it.

    Deliberately not the terminal's own single-line helper. That one is for
    drawing untrusted text: it makes a newline visible by writing the four
    characters "\x0A" into the string. Used on input, those four characters
    were stored, sent to Slack as part of a scope name, and came back as
    "Invalid permissions requested".

    Bytes at or above 0x80 are left alone -- they are UTF-8, not control
    characters. *)
let identity_field_paste text =
  let out = Buffer.create (String.length text) in
  String.iter
    (fun c ->
       let code = Char.code c in
       if code < 0x20 || code = 0x7f
       then Buffer.add_char out ' '
       else Buffer.add_char out c)
    text;
  Buffer.contents out
  |> String.split_on_char ' '
  |> List.filter (fun part -> not (String.equal part ""))
  |> String.concat " "
;;

(** Whether the pane's notice reports something that worked.

    One line reports both -- a refusal to start and an app recorded -- and
    without this they are drawn the same, so a save that succeeded arrives in
    the colour of a failure. *)
type identity_notice_kind =
  | Notice_ok
  | Notice_bad

(** What one attempt answered, as pane rows.

    Built here rather than at each side because two places wrapping the same
    text at their own idea of the width would draw a different number of
    lines, and the key handler's idea of where the list starts would stop
    matching the renderer's.

    Wrapped, because the message that matters most is the long one: a
    provider that registers no client says what to make and where to put it,
    and a single truncated line is the half of that sentence an operator
    cannot act on. *)
let identity_notice ~cols detail =
  match detail with
  | None -> []
  | Some (kind, text) ->
    (* Two for this indent, two for the one the pane adds, four for the box
       around it. Wrapping wider than that is a line the frame truncates --
       which is the whole failure this exists to undo. *)
    List.map
      (fun line -> "  " ^ line)
      (Masc_tui_message_layout.wrap_words ~max_cells:(max 20 (cols - 8)) text)
    @
    (* Only on a refusal, and pointing at the key on this pane rather than at
       the dashboard: the form is here now. *)
    (match kind with
      | Notice_ok -> [ "" ]
      | Notice_bad -> [ "  A records an app for the row the cursor is on."; "" ])
;;

(** The filter's own two rows: what was typed, and how much of the set is
    left. Built here for the same reason the notice is -- the key handler
    counts these to know where the list starts, and a count that disagreed
    with what is drawn would scroll the cursor to the wrong row. *)
let identity_filter_rows ~providers filter =
  match filter with
  | None -> []
  | Some typed ->
    [ Printf.sprintf
        "  /%s   %d of %d"
        typed
        (List.length (identity_connectable ~query:typed providers))
        (List.length (identity_connectable providers))
    ; ""
    ]
;;

(* Each block above the list brings its own trailing blank, so two of them
   do not stack two blanks and none of them leaves the list flush against
   the tally.

   No keys here. The tab's own keys ride the footer, which is where every
   other surface puts them: at 120 columns it draws all six
   ([ ]:tab, arrows+enter:connect, T:toggle, A:app, /:filter, R:refresh) and
   at 80 it gives up /:filter and R:refresh in that order, with [?] naming
   what it dropped. A sentence spelling them again stood here while the
   title row carried the hint and cut it, which the footer no longer does. *)

(** The lines the Identity pane prints above the provider rows.

    Here rather than in the renderer because the key handler has to know how
    far down the pane a provider sits: it moves a cursor over
    [identity_connectable] and then scrolls the pane's lines so that row
    stays visible. A header written in the renderer and counted in the key
    handler is two numbers that drift the first time a line is added. *)
let identity_preamble ~summary ~notice = summary :: "" :: notice

(** Which pane line the provider at [index] is drawn on.

    [notice] is what the preamble is carrying: a message about the attempt
    just made belongs where the operator is looking rather than below
    fifty-odd rows they would have to scroll past. It moves the list down,
    so the row a keypress scrolls to moves with it. *)
let identity_provider_line ~summary ~notice ~index =
  List.length (identity_preamble ~summary ~notice) + index
;;

(** The cursor held inside the list it names. A cursor left behind by a
    shorter list answers from the last row rather than from one that is no
    longer there. *)
let identity_cursor_clamped ~query ~providers cursor =
  let count = List.length (identity_connectable ~query providers) in
  if count = 0 then 0 else max 0 (min cursor (count - 1))
;;

(** The provider a keypress on the cursor would start, if any. *)
let identity_cursor_provider ~query ~providers cursor =
  List.nth_opt
    (identity_connectable ~query providers)
    (identity_cursor_clamped ~query ~providers cursor)
;;

(** Which of the three fields is taking keys. Sequential rather than
    clickable: a terminal has no pointer, and tab-between-fields is a second
    idea to explain when enter-to-advance already reads as a form. *)
type identity_app_field =
  | App_client_id
  | App_client_secret
  | App_scopes

type identity_app_form =
  { iaf_provider : string
  ; iaf_label : string
  ; iaf_field : identity_app_field
  ; iaf_client_id : string
  ; iaf_client_secret : string
  ; iaf_scopes : string
  }

(** The form's rows. Built here with the notice and the filter rows so the
    key handler counts the same preamble the renderer draws. The secret is
    shown as asterisks: a terminal scrolls back, and a credential on screen is a
    credential in the scrollback. *)
let identity_app_form_rows form =
  match form with
  | None -> []
  | Some f ->
    let mark field = if f.iaf_field = field then ">" else " " in
    [ Printf.sprintf "  %s \xec\x95\xb1" f.iaf_label
    ; Printf.sprintf "  %s client id      %s" (mark App_client_id) f.iaf_client_id
    ; Printf.sprintf
        "  %s client secret  %s"
        (mark App_client_secret)
        (String.concat "" (List.init (String.length f.iaf_client_secret) (fun _ -> "*")))
    ; Printf.sprintf "  %s scopes         %s" (mark App_scopes) f.iaf_scopes
    ; "  enter 다음 칸 · 마지막 칸에서 enter 저장 · esc 취소"
    ; ""
    ]
;;

(** A login the operator has started but not finished: they have to open
    [ils_url] in a browser, and until they come back nothing has been
    written to the Keeper. *)
type identity_login_started =
  { ils_keeper : string
  ; ils_provider : string
    (** Which service, by id. The label is for a screen; matching on it
          would tie "this login landed" to a display string that a
          declaration is free to change. *)
  ; ils_label : string
  ; ils_url : string
  }

(** Whether the login [login] started has landed: the service it was for now
    reports tools for this Keeper.

    This is what ends the tick's re-asking. A poll with no end condition is a
    poll that runs for the life of the process, so the condition is named
    here and tested rather than being a line inside the message handler. *)
let identity_provider_attached ~providers ~provider_id =
  List.exists
    (function
      | Identity_declared { idp_id; idp_tools = Some _; _ } ->
        String.equal idp_id provider_id
      | Identity_declared _ | Identity_unreadable _ -> false)
    providers
;;

(* Declared at all, attached or not, including a declaration that could not
   be read: the provider can still complete a pending consent, and an
   unreadable row may come back readable on the next inventory. A provider
   absent from the inventory never can, which is what lets its login intent
   retire instead of polling forever. *)
let identity_provider_declared ~providers ~provider_id =
  List.exists
    (function
      | Identity_declared { idp_id; _ }
      | Identity_unreadable { idp_id; _ } ->
          String.equal idp_id provider_id)
    providers
;;

let identity_login_landed ~providers ~login =
  identity_provider_attached ~providers ~provider_id:login.ils_provider
;;

type identity_login_result =
  | Login_started of
      { provider_id : string
      ; label : string
      ; url : string
      }
  | Login_attached of string
  | Login_failed of string

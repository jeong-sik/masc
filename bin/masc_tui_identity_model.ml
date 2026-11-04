(** Identity data and pure projections shared by input, rendering, and responses. *)

(** Whether an operator app is on file for a service. *)
type identity_app =
  | App_on_file
  | App_none
  | App_problem of string

(** The callback a login started now would name. An operator who makes their
    own app registers exactly this URL as its redirect URI. *)
type identity_callback =
  | Callback_url of string
  | Callback_unknown of string (** why the server does not know it *)

(** A callback a row names for itself. *)
type identity_row_callback =
  | Loopback_row of identity_callback
      (** The service accepts only an RFC 8252 loopback redirect. *)
  | Row_callback_unreadable
      (** The row carried a callback in a shape this screen does not read. *)

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
            account -- the token is its own -- so this is
            the one question a single Keeper's tab cannot answer for itself,
            and answering it by opening each Keeper in turn is how an
            operator loses track of which account went where. *)
      ; idp_enabled : bool option
        (** The on/off switch on an attached row. [None] when the row is not
            attached or the switch store could not be read; the render must
            not show a guess for either. *)
      ; idp_switch_problem : string option
        (** Why the switch state is unknown, when it is. *)
      ; idp_app : identity_app option
        (** Whether an app the operator made is on file for this service.
            [None] when the server did not say. *)
      ; idp_callback : identity_row_callback option
        (** The service's own callback when it is not the server's. [None]
            when the row carries none. *)
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

(** Whether this Keeper holds a token for the service, whatever it offers or
    its switch says. *)
let identity_attached = function
  | Identity_not_attached -> false
  | Identity_attached _ | Identity_attached_without_tools | Identity_switch_unreadable
  | Identity_switched_off -> true
;;

type identity_order =
  | Identity_attached_first
  | Identity_declared_order

type identity_show =
  | Identity_show_all
  | Identity_show_attached
  | Identity_show_not_attached

type identity_listing =
  { query : string
  ; order : identity_order
  ; show : identity_show
  }

let identity_listing_default =
  { query = ""; order = Identity_attached_first; show = Identity_show_all }
;;

let identity_next_order = function
  | Identity_attached_first -> Identity_declared_order
  | Identity_declared_order -> Identity_attached_first
;;

let identity_next_show = function
  | Identity_show_all -> Identity_show_attached
  | Identity_show_attached -> Identity_show_not_attached
  | Identity_show_not_attached -> Identity_show_all
;;

(** The providers a key can act on, in the order the screen numbers them.
    Both the renderer and the key handler read this, so the number an
    operator sees and the provider a keypress starts cannot drift apart. *)
let identity_connectable ~listing providers =
  let named =
    List.filter_map
      (function
        | Identity_declared { idp_id; idp_label; _ } ->
          if identity_names ~query:listing.query (idp_id, idp_label)
          then Some (idp_id, idp_label)
          else None
        | Identity_unreadable _ -> None)
      providers
  in
  let attached (id, _) = identity_attached (identity_row_state ~providers ~id) in
  let shown =
    match listing.show with
    | Identity_show_all -> named
    | Identity_show_attached -> List.filter attached named
    | Identity_show_not_attached -> List.filter (fun row -> not (attached row)) named
  in
  match listing.order with
  | Identity_declared_order -> shown
  | Identity_attached_first ->
    let held, rest = List.partition attached shown in
    held @ rest
;;

(** The line above the provider list: how many services it draws, out of how
    many this Keeper has, and what the drawn ones report. The states a row
    already spells one by one are summed here only where one holds: a pane of
    nothing but unattached services says so by having no tally to print. *)
let identity_summary ~providers ~listing =
  let shown = identity_connectable ~listing providers in
  let total =
    List.length (identity_connectable ~listing:identity_listing_default providers)
  in
  let states = List.map (fun (id, _) -> identity_row_state ~providers ~id) shown in
  let count wanted = List.length (List.filter (fun state -> state = wanted) states) in
  let attached =
    List.length
      (List.filter
         (function
           | Identity_attached _ -> true
           | Identity_not_attached | Identity_attached_without_tools | Identity_switch_unreadable
           | Identity_switched_off -> false)
         states)
  in
  (* These are states, not nouns: "3 attached", not "3 attacheds". *)
  let parts =
    List.filter_map
      (fun (label, n) -> if n > 0 then Some (Printf.sprintf "%d %s" n label) else None)
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
    (* Two for this indent and two for the one the pane adds, inside the
       frame's inner width. Wrapping wider than that is a line the frame
       truncates -- which is the whole failure this exists to undo. *)
    List.map
      (fun line -> "  " ^ line)
      (Masc_tui_message_layout.wrap_words
         ~max_cells:(max 20 (Masc_tui_frame.inner_width ~cols - 4)) text)
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
let identity_filter_rows ~providers ~listing filter =
  match filter with
  | None -> []
  | Some typed ->
    [ Printf.sprintf
        "  /%s   %d of %d"
        typed
        (List.length (identity_connectable ~listing:{ listing with query = typed } providers))
        (List.length (identity_connectable ~listing:{ listing with query = "" } providers))
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
let identity_preamble ~summary ~callback ~notice = (summary :: callback) @ ("" :: notice)

(** The callback line under the summary. The value comes from the server,
    which follows [MASC_HTTP_BASE_URL] or the address it bound, so this is
    the line that says where providers will send the browser back to. *)
let identity_server_callback_rows = function
  | None -> []
  | Some (Callback_url url) ->
    [ "  callback  " ^ Masc_tui_ansi.Terminal_text.single_line url ]
  | Some (Callback_unknown why) ->
    [ "  callback  unknown: " ^ Masc_tui_ansi.Terminal_text.single_line why ]
;;

(* Every loopback service names the same URL -- this server on 127.0.0.1 --
   so one line says it, with the condition it carries. *)
let identity_loopback_callback_rows providers =
  let named =
    List.filter_map
      (function
        | Identity_declared { idp_callback; _ } ->
          (match idp_callback with
           | Some (Loopback_row callback) -> Some callback
           | Some Row_callback_unreadable | None -> None)
        | Identity_unreadable _ -> None)
      providers
    |> List.sort_uniq compare
  in
  List.map
    (function
      | Callback_url url ->
        "  loopback  " ^ Masc_tui_ansi.Terminal_text.single_line url
        ^ "  (browser on this machine)"
      | Callback_unknown why ->
        "  loopback  unavailable: " ^ Masc_tui_ansi.Terminal_text.single_line why)
    named
;;



(** The cursor held inside the list it names. A cursor left behind by a
    shorter list answers from the last row rather than from one that is no
    longer there. *)
let identity_cursor_clamped ~listing ~providers cursor =
  let count = List.length (identity_connectable ~listing providers) in
  if count = 0 then 0 else max 0 (min cursor (count - 1))
;;

(** The provider a keypress on the cursor would start, if any. *)
let identity_cursor_provider ~listing ~providers cursor =
  List.nth_opt
    (identity_connectable ~listing providers)
    (identity_cursor_clamped ~listing ~providers cursor)
;;

(** Where the cursor lands once the list changes under it -- a new reading,
    another order, another view: on the provider it was on when that one is
    still listed, so a login that moves its row up does not leave the marker
    on whichever service slid into the old position. *)
let identity_cursor_following ~before:(before_listing, before_providers)
    ~after:(after_listing, after_providers) cursor =
  let landing =
    match
      identity_cursor_provider ~listing:before_listing ~providers:before_providers cursor
    with
    | None -> None
    | Some (id, _) ->
      let rec index_of position = function
        | [] -> None
        | (candidate, _) :: rest ->
          if String.equal candidate id then Some position else index_of (position + 1) rest
      in
      index_of 0 (identity_connectable ~listing:after_listing after_providers)
  in
  match landing with
  | Some position -> position
  | None -> identity_cursor_clamped ~listing:after_listing ~providers:after_providers cursor
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
  ; ils_expires_at : float
  ; ils_attempt_id : string
  }

(** The consent prompt for each login this Keeper started and has not
    finished. Wrapped, not truncated: the URL is about nine hundred characters
    and a pane cuts it at its own width; a cut URL cannot be selected or
    copied. The TUI opens it as well -- this is what is left when the machine
    has no opener. *)
let identity_started_rows ~cols ~keeper_name logins =
  let open Masc_tui_ansi in
  List.concat_map
    (fun login ->
       let url = Terminal_text.single_line login.ils_url in
       let width = max 20 (framed_inner_width cols - 2) in
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
       @ [ Ansi.dim ^ "  Nothing is written to this keeper until you come back." ^ Ansi.reset ])
    (List.filter (fun login -> String.equal login.ils_keeper keeper_name) logins)
;;

(** Whether [provider_id] is attached for this Keeper: its declaration
    reports a tool list, an empty one included. Matched by id, not by the
    label a screen shows. *)
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
   absent from the inventory never can, which is what lets its login wait
   retire instead of being waited on forever. *)
let identity_provider_declared ~providers ~provider_id =
  List.exists
    (function
      | Identity_declared { idp_id; _ }
      | Identity_unreadable { idp_id; _ } ->
          String.equal idp_id provider_id)
    providers
;;

type identity_login_result =
  | Login_started of
      { provider_id : string
      ; label : string
      ; url : string
      ; expires_at : float
      ; attempt_id : string
      }
  | Login_attached of string
  | Login_failed of string

(* The absolute deadline governs browser consent only. Completion is observed
   with the independent attempt id; CLI-token attachment is already complete. *)
let decode_identity_login ~provider_id ~label ~now (json : Yojson.Safe.t) =
  match json with
  | `Assoc fields ->
      (match List.assoc_opt "attached" fields with
       | Some (`Bool true) ->
           let message = match List.assoc_opt "message" fields with
             | Some (`String message) -> message
             | _ -> label ^ ": credentials attached."
           in
           Login_attached message
       | _ ->
           let deadline = match List.assoc_opt "expires_at" fields with
             | Some (`Float value) when Float.is_finite value -> Some value
             | Some (`Int value) -> Some (float_of_int value)
             | _ -> None
           in
           (match List.assoc_opt "authorize_url" fields, deadline with
            | Some (`String _), None ->
                Login_failed "the server answered without a valid expires_at"
            | Some (`String _), Some expires_at when expires_at <= now ->
                Login_failed "login expired; start a new login"
            | Some (`String url), Some expires_at ->
                let provider_id = match List.assoc_opt "provider" fields with
                  | Some (`String id) -> id
                  | _ -> provider_id
                in
                (match List.assoc_opt "attempt_id" fields with
                 | Some (`String attempt_id) when attempt_id <> "" ->
                     Login_started { provider_id; label; url; expires_at; attempt_id }
                 | _ -> Login_failed "the server answered without an attempt_id")
            | _ -> Login_failed "the server answered without an authorize_url"))
  | _ -> Login_failed "the server answered with something this cannot read"
;;

type identity_login_status =
  | Consent_waiting of float | Callback_in_progress
  | Credentials_published of (int, unit) result
  | Login_exchange_failed | Credential_publication_incomplete
  | Consent_expired | Consent_superseded | Attempt_unavailable
let decode_identity_login_status = function
  | `Assoc fields ->
      (match List.assoc_opt "kind" fields with
       | Some (`String "awaiting_consent") -> (match List.assoc_opt "expires_at" fields with
           | Some (`Float value) when Float.is_finite value -> Ok (Consent_waiting value)
           | Some (`Int value) -> Ok (Consent_waiting (float_of_int value))
           | _ -> Error "invalid consent deadline")
       | Some (`String "callback_admitted") -> Ok Callback_in_progress
       | Some (`String "completed") ->
           (match List.assoc_opt "credential_publication" fields, List.assoc_opt "tool_discovery" fields with
            | Some (`String "published"), Some (`Assoc discovery) ->
                (match List.assoc_opt "kind" discovery, List.assoc_opt "count" discovery with
                 | Some (`String "discovered"), Some (`Int count) when count >= 0 -> Ok (Credentials_published (Ok count))
                 | Some (`String "failed"), _ -> Ok (Credentials_published (Error ()))
                 | _ -> Error "invalid discovery outcome")
            | _ -> Error "invalid credential publication")
       | Some (`String "failed") -> Ok Login_exchange_failed
       | Some (`String "credential_publication_incomplete") -> Ok Credential_publication_incomplete
       | Some (`String "expired") -> Ok Consent_expired
       | Some (`String "superseded") -> Ok Consent_superseded
       | Some (`String "unavailable") -> Ok Attempt_unavailable
       | _ -> Error "unknown login attempt state")
  | _ -> Error "login attempt response is not an object"

let disconnect_receipt_text ~provider_id json =
  let field key =
    match json with
    | `Assoc fields -> List.assoc_opt key fields
    | _ -> None
  in
  let deleted =
    match field "deleted" with
    | Some (`Assoc items) ->
      List.filter_map
        (fun (name, value) ->
           match value with
           | `Bool true ->
             Some
               (match name with
                | "refresh_token" -> "stored tokens"
                | "tool_catalog" -> "attached tools"
                | other -> other)
           | `Bool false | `Null -> None
           | _ -> Some name)
        items
    | _ -> []
  in
  let revoke =
    match field "revocation" with
    | Some (`Assoc fields) ->
      let detail =
        match List.assoc_opt "detail" fields with
        | Some (`String detail) -> " (" ^ detail ^ ")"
        | _ -> ""
      in
      (* A kind this build does not know is said as such, not read as the
         quietest outcome. *)
      (match List.assoc_opt "kind" fields with
       | Some (`String "revoked") -> "provider revoke: taken"
       | Some (`String "failed") -> "provider revoke: failed" ^ detail
       | Some (`String "not_sent") -> "provider revoke: not sent" ^ detail
       | Some (`String "not_published") -> "provider revoke: not offered"
       | Some _ | None -> "provider revoke: unreadable")
    | _ -> "provider revoke: unreadable"
  in
  let removed =
    if deleted = [] then "nothing was still there to delete"
    else "removed " ^ String.concat ", " deleted
  in
  Printf.sprintf "%s: %s; %s" provider_id removed revoke
;;

(** The Identity tab's reading of [/api/v1/keepers/oauth/attached-tools]: the
    rows, and the callback the server would name. A callback object of any
    other shape is not read as either a URL or a problem, and an [app_state]
    of an unknown kind is not read as any app state. *)
let decode_identity_providers (json : Yojson.Safe.t)
  : ( identity_provider list
      * identity_callback option
    , string )
    result
  =
    let rows =
      match json with
      | `Assoc fields -> (
        match List.assoc_opt "providers" fields with
        | Some (`List rows) -> Some rows
        | Some _ | None -> None)
      | _ -> None
    in
    (* A callback object, or why there is none. Anything else is not read as
       either. *)
    let callback_of = function
      | Some (`Assoc [ ("url", `String url) ]) -> Some (Callback_url url)
      | Some (`Assoc [ ("problem", `String why) ]) -> Some (Callback_unknown why)
      | Some _ | None -> None
    in
    (* A row's own callback carries its kind. A present one this screen cannot
       read is said to be unreadable, not taken for the server's. *)
    let row_callback_of = function
      | None -> None
      | Some (`Assoc fields) ->
        (match List.assoc_opt "kind" fields with
         | Some (`String "loopback") ->
           (match
              callback_of
                (Some (`Assoc (List.filter (fun (key, _) -> key <> "kind") fields)))
            with
            | Some callback -> Some (Loopback_row callback)
            | None -> Some Row_callback_unreadable)
         | Some _ | None -> Some Row_callback_unreadable)
      | Some _ -> Some Row_callback_unreadable
    in
    let callback =
      match json with
      | `Assoc fields -> callback_of (List.assoc_opt "callback" fields)
      | _ -> None
    in
    (match rows with
     | None -> Error "identity providers response carries no providers list"
     | Some rows ->
       Ok
         (List.filter_map
            (fun row ->
              let field key =
                match row with
                | `Assoc fields -> List.assoc_opt key fields
                | _ -> None
              in
              let string_field key =
                match field key with
                | Some (`String value) -> Some value
                | Some _ | None -> None
              in
              match string_field "provider", string_field "problem" with
              | Some idp_id, Some idp_problem ->
                Some (Identity_unreadable { idp_id; idp_problem })
              | Some idp_id, None ->
                let idp_label =
                  Option.value ~default:idp_id (string_field "provider_label")
                in
                let idp_tools =
                  match field "tools" with
                  | Some (`List names) ->
                    Some
                      (List.filter_map
                         (function `String name -> Some name | _ -> None)
                         names)
                  (* No tools key means the server said this one is not
                     attached; an empty list would mean attached and
                     offering nothing. *)
                  | Some _ | None -> None
                in
                let idp_also_on =
                  match field "also_on" with
                  | Some (`List names) ->
                    List.filter_map
                      (function `String name -> Some name | _ -> None)
                      names
                  | Some _ | None -> []
                in
                let idp_enabled =
                  match field "enabled" with
                  | Some (`Bool value) -> Some value
                  | Some _ | None -> None
                in
                let idp_switch_problem = string_field "switch_problem" in
                let idp_app =
                  match field "app_state" with
                  | Some (`Assoc state) -> (
                    match List.assoc_opt "kind" state with
                    | Some (`String "on_file") -> Some App_on_file
                    | Some (`String "none") -> Some App_none
                    | Some (`String "problem") ->
                      (match List.assoc_opt "problem" state with
                       | Some (`String why) -> Some (App_problem why)
                       | Some _ | None -> None)
                    | Some _ | None -> None)
                  | Some _ | None -> None
                in
                let idp_callback = row_callback_of (field "callback") in
                Some
                  (Identity_declared
                     { idp_id; idp_label; idp_tools; idp_also_on
                     ; idp_enabled; idp_switch_problem; idp_app; idp_callback })
              | None, _ -> None)
            rows, callback))

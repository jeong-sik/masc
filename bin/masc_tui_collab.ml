type form = Browsing | Name of string | Hours of string * string | Confirm_revoke of string | Confirm_resolution of string
type write_access = Writable | Pending of string | Uncertain of { request_id : string; notice : string } | Read_only of string
type inventory = Loading | Listed of Masc.Tui_decode.play_invites | Failed of string
type read = Read of unit ref
type mutation = Mutation of unit ref
type t = {
  owner : unit ref;
  read : read option;
  inventory : inventory;
  selected : string option;
  form : form;
  pending : mutation option;
  message : string option;
  write_access : write_access;
}
type action = Stay | Close | Watch of Masc.Machine_lane.t | Game_menu | Refresh
  | Issue of mutation * string * int | Revoke of mutation * string | Open_link of string | Resolve_unknown of string

let create () = { owner = ref (); read = None; inventory = Loading; selected = None;
  form = Browsing; pending = None; message = None; write_access = Writable }
let owner t = t.owner
let write_access t access =
  let form = match t.form, access with
    | (Name _ | Hours _ | Confirm_revoke _), (Pending _ | Uncertain _ | Read_only _)
    | Confirm_resolution _, (Writable | Pending _ | Read_only _) -> Browsing
    | Confirm_resolution request_id, Uncertain current when request_id <> current.request_id -> Browsing
    | (Browsing as form), _
    | ((Name _ | Hours _ | Confirm_revoke _) as form), Writable
    | (Confirm_resolution _ as form), Uncertain _ -> form in
  {t with write_access = access; form}
let loading t =
  let read = Read (ref ()) in
  {t with inventory = Loading; read = Some read}, read
let listed t read result =
  match t.read with
  | None -> t
  | Some current when current != read -> t
  | Some _ ->
      let t = {t with read = None} in
      (match result with
       | Error error -> {t with inventory = Failed error}
       | Ok listed ->
           let rows = listed.Masc.Tui_decode.pis_rows in
           let selected = match t.selected with
             | Some name when List.exists (fun row -> String.equal row.Masc.Tui_decode.pi_name name) rows -> Some name
             | Some _ | None -> Option.map (fun row -> row.Masc.Tui_decode.pi_name) (List.nth_opt rows 0) in
           {t with inventory = Listed listed; selected})
let notice t message = {t with message = Some message}
let busy t =
  let mutation = Mutation (ref ()) in
  {t with pending = Some mutation; form = Browsing; message = Some "Waiting for the server…"}, mutation
let settled t mutation = match t.pending with
  | Some pending when pending == mutation -> {t with pending = None}
  | Some _ | None -> t
let text_input_active t = match t.form with
  | Name _ | Hours _ -> true
  | Browsing | Confirm_revoke _ | Confirm_resolution _ -> false
let paste t text = match t.form with
  | Name value -> {t with form = Name (value ^ text)}
  | Hours (name, value) -> {t with form = Hours (name, value ^ text)}
  | Browsing | Confirm_revoke _ | Confirm_resolution _ -> t
let rows t = match t.inventory with Listed listed -> listed.Masc.Tui_decode.pis_rows | Loading | Failed _ -> []
let selected t = List.find_opt (fun row -> Some row.Masc.Tui_decode.pi_name = t.selected) (rows t)
let move t delta =
  let rows = rows t in
  let index = List.find_index (fun row -> Some row.Masc.Tui_decode.pi_name = t.selected) rows in
  let index = match index with None -> 0 | Some index -> max 0 (min (List.length rows - 1) (index + delta)) in
  {t with selected = Option.map (fun row -> row.Masc.Tui_decode.pi_name) (List.nth_opt rows index)}

(* Invite names and integer lifetimes are ASCII protocol fields. *)
let edit value key = match key with
  | "\127" | "\b" | "backspace" -> String.sub value 0 (max 0 (String.length value - 1))
  | "\021" -> ""
  | key when String.length key = 1 && Char.code key.[0] >= 32 && Char.code key.[0] < 127 -> value ^ key
  | _ -> value

let key t key =
  match t.form, key with
  | (Name _ | Hours _ | Confirm_revoke _ | Confirm_resolution _), ("esc" | "cancel") -> {t with form = Browsing; message = None}, Stay
  | Confirm_resolution request_id, ("\r" | "enter") -> {t with form = Browsing}, Resolve_unknown request_id
  | Confirm_resolution _, _ -> t, Stay
  | Name name, ("\r" | "enter") ->
      (match Masc.Play_invite.Name.of_string name with
       | Error reason -> {t with message = Some reason}, Stay
       | Ok name -> {t with form = Hours (Masc.Play_invite.Name.to_string name, "24"); message = None}, Stay)
  | Hours (name, value), ("\r" | "enter") ->
      (match int_of_string_opt value with
       | Some hours when hours >= Masc_domain.min_token_expiry_hours && hours <= Masc_domain.max_token_expiry_hours ->
           let t, mutation = busy t in t, Issue (mutation, name, hours)
       | Some _ | None -> {t with message = Some (Printf.sprintf "Hours must be between %d and %d"
           Masc_domain.min_token_expiry_hours Masc_domain.max_token_expiry_hours)}, Stay)
  | Confirm_revoke name, ("\r" | "enter") ->
      let t, mutation = busy t in t, Revoke (mutation, name)
  | Name name, key -> {t with form = Name (edit name key)}, Stay
  | Hours (name, value), key -> {t with form = Hours (name, edit value key)}, Stay
  | Confirm_revoke _, _ -> t, Stay
  | Browsing, ("esc" | "q") -> t, Close
  | Browsing, "m" -> t, Watch Masc.Machine_lane.Msx
  | Browsing, "d" -> t, Watch Masc.Machine_lane.Dos
  | Browsing, "g" -> t, Game_menu
  | Browsing, "r" -> t, Refresh
  | Browsing, "u" ->
      (match t.write_access with
       | Uncertain {request_id; _} -> {t with form = Confirm_resolution request_id; message = None}, Stay
       | Writable | Pending _ | Read_only _ -> t, Stay)
  | Browsing, ("j" | "down") -> move t 1, Stay
  | Browsing, ("k" | "up") -> move t (-1), Stay
  | Browsing, ("n" | "x") when t.write_access <> Writable ->
      let message = match t.write_access with
        | Pending text | Read_only text | Uncertain {notice=text; _} -> text
        | Writable -> "" in
      {t with message = Some message}, Stay
  | Browsing, "n" when Option.is_none t.pending -> {t with form = Name ""; message = None}, Stay
  | Browsing, "x" when Option.is_none t.pending ->
      (match selected t with
       | None -> t, Stay
       | Some row -> {t with form = Confirm_revoke row.pi_name; message = None}, Stay)
  | Browsing, ("\r" | "enter") ->
      (match selected t with None -> t, Stay | Some row -> t, Open_link row.pi_name)
  | Browsing, _ -> t, Stay

let hints t = match t.form with
  | Browsing ->
      "m:MSX  d:DOS  g:games  j/k:choose  Enter:link  r:refresh  Esc:back"
      ^ (match t.write_access with Writable -> "  n:invite  x:revoke"
         | Uncertain _ -> "  u:resolve unknown" | Pending _ | Read_only _ -> "")
  | Name _ | Hours _ -> "Enter:continue  Ctrl-U:clear  Backspace:delete  Esc:cancel"
  | Confirm_revoke _ -> "Enter:revoke this invite  Esc:cancel"
  | Confirm_resolution _ -> "Enter:I verified the server request finished  Esc:keep blocked"

let controller_note controller name = match controller with
  | Masc.Tui_decode.Play_controller_held holder when String.equal holder name -> " · controlling"
  | Masc.Tui_decode.Play_controller_held _ | Masc.Tui_decode.Play_controller_free
  | Masc.Tui_decode.Play_machine_absent | Masc.Tui_decode.Play_controller_unobserved _ -> ""

let controller_summary = function
  | Masc.Tui_decode.Play_controller_held holder ->
      ["DOS controller: " ^ Masc.Tui_terminal_text.sanitize_terminal_text holder]
  | Masc.Tui_decode.Play_controller_free -> []
  | Masc.Tui_decode.Play_machine_absent -> ["No DOS machine is loaded."]
  | Masc.Tui_decode.Play_controller_unobserved reason ->
      ["DOS controller unknown: " ^ Masc.Tui_terminal_text.sanitize_terminal_text reason]

(* Prose wraps at the overlay's width instead of being cut at the frame's edge:
   the end of a refusal, an error or a confirmation is the part that says what
   to do. The text is sanitized first so the rows are as wide as the rows drawn. *)
let wrap ~width text =
  match Masc_tui_message_layout.wrap_words ~max_cells:width
          (Masc.Tui_terminal_text.sanitize_terminal_text text) with
  | [] -> [""]
  | rows -> rows

(* The three machine keys share one row while it fits and take a row each when
   it does not. *)
let machine_keys ~width =
  let keys = ["m  Watch MSX"; "d  Watch DOS"; "g  Choose an MSX game"] in
  let row = String.concat "     " keys in
  if String.length row <= width then [row] else keys

(* One invite as the rows it takes at [width]: the selection mark leads the
   first row and a longer row hangs under the name. *)
let invite_rows ~width t controller (row : Masc.Tui_decode.play_invite_row) =
  let lead = "  " in
  let mark = if Some row.pi_name = t.selected then "› " else lead in
  wrap ~width:(max 1 (width - String.length lead))
    (row.pi_name ^ controller_note controller row.pi_name
     ^ (if row.pi_expired then " · expired" else "")
     ^ " · " ^ (match row.pi_expires_at with Some date -> date | None -> "expiry not recorded"))
  |> List.mapi (fun index text -> (if index = 0 then mark else lead) ^ text)

(* The invites that fit [available] rows: the selected one always, the ones
   above it first, the ones below with the rows that are left. *)
let visible_invites ~available ~selected invites =
  let rec fit room taken = function
    | rows :: rest when List.length rows <= room -> fit (room - List.length rows) (rows :: taken) rest
    | _ -> taken, room in
  let above = List.filteri (fun index _ -> index < selected) invites in
  let below = List.filteri (fun index _ -> index > selected) invites in
  let current = Option.value (List.nth_opt invites selected) ~default:[] in
  let above, room = fit (available - List.length current) [] (List.rev above) in
  let below, _ = fit room [] below in
  List.concat (above @ [current] @ List.rev below)

let lines ~height ~width t =
  let wrap_each = List.concat_map (wrap ~width) in
  let keys = machine_keys ~width in
  let heading = wrap ~width "Shared machines · observation does not send game input"
    @ keys @ [""] @ wrap ~width "DOS play links · invite a player to the shared game" in
  let form = wrap_each (match t.form with
    | Name value -> ["Player name: " ^ value ^ "▌"; "Lowercase letters and digits; start with a letter."]
    | Hours (name, value) -> ["Player: " ^ name; "Expires in hours: " ^ value ^ "▌"]
    | Confirm_revoke name -> ["Revoke " ^ name ^ "? Their link stops working and their controller is released."]
    | Confirm_resolution request_id ->
        ["Resolve the unknown invite change?"
        ; "Request: " ^ Masc.Tui_terminal_text.sanitize_terminal_text request_id
        ; "Verify the original request cannot still complete (logs/server stop)."
        ; "Then inspect final invites. A refresh alone is not completion proof."
        ; "Enter: I verified this. Esc: keep changes blocked."]
    | Browsing -> []) in
  let access = match t.write_access with Writable -> []
    | Pending text | Read_only text | Uncertain {notice=text; _} -> [text] in
  let message = wrap_each (access @ (match t.message with None -> [] | Some text -> [text])) in
  let footer = wrap ~width "Links issued here remain in this TUI session. Enter opens the retained QR/link." in
  (* [fixed] is the body outside the invite list, [invites] the rows of each
     invite and [selected] the invite the list keeps in view. *)
  let fixed, invites, selected = match t.inventory with
    | Loading -> ["Reading invites…"], [], 0
    | Failed error ->
        wrap_each ["Could not read invites: " ^ error; "r retries the read; machine observation remains available."], [], 0
    | Listed {Masc.Tui_decode.pis_rows = []; pis_controller} ->
        wrap_each (controller_summary pis_controller
          @ [if t.write_access = Writable then "No invites. Press n to create a play link." else "No invites."]), [], 0
    | Listed {Masc.Tui_decode.pis_rows = rows; pis_controller} ->
        let selected = match List.find_index (fun row -> Some row.Masc.Tui_decode.pi_name = t.selected) rows with
          | Some index -> index | None -> 0 in
        wrap_each (controller_summary pis_controller), List.map (invite_rows ~width t pis_controller) rows, selected in
  let kept = List.length form + List.length message + List.length fixed in
  let everything = List.length heading + kept + List.length (List.concat invites) + 1 + List.length footer in
  if everything <= height then heading @ form @ message @ fixed @ List.concat invites @ [""] @ footer
  else begin
    (* A short window gives up its static text first: the closing sentence,
       then the two explanatory sentences, then the keys. The form, the messages
       and the selected invite stay, and the invites take the rows that are
       left. The frame says how many rows it cut, in a row of its own that is
       kept free here. *)
    let current = List.length (Option.value (List.nth_opt invites selected) ~default:[]) in
    let room = height - kept - current - 1 in
    let heading = Option.value (List.find_opt (fun rows -> List.length rows <= room) [heading; keys]) ~default:[] in
    let available = max 1 (height - List.length heading - kept - 1) in
    heading @ form @ message @ fixed @ visible_invites ~available ~selected invites @ [""] @ footer
  end

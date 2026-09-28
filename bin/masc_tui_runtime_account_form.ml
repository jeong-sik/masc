module D = Runtime_account_declaration
module Terminal_text = Masc_tui_ansi.Terminal_text

type field =
  | Base
  | Id
  | Location

(* The providers to copy, as a ring: left and right walk it and wrap. A list
   and an index would need an index check on every read. *)
type ring =
  { before : D.base list  (** nearest first *)
  ; chosen : D.base
  ; after : D.base list
  }

(* Defined before [t] so that an unannotated [x.id] below reads the form's
   field, not this one's. *)
type declared =
  { id : string
  ; text : string
  ; sign_in : string option
  }

(* [declaration] is the file the form was opened on. It only supplies the
   providers to choose from and the suggested id; what is saved is declared
   against the file as the server holds it at submit, so a change made while
   the form stood open is kept rather than written over. *)
type t =
  { declaration : D.t
  ; home_dir : string option
  ; ring : ring
  ; field : field
  ; id : string
  ; location : string
  ; error : string option
  }

type outcome =
  | Editing of t
  | Cancelled
  | Submitted of t

let field t = t.field

let open_on ?home_dir text =
  match D.parse text with
  | Error e -> Error (D.error_message e)
  | Ok declaration ->
    (match D.bases declaration with
     | [] -> Error "runtime.toml declares no Claude Code, Codex or Antigravity provider to copy"
     | chosen :: after ->
       Ok
         { declaration
         ; home_dir
         ; ring = { before = []; chosen; after }
         ; field = Base
         ; id = D.suggest_id declaration chosen
         ; location = ""
         ; error = None
         })
;;

let next ring =
  match ring.after with
  | base :: after -> { before = ring.chosen :: ring.before; chosen = base; after }
  | [] ->
    (match List.rev (ring.chosen :: ring.before) with
     | chosen :: after -> { before = []; chosen; after }
     | [] -> ring)
;;

let previous ring =
  match ring.before with
  | base :: before -> { before; chosen = base; after = ring.chosen :: ring.after }
  | [] ->
    (match List.rev (ring.chosen :: ring.after) with
     | chosen :: before -> { before; chosen; after = [] }
     | [] -> ring)
;;

(* The id follows the chosen provider until the operator types one. *)
let choose t ring =
  let id =
    if t.id = D.suggest_id t.declaration t.ring.chosen
    then D.suggest_id t.declaration ring.chosen
    else t.id
  in
  { t with ring; id; error = None }
;;

let field_after = function
  | Base -> Id
  | Id | Location -> Location
;;

let field_before = function
  | Base | Id -> Base
  | Location -> Id
;;

(* Where to put the cursor for a refusal: the field the operator has to
   change to get past it. *)
let field_of_error = function
  | D.Unknown_base _ | D.Nothing_to_bind _ -> Base
  | D.Id_taken _ | D.Rejected _ -> Id
  | D.Invalid_location _ | D.Location_taken _ -> Location
  | D.Unparsable _ | D.Unsupported_layout _ -> Base
;;

(* The home a Claude Code or Codex provider without [account-home] runs on,
   read the way the runtime reads it. A new account there would share that
   login, so the declaration refuses it. *)
let inherited_home = function
  | D.Claude_code -> Runtime_claude_code.effective_account_home None
  | D.Codex -> Runtime_codex_app_server.effective_account_home None
  | D.Antigravity -> None
;;

(* The command that signs the chosen client in, with [home] as the shell
   will read it. Antigravity has none -- its OAuth file exists before it can
   be typed here. *)
let command client home =
  match client with
  | D.Codex -> Some (Printf.sprintf "CODEX_HOME=%s codex login" home)
  | D.Claude_code -> Some (Printf.sprintf "CLAUDE_CONFIG_DIR=%s claude, then /login" home)
  | D.Antigravity -> None
;;

(* Quoted, because a home with a space in it is still one argument. *)
let sign_in_command client home = command client (Filename.quote home)

(* The rows under the fields: how to get the login this form points at. *)
let sign_in_rows t =
  let client = t.ring.chosen.client in
  let home =
    if t.location = ""
    then "<" ^ D.location_label client ^ ">"
    else Filename.quote (D.expand_home ?home_dir:t.home_dir t.location)
  in
  match client, command client home with
  | D.Codex, Some line ->
    [ "  로그인: " ^ line
    ; "  (먼저 그 폴더의 config.toml 에 cli_auth_credentials_store = \"file\")"
    ]
  | D.Claude_code, Some line -> [ "  로그인: " ^ line ]
  | D.Antigravity, _ ->
    [ "  OAuth 파일: masc runtime-antigravity-account --sign-in 이 출력하는 credential_file" ]
  | (D.Codex | D.Claude_code), None -> []
;;

let edit t f =
  match t.field with
  | Base -> t
  | Id -> { t with id = f t.id; error = None }
  | Location -> { t with location = f t.location; error = None }
;;

let printable key =
  (String.length key = 1 && Char.code key.[0] >= 32 && key <> "\127")
  || (String.length key > 1 && Char.code key.[0] >= 0x80)
;;

let key t key =
  match key with
  | "esc" -> Cancelled
  | "left" when t.field = Base -> Editing (choose t (previous t.ring))
  | "right" when t.field = Base -> Editing (choose t (next t.ring))
  | "up" -> Editing { t with field = field_before t.field }
  | "down" | "tab" | "\t" -> Editing { t with field = field_after t.field }
  | "\127" | "\b" | "backspace" ->
    Editing (edit t Masc_tui_message_layout.drop_last_utf8_scalar)
  | "\r" | "\n" | "enter" ->
    (match t.field with
     | Base | Id -> Editing { t with field = field_after t.field }
     | Location -> Submitted t)
  | typed when printable typed -> Editing (edit t (fun value -> value ^ typed))
  | _ -> Editing t
;;

let refused t reason = { t with error = Some reason }

let declare_on ~inherited_home t current =
  let refuse e = Error { t with error = Some (D.error_message e); field = field_of_error e } in
  match D.parse current with
  | Error e -> refuse e
  | Ok declaration ->
    let chosen = t.ring.chosen.id in
    (match List.find_opt (fun (base : D.base) -> base.id = chosen) (D.bases declaration) with
     | None -> refuse (D.Unknown_base chosen)
     | Some base ->
       (match
          D.declare ?home_dir:t.home_dir ~inherited_home declaration ~base ~id:t.id
            ~location:t.location
        with
        | Ok declared ->
          Ok
            { id = t.id
            ; text = declared.D.text
            ; sign_in = sign_in_command base.client declared.D.location
            }
        | Error e -> refuse e))
;;

let paste t text =
  let kept = String.of_seq (Seq.filter (fun c -> Char.code c >= 32 && c <> '\127') (String.to_seq text)) in
  edit t (fun value -> value ^ kept)
;;

(* Cells of the widest label, "credentials.path", with two to spare. *)
let label_cells = 18

let rows t =
  let mark field = if t.field = field then ">" else " " in
  let line field label value =
    Printf.sprintf "  %s %s %s" (mark field)
      (Masc_tui_message_layout.fit_width label label_cells)
      (Terminal_text.single_line value)
  in
  let base = t.ring.chosen in
  let count = List.length t.ring.before + 1 + List.length t.ring.after in
  [ "  계정 하나 더 · 고른 provider 를 복사하고 로그인 위치만 바꿉니다"
  ; line Base "복사할 provider"
      (Printf.sprintf "\xe2\x80\xb9 %s (%s) \xe2\x80\xba  %d/%d" base.display_name base.id
         (List.length t.ring.before + 1) count)
  ; line Id "새 provider id" t.id
  ; line Location (D.location_label base.client) t.location
  ]
  @ List.map Terminal_text.single_line (sign_in_rows t)
  @ (match t.error with
     | None -> []
     | Some reason -> [ "  ! " ^ Terminal_text.single_line reason ])
  @ [ "" ]
;;

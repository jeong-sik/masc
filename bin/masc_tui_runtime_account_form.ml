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

type t =
  { declaration : D.t
  ; ring : ring
  ; field : field
  ; id : string
  ; location : string
  ; error : string option
  }

type outcome =
  | Editing of t
  | Cancelled
  | Declared of
      { id : string
      ; text : string
      ; sign_in : string
      }

let field t = t.field

let open_on text =
  match D.parse text with
  | Error e -> Error (D.error_message e)
  | Ok declaration ->
    (match D.bases declaration with
     | [] -> Error "runtime.toml declares no Claude Code, Codex or Antigravity provider to copy"
     | chosen :: after ->
       Ok
         { declaration
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

let sign_in_command client location =
  let at = if location = "" then "<" ^ D.location_label client ^ ">" else location in
  match client with
  | D.Codex ->
    Printf.sprintf
      "CODEX_HOME=%s codex login (먼저 그 폴더 config.toml 에 cli_auth_credentials_store = \"file\")"
      at
  | D.Claude_code -> Printf.sprintf "CLAUDE_CONFIG_DIR=%s claude 를 실행하고 /login" at
  | D.Antigravity ->
    "masc runtime-antigravity-account --sign-in 이 알려 주는 credential_file 경로를 넣으세요"
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

let key ?home_dir ~inherited_home t key =
  match key with
  | "esc" -> Cancelled
  | "left" when t.field = Base -> Editing (choose t (previous t.ring))
  | "right" when t.field = Base -> Editing (choose t (next t.ring))
  | "up" -> Editing { t with field = field_before t.field }
  | "down" | "tab" | "\t" -> Editing { t with field = field_after t.field }
  | "\127" | "\b" | "backspace" ->
    Editing (edit t Masc_tui_message_layout.drop_last_utf8_scalar)
  | "\r" | "\n" ->
    (match t.field with
     | Base | Id -> Editing { t with field = field_after t.field }
     | Location ->
       (match
          D.declare ?home_dir ~inherited_home t.declaration ~base:t.ring.chosen
            ~id:t.id ~location:t.location
        with
        | Ok declared ->
          Declared
            { id = t.id
            ; text = declared.D.text
            ; sign_in = sign_in_command t.ring.chosen.client declared.D.location
            }
        | Error e ->
          Editing { t with error = Some (D.error_message e); field = field_of_error e }))
  | typed when printable typed -> Editing (edit t (fun value -> value ^ typed))
  | _ -> Editing t
;;

let refused t reason = { t with error = Some reason }

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
  ; "  로그인: " ^ Terminal_text.single_line (sign_in_command base.client t.location)
  ]
  @ (match t.error with
     | None -> []
     | Some reason -> [ "  ! " ^ Terminal_text.single_line reason ])
  @ [ "  \xe2\x86\x90/\xe2\x86\x92 provider \xc2\xb7 \xe2\x86\x91/\xe2\x86\x93 칸 이동 \xc2\xb7 enter 다음 칸, 마지막 칸에서 저장 \xc2\xb7 esc 취소"
    ; ""
    ]
;;

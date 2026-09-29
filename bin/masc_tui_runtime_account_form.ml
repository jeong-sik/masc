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
type sign_in =
  { client : D.client
  ; setup : string
  ; run : string
  }

type declared =
  { id : string
  ; text : string
  ; sign_in : sign_in option
  }

(* After a save with a sign-in, the form stays open on the command until the
   operator closes it, so it can be copied whole. *)
type phase =
  | Filling
  | Saved of
      { saved_id : string
      ; saved_sign_in : sign_in
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
  ; phase : phase
  }

type outcome =
  | Editing of t
  | Cancelled
  | Submitted of t
  | Copy of t * string

let field t = t.field

let open_on ?home_dir text =
  match D.parse text with
  | Error e -> Error (D.error_message e)
  | Ok declaration ->
    (match D.bases declaration with
     | [] -> Error "runtime.toml declares no Claude Code, Codex, Antigravity or Muse provider to copy"
     | chosen :: after ->
       Ok
         { declaration
         ; home_dir
         ; ring = { before = []; chosen; after }
         ; field = Base
         ; id = D.suggest_id declaration chosen
         ; location = ""
         ; error = None
         ; phase = Filling
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
  | D.Muse -> Sys.getenv_opt "HOME"
  | D.Antigravity -> None
;;

(* The command that signs the chosen client in, with [home] as the shell
   will read it, in two halves: [(export VAR=home &&] and [client)]. The
   client runs in a subshell, so the export does not stay in the operator's
   shell. The halves are where a row may break: each half alone is a syntax
   error the shell refuses, and the two pasted together are the command. A
   break anywhere else -- between the home and the client -- would leave the
   client to run, and sign in, on the default login. Antigravity has none;
   its OAuth file exists before it can be typed here. *)
let muse_executable command =
  let command = match command with Some configured -> configured | None -> "muse" in
  Runtime_official_cli_install.spawn_path Muse ~command
;;

let command_halves (base : D.base) home =
  match base.client with
  | D.Codex -> Some (Printf.sprintf "(export CODEX_HOME=%s &&" home, "codex login)")
  | D.Claude_code -> Some (Printf.sprintf "(export CLAUDE_CONFIG_DIR=%s &&" home, "claude)")
  | D.Muse ->
    Some
      ( Printf.sprintf
          "(unset META_API_KEY && export MUSE_NO_AUTO_UPDATE=1 %s HOME=%s XDG_CONFIG_HOME=%s/.config XDG_DATA_HOME=%s/.local/share XDG_CACHE_HOME=%s/.cache XDG_STATE_HOME=%s/.local/state XDG_RUNTIME_DIR=%s/.local/run &&"
          Runtime_muse_serve.credential_backend_entry home home home home home home
      , Filename.quote (muse_executable base.command) ^ " login)" )
  | D.Antigravity -> None
;;

(* What to type inside the client once it runs; Codex logs in by itself. *)
let typed_after = function
  | D.Claude_code -> Some "/login"
  | D.Codex | D.Muse | D.Antigravity -> None
;;

let one_line (setup, run) = setup ^ " " ^ run
let command s = one_line (s.setup, s.run)
let then_type s = typed_after s.client

(* Quoted, because a home with a space in it is still one argument. *)
let sign_in (base : D.base) home =
  Option.map
    (fun (setup, run) -> { client = base.client; setup; run })
    (command_halves base (Filename.quote home))
;;

type hint =
  | Say of string
  | Run of (string * string)

(* How to get the login the form points at, for [client] with the command's
   [halves]. {!rows} draws a [Run] as the command and wraps a [Say] to the
   pane. *)
let hints_for client halves =
  match client, halves with
  | D.Codex, Some halves ->
    [ Run halves
    ; Say
        (Printf.sprintf "(먼저 그 폴더의 config.toml 에 %s = \"%s\")"
           Runtime_verification_codex_home.credentials_store_key
           Runtime_verification_codex_home.credentials_store_file)
    ]
  | D.Claude_code, Some halves ->
    Run halves
    :: List.map
         (fun typed -> Say ("그다음 claude 안에서 " ^ typed ^ " 을 입력합니다"))
         (Option.to_list (typed_after client))
  | D.Muse, Some halves ->
    [ Run halves
    ; Say "이 HOME의 .config/muse/auth.json 파일이 필요합니다."
    ; Say "이 명령은 Keychain 대신 선택한 HOME의 파일에 로그인 정보를 저장합니다."
    ]
  | D.Antigravity, _ ->
    [ Say "OAuth 파일: masc runtime-antigravity-account --sign-in 이 출력하는 credential_file" ]
  | (D.Codex | D.Claude_code | D.Muse), None -> []
;;

(* The hints under the fields, for the location typed so far. *)
let sign_in_hints t =
  let client = t.ring.chosen.client in
  let home =
    if t.location = ""
    then "<" ^ D.location_label client ^ ">"
    else Filename.quote (D.expand_home ?home_dir:t.home_dir t.location)
  in
  hints_for client (command_halves t.ring.chosen home)
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

let saved t ~id sign_in = { t with phase = Saved { saved_id = id; saved_sign_in = sign_in } }

let is_saved t =
  match t.phase with
  | Saved _ -> true
  | Filling -> false
;;

(* Nothing is typed once the form is saved, so [y] copies as it does in the
   link and browser views, and Enter or Esc closes. *)
let key_when_saved t sign_in key =
  match key with
  | "y" | "Y" -> Copy (t, command sign_in)
  | "\r" | "\n" | "enter" | "esc" -> Cancelled
  | _ -> Editing t
;;

let key_when_filling t key =
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

let key t key =
  match t.phase with
  | Filling -> key_when_filling t key
  | Saved { saved_sign_in; _ } -> key_when_saved t saved_sign_in key
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
            ; sign_in = sign_in base declared.D.location
            }
        | Error e -> refuse e))
;;

let paste t text =
  let kept = String.of_seq (Seq.filter (fun c -> Char.code c >= 32 && c <> '\127') (String.to_seq text)) in
  edit t (fun value -> value ^ kept)
;;

let base_label = "복사할 provider"
let id_label = "새 provider id"

(* Cells between the widest label and its value. *)
let label_gap_cells = 2

(* The label column fits the widest label any client can draw, so it stays
   put while the operator cycles through bases. *)
let label_cells =
  label_gap_cells
  + List.fold_left
      (fun widest label -> max widest (Masc_tui_message_layout.display_width label))
      0
      (base_label :: id_label :: List.map D.location_label D.all_of_client)

(* What a hint row starts with, and what a refusal starts with. *)
let hint_lead = "  "
let refusal_lead = "  ! "

(* [text] after [lead], on as many rows of [width] cells as it takes. The pane
   cuts a row at its edge: at 80 columns that cut the Antigravity hint to
   "creden…", and a sign-in command with a long home the same way.
   Continuation rows step in as far as [lead], so they read as one hint.
   [wrap_words] breaks at spaces, and inside a word only where the word alone
   is wider than the row -- a long quoted home -- so a command copied off the
   screen differs from the printed one only where a space became a row
   break. *)
let wrapped ~width ~lead text =
  let lead_cells = Masc_tui_message_layout.display_width lead in
  let indent = String.make lead_cells ' ' in
  match
    Masc_tui_message_layout.wrap_words ~max_cells:(width - lead_cells)
      (Terminal_text.single_line text)
  with
  | [] -> [ lead ]
  | first :: rest -> (lead ^ first) :: List.map (fun row -> indent ^ row) rest
;;

let command_lead = "  로그인: "

(* Show only complete shell segments. A clipped export can still parse,
   so neither half is displayed when either one would be cut by the pane.
   The saved form's copy action always carries the complete command. *)
let command_rows ~width ~copy_available halves =
  let whole = command_lead ^ Terminal_text.single_line (one_line halves) in
  if Masc_tui_message_layout.display_width whole <= width
  then [ whole ]
  else (
    let setup, run = halves in
    let indent = String.make (Masc_tui_message_layout.display_width command_lead) ' ' in
    let rows = [ command_lead ^ Terminal_text.single_line setup; indent ^ run ] in
    if List.for_all (fun row -> Masc_tui_message_layout.display_width row <= width) rows
    then rows
    else
      wrapped ~width ~lead:hint_lead
        (if copy_available
         then "명령이 화면보다 깁니다. y 를 눌러 전체 명령을 복사하세요."
         else "명령이 화면보다 깁니다. 저장 후 y 로 전체 명령을 복사하세요."))
;;

let hint_rows ~width ~copy_available hints =
  List.concat_map
    (function
      | Say text -> wrapped ~width ~lead:hint_lead text
      | Run halves -> command_rows ~width ~copy_available halves)
    hints
;;

let filling_rows ~width t =
  let mark field = if t.field = field then ">" else " " in
  let line field label value =
    Printf.sprintf "  %s %s %s" (mark field)
      (Masc_tui_message_layout.fit_width label label_cells)
      (Terminal_text.single_line value)
  in
  let base = t.ring.chosen in
  let count = List.length t.ring.before + 1 + List.length t.ring.after in
  wrapped ~width ~lead:hint_lead "계정 하나 더 · 고른 provider 를 복사하고 로그인 위치만 바꿉니다"
  @ [ line Base base_label
        (Printf.sprintf "\xe2\x80\xb9 %s (%s) \xe2\x80\xba  %d/%d" base.display_name base.id
           (List.length t.ring.before + 1) count)
    ; line Id id_label t.id
    ; line Location (D.location_label base.client) t.location
    ]
  @ hint_rows ~width ~copy_available:false (sign_in_hints t)
  @ (match t.error with
     | None -> []
     | Some reason -> wrapped ~width ~lead:refusal_lead reason)
  @ [ "" ]
;;

(* The saved account and how to sign it in, drawn the way the form drew
   them, without the fields. *)
let saved_rows ~width ~id sign_in =
  wrapped ~width ~lead:hint_lead
    (Printf.sprintf "%s 를 저장했습니다 · lane 후보에 넣어야 턴이 갑니다" id)
  @ hint_rows ~width ~copy_available:true (hints_for sign_in.client (Some (sign_in.setup, sign_in.run)))
  @ [ "" ]
;;

let rows ~width t =
  match t.phase with
  | Filling -> filling_rows ~width t
  | Saved { saved_id; saved_sign_in } -> saved_rows ~width ~id:saved_id saved_sign_in
;;

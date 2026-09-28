module D = Runtime_account_declaration
module R = Runtime_account_removal
module Terminal_text = Masc_tui_ansi.Terminal_text

(* The accounts, as a ring: left and right walk it and wrap. *)
type ring =
  { before : D.base list  (** nearest first *)
  ; chosen : D.base
  ; after : D.base list
  }

(* [text] is the file the preview was computed on: the pane's copy when the
   screen opens, the server's once a submit has read it. *)
type t =
  { text : string
  ; ring : ring
  ; preview : (R.removed, R.error) result
  ; notice : string option
  }

type outcome =
  | Choosing of t
  | Cancelled
  | Submitted of t

let preview_of text (base : D.base) = R.remove text ~id:base.id

let open_on text =
  match D.parse text with
  | Error e -> Error (D.error_message e)
  | Ok declaration ->
    (match D.bases declaration with
     | [] -> Error "runtime.toml declares no Claude Code, Codex or Antigravity account to remove"
     | chosen :: after ->
       Ok
         { text
         ; ring = { before = []; chosen; after }
         ; preview = preview_of text chosen
         ; notice = None
         })
;;

let chosen t = t.ring.chosen.id

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

let choose t ring = { t with ring; preview = preview_of t.text ring.chosen; notice = None }

let key t key =
  match key with
  | "esc" -> Cancelled
  | "left" -> Choosing (choose t (previous t.ring))
  | "right" -> Choosing (choose t (next t.ring))
  | "\r" | "\n" | "enter" ->
    (match t.preview with
     | Ok _ -> Submitted t
     | Error _ -> Choosing t)
  | _ -> Choosing t
;;

let changed_notice =
  "runtime.toml 이 그사이 바뀌어 지우거나 고칠 것이 달라졌습니다 · 확인하고 다시 Enter"
;;

(* What the operator confirmed is the list of changes on screen, so a file
   that would change differently is shown again rather than saved. *)
let remove_on t current =
  let now = preview_of current t.ring.chosen in
  match now, t.preview with
  | Ok removed, Ok shown when removed.R.changes = shown.R.changes -> Ok removed
  | Ok _, (Ok _ | Error _) -> Error { t with text = current; preview = now; notice = Some changed_notice }
  | Error _, (Ok _ | Error _) -> Error { t with text = current; preview = now; notice = None }
;;

let refused t reason = { t with notice = Some reason }

let hint_lead = "  "
let change_lead = "    "
let refusal_lead = "  ! "

(* [text] after [lead], on as many rows of [width] cells as it takes, the
   continuation rows under the text rather than under the lead. *)
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

let describe = function
  | R.Table path -> Printf.sprintf "[%s]" path
  | R.Lane_candidate { lane; runtime } ->
    Printf.sprintf "lane %s 후보에서 %s 를 뺍니다" lane runtime
  | R.Exact_lane_slot { lane; runtime } ->
    Printf.sprintf "exact-output lane %s 에서 %s 를 뺍니다" lane runtime
  | R.Vision_runtime runtime -> Printf.sprintf "media_failover 에서 %s 를 뺍니다" runtime
  | R.Assignment { keeper; runtime } ->
    Printf.sprintf "keeper %s 는 %s 대신 default 로 갑니다" keeper runtime
;;

let account_row t =
  let base = t.ring.chosen in
  Printf.sprintf "  > 지울 계정  \xe2\x80\xb9 %s (%s) \xe2\x80\xba  %d/%d"
    (Terminal_text.single_line base.display_name)
    (Terminal_text.single_line base.id)
    (List.length t.ring.before + 1)
    (List.length t.ring.before + 1 + List.length t.ring.after)
;;

let rows ~width t =
  wrapped ~width ~lead:hint_lead
    "계정 지우기 · 고른 provider 와 그 계정으로 가는 설정을 runtime.toml 에서 지웁니다"
  @ [ account_row t ]
  @ (match t.preview with
     | Ok removed ->
       wrapped ~width ~lead:hint_lead "지우거나 고치는 것:"
       @ List.concat_map (fun change -> wrapped ~width ~lead:change_lead (describe change))
           removed.changes
       @ (match removed.login_store with
          | Some path -> wrapped ~width ~lead:hint_lead ("로그인 정보는 지우지 않습니다: " ^ path)
          | None -> [])
     | Error e -> wrapped ~width ~lead:refusal_lead (R.error_message e))
  @ (match t.notice with
     | None -> []
     | Some notice -> wrapped ~width ~lead:refusal_lead notice)
  @ [ "" ]
;;

(* The words more than one screen says, in both languages, in one table
   (RFC-tui-one-screen-grammar section 7.1: one concept is one word). It
   depends on nothing, so every renderer can say them; [Masc_tui_types]
   includes it. *)

(* What a title says where its counts would go. A read nobody has asked for and a
   read that failed both leave the snapshot empty, and the title is the row on
   top, so it is the answer that gets read: "not loaded" after a failure sends
   the operator to [r] while the server's reason sits in red two rows below.

   The same distinction the body makes with
   [Masc_tui_types.page_unread_note] and [Masc_tui_types.page_failed_note],
   in the words a title has room for. The Memory header was
   taught it in #35457; every other surface still said "not loaded" for both. *)
(* A title has no label to hang the words on, so it brackets them: the
   parentheses are what says "this is the state of the reading, not a count".
   A labelled field already says that with its label, and the brackets inside
   one cost two cells on the keeper chat header -- the narrowest row the TUI
   draws, which at 120 columns beside the roster has none to spare. Both
   spellings come from here so the words stay one. *)
let field_unread ~ko = if ko then "미조회" else "not loaded"
let title_unread ~ko = "(" ^ field_unread ~ko ^ ")"
(* The same pair one layer down. A title brackets its words because it has no
   label to hang them on; a labelled field does not, and said so already for
   the unread half. The failed half had no name here, so the Memory header
   spelled the title's words itself, minus the brackets -- the one place in
   the TUI that decided what a field says after a failed read. *)
let field_failed ~ko = if ko then "조회 실패" else "load failed"
let title_failed ~ko = "(" ^ field_failed ~ko ^ ")"

(* A reading kept from before a refresh that failed, in RFC-0519 section 2's
   word. The Runtime probe column and the Metrics Memory and Gate rows draw
   it; the fleet line still spells the same pair itself. *)
let field_stale ~ko = if ko then "이전 관측" else "stale"

(* A span that has passed, after its value: "3m 전", "3m ago" (RFC section
   6.2). *)
let span_ago ~ko span = span ^ if ko then " 전" else " ago"

(* The workspace the server serves, named where the TUI cannot confirm it:
   the identity was not read, the latest read did not match again, or the
   server is not ready to say ([server_authority_ready]). A request that
   needs it is kept back, and rows read before it say so, in these words.
   They are lower case for the middle of a row; a row that starts with one
   capitalises it in English, as its neighbours do. *)
let workspace_name ~ko = if ko then "워크스페이스" else "workspace"
let field_unconfirmed ~ko = if ko then "미확인" else "unconfirmed"
let workspace_identity_name ~ko = workspace_name ~ko ^ if ko then " 식별" else " identity"
let workspace_identity_unconfirmed ~ko =
  workspace_identity_name ~ko ^ " " ^ field_unconfirmed ~ko
let workspace_identity_unread ~ko = workspace_identity_name ~ko ^ " " ^ field_unread ~ko

(* The workspace the TUI resolved is not the one the server serves. *)
let field_mismatch ~ko = if ko then "불일치" else "mismatch"
let workspace_mismatch ~ko = workspace_name ~ko ^ " " ^ field_mismatch ~ko

(* What a send the TUI kept back did not do, and what stayed where it was. A
   refusal reads reason · not sent · what was kept, in these words on every
   screen that refuses one. *)
let not_sent ~ko = if ko then "보내지 않음" else "not sent"
let draft_retained ~ko = if ko then "초안 남아 있음" else "draft retained"
let queued_input_retained ~ko = if ko then "대기 입력 남아 있음" else "queued input retained"

(* What stays when a request is kept back: a message, a post, a comment or a
   Keeper declaration keeps its draft, a queued run keeps its input, and a
   decision or a vote has nothing to keep. *)
type kept = Draft_kept | Queued_input_kept | Nothing_kept

let kept_back ~ko reason kept =
  let kept = match kept with
    | Draft_kept -> [ draft_retained ~ko ]
    | Queued_input_kept -> [ queued_input_retained ~ko ]
    | Nothing_kept -> [] in
  String.concat " · " (String.capitalize_ascii reason :: not_sent ~ko :: kept)

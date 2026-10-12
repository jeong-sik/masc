open Alcotest
module View = Masc_tui_play_room
let request = function Some request -> request | None -> fail "room request was not admitted"
let empty : Masc.Play_room.snapshot = {messages = []; members = []; has_more = false}
let idle () = View.create () |> fun t -> View.active t true
let enter t = View.focus t true |> fun t -> View.paste t "한글 message"
let body request = Yojson.Safe.to_string (View.request_json request)
let text t = String.concat "\n" (snd (View.layout t ~width:80 ~height:12))
let has source needle =
  let rec seek i = i + String.length needle <= String.length source
    && (String.sub source i (String.length needle) = needle || seek (i + 1)) in seek 0

let test_retry_and_edit () =
  let t = enter (idle ()) in
  let t, first = View.send t ~machine:Masc.Machine_lane.Dos in
  let first = request first in
  let t = View.receive t first ~now:1. (Error "connection lost") in
  check bool "pending payload remains visible after unknown result" true (has (text t) "한글 message");
  let t, retry = View.send (View.active (View.active t false) true) ~machine:Masc.Machine_lane.Msx in
  let retry = request retry in
  check string "retry keeps id, text and original machine" (body first) (body retry);
  let t = View.paste t " edited" in
  let t = View.receive t retry ~now:2. (Ok empty) in
  check bool "a later draft survives acknowledgment" true (has (text t) "edited");
  let _, next = View.send t ~machine:Masc.Machine_lane.Msx in
  check bool "new draft has a new receipt" true (body first <> body (request next))

let test_serial_leave () =
  let t, read = View.poll (idle ()) ~now:1. ~machine:Masc.Machine_lane.Dos in
  let t, blocked = View.send (enter t) ~machine:Masc.Machine_lane.Dos in
  check bool "read owns the pending slot" true (Option.is_none blocked);
  let t = View.receive (View.active t false) (request read) ~now:2. (Ok empty) in
  let t, leave = View.poll t ~now:2. ~machine:Masc.Machine_lane.Dos in
  check bool "closing after read settles issues leave" true (has (body (request leave)) "leave");
  let t = View.receive t (request leave) ~now:3. (Ok empty) in
  let _, none = View.poll t ~now:4. ~machine:Masc.Machine_lane.Dos in
  check bool "closed view no longer polls" true (Option.is_none none)

let test_leave_unknown_retries () =
  let t, read = View.poll (idle ()) ~now:0. ~machine:Masc.Machine_lane.Dos in
  let t = View.receive t (request read) ~now:0. (Ok empty) in
  let t, leave = View.poll (View.active t false) ~now:1. ~machine:Masc.Machine_lane.Dos in
  let leave = request leave in
  let t = View.receive t leave ~now:2. (Error "connection lost before leave acknowledgement") in
  let t, early = View.poll t ~now:2. ~machine:Masc.Machine_lane.Dos in
  check bool "unknown leave waits for the ordinary polling cadence" true (Option.is_none early);
  let t, retry = View.poll t ~now:4. ~machine:Masc.Machine_lane.Dos in
  let retry = request retry in
  check string "inactive view retries removal of the same client" (body leave) (body retry);
  let t = View.receive t leave ~now:4. (Ok empty) in
  let _, pending = View.poll t ~now:5. ~machine:Masc.Machine_lane.Dos in
  check bool "stale leave acknowledgement cannot release the retry" true (Option.is_none pending);
  let t = View.receive t retry ~now:5. (Ok empty) in
  let _, stopped = View.poll t ~now:8. ~machine:Masc.Machine_lane.Dos in
  check bool "confirmed leave stops retries" true (Option.is_none stopped)

let test_next_draft_is_separate () =
  let t, first = View.send (enter (idle ())) ~machine:Masc.Machine_lane.Dos in
  let first = request first in
  let t = View.paste t "다음 초안" in
  let t = View.receive t first ~now:1. (Ok empty) in
  let t, second = View.send t ~machine:Masc.Machine_lane.Dos in
  let second = request second in
  let field key request = View.request_json request |> Yojson.Safe.Util.member key in
  check string "typing after Enter starts a fresh message without Ctrl-U"
    "다음 초안" (field "text" second |> Yojson.Safe.Util.to_string);
  check bool "the new message has its own id" true (field "message_id" first <> field "message_id" second);
  let t = View.paste t "다음 초안" in
  let t = View.receive t second ~now:2. (Ok empty) in
  let _, third = View.send t ~machine:Masc.Machine_lane.Dos in
  check string "an identical next draft is still a separate message"
    "다음 초안" (field "text" (request third) |> Yojson.Safe.Util.to_string)

let test_unknown_send_preserves_next_draft () =
  let t, first = View.send (enter (idle ())) ~machine:Masc.Machine_lane.Dos in
  let first = request first in
  let t = View.paste t "다음 초안" in
  let t = View.receive t first ~now:1. (Error "first outcome unknown") in
  check bool "Enter names reconciliation of the earlier send" true
    (has (View.footer t) "Enter: 이전 전송 확인");
  let t, retry = View.send t ~machine:Masc.Machine_lane.Msx in
  check string "editing the composer cannot replace the original receipt or payload"
    (body first) (body (request retry));
  let t = View.receive t (request retry) ~now:2. (Ok empty) in
  check bool "acknowledgment retains the next draft" true (has (text t) "› 다음 초안");
  let _, next = View.send t ~machine:Masc.Machine_lane.Msx in
  let next = request next in
  check bool "a later send submits the new draft with a new receipt" true
    (body next <> body first && has (body next) "다음 초안" && has (body next) "msx")

let test_unknown_send_with_empty_next_draft () =
  let t, first = View.send (enter (idle ())) ~machine:Masc.Machine_lane.Dos in
  let first = request first in
  let t = View.receive t first ~now:1. (Error "unknown") in
  let t, _ = View.key t "\021" in
  let t, retry = View.send t ~machine:Masc.Machine_lane.Msx in
  check string "clearing the composer still permits the exact earlier retry"
    (body first) (body (request retry));
  let t = View.receive t (request retry) ~now:2. (Ok empty) in
  let _, no_draft = View.send t ~machine:Masc.Machine_lane.Msx in
  check bool "an empty next draft does not send after reconciliation" true (Option.is_none no_draft)

let test_withdrawal () =
  let t, send = View.send (enter (idle ())) ~machine:Masc.Machine_lane.Dos in
  let send = request send in
  let t = View.suspend t in
  let t = View.receive t send ~now:1. (Ok empty) in
  check bool "withdrawn response cannot erase pending payload" true (has (text t) "한글 message");
  let _, retry = View.send (View.active t true) ~machine:Masc.Machine_lane.Dos in
  check string "confirmed workspace return retries same receipt" (body send) (body (request retry))

let test_retired_read () =
  let t, read = View.poll (idle ()) ~now:1. ~machine:Masc.Machine_lane.Dos in
  let read = request read in
  check bool "a poll is a read" true (View.is_read read);
  let t, again = View.poll (View.retire_read t) ~now:1. ~machine:Masc.Machine_lane.Dos in
  check bool "a retired read frees the slot for the next poll" true (Option.is_some again);
  let t = View.receive t read ~now:2. (Ok empty) in
  let _, blocked = View.poll t ~now:3. ~machine:Masc.Machine_lane.Dos in
  check bool "the discarded reply cannot settle the read after it" true (Option.is_none blocked);
  let t, send = View.send (enter (idle ())) ~machine:Masc.Machine_lane.Dos in
  check bool "a send is not a read" false (View.is_read (request send));
  let _, held = View.poll (View.retire_read t) ~now:5. ~machine:Masc.Machine_lane.Dos in
  check bool "retiring reads keeps a send's receipt" true (Option.is_none held)

let test_retired_first_read_keeps_presence () =
  let t, read = View.poll (idle ()) ~now:1. ~machine:Masc.Machine_lane.Dos in
  check bool "the first read is in flight" true (View.is_read (request read));
  let t = View.active (View.retire_read t) false in
  let _, leave = View.poll t ~now:1. ~machine:Masc.Machine_lane.Dos in
  check bool "closing after a retired first read still leaves" true
    (has (body (request leave)) "\"leave\"")

let test_withdrawal_preserves_presence_release () =
  List.iter (fun acknowledged ->
    let t, read = View.poll (idle ()) ~now:1. ~machine:Masc.Machine_lane.Dos in
    let t = if acknowledged then View.receive t (request read) ~now:1. (Ok empty) else t in
    let t = View.suspend (View.suspend t) in
    let t, leave = View.poll t ~now:2. ~machine:Masc.Machine_lane.Dos in
    check bool "confirmed or possible presence is released after same-workspace return" true
      (has (body (request leave)) "leave");
    let t = View.receive t (request leave) ~now:3. (Ok empty) in
    let _, again = View.poll t ~now:4. ~machine:Masc.Machine_lane.Dos in
    check bool "confirmed leave ends the obligation" true (Option.is_none again)) [false; true]

let test_paste_and_keys () =
  let t = View.paste (idle ()) "한글\027[31m" in
  check bool "terminal escape is rendered as text" false (has (text t) "\027");
  let t = View.focus (idle ()) true |> fun t -> View.paste t "가나" in
  let t, _ = View.key t "backspace" in
  check bool "backspace retains valid UTF-8" true (String.is_valid_utf_8 (text t));
  check bool "backspace removes final Korean scalar" false (has (text t) "나");
  let t, intent = View.key t "esc" in
  check bool "Esc returns focus without sending" true (intent = View.Repaint && not (View.focused t))

let message id text : Masc.Play_room.message =
  {id; at = float_of_int id; who = Printf.sprintf "keeper-%02d" id;
   speaker = Keeper; machine = Dos; text}

let test_authenticated_viewer_marks () =
  let own = { (message 1 "same words") with who = "operator"; speaker = Participant } in
  let peer = { own with id = 2; who = "guest" } in
  let snapshot = {empty with messages = [own; peer]} in
  let t, read = View.poll (idle ()) ~now:0. ~machine:Masc.Machine_lane.Dos in
  let read = request read in
  let t = View.receive ~viewer:"operator" t read ~now:0. (Ok snapshot) in
  check bool "own messages use the operator mark without colour" true
    (has (text t) "▶ operator · DOS");
  check bool "identical text from another participant remains inbound" true
    (has (text t) "◀ guest · DOS");
  let t, _ = View.poll t ~now:3. ~machine:Masc.Machine_lane.Dos in
  let t = View.receive ~viewer:"guest" t read ~now:3. (Ok snapshot) in
  check bool "a stale response cannot replace the authenticated viewer" true
    (has (text t) "▶ operator · DOS" && has (text t) "◀ guest · DOS")
let messages first count = List.init count (fun index ->
  let id = first + index in message id (Printf.sprintf "message-%02d" id))
let refresh t ~now messages =
  let t, read = View.poll t ~now ~machine:Masc.Machine_lane.Dos in
  View.receive t (request read) ~now (Ok {empty with messages})
let paint t = View.layout t ~width:40 ~height:7
let body_rows rows = List.take 4 (List.drop 2 rows)
let move t key = fst (View.key t key)
let rec move_many t count key =
  if count = 0 then t else move_many (move t key) (count - 1) key

let test_scroll_bounds () =
  let t, _ = paint (refresh (idle ()) ~now:0. (messages 1 10)) in
  let t, at_top = paint (move_many t 10 "pgup") in
  check string "oldest visible message" "● keeper-01 · DOS"
    (String.trim (List.hd (body_rows at_top)));
  let t, next = paint (move t "pgdn") in
  check string "one downward step moves immediately after repeated upward steps"
    "message-03" (String.trim (List.hd (body_rows next)));
  let t, _ = View.layout t ~width:40 ~height:30 in
  let t = move_many t 10 "pgup" |> fun t -> move t "pgdn" in
  let _, small = paint t in
  check string "a viewport containing all messages accumulates no hidden movement"
    "message-10" (String.trim (List.nth (body_rows small) 3))

let test_wrapped_history_anchor () =
  let long = message 1 (String.concat " " (List.init 8 (fun i -> Printf.sprintf "segment%02d" (i + 1)))) in
  let paint t = View.layout t ~width:12 ~height:7 in
  let t, _ = paint (refresh (idle ()) ~now:0. [long; message 2 "tail"]) in
  let t, before = paint (move t "pgup") in
  check string "history begins inside a wrapped message" "segment02"
    (String.trim (List.hd (body_rows before)));
  let _, after = paint (refresh t ~now:3. [long; message 2 "tail"; message 3 "new"]) in
  check (list string) "new messages preserve the exact historical lines"
    (body_rows before) (body_rows after)

let test_retained_history_anchor () =
  let t, _ = paint (refresh (idle ()) ~now:0. (messages 1 10)) in
  let t, before = paint (move t "pgup") in
  let t, surviving = paint (refresh t ~now:3. (messages 3 10)) in
  check (list string) "rolling history preserves a surviving message and line"
    (body_rows before) (body_rows surviving);
  let t, removed = paint (refresh t ~now:6. (messages 8 10)) in
  check string "an evicted anchor clamps to the oldest surviving message"
    "● keeper-08 · DOS" (String.trim (List.hd (body_rows removed)));
  let _, next = paint (move t "pgdn") in
  check string "navigation starts from the displayed replacement anchor"
    "message-10" (String.trim (List.hd (body_rows next)))

let test_resume_latest () =
  let t, _ = paint (refresh (idle ()) ~now:0. (messages 1 10)) in
  let t, _ = paint (move t "pgup") in
  let t, _ = paint (move t "end") in
  let _, latest = paint (refresh t ~now:3. (messages 1 11)) in
  check string "End resumes following new messages" "message-11"
    (String.trim (List.nth (body_rows latest) 3))

let test_unusable_width_retains_room_state () =
  let t = refresh (enter (idle ())) ~now:0.
    (List.init 100 (fun i -> message (i + 1) (String.make 4096 'x'))) in
  let t, rows = View.layout t ~width:4 ~height:3 in
  check int "narrow layout keeps only screen rows" 3 (List.length rows);
  (* The notice is cut to the width with the layout's cut mark; what matters
     is that it stands in for the messages instead of wrapping them. *)
  let notice = List.hd rows in
  check bool "compact resize notice replaces wrapping" true
    (String.starts_with ~prefix:"공" notice && not (String.contains notice 'x'));
  check bool "draft survives unsupported width" true (has (text t) "한글 message")

let () = run "TUI public room" ["room", [
  test_case "unusable width preserves room state" `Quick test_unusable_width_retains_room_state;
  test_case "unknown send, reopen and edited draft" `Quick test_retry_and_edit;
  test_case "withdrawal preserves presence release" `Quick test_withdrawal_preserves_presence_release;
  test_case "serial request and deferred leave" `Quick test_serial_leave;
  test_case "uncertain leave retries while inactive" `Quick test_leave_unknown_retries;
  test_case "sending frees the composer for the next message" `Quick test_next_draft_is_separate;
  test_case "unknown send remains separate from the next draft" `Quick test_unknown_send_preserves_next_draft;
  test_case "unknown send can be retried with an empty composer" `Quick test_unknown_send_with_empty_next_draft;
  test_case "workspace withdrawal invalidates receipts" `Quick test_withdrawal;
  test_case "a retired reading releases only the room read" `Quick test_retired_read;
  test_case "a retired first read keeps presence to release" `Quick test_retired_first_read_keeps_presence;
  test_case "safe paste and Korean editing" `Quick test_paste_and_keys;
  test_case "authenticated viewer identifies local messages" `Quick test_authenticated_viewer_marks;
  test_case "scroll bounds follow the displayed viewport" `Quick test_scroll_bounds;
  test_case "new messages preserve a wrapped history line" `Quick test_wrapped_history_anchor;
  test_case "history retention preserves or clamps its anchor" `Quick test_retained_history_anchor;
  test_case "End resumes live following" `Quick test_resume_latest;
]]

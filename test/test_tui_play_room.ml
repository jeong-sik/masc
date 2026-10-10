open Alcotest
module View = Masc_tui_play_room
let request = function Some request -> request | None -> fail "room request was not admitted"
let empty : Masc.Play_room.snapshot = {messages = []; members = []; has_more = false}
let idle () = View.create () |> fun t -> View.active t true
let enter t = View.focus t true |> fun t -> View.paste t "한글 message"
let body request = Yojson.Safe.to_string (View.request_json request)
let has source needle =
  let rec seek i = i + String.length needle <= String.length source
    && (String.sub source i (String.length needle) = needle || seek (i + 1)) in seek 0

let test_retry_and_edit () =
  let t = enter (idle ()) in
  let t, first = View.send t ~machine:Masc.Machine_lane.Dos in
  let first = request first in
  let t = View.receive t first ~now:1. (Error "connection lost") in
  let t, retry = View.send (View.active (View.active t false) true) ~machine:Masc.Machine_lane.Msx in
  let retry = request retry in
  check string "retry keeps id, text and original machine" (body first) (body retry);
  let t = View.paste t " edited" in
  let t = View.receive t retry ~now:2. (Ok empty) in
  let _, next = View.send t ~machine:Masc.Machine_lane.Msx in
  let next = request next in
  check bool "a later draft survives acknowledgment" true (has (body next) "edited");
  check bool "new draft has a new receipt" true (body first <> body next)

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
  let t, retry = View.send t ~machine:Masc.Machine_lane.Msx in
  check string "editing the composer cannot replace the original receipt or payload"
    (body first) (body (request retry));
  let t = View.receive t (request retry) ~now:2. (Ok empty) in
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
  let sent_text t =
    match View.send t ~machine:Masc.Machine_lane.Dos with
    | _, Some sent -> View.request_json sent |> Yojson.Safe.Util.member "text" |> Yojson.Safe.Util.to_string
    | _, None -> fail "the draft was not sent" in
  check bool "a pasted terminal escape never reaches the message" false
    (String.contains (sent_text (View.paste (idle ()) "한글\027[31m")) '\027');
  let t = View.focus (idle ()) true |> fun t -> View.paste t "가나" in
  let t, _ = View.key t "backspace" in
  check string "backspace removes the final Korean scalar" "가" (sent_text t);
  let t, intent = View.key t "esc" in
  check bool "Esc returns focus without sending" true (intent = View.Repaint && not (View.focused t))

let message id text : Masc.Play_room.message =
  {id; at = float_of_int id; who = Printf.sprintf "keeper-%02d" id;
   speaker = Keeper; machine = Dos; text}

let refresh t ~now messages =
  let t, read = View.poll t ~now ~machine:Masc.Machine_lane.Dos in
  View.receive t (request read) ~now (Ok {empty with messages})
let test_unusable_width_retains_room_state () =
  let t = refresh (enter (idle ())) ~now:0.
    (List.init 100 (fun i -> message (i + 1) (String.make 4096 'x'))) in
  let t, _ = View.layout t ~width:4 ~height:3 in
  let _, sent = View.send t ~machine:Masc.Machine_lane.Dos in
  check bool "draft survives unsupported width" true (has (body (request sent)) "한글 message")

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
]]

(** What happens to a line typed while a turn is running.

    It used to be answered with "Keeper message already in progress" and lost.
    These pin what replaced that: the line waits, in the order it was written,
    addressed to the keeper it was written to. *)

open Alcotest
module Queue = Masc_tui_keeper_chat_queue
module Chat = Masc_tui_keeper_chat_projection

(* What waits is the whole request, built when the operator pressed Enter.
   These tests are about order, so they build the smallest one that carries a
   keeper and a message. *)
let request ~keeper_name text =
  Chat.create_request ~attachments:[] ~keeper_name ~message:text ()
;;

let messages queue =
  List.map
    (fun (item : Queue.item) -> item.request.Chat.message)
    (Queue.waiting queue)
;;

let push_exn queue ~keeper_name text =
  match Queue.push queue ~submitted_at:42. (request ~keeper_name text) with
  | Ok (queue, waiting) -> (queue, waiting)
  | Error detail -> failf "expected the line to queue, got: %s" detail
;;

let test_lines_wait_in_the_order_they_were_written () =
  let q, first = push_exn Queue.empty ~keeper_name:"bluebird" "one" in
  let q, second = push_exn q ~keeper_name:"bluebird" "two" in
  let q, third = push_exn q ~keeper_name:"bluebird" "three" in
  check (list int) "each push says how many are waiting" [ 1; 2; 3 ]
    [ first; second; third ];
  check (list string) "and they wait in submission order"
    [ "one"; "two"; "three" ]
    (messages q)
;;

let test_recall_replacement_checks_the_original_payload () =
  let original = request ~keeper_name:"alpha" "original" in
  let queue, _ = match Queue.push Queue.empty ~submitted_at:42. original with
    | Ok pair -> pair | Error detail -> fail detail in
  let item = Option.get (Queue.find queue ~request_id:original.request_id) in
  let priority = match Queue.mark_run_next queue ~request_id:original.request_id with
    | Ok queue -> queue | Error detail -> fail detail in
  let edited = {original with Chat.message="edited"} in
  (match Queue.replace_recalled_request priority ~original:item edited with
   | Error detail -> fail detail
   | Ok replaced ->
       let actual = Option.get (Queue.find replaced ~request_id:original.request_id) in
       check bool "the edited payload keeps the current priority and position" true
         (actual.request = edited && actual.intent = Queue.Run_next {automatic=false}
          && actual.submission_seq = item.submission_seq && actual.submitted_at = item.submitted_at));
  let changed = {original with Chat.references=[Chat.Ref_url "https://example.org/image"]} in
  let changed_queue = match Queue.replace_request queue ~request_id:original.request_id changed with
    | Ok queue -> queue | Error detail -> fail detail in
  check bool "a changed reference with the same request ID cannot be overwritten" true
    (Result.is_error (Queue.replace_recalled_request changed_queue ~original:item edited));
  let different_keeper = {original with Chat.keeper_name="beta"} in
  let changed_queue = match Queue.replace_request queue ~request_id:original.request_id different_keeper with
    | Ok queue -> queue | Error detail -> fail detail in
  check bool "same ID for a different Keeper cannot be overwritten" true
    (Result.is_error (Queue.replace_recalled_request changed_queue ~original:item edited));
  check bool "a missing request cannot be recreated by editing" true
    (Result.is_error (Queue.replace_recalled_request Queue.empty ~original:item edited))
;;

let test_staged_source_follows_the_pending_item () =
  let original = request ~keeper_name:"alpha" "before paste\noriginal bytes" in
  let queue, _ = match Queue.push Queue.empty ~submitted_at:42. original with
    | Ok pair -> pair | Error detail -> fail detail in
  let accepted = Option.get (Queue.find queue ~request_id:original.request_id) in
  let staged = {original with Chat.message="before paste\n[file reference]"} in
  let source = Queue.source_for_staging accepted ~message:staged.message in
  let queue = match Queue.replace_recalled_request ~source
      queue ~original:accepted staged with
    | Ok queue -> queue | Error detail -> fail detail in
  let staged_item = Option.get (Queue.find queue ~request_id:original.request_id) in
  check string "the wire payload names the file" staged.message staged_item.request.message;
  check string "the accepted source stays with the queue item" original.message (Queue.source_text staged_item);
  let promoted = Queue.prepare_for_admission ~automatic:true staged_item in
  let restored = Queue.restore_unsent Queue.empty promoted in
  let restored_item = Option.get (Queue.find restored ~request_id:original.request_id) in
  check bool "preflight promotion and restoration retain both payloads" true
    (restored_item.request = staged && Queue.source_text restored_item = original.message);
  let changed_source = match Queue.replace_request ~source:(Queue.Staged_fragments ["changed source"])
      queue ~request_id:original.request_id staged with
    | Ok queue -> queue | Error detail -> fail detail in
  check bool "an editor cannot overwrite a source-only change" true
    (Result.is_error (Queue.replace_recalled_request changed_source ~original:staged_item staged));
  let edited = {staged with Chat.message="new input"} in
  let edited_queue = match Queue.replace_recalled_request queue ~original:staged_item edited with
    | Ok queue -> queue | Error detail -> fail detail in
  let edited_item = Option.get (Queue.find edited_queue ~request_id:original.request_id) in
  check string "an ordinary edit becomes the new source" edited.message (Queue.source_text edited_item);
  let later = "later input" in
  let merged = {staged with Chat.message=staged.message ^ "\n" ^ later} in
  let source = Queue.source_for_join staged_item ~message:later in
  let joined = match Queue.replace_request ~source queue ~request_id:original.request_id merged with
    | Ok queue -> queue | Error detail -> fail detail in
  let joined_item = Option.get (Queue.find joined ~request_id:original.request_id) in
  check string "joined staged source retains original bytes and input order"
    (original.message ^ "\n" ^ later) (Queue.source_text joined_item);
  check bool "an unchanged wire edit preserves the staged source" true
    (Queue.source_for_edit joined_item ~message:joined_item.request.message = joined_item.source)
;;

(* The operator can switch keepers while a turn runs. A queued line must reach
   the keeper it was written to, not whoever is selected when it finally goes. *)
let test_a_line_keeps_the_keeper_it_was_written_to () =
  let q, _ = push_exn Queue.empty ~keeper_name:"bluebird" "for bluebird" in
  let q, _ = push_exn q ~keeper_name:"bandleader" "for bandleader" in
  match Queue.take_first_sendable q ~sendable:(fun _ -> true) with
  | None -> fail "expected a waiting line"
  | Some (first_item, rest) ->
      let first = first_item.Queue.request in
      check string "the oldest goes first" "for bluebird" first.Chat.message;
      check string "to its own keeper" "bluebird" first.Chat.keeper_name;
      (match Queue.take_first_sendable rest ~sendable:(fun _ -> true) with
       | None -> fail "expected the second line to still be waiting"
       | Some (second_item, rest) ->
           let second = second_item.Queue.request in
           check string "and the next keeps its own" "bandleader"
             second.Chat.keeper_name;
           check string "with its own text" "for bandleader" second.Chat.message;
           check bool "nothing left after both" true (Queue.is_empty rest))
;;

(* Refused and named at the cap rather than dropping the oldest: a line that
   silently disappeared is the failure this whole queue exists to end. *)
let test_the_cap_refuses_rather_than_forgetting () =
  let rec fill queue = function
    | 0 -> queue
    | n ->
        let queue, _ = push_exn queue ~keeper_name:"k" (string_of_int n) in
        fill queue (n - 1)
  in
  let full = fill Queue.empty Queue.cap in
  check int "the queue is at its cap" Queue.cap (Queue.length full);
  match
    Queue.push full ~submitted_at:42. (request ~keeper_name:"k" "one too many")
  with
  | Ok _ -> fail "the cap must refuse"
  | Error detail ->
      check bool "the refusal says the line was not taken" true
        (Astring.String.is_infix ~affix:"not queued" detail);
      check int "and nothing already waiting was dropped" Queue.cap
        (Queue.length full)
;;

(* Temporary inability to dispatch must not consume the operator's request.
   Other Keepers may advance while the original identity and payload wait. *)
let test_unavailable_keeper_input_survives_reconnection () =
  let q, _ = push_exn Queue.empty ~keeper_name:"leaving" "pending original" in
  let original = List.hd (Queue.waiting q) in
  let q, _ = push_exn q ~keeper_name:"staying" "ready other" in
  let retained = match Queue.take_first_sendable q ~sendable:(fun name -> name = "staying") with
    | None -> fail "ready other request did not dispatch"
    | Some (sent, retained) ->
        check string "other Keeper can advance" "ready other" sent.request.message;
        retained in
  check bool "unavailable Keeper alone has no dispatch" true
    (Option.is_none (Queue.take_first_sendable retained ~sendable:(fun _ -> false)));
  match Queue.take_first_sendable retained ~sendable:(fun _ -> true) with
  | None -> fail "reconnected Keeper lost the queued request"
  | Some (sent, rest) ->
      check bool "complete original request retained" true (sent == original);
      check bool "successful dispatch consumes only that request" true (Queue.is_empty rest)
;;

(* Lines wait because their own keeper had a turn running, and keepers run
   turns independently. Taking strictly from the front stalls every line behind
   one whose keeper is still busy — and permanently, because the ones behind it
   are addressed to keepers that are idle and so have no settle coming. *)
let test_a_busy_keeper_does_not_stall_the_lines_behind_it () =
  let q, _ = push_exn Queue.empty ~keeper_name:"busy" "waits" in
  let q, _ = push_exn q ~keeper_name:"free" "can go" in
  let q, _ = push_exn q ~keeper_name:"busy" "waits too" in
  match Queue.take_first_sendable q ~sendable:(fun k -> not (String.equal k "busy")) with
  | None -> fail "the free keeper's line should be sendable"
  | Some (taken_item, rest) ->
      let taken = taken_item.Queue.request in
      check string "the free keeper's line comes out" "can go" taken.Chat.message;
      check string "with its own keeper" "free" taken.Chat.keeper_name;
      check (list string) "and the busy keeper's lines keep their order"
        [ "waits"; "waits too" ]
        (messages rest)
;;

let test_nothing_sendable_takes_nothing () =
  let q, _ = push_exn Queue.empty ~keeper_name:"busy" "waits" in
  check bool "a queue with only busy keepers takes nothing" true
    (Option.is_none (Queue.take_first_sendable q ~sendable:(fun _ -> false)));
  check int "and keeps what it had" 1 (Queue.length q)
;;

(* With everything sendable it is the oldest line, the same as popping. *)
let test_all_sendable_is_oldest_first () =
  let q, _ = push_exn Queue.empty ~keeper_name:"a" "one" in
  let q, _ = push_exn q ~keeper_name:"b" "two" in
  match Queue.take_first_sendable q ~sendable:(fun _ -> true) with
  | None -> fail "expected a line"
  | Some (taken_item, rest) ->
      let taken = taken_item.Queue.request in
      check string "oldest first" "one" taken.Chat.message;
      check (list string) "the rest keeps its order" [ "two" ]
        (messages rest)
;;

(* Editing a waiting line takes that line out, not the newest one. The arrows
   can walk back past several, and replacing "whichever was last" would drop a
   line the operator never looked at. *)
let test_take_removes_the_named_line_and_keeps_the_order () =
  let one = request ~keeper_name:"k" "one" in
  let two = request ~keeper_name:"k" "two" in
  let three = request ~keeper_name:"k" "three" in
  let queue =
    List.fold_left
      (fun queue request ->
        match Queue.push queue ~submitted_at:42. request with
        | Ok (queue, _) -> queue
        | Error detail -> failf "push failed: %s" detail)
      Queue.empty [ one; two; three ]
  in
  (match Queue.take queue ~request_id:two.Chat.request_id with
   | None -> fail "the queue holds this request"
   | Some (taken_item, rest) ->
       let taken = taken_item.Queue.request in
       check string "the named line comes out" "two" taken.Chat.message;
       check (list string) "and the rest keeps its order" [ "one"; "three" ]
         (messages rest));
  check bool "a request the queue does not hold takes nothing" true
    (Option.is_none (Queue.take queue ~request_id:"tui-request-not-here"))
;;

(* [holds] and [take] answer about the same line: the pane asks the first to
   mark a row as waiting and the send asks the second to replace it. Two
   answers that disagreed would mark a row the send could not find. *)
let test_holds_agrees_with_take () =
  let only = request ~keeper_name:"k" "only" in
  let queue =
    match Queue.push Queue.empty ~submitted_at:42. only with
    | Ok (queue, _) -> queue
    | Error detail -> failf "push failed: %s" detail
  in
  check bool "holds says yes" true
    (Queue.holds queue ~request_id:only.Chat.request_id);
  check bool "and take agrees" true
    (Option.is_some (Queue.take queue ~request_id:only.Chat.request_id));
  check bool "holds says no for a stranger" false
    (Queue.holds queue ~request_id:"tui-request-stranger")
;;

let test_an_empty_queue_takes_nothing () =
  check bool "empty is empty" true (Queue.is_empty Queue.empty);
  check int "and has no length" 0 (Queue.length Queue.empty);
  check bool "and takes nothing" true
    (Option.is_none (Queue.take_first_sendable Queue.empty ~sendable:(fun _ -> true)))
;;

let test_submission_clock_and_per_keeper_count_are_preserved () =
  let alpha = request ~keeper_name:"alpha" "one" in
  let beta = request ~keeper_name:"beta" "two" in
  let queue =
    match Queue.push Queue.empty ~submitted_at:12.5 alpha with
    | Error detail -> fail detail
    | Ok (queue, _) ->
        (match Queue.push queue ~submitted_at:13.5 beta with
         | Error detail -> fail detail
         | Ok (queue, _) -> queue)
  in
  check int "alpha count" 1 (Queue.length_for_keeper queue ~keeper_name:"alpha");
  check int "beta count" 1 (Queue.length_for_keeper queue ~keeper_name:"beta");
  match Queue.waiting_for_keeper queue ~keeper_name:"alpha" with
  | [ item ] ->
      check (float 0.001) "first submission clock" 12.5 item.Queue.submitted_at
  | items -> failf "expected one alpha item, got %d" (List.length items)
;;

let test_steer_precedes_next_for_its_keeper () =
  let queue, _ = push_exn Queue.empty ~keeper_name:"alpha" "next one" in
  let queue, _ = push_exn queue ~keeper_name:"beta" "beta next" in
  let queue, _ = push_exn queue ~keeper_name:"alpha" "next two" in
  let steer = request ~keeper_name:"alpha" "replacement" in
  let queue =
    match
      Queue.push_steer queue ~submitted_at:99.
        ~causal_parent_request_id:"active-a" steer
    with
    | Error detail -> fail detail
    | Ok (queue, waiting) ->
        check int "three alpha items" 3 waiting;
        queue
  in
  check (list string) "alpha dispatch order"
    [ "replacement"; "next one"; "next two" ]
    (Queue.waiting_for_keeper queue ~keeper_name:"alpha"
     |> List.map (fun item -> item.Queue.request.Chat.message));
  (match Queue.take_first_sendable queue ~sendable:(fun _ -> true) with
   | Some (item, _) ->
       check string "steer dispatches first" "replacement"
         item.Queue.request.Chat.message;
       check bool "typed intent" true
         (item.Queue.intent = Queue.Steer_after_interrupt);
       check (option string) "exact causal parent" (Some "active-a")
         item.Queue.causal_parent_request_id
   | None -> fail "steer should be sendable");
  (match Queue.take_newest_for_keeper queue ~keeper_name:"alpha" with
   | Some (item, _) ->
       check string "newest means submission, not dispatch tail" "replacement"
         item.Queue.request.Chat.message
   | None -> fail "newest alpha submission should exist");
  let edited = { steer with Chat.message = "edited replacement" } in
  (match Queue.replace_request queue ~request_id:steer.request_id edited with
   | Error detail -> fail detail
   | Ok edited_queue ->
       (match Queue.find edited_queue ~request_id:steer.request_id with
        | None -> fail "edited steer disappeared"
        | Some edited_item ->
            check string "edited body" "edited replacement"
              edited_item.request.message;
            check (float 0.001) "edit keeps submission clock" 99.
              edited_item.submitted_at;
            check (option string) "edit keeps causal parent" (Some "active-a")
              edited_item.causal_parent_request_id));
  match
    Queue.push_steer queue ~submitted_at:100.
      ~causal_parent_request_id:"active-a" steer
  with
  | Ok _ -> fail "a second steer for one Keeper must be refused"
  | Error detail ->
      check bool "refusal names existing steer" true
        (Astring.String.is_infix ~affix:"already waiting" detail)
;;

let test_take_newest_for_keeper_does_not_touch_another_keeper () =
  let queue, _ = push_exn Queue.empty ~keeper_name:"alpha" "alpha one" in
  let queue, _ = push_exn queue ~keeper_name:"beta" "beta one" in
  let queue, _ = push_exn queue ~keeper_name:"alpha" "alpha two" in
  let queue, _ = push_exn queue ~keeper_name:"beta" "beta two" in
  match Queue.take_newest_for_keeper queue ~keeper_name:"alpha" with
  | None -> fail "alpha has waiting input"
  | Some (taken, rest) ->
      check string "newest alpha" "alpha two" taken.Queue.request.Chat.message;
      check (list string) "other positions survive"
        [ "alpha one"; "beta one"; "beta two" ]
        (messages rest)
;;

let test_reorder_preserves_identity_other_keepers_and_steer () =
  let first = request ~keeper_name:"alpha" "alpha first" in
  let middle = request ~keeper_name:"alpha" "alpha middle" in
  let last = request ~keeper_name:"alpha" "alpha last" in
  let other_first = request ~keeper_name:"beta" "beta first" in
  let other_last = request ~keeper_name:"beta" "beta last" in
  let steer = request ~keeper_name:"alpha" "steer" in
  let original =
    List.fold_left (fun queue request ->
      match Queue.push queue ~submitted_at:42. request with
      | Ok (queue, _) -> queue | Error detail -> fail detail)
      Queue.empty [first; other_first; middle; other_last; last] in
  let original = match Queue.push_steer original ~submitted_at:99.
    ~causal_parent_request_id:"active-alpha" steer with
    | Ok (queue, _) -> queue | Error detail -> fail detail in
  let before = match Queue.find original ~request_id:last.request_id with
    | Some item -> item | None -> fail "the selected request is missing" in
  let ids queue = Queue.waiting queue |> List.map (fun (item : Queue.item) -> item.request.request_id) in
  let moved = match Queue.move_to_front original ~keeper_name:"alpha" ~request_id:last.request_id with
    | Ok queue -> queue | Error detail -> fail detail in
  check (list string) "move to front preserves the steer and other Keeper slots"
    [steer.request_id; last.request_id; other_first.request_id;
     first.request_id; other_last.request_id; middle.request_id] (ids moved);
  (match Queue.find moved ~request_id:last.request_id with
   | Some after -> check bool "the whole queued item is retained" true (after == before)
   | None -> fail "reorder lost the selected request");
  (match Queue.take_first_sendable moved ~sendable:(String.equal "alpha") with
   | Some (item, _) ->
     check string "the existing steer remains the next alpha request" steer.request_id item.request.request_id;
     check (option string) "steer retains its causal parent" (Some "active-alpha") item.causal_parent_request_id
   | None -> fail "alpha input was lost");
  let restored = match Queue.move_to_end moved ~keeper_name:"alpha" ~request_id:last.request_id with
    | Ok queue -> queue | Error detail -> fail detail in
  check (list string) "move to end preserves each Keeper's slots"
    (ids original) (ids restored);
  let older_last = match Queue.move_to_end original ~keeper_name:"alpha" ~request_id:first.request_id with
    | Ok queue -> queue | Error detail -> fail detail in
  (match Queue.join_target older_last ~keeper_name:"alpha" with
   | Some item -> check string "coalescing still targets the newest submitted ordinary message"
       last.request_id item.request.request_id
   | None -> fail "the newest ordinary message was lost");
  (match Queue.take_newest_for_keeper restored ~keeper_name:"alpha" with
   | Some (item, _) -> check string "newest still means submission identity" steer.request_id item.request.request_id
   | None -> fail "alpha input was lost");
  List.iter (fun move ->
    check bool "a different Keeper cannot move this request" true
      (Result.is_error (move original ~keeper_name:"beta" ~request_id:last.request_id));
    check bool "a missing request cannot be moved" true
      (Result.is_error (move original ~keeper_name:"alpha" ~request_id:"missing"));
    check bool "a steer cannot be displaced" true
      (Result.is_error (move original ~keeper_name:"alpha" ~request_id:steer.request_id)))
    [Queue.move_to_front; Queue.move_to_end];
  check (list string) "refused changes preserve the original queue"
    [steer.request_id; first.request_id; other_first.request_id;
     middle.request_id; other_last.request_id; last.request_id] (ids original)
;;

let test_unsent_priority_stays_with_the_item () =
  let queue, _ = push_exn Queue.empty ~keeper_name:"alpha" "older" in
  let queue, _ = push_exn queue ~keeper_name:"alpha" "priority" in
  let priority = List.nth (Queue.waiting queue) 1 in
  let request_id = priority.Queue.request.Chat.request_id in
  let queue = match Queue.mark_run_next queue ~request_id with
    | Ok queue -> queue | Error detail -> fail detail in
  check bool "priority cannot be skipped to join an older line" true
    (Queue.join_target queue ~keeper_name:"alpha" = None);
  let edited = {priority.request with Chat.message="edited priority"} in
  let queue = match Queue.replace_request queue ~request_id edited with
    | Ok queue -> queue | Error detail -> fail detail in
  let item = Option.get (Queue.find queue ~request_id) in
  check bool "edit retains explicit priority and queue position" true
    (item.intent = Queue.Run_next {automatic=false}
     && messages queue = ["older"; "edited priority"]);
  let promoted, remaining = match Queue.take queue ~request_id with
    | Some pair -> pair | None -> fail "priority item disappeared" in
  let restored = Queue.restore_unsent remaining promoted in
  check bool "preflight restoration retains the exact priority" true
    ((Option.get (Queue.find restored ~request_id)).intent = Queue.Run_next {automatic=false});
  let unaffected = Queue.clear_run_next_for_keeper restored ~keeper_name:"beta" in
  check bool "another Keeper's control does not clear it" true
    ((Option.get (Queue.find unaffected ~request_id)).intent = Queue.Run_next {automatic=false});
  let refused = {promoted with Queue.intent=Queue.Next_without_auto_priority} in
  let restored_after_stop = Queue.restore_unsent remaining refused in
  check (list string) "late refused priority returns behind an older input"
    ["older"; "edited priority"] (messages restored_after_stop);
  let superseded = Queue.clear_run_next_for_keeper restored ~keeper_name:"alpha" in
  check bool "a superseding control clears priority without dropping input" true
    ((Option.get (Queue.find superseded ~request_id)).intent = Queue.Next_without_auto_priority
     && messages superseded = ["older"; "edited priority"]);
  let after_control = Option.get (Queue.find superseded ~request_id) in
  check bool "auto-next does not revive a superseded priority" true
    ((Queue.prepare_for_admission ~automatic:true after_control).intent
     = Queue.Next_without_auto_priority);
  let older = List.nth (Queue.waiting superseded) 0 in
  check bool "an unpromoted ordinary item uses the policy at admission" true
    ((Queue.prepare_for_admission ~automatic:true older).intent = Queue.Run_next {automatic=true}
     && (Queue.prepare_for_admission ~automatic:false older).intent = Queue.Next);
  let chosen_again = match Queue.mark_run_next superseded ~request_id with
    | Ok queue -> queue | Error detail -> fail detail in
  check bool "a new explicit run-next can restore priority" true
    ((Option.get (Queue.find chosen_again ~request_id)).intent = Queue.Run_next {automatic=false});
  let _, cancelled = match Queue.take restored ~request_id with
    | Some pair -> pair | None -> fail "priority item disappeared before cancellation" in
  check bool "cancellation leaves no queued priority" true
    (Queue.find cancelled ~request_id = None)
;;

let test_a_steer_is_not_replaced_by_run_next_or_coalesced_past () =
  let queue, _ = push_exn Queue.empty ~keeper_name:"alpha" "earlier" in
  let earlier = List.hd (Queue.waiting queue) in
  let _, queue = match Queue.take queue ~request_id:earlier.request.request_id with
    | Some pair -> pair | None -> fail "earlier input disappeared" in
  let steer = request ~keeper_name:"alpha" "steer" in
  let queue = match Queue.push_steer queue ~submitted_at:2.
      ~causal_parent_request_id:"parent" steer with
    | Ok (queue, _) -> queue | Error detail -> fail detail in
  let queue = Queue.restore_unsent queue earlier in
  let queue = match Queue.mark_run_next queue ~request_id:steer.request_id with
    | Ok queue -> queue | Error detail -> fail detail in
  let kept = Option.get (Queue.find queue ~request_id:steer.request_id) in
  check bool "steer retains its causal parent" true
    (kept.intent = Queue.Steer_after_interrupt
     && kept.causal_parent_request_id = Some "parent");
  check bool "coalescing does not reach past the steer" true
    (Queue.join_target queue ~keeper_name:"alpha" = None);
  let controlled = Queue.clear_run_next_for_keeper queue ~keeper_name:"alpha" in
  let kept = Option.get (Queue.find controlled ~request_id:steer.request_id) in
  check bool "stop preserves steer origin but cancels its priority" true
    (kept.intent = Queue.Steer_without_priority
     && kept.causal_parent_request_id = Some "parent"
     && (Queue.prepare_for_admission ~automatic:true kept).intent = Queue.Steer_without_priority);
  check bool "a retained steer still prevents a duplicate" true
    (Result.is_error (Queue.push_steer controlled ~submitted_at:3.
      ~causal_parent_request_id:"other-parent" (request ~keeper_name:"alpha" "another")));
  let selected_again = match Queue.mark_run_next controlled ~request_id:steer.request_id with
    | Ok queue -> queue | Error detail -> fail detail in
  let kept = Option.get (Queue.find selected_again ~request_id:steer.request_id) in
  check bool "a new explicit priority preserves the steer parent" true
    (kept.intent = Queue.Steer_after_interrupt && kept.causal_parent_request_id = Some "parent")
;;

let test_superseded_steer_returns_to_submission_order () =
  let queue, _ = push_exn Queue.empty ~keeper_name:"alpha" "first" in
  let queue, _ = push_exn queue ~keeper_name:"beta" "other" in
  let queue, _ = push_exn queue ~keeper_name:"alpha" "second" in
  let steer = request ~keeper_name:"alpha" "later steer" in
  let priority = match Queue.push_steer queue ~submitted_at:3.
      ~causal_parent_request_id:"parent" steer with
    | Ok (queue, _) -> queue | Error detail -> fail detail in
  check (list string) "the steer initially owns the earlier alpha slot"
    ["later steer"; "first"; "other"; "second"] (messages priority);
  let controlled = Queue.clear_run_next_for_keeper priority ~keeper_name:"alpha" in
  check (list string) "stop restores alpha order and leaves beta's slot"
    ["first"; "second"; "other"; "later steer"] (messages controlled);
  let promoted, waiting = match Queue.take priority ~request_id:steer.request_id with
    | Some pair -> pair | None -> fail "steer preflight disappeared" in
  let refused = {promoted with Queue.intent=Queue.Steer_without_priority} in
  let recovered = Queue.restore_unsent waiting refused in
  check (list string) "late preflight recovery cannot restore the old priority"
    ["first"; "second"; "other"; "later steer"] (messages recovered);
  check (option string) "the original parent survives the reorder" (Some "parent")
    (Option.get (Queue.find recovered ~request_id:steer.request_id)).causal_parent_request_id
;;

(* Which waiting line a newly typed one joins. The reader types a thought,
   then its correction: both are meant for one turn, and neither has been sent
   -- dispatch takes a line out of the queue -- so joining them changes what
   one turn receives, not what a turn in flight sees. *)
(* One item per intent, built the way the product builds them, so a sixth
   intent cannot be added without deciding here whether it may be moved. *)
let test_only_a_waiting_steer_is_fixed_in_place () =
  let ok_or_fail = function Ok queue -> queue | Error detail -> fail detail in
  let id queue text =
    (List.find (fun (item : Queue.item) -> String.equal item.request.Chat.message text)
       (Queue.waiting queue)).request.Chat.request_id in
  let base () =
    let queue, _ = push_exn Queue.empty ~keeper_name:"alpha" "target" in
    let queue, _ = push_exn queue ~keeper_name:"alpha" "other" in
    queue in
  let editable_after ~name queue =
    let target = Option.get (Queue.find queue ~request_id:(id queue "target")) in
    check bool (name ^ ": predicate agrees with move") (Queue.local_order_editable target)
      (Result.is_ok (Queue.move_to_end queue ~keeper_name:"alpha" ~request_id:target.request.Chat.request_id));
    Queue.local_order_editable target in
  check bool "next" true (editable_after ~name:"next" (base ()));
  let queue = base () in
  let queue = ok_or_fail (Queue.mark_run_next queue ~request_id:(id queue "target")) in
  check bool "run next" true (editable_after ~name:"run next" queue);
  let cleared = Queue.clear_run_next_for_keeper queue ~keeper_name:"alpha" in
  check bool "next without auto priority" true (editable_after ~name:"cleared" cleared);
  let steer = request ~keeper_name:"alpha" "target" in
  let queue = match Queue.push_steer Queue.empty ~submitted_at:1.
      ~causal_parent_request_id:"parent" steer with
    | Ok (queue, _) -> queue | Error detail -> fail detail in
  let queue, _ = push_exn queue ~keeper_name:"alpha" "other" in
  check bool "steer after interrupt" false (editable_after ~name:"steer" queue);
  let queue = Queue.clear_run_next_for_keeper queue ~keeper_name:"alpha" in
  check bool "steer without priority" true (editable_after ~name:"released steer" queue)
;;

(* A line typed after a run-next item must not join an older line that the
   run-next item was moved behind: it would be sent ahead of that priority. *)
let test_a_line_does_not_join_ahead_of_run_next () =
  let queue, _ = push_exn Queue.empty ~keeper_name:"alpha" "first" in
  let queue, _ = push_exn queue ~keeper_name:"alpha" "second" in
  let id text =
    (List.find (fun (item : Queue.item) -> String.equal item.request.Chat.message text)
       (Queue.waiting queue)).request.Chat.request_id in
  let queue = match Queue.mark_run_next queue ~request_id:(id "first") with
    | Ok queue -> queue | Error detail -> fail detail in
  let queue = match Queue.move_to_end queue ~keeper_name:"alpha" ~request_id:(id "first") with
    | Ok queue -> queue | Error detail -> fail detail in
  check (list string) "the run-next line now waits last" [ "second"; "first" ] (messages queue);
  check bool "no line to join: the run-next line waits behind it" true
    (Queue.join_target queue ~keeper_name:"alpha" = None)
;;

let join_target_cases =
  [ test_case "nothing waiting -> no target" `Quick (fun () ->
        check bool "none" true
          (Queue.join_target Queue.empty ~keeper_name:"alpha" = None))
  ; test_case "joins the last waiting line, not the first" `Quick (fun () ->
        let queue, _ = push_exn Queue.empty ~keeper_name:"alpha" "first" in
        let queue, _ = push_exn queue ~keeper_name:"alpha" "second" in
        match Queue.join_target queue ~keeper_name:"alpha" with
        | Some item -> check string "last" "second" item.Queue.request.Chat.message
        | None -> fail "expected a join target")
  ; test_case "another keeper's line is not a target" `Quick (fun () ->
        let queue, _ = push_exn Queue.empty ~keeper_name:"beta" "beta line" in
        check bool "none" true
          (Queue.join_target queue ~keeper_name:"alpha" = None))
  ]

let () =
  run
    "tui_keeper_chat_queue"
    [ ( "queue"
      , [ test_case "lines wait in the order they were written" `Quick
            test_lines_wait_in_the_order_they_were_written
        ; test_case "recall replacement checks its original payload" `Quick
            test_recall_replacement_checks_the_original_payload
        ; test_case "staged source follows the pending item" `Quick
            test_staged_source_follows_the_pending_item
        ; test_case "a line keeps the keeper it was written to" `Quick
            test_a_line_keeps_the_keeper_it_was_written_to
        ; test_case "the cap refuses rather than forgetting" `Quick
            test_the_cap_refuses_rather_than_forgetting
        ; test_case "unavailable Keeper input survives reconnection" `Quick
            test_unavailable_keeper_input_survives_reconnection
        ; test_case "a busy keeper does not stall the lines behind it" `Quick
            test_a_busy_keeper_does_not_stall_the_lines_behind_it
        ; test_case "take removes the named line and keeps the order" `Quick
            test_take_removes_the_named_line_and_keeps_the_order
        ; test_case "holds agrees with take" `Quick test_holds_agrees_with_take
        ; test_case "nothing sendable takes nothing" `Quick
            test_nothing_sendable_takes_nothing
        ; test_case "all sendable is oldest first" `Quick
            test_all_sendable_is_oldest_first
        ; test_case "an empty queue takes nothing" `Quick
            test_an_empty_queue_takes_nothing
        ; test_case "submission clock and per-keeper count are preserved" `Quick
            test_submission_clock_and_per_keeper_count_are_preserved
        ; test_case "steer precedes next for its keeper" `Quick
            test_steer_precedes_next_for_its_keeper
        ; test_case "take newest is scoped to one Keeper" `Quick
            test_take_newest_for_keeper_does_not_touch_another_keeper
        ; test_case "reorder preserves identity, Keeper ownership, and steer" `Quick
            test_reorder_preserves_identity_other_keepers_and_steer
        ; test_case "unsent priority follows its item" `Quick
            test_unsent_priority_stays_with_the_item
        ; test_case "steer intent is preserved across priority and coalescing" `Quick
            test_a_steer_is_not_replaced_by_run_next_or_coalesced_past
        ; test_case "superseded steer returns to submission order" `Quick
            test_superseded_steer_returns_to_submission_order
        ; test_case "only a waiting steer is fixed in place" `Quick
            test_only_a_waiting_steer_is_fixed_in_place
        ; test_case "a line does not join ahead of run-next" `Quick
            test_a_line_does_not_join_ahead_of_run_next
        ] )
    ; ("join_target", join_target_cases)
    ]
;;

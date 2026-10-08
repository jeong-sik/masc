(** The queue is wired into the two places that make it work.

    The pure ordering and cap live in [Masc_tui_keeper_chat_queue] and are
    tested there. What cannot be tested there is that the executable actually
    uses it: a queue nothing pushes to is a refusal with extra steps, and a
    queue nothing drains is a message that never arrives. Both were the bug —
    Enter during a turn answered "Keeper message already in progress" and threw
    the text away. *)

open Alcotest

module Keeper_chat = Masc_tui_keeper_chat_projection
module Keeper_chat_transcript = Masc_tui_keeper_chat_transcript
module Live = Masc_tui_keeper_chat_live
module Log = Masc_tui_keeper_chat_log
module Tui_types = Masc_tui_types
module Tui_decode = Masc.Tui_decode
module Keeper_selection = Masc_tui_keeper_selection

let operation_key id : Tui_types.journal_key = "alpha", Log.Operation id
let journal_key_test = testable
    (fun ppf (keeper, source) -> Format.fprintf ppf "%s/%s:%s" keeper
      (match source with Log.Operation _ -> "operation" | Autonomous_turn _ -> "turn")
      (Log.source_key source)) (=)
let operation_targets rows = List.map (fun (id, at) -> operation_key id, at) rows

let position =
  testable
    (fun formatter position ->
      Format.pp_print_string formatter
        (Masc.Keeper_chat_event_log.replay_position_to_string position))
    ( = )
module Interrupt_signal = Masc_tui_interrupt_signal

;;

let entry_at ?(id = "") at : Tui_types.msg_entry =
  { Tui_types.me_keeper_name = "alpha"
  ; me_role = Tui_types.Message_keeper
  ; me_identity =
      Tui_types.Persisted_row
        (if id = "" then Printf.sprintf "msg-%.0f" at else id)
  ; me_turn_phase = Tui_types.Turn_output
  ; me_turn_sequence = None
  ; me_operation_seq = 0
  ; me_text = Printf.sprintf "row at %.0f" at
  ; me_image = Masc_tui_image_preview.No_image
  ; me_memory_summary = None
  ; me_journal = []
  ; me_memory_pass = Masc_tui_message_layout.No_pass
  ; me_gate = None
  ; me_submitted_at = None
  ; me_tool_block = None
  ; me_skill_block = []
  ; me_timestamp = ""
  ; me_request_id = ""
  ; me_at = at
  }

(* The trailing unit is what lets the three optional parameters be erased:
   without a positional parameter after them, OCaml cannot tell an omitted
   [?turn_phase] from a partial application. *)
let chat_entry ?turn_phase ?turn_sequence ?(operation_seq = 0) ?memory_summary
    ~request_id ~role ~text ~at () : Tui_types.msg_entry =
  { Tui_types.me_keeper_name = "alpha"
  ; me_role = role
  ; me_identity =
      Tui_types.Persisted_legacy_row { request_id; operation_seq }
  ; me_turn_phase =
      Option.value ~default:(Tui_types.chat_turn_phase_of_role role) turn_phase
  ; me_turn_sequence = turn_sequence
  ; me_operation_seq = operation_seq
  ; me_text = text
  ; me_image = Masc_tui_image_preview.No_image
  ; me_memory_summary = memory_summary
  ; me_journal = []
  ; me_memory_pass = Masc_tui_message_layout.No_pass
  ; me_gate = None
  ; me_submitted_at = None
  ; me_tool_block = None
  ; me_skill_block = []
  ; me_timestamp = Printf.sprintf "%.0f" at
  ; me_request_id = request_id
  ; me_at = at
  }

let ats entries =
  List.map (fun (e : Tui_types.msg_entry) -> e.Tui_types.me_at) entries

(* The refresh brings the newest window. Anything the operator paged back to is
   older than that window and has to survive the tick. *)
let test_a_refresh_keeps_what_was_paged_back_to () =
  let paged = [ entry_at 100.; entry_at 200. ] in
  let fresh = [ entry_at 300.; entry_at 400. ] in
  check
    (list (float 0.001))
    "older rows kept, fresh window appended"
    [ 100.; 200.; 300.; 400. ]
    (ats (Tui_types.merge_paged_history ~paged ~fresh))
;;

(* Rows the fresh window already carries come back in it, so keeping the paged
   copy too would show them twice. Same row, same id: the window's copy
   replaces the held one. *)
let test_a_refresh_does_not_double_the_overlap () =
  let paged =
    [ entry_at 100.; entry_at ~id:"msg-300" 300.; entry_at ~id:"msg-400" 400. ]
  in
  let fresh =
    [ entry_at ~id:"msg-300" 300.; entry_at ~id:"msg-400" 400.; entry_at 500. ]
  in
  check
    (list (float 0.001))
    "only rows older than the window survive"
    [ 100.; 300.; 400.; 500. ]
    (ats (Tui_types.merge_paged_history ~paged ~fresh))
;;

(* The tail window is bounded, and a keeper flooding approval rows pushes
   conversation rows out of it between two refreshes. The old rule dropped
   every held row at or after the window's oldest -- on the assumption the
   window still carried it -- so the middle of the conversation vanished on
   the tick that pushed it out (#32660). A row the window does not carry
   stays on screen. *)
let test_a_row_the_window_evicted_stays_visible () =
  let paged = [ entry_at 300.; entry_at 400. ] in
  let fresh = [ entry_at 500.; entry_at 600. ] in
  check
    (list (float 0.001))
    "evicted rows kept, fresh window appended"
    [ 300.; 400.; 500.; 600. ]
    (ats (Tui_types.merge_paged_history ~paged ~fresh))
;;

(* A window that came back empty says nothing about what is behind it, so it
   is not a reason to drop what is held. *)
let test_an_empty_refresh_keeps_the_transcript () =
  let paged = [ entry_at 100.; entry_at 200. ] in
  check
    (list (float 0.001))
    "kept"
    [ 100.; 200. ]
    (ats (Tui_types.merge_paged_history ~paged ~fresh:[]))
;;

let test_oldest_at_reports_the_cursor () =
  check
    (option (float 0.001))
    "oldest of the held rows"
    (Some 100.)
    (Tui_types.oldest_at [ entry_at 300.; entry_at 100.; entry_at 200. ]);
  check
    (option (float 0.001))
    "nothing to page back from"
    None
    (Tui_types.oldest_at [])
;;

let test_visible_clock_stays_monotonic_inside_one_causal_turn () =
  let user = Tui_types.Message_user (Tui_types.Sent_by_operator { surface = None }) in
  let loaded =
    [ chat_entry ~operation_seq:0 ~request_id:"turn-d" ~role:user ~text:"D"
        ~at:100. ()
    ; chat_entry ~operation_seq:2 ~request_id:"turn-d"
        ~role:Tui_types.Message_tool ~text:"Execute" ~at:300. ()
    ; chat_entry ~turn_phase:Tui_types.Turn_output ~operation_seq:3
        ~request_id:"turn-d" ~role:Tui_types.Message_status ~text:"D answer"
        ~at:50. ()
    ]
  in
  let session =
    [ chat_entry ~operation_seq:1 ~request_id:"turn-d"
        ~role:Tui_types.Message_status ~text:"approved" ~at:200. ()
    ; chat_entry ~request_id:"turn-next" ~role:user ~text:"queued correction"
        ~at:150. ()
    ; chat_entry ~request_id:"turn-active" ~role:user ~text:"active input"
        ~at:120. ()
    ]
  in
  let timeline =
    Tui_types.chat_timeline ~loaded ~session
      ~queued_request_ids:[ "turn-next" ]
  in
  check (list string) "causal phases project onto one monotonic axis"
    [ "D"; "active input"; "approved"; "Execute"; "D answer" ]
    (Tui_types.chat_timeline_rows timeline
     |> List.map (fun row -> row.Tui_types.me_text));
  check bool "queued input is a separate NEXT lane" true
    (not
       (List.exists
          (fun row -> String.equal row.Tui_types.me_request_id "turn-next")
          (Tui_types.chat_timeline_rows timeline)))
;;

let test_same_request_exact_clock_normalizes_the_turn_sequence () =
  let user = Tui_types.Message_user (Tui_types.Sent_by_operator { surface = None }) in
  let rows =
    Tui_types.chat_timeline
      ~loaded:
        [ chat_entry ~turn_sequence:54 ~turn_phase:Tui_types.Turn_output
            ~operation_seq:1 ~request_id:"direct" ~role:Tui_types.Message_keeper
            ~text:"persisted output" ~at:100. ()
        ]
      ~session:
        [ chat_entry ~operation_seq:0 ~request_id:"direct" ~role:user
            ~text:"session input" ~at:100. ()
        ]
      ~queued_request_ids:[]
    |> Tui_types.chat_timeline_rows
  in
  check (list string) "request phase wins over mixed per-row sequence presence"
    [ "session input"; "persisted output" ]
    (List.map (fun row -> row.Tui_types.me_text) rows)
;;

let test_distinct_requests_keep_producer_order_on_exact_clock_tie () =
  let rows =
    Tui_types.chat_timeline
      ~loaded:
        [ chat_entry ~request_id:"z-request" ~role:Tui_types.Message_keeper
            ~text:"producer first" ~at:100. ()
        ; chat_entry ~request_id:"a-request" ~role:Tui_types.Message_keeper
            ~text:"producer second" ~at:100. ()
        ]
      ~session:[]
      ~queued_request_ids:[]
    |> Tui_types.chat_timeline_rows
  in
  check (list string) "request ids never invent exact-clock order"
    [ "producer first"; "producer second" ]
    (List.map (fun row -> row.Tui_types.me_text) rows)
;;

(* #32434 registered this case without a body (#32453). Two distinct
   requests on the same clock instant both carry an absolute turn sequence;
   the sequence, not producer order, decides the tie. *)
let test_absolute_turn_sequence_breaks_equal_clock_ties () =
  let rows =
    Tui_types.chat_timeline
      ~loaded:
        [ chat_entry ~turn_sequence:20 ~request_id:"later-turn"
            ~role:Tui_types.Message_keeper ~text:"turn twenty" ~at:100. ()
        ; chat_entry ~turn_sequence:10 ~request_id:"earlier-turn"
            ~role:Tui_types.Message_keeper ~text:"turn ten" ~at:100. ()
        ]
      ~session:[]
      ~queued_request_ids:[]
    |> Tui_types.chat_timeline_rows
  in
  check (list string) "absolute turn sequence orders an exact-clock tie"
    [ "turn ten"; "turn twenty" ]
    (List.map (fun row -> row.Tui_types.me_text) rows)
;;

let test_journal_interleaves_request_and_reply_by_displayed_time () =
  let user = Tui_types.Message_user (Tui_types.Sent_by_operator { surface = None }) in
  let rows =
    Tui_types.chat_timeline
      ~loaded:
        [ chat_entry ~operation_seq:0 ~request_id:"direct" ~role:user
            ~text:"23:34:51 request" ~at:100. ()
        ; chat_entry ~turn_phase:Tui_types.Turn_output ~operation_seq:1
            ~request_id:"direct" ~role:Tui_types.Message_keeper
            ~text:"23:35:06 reply" ~at:200. ()
        ; chat_entry ~request_id:"" ~role:Tui_types.Message_memory
            ~text:"23:34:55 journal" ~at:150. ()
        ]
      ~session:[] ~queued_request_ids:[]
    |> Tui_types.chat_timeline_rows
  in
  check (list string) "parallel lane never makes the visible clock go backwards"
    [ "23:34:51 request"; "23:34:55 journal"; "23:35:06 reply" ]
    (List.map (fun row -> row.Tui_types.me_text) rows)
;;

let test_scroll_anchor_follows_structure_not_clock () =
  let rows =
    [ chat_entry ~request_id:"one" ~role:Tui_types.Message_keeper ~text:"one"
        ~at:300. ()
    ; chat_entry ~request_id:"two" ~role:Tui_types.Message_keeper ~text:"two"
        ~at:100. ()
    ; chat_entry ~request_id:"three" ~role:Tui_types.Message_keeper
        ~text:"three" ~at:200. ()
    ]
  in
  match Tui_types.msg_entries_after_anchor rows (Tui_types.msg_anchor (List.hd rows)) with
  | None -> fail "the anchor is present"
  | Some after ->
      check (list string) "list suffix wins over timestamps" [ "two"; "three" ]
        (List.map (fun row -> row.Tui_types.me_text) after)
;;

let test_scroll_anchor_distinguishes_duplicate_text_in_one_turn () =
  let first =
    chat_entry ~operation_seq:1 ~request_id:"same-turn"
      ~role:Tui_types.Message_status ~text:"working" ~at:10. ()
  in
  let second =
    chat_entry ~operation_seq:2 ~request_id:"same-turn"
      ~role:Tui_types.Message_status ~text:"working" ~at:10. ()
  in
  match Tui_types.msg_entries_after_anchor [ first; second ]
          (Tui_types.msg_anchor first) with
  | Some [ found ] ->
      check int "second duplicate has its own structural identity" 2
        found.Tui_types.me_operation_seq
  | Some _ | None -> fail "duplicate text collapsed the structural scroll anchor"
;;

let test_scroll_anchor_survives_session_user_persistence () =
  let user = Tui_types.Message_user (Tui_types.Sent_by_operator { surface = None }) in
  let session =
    chat_entry ~operation_seq:0 ~request_id:"same-turn" ~role:user
      ~text:"submitted locally" ~at:10. ()
  in
  let session =
    { session with
      Tui_types.me_identity =
        Tui_types.Session_row
          { request_id = "same-turn"
          ; turn_phase = Tui_types.Turn_input
          ; operation_seq = 0
          }
    }
  in
  let persisted =
    { session with
      Tui_types.me_identity = Tui_types.Persisted_row "server-user-row"
    ; me_text = "submitted locally\n"
    }
  in
  let answer =
    chat_entry ~operation_seq:1 ~request_id:"same-turn"
      ~role:Tui_types.Message_keeper ~text:"answer" ~at:11. ()
  in
  match
    Tui_types.msg_entries_after_anchor [ persisted; answer ]
      (Tui_types.msg_anchor session)
  with
  | Some [ found ] -> check string "answer remains below pin" "answer" found.me_text
  | Some _ | None -> fail "session USER pin was lost when history persisted it"
;;

let test_running_turn_does_not_escape_the_displayed_time_axis () =
  let loaded =
    [ chat_entry ~turn_sequence:20 ~request_id:"settled-20"
        ~role:Tui_types.Message_keeper ~text:"settled at 200" ~at:200. () ]
  in
  let session =
    [ chat_entry ~turn_sequence:10 ~request_id:"running-10"
        ~role:(Tui_types.Message_user (Tui_types.Sent_by_operator { surface = None }))
        ~text:"running at 100" ~at:100. () ]
  in
  let rows =
    Tui_types.chat_timeline ~loaded ~session ~queued_request_ids:[]
    |> Tui_types.chat_timeline_rows
    |> List.map (fun row -> row.Tui_types.me_text)
  in
  check (list string) "the lower typed turn sequence remains first"
    [ "running at 100"; "settled at 200" ] rows
;;

let test_uncommitted_live_turn_inserts_on_the_visible_clock_axis () =
  let user = Tui_types.Message_user (Tui_types.Sent_by_operator { surface = None }) in
  let messages =
    [ chat_entry ~request_id:"skewed" ~role:user ~text:"input at 100" ~at:100.
        ()
    ; chat_entry ~request_id:"" ~role:Tui_types.Message_memory
        ~text:"journal at 200" ~at:200. ()
    ; chat_entry ~turn_phase:Tui_types.Turn_output ~operation_seq:1
        ~request_id:"skewed" ~role:Tui_types.Message_keeper
        ~text:"output at 300" ~at:300. ()
    ]
  in
  let positioned =
    List.combine messages (Tui_types.chat_projected_timeline_ats messages)
  in
  check int "live at 150 precedes the later committed output" 1
    (Tui_types.chat_live_insertion_index ~request_id:"live"
       ~timeline_at:(Some 150.) positioned);
  check int "an equal-clock live turn precedes the Journal lane" 1
    (Tui_types.chat_live_insertion_index ~request_id:"live"
       ~timeline_at:(Some 200.) positioned)
;;

let test_live_turn_uses_its_latest_committed_causal_frontier () =
  let user = Tui_types.Message_user (Tui_types.Sent_by_operator { surface = None }) in
  let messages =
    [ chat_entry ~request_id:"running" ~role:user ~text:"input" ~at:100. ()
    ; chat_entry ~request_id:"" ~role:Tui_types.Message_memory ~text:"journal"
        ~at:200. ()
    ; chat_entry ~turn_phase:Tui_types.Turn_progress ~operation_seq:1
        ~request_id:"running" ~role:Tui_types.Message_status
        ~text:"approval settled" ~at:300. ()
    ]
  in
  check (option (float 0.001)) "live bucket follows approval, not first input"
    (Some 300.)
    (Tui_types.chat_request_timeline_at ~request_id:"running" messages);
  check int "live trail follows the same-clock approval frontier" 3
    (Tui_types.chat_live_insertion_index ~request_id:"running"
       ~timeline_at:(Some 300.)
       (List.combine messages
          (Tui_types.chat_projected_timeline_ats messages)))
;;

let test_live_turn_follows_an_unknown_same_request_row () =
  let user = Tui_types.Message_user (Tui_types.Sent_by_operator { surface = None }) in
  let rows =
    Tui_types.chat_timeline
      ~loaded:
        [ chat_entry ~request_id:"other" ~role:Tui_types.Message_keeper
            ~text:"unrelated at 300" ~at:300. ()
        ; chat_entry ~request_id:"running" ~role:user
            ~text:"clockless running input" ~at:0. ()
        ]
      ~session:[] ~queued_request_ids:[]
    |> Tui_types.chat_timeline_rows
  in
  let positioned =
    List.combine rows (Tui_types.chat_projected_timeline_ats rows)
  in
  check (option (float 0.001))
    "live clock clamps to the known row before its clockless input"
    (Some 300.)
    (Tui_types.chat_live_timeline_at ~request_id:"running" ~started_at:100.
       ~request_messages:rows positioned);
  check int "live stays below its committed clockless input" 2
    (Tui_types.chat_live_insertion_index ~request_id:"running"
       ~timeline_at:(Some 300.) positioned)
;;

let test_hidden_phase_keeps_its_timeline_projection () =
  let user = Tui_types.Message_user (Tui_types.Sent_by_operator { surface = None }) in
  let rows =
    Tui_types.chat_timeline
      ~loaded:
        [ chat_entry ~operation_seq:0 ~request_id:"running" ~role:user
            ~text:"input" ~at:100. ()
        ; chat_entry ~turn_phase:Tui_types.Turn_progress ~operation_seq:1
            ~request_id:"running" ~role:Tui_types.Message_thinking
            ~text:"hidden reasoning" ~at:300. ()
        ; chat_entry ~turn_phase:Tui_types.Turn_output ~operation_seq:2
            ~request_id:"running" ~role:Tui_types.Message_keeper ~text:"output"
            ~at:200. ()
        ; chat_entry ~request_id:"" ~role:Tui_types.Message_memory
            ~text:"journal" ~at:250. ()
        ]
      ~session:[] ~queued_request_ids:[]
    |> Tui_types.chat_timeline_rows
  in
  let visible =
    List.combine rows (Tui_types.chat_projected_timeline_ats rows)
    |> List.filter (fun (row, _) ->
      row.Tui_types.me_role <> Tui_types.Message_thinking)
  in
  check (list string) "hidden phase leaves the visible row order intact"
    [ "input"; "journal"; "output" ]
    (List.map (fun (row, _) -> row.Tui_types.me_text) visible);
  check (list (option (float 0.001)))
    "hidden phase still clamps the later visible output clock"
    [ Some 100.; Some 250.; Some 300. ]
    (List.map snd visible);
  let visible_without_journal =
    List.filter (fun (row, _) -> row.Tui_types.me_role <> Tui_types.Message_memory)
      visible
  in
  check int "an unrelated live turn compares with the projected output clock" 1
    (Tui_types.chat_live_insertion_index ~request_id:"live"
       ~timeline_at:(Some 200.)
       visible_without_journal)
;;

let test_unknown_phase_clock_inherits_the_causal_frontier () =
  let user = Tui_types.Message_user (Tui_types.Sent_by_operator { surface = None }) in
  let rows =
    [ chat_entry ~operation_seq:0 ~request_id:"legacy" ~role:user ~text:"input"
        ~at:100. ()
    ; chat_entry ~turn_phase:Tui_types.Turn_progress ~operation_seq:1
        ~request_id:"legacy" ~role:Tui_types.Message_status
        ~text:"unknown clock" ~at:0. ()
    ; chat_entry ~turn_phase:Tui_types.Turn_output ~operation_seq:2
        ~request_id:"legacy" ~role:Tui_types.Message_keeper ~text:"output"
        ~at:200. ()
    ]
  in
  check (list (option (float 0.001)))
    "an unknown later phase keeps the latest known request clock"
    [ Some 100.; Some 100.; Some 200. ]
    (Tui_types.chat_projected_timeline_ats rows);
  let leading_unknown =
    [ chat_entry ~operation_seq:0 ~request_id:"leading" ~role:user
        ~text:"unknown input" ~at:0. ()
    ; chat_entry ~turn_phase:Tui_types.Turn_output ~operation_seq:1
        ~request_id:"leading" ~role:Tui_types.Message_keeper
        ~text:"known output" ~at:200. ()
    ]
  in
  check (list (option (float 0.001)))
    "a leading unknown borrows the first later request clock"
    [ Some 200.; Some 200. ]
    (Tui_types.chat_projected_timeline_ats leading_unknown);
  check (list string) "equal projected clocks retain input before output"
    [ "unknown input"; "known output" ]
    (Tui_types.chat_timeline ~loaded:leading_unknown ~session:[]
       ~queued_request_ids:[]
     |> Tui_types.chat_timeline_rows
     |> List.map (fun row -> row.Tui_types.me_text))
;;

let test_producer_append_keeps_a_structural_scroll_pin () =
  let pinned =
    chat_entry ~turn_sequence:20 ~operation_seq:1 ~request_id:"turn-20"
      ~role:Tui_types.Message_keeper ~text:"pinned output" ~at:200. ()
  in
  let earlier =
    chat_entry ~turn_sequence:10 ~request_id:"turn-10"
      ~role:Tui_types.Message_keeper ~text:"earlier turn" ~at:100. ()
  in
  let pin = Tui_types.msg_anchor pinned in
  let with_appended_journal =
    Tui_types.chat_timeline
      ~loaded:
        [ earlier
        ; pinned
        ; chat_entry ~request_id:"" ~role:Tui_types.Message_memory
            ~text:"appended journal row" ~at:50. ()
        ]
      ~session:[] ~queued_request_ids:[]
    |> Tui_types.chat_timeline_rows
  in
  check (option (list string)) "an older Journal append stays above the pin"
    (Some [])
    (Tui_types.msg_entries_after_anchor with_appended_journal pin
     |> Option.map (List.map (fun row -> row.Tui_types.me_text)));

  let moved_turn =
    chat_entry ~turn_sequence:20 ~operation_seq:0 ~request_id:"turn-20"
      ~role:(Tui_types.Message_user (Tui_types.Sent_by_operator { surface = None }))
      ~text:"late-arriving input" ~at:50. ()
  in
  let moved =
    Tui_types.chat_timeline ~loaded:[ earlier; pinned; moved_turn ] ~session:[]
      ~queued_request_ids:[]
    |> Tui_types.chat_timeline_rows
  in
  check (option (list string))
    "the identity pin survives when an earlier row joins its turn"
    (Some [])
    (Tui_types.msg_entries_after_anchor moved pin
     |> Option.map (List.map (fun row -> row.Tui_types.me_text)))
;;

let test_find_anchor_survives_a_producer_prepend () =
  let matched_older =
    chat_entry ~request_id:"older" ~role:Tui_types.Message_keeper
      ~text:"match older" ~at:100. ()
  in
  let matched_newer =
    chat_entry ~request_id:"newer" ~role:Tui_types.Message_keeper
      ~text:"match newer" ~at:200. ()
  in
  let anchor = Tui_types.msg_anchor matched_newer in
  let backfilled =
    chat_entry ~request_id:"" ~role:Tui_types.Message_memory
      ~text:"backfilled" ~at:50. ()
  in
  let rows =
    Tui_types.chat_timeline
      ~loaded:[ backfilled; matched_older; matched_newer ] ~session:[]
      ~queued_request_ids:[]
    |> Tui_types.chat_timeline_rows
  in
  let ceiling = Tui_types.msg_index_of_anchor rows anchor in
  check (option int) "newer match resolves after a producer prepend"
    (Some 2) ceiling;
  let older_matches =
    match ceiling with
    | None -> []
    | Some ceiling ->
        List.filteri
          (fun index row ->
             index < ceiling
             && String.starts_with ~prefix:"match " row.Tui_types.me_text)
          rows
  in
  check (list string) "repeated find still sees the older match"
    [ "match older" ]
    (List.map (fun row -> row.Tui_types.me_text) older_matches)
;;

(* A late answer to an earlier interrupt must not be read as this one's
   outcome, so the decode rejects a response whose echoed request_id is not
   the one asked about.

   The decode now lives in masc_tui_interrupt_signal, a library, because
   masc_tui_http is a module of the masc_tui executable and no test can link
   it. #32330 removed this check for exactly that reason. *)
let test_interrupt_receipt_is_bound_to_the_exact_request () =
  let response request_id =
    `Assoc
      [ "signalled", `Bool true
      ; "request_id", `String request_id
      ]
  in
  (match
     Interrupt_signal.decode_interrupt_signal ~expected_request_id:"parent-a"
       (response "parent-a")
   with
   | Ok (Interrupt_signal.Signalled _) -> ()
   | Ok Interrupt_signal.Pending_admission_paused | Ok (Interrupt_signal.Not_signalled _) | Error _ ->
     Alcotest.fail "the keeper's own receipt was not accepted");
  match
    Interrupt_signal.decode_interrupt_signal ~expected_request_id:"parent-a"
      (response "parent-b")
  with
  | Ok _ -> Alcotest.fail "another request's receipt was read as this one's"
  | Error detail ->
    Alcotest.(check bool)
      "the mismatch is named"
      true
      (Astring.String.is_infix ~affix:"request_id mismatch" detail)
;;
let test_observed_interrupt_response_identity () =
  let decode = Interrupt_signal.decode_observed_interrupt_signal ~expected_token:"observed" in
  let response token = `Assoc ["interrupt_token", `String token; "signalled", `Bool true] in
  (match decode (response "observed") with Ok (Interrupt_signal.Signalled _) -> ()
   | _ -> Alcotest.fail "exact observed receipt rejected");
  List.iter (fun json -> match decode json with
    | Error _ -> () | Ok _ -> Alcotest.fail "unbound observed receipt accepted")
    [response "successor"; `Assoc ["signalled", `Bool true]; `Null]
;;

let test_pending_admission_pause_is_not_a_cancellation_claim () =
  let receipt = `Assoc ["request_id", `String "pending"; "signalled", `Bool false;
    "paused", `Bool true; "reason", `String "paused_pending_admission"] in
  (match Interrupt_signal.decode_interrupt_signal ~expected_request_id:"pending" receipt with
   | Ok Interrupt_signal.Pending_admission_paused -> ()
   | _ -> fail "exact pending pause receipt rejected");
  let missing_pause = `Assoc ["request_id", `String "pending"; "signalled", `Bool false;
    "reason", `String "paused_pending_admission"] in
  (match Interrupt_signal.decode_interrupt_signal ~expected_request_id:"pending" missing_pause with
   | Error _ -> () | Ok _ -> fail "unconfirmed pause accepted");
  let observed = `Assoc ["interrupt_token", `String "observed"; "signalled", `Bool false;
    "paused", `Bool true; "reason", `String "paused_pending_admission"] in
  (match Interrupt_signal.decode_observed_interrupt_signal ~expected_token:"observed" observed with
   | Error _ -> () | Ok _ -> fail "pending receipt accepted for an observed running turn")
;;

let test_stop_ack_releases_only_input_after_that_stop () =
  let state = Tui_types.create_state ~workspace:"test" ~port:8935 ~refresh_interval:2.0 () in
  state.keeper_chat_control_tokens <- ["alpha", "before"; "beta", "other"];
  let stop = Tui_types.begin_keeper_chat_control state "alpha" in
  state.keeper_interactive_waiting <- ["alpha", "after-stop", Tui_types.Awaiting_control {generation=stop;target=None}];
  check bool "old snapshot is no longer current" true
    (Tui_types.keeper_chat_control_generation state "alpha" <> 0);
  check bool "stop acknowledgement settles pending control" true
    (Tui_types.finish_keeper_chat_control state "alpha" ~generation:stop);
  let acknowledged = Tui_types.keeper_chat_control_generation state "alpha" in
  check bool "poll started before acknowledgement is stale" true (acknowledged <> stop);
  check bool "later input follows acknowledged control epoch" true
    (state.keeper_interactive_waiting = ["alpha", "after-stop", Tui_types.Awaiting_control {generation=acknowledged;target=None}]);
  ignore (Tui_types.begin_keeper_chat_control state "alpha");
  check bool "a newer stop retains the input but revokes automatic resumption" true
    (state.keeper_interactive_waiting = ["alpha", "after-stop", Tui_types.Retained_after_stop]);
  let newer_stop = Tui_types.keeper_chat_control_generation state "alpha" in
  check bool "new stop acknowledgement finishes" true
    (Tui_types.finish_keeper_chat_control state "alpha" ~generation:newer_stop);
  check bool "acknowledgement cannot release revoked input" true
    (state.keeper_interactive_waiting = ["alpha", "after-stop", Tui_types.Retained_after_stop]);
  check bool "older acknowledgement cannot finish newer stop" false
    (Tui_types.finish_keeper_chat_control state "alpha" ~generation:stop);
  check (option string) "unrelated keeper token remains usable" (Some "other")
    (List.assoc_opt "beta" state.keeper_chat_control_tokens);
  state.keeper_interactive_waiting <- state.keeper_interactive_waiting @
    ["beta", "other-stopped", Tui_types.Retained_after_stop;
     "alpha", "fresh-input", Tui_types.Awaiting_control {generation=acknowledged;target=None}];
  Tui_types.release_retained_keeper_input state "alpha";
  check bool "explicit resume releases only stopped input for its keeper" true
    (state.keeper_interactive_waiting =
      ["beta", "other-stopped", Tui_types.Retained_after_stop;
       "alpha", "fresh-input", Tui_types.Awaiting_control {generation=acknowledged;target=None}])
;;

let test_late_interrupt_outcome_cannot_mark_newer_control () =
  let state = Tui_types.create_state ~workspace:"test" ~port:8935 ~refresh_interval:2.0 () in
  let stop = Tui_types.begin_keeper_chat_control state "alpha" in
  check bool "outcome without a token callback is current" true
    (Tui_types.keeper_chat_control_result_current state "alpha" ~generation:stop);
  ignore (Tui_types.finish_keeper_chat_control state "alpha" ~generation:stop);
  check bool "outcome after its own callback is current" true
    (Tui_types.keeper_chat_control_result_current state "alpha" ~generation:stop);
  ignore (Tui_types.advance_keeper_chat_control state "alpha");
  check bool "resumed Enter excludes previous stop outcome" false
    (Tui_types.keeper_chat_control_result_current state "alpha" ~generation:stop);
  let first = Tui_types.begin_keeper_chat_control state "alpha" in
  let second = Tui_types.begin_keeper_chat_control state "alpha" in
  let pending_started = List.assoc "alpha" state.keeper_chat_control_pending in
  check bool "stale finish retains newer request clock" false
    (Tui_types.finish_keeper_chat_control state "alpha" ~generation:first);
  check int64 "pending time belongs to newer control" pending_started
    (List.assoc "alpha" state.keeper_chat_control_pending);
  check bool "second pending stop is not first receipt acknowledgement" false
    (Tui_types.keeper_chat_control_result_current state "alpha" ~generation:first);
  check bool "the newer request clock is the one a finish settles" true
    (Tui_types.finish_keeper_chat_control state "alpha" ~generation:second)
;;

let test_control_receipts_are_scoped_to_each_keeper () =
  let state = Tui_types.create_state ~workspace:"test" ~port:8935 ~refresh_interval:2.0 () in
  let alpha = Tui_types.begin_keeper_chat_control state "alpha" in
  let beta = Tui_types.begin_keeper_chat_control state "beta" in
  check bool "beta does not invalidate alpha receipt" true
    (Tui_types.finish_keeper_chat_control state "alpha" ~generation:alpha);
  check bool "alpha does not invalidate beta receipt" true
    (Tui_types.finish_keeper_chat_control state "beta" ~generation:beta)
;;

let test_new_control_discards_only_its_keeper_priority_intents () =
  let state = Tui_types.create_state ~workspace:"test" ~port:8935 ~refresh_interval:2.0 () in
  let alpha = Keeper_chat.create_request ~keeper_name:"alpha" ~message:"alpha" () in
  let beta = Keeper_chat.create_request ~keeper_name:"beta" ~message:"beta" () in
  state.keeper_run_next_pending <- [alpha; beta];
  state.keeper_run_next_ready <- [alpha; beta];
  state.keeper_run_next_inflight <- [alpha; beta];
  ignore (Tui_types.begin_keeper_chat_control state "alpha");
  check (list string) "new Esc drops only alpha admissions awaiting priority"
    [beta.request_id]
    (List.map (fun (request : Keeper_chat.request) -> request.request_id)
       state.keeper_run_next_pending);
  check (list string) "new Esc drops only alpha promotions not yet dispatched"
    [beta.request_id]
    (List.map (fun (request : Keeper_chat.request) -> request.request_id)
       state.keeper_run_next_ready);
  check (list string) "already dispatched controls retain exact callbacks"
    [alpha.request_id; beta.request_id]
    (List.map (fun (request : Keeper_chat.request) -> request.request_id)
       state.keeper_run_next_inflight)

;;

(* The pin is on the pane's own turn. A request in flight to another keeper
   is drawn as an "(also sending to X ...)" row, and while that row was on
   screen the switch was refused -- so the operator could read about a turn
   and had no key that would take them to it (#33852). *)
let test_a_request_to_another_keeper_does_not_pin_this_pane () =
  let state =
    Tui_types.create_state ~workspace:"test" ~port:8935 ~refresh_interval:2.0 ()
  in
  let entry keeper_name =
    let sent_request =
      Keeper_chat.create_request ~keeper_name ~message:"hello" ()
    in
    ({ Tui_types.sent_request
     ; submitted_at = 1.0
     ; sent_at = 1.0
     ; control_generation = 0
     ; phase = Tui_types.Turn_streaming
     ; log =
         Tui_types.turn_log_create ~keeper_name
           ~request_id:sent_request.request_id ~started_at:1.0
     }
      : Tui_types.inflight)
  in
  let has_target () =
    match Tui_types.next_keeper_message_target state with
    | Keeper_selection.No_alternative -> false
    | Keeper_selection.Switch_to _ -> true
  in
  let roster_row name : Tui_types.keeper =
    { k_origin = Masc.Tui_decode.Persisted_keeper
  ; k_name = name
  ; k_paused = false
  ; k_identity = Ok { k_trace_id = "trace-" ^ name; k_created_at = "2026-09-07T00:00:00Z"; k_updated_at = "2026-09-07T00:00:00Z" }
  ; k_activity = Some { k_current_task_id = None; k_total_turns = 0; k_total_tokens = 0; k_total_cost_usd = 0.0; k_last_turn_ts = ""; k_last_proactive_outcome = None }
  }
  in
  state.keepers <- [ roster_row "alpha"; roster_row "beta" ];
  state.workspace_identity <- Tui_types.Workspace_identity_match;
  state.msg_target_keeper_name <- Some "alpha";
  check bool "with nothing in flight the pane can switch" true (has_target ());
  state.msg_inflight <- [ entry "beta" ];
  check bool "another keeper's request does not pin this pane" true
    (has_target ());
  state.msg_inflight <- [ entry "alpha" ];
  check bool "this pane's own request pins it" false (has_target ())
;;

let test_live_transcripts_are_kept_per_keeper () =
  let state =
    Tui_types.create_state ~workspace:"test" ~port:8935 ~refresh_interval:2.0 ()
  in
  let entry keeper_name started_at =
    let sent_request =
      Keeper_chat.create_request ~keeper_name ~message:("hello " ^ keeper_name) ()
    in
    let log =
      Tui_types.turn_log_create
        ~keeper_name
        ~request_id:sent_request.request_id
        ~started_at
    in
    ({ Tui_types.sent_request = sent_request
     ; submitted_at = started_at
     ; sent_at = started_at
     ; control_generation = 0
     (* A request that has just been POSTed is streaming; reconciling is what
        it becomes after the stream settles. *)
     ; phase = Tui_types.Turn_streaming
     ; log
     }
      : Tui_types.inflight)
  in
  let alpha = entry "alpha" 1.0 in
  let beta = entry "beta" 2.0 in
  state.msg_inflight <- [ beta; alpha ];
  check bool "alpha keeps its own live log" true
    (match Tui_types.live_for_keeper state "alpha" with
     | Some live -> live == alpha.log
     | None -> false);
  check bool "beta keeps its own live log" true
    (match Tui_types.live_for_keeper state "beta" with
     | Some live -> live == beta.log
     | None -> false)
;;

(* The log and its transcript move together: one writer folds a delta into
   the transcript exactly when the log accepted it, so a seq the log already
   holds is folded once, and the transcript equals the fold of the log. *)
let test_a_turn_log_folds_each_accepted_delta_once () =
  let log =
    Tui_types.turn_log_create ~keeper_name:"alpha" ~request_id:"req-1"
      ~started_at:10.0
  in
  let add seq delta = Tui_types.turn_log_add ~now:11.0 log ~seq delta in
  add (Some 1) Live.Run_started;
  add (Some 2) (Live.Text "hel");
  add (Some 2) (Live.Text "hel");
  add (Some 3) (Live.Text "lo");
  add None (Live.Text "!");
  add None (Live.Text "!");
  check string "a replayed seq is folded once, an id-less frame every time"
    "hello!!"
    (Keeper_chat_transcript.text log.Tui_types.tl_transcript);
  check int "the log holds one entry per accepted delta" 5
    (List.length (Log.entries log.Tui_types.tl_log));
  check string "the transcript is the fold of the log"
    (Keeper_chat_transcript.text
       (Keeper_chat_transcript.of_log ~now:11.0 log.Tui_types.tl_log))
    (Keeper_chat_transcript.text log.Tui_types.tl_transcript)

;;

let inflight_with_log ~keeper_name ~started_at deltas : Tui_types.inflight =
  let sent_request = Keeper_chat.create_request ~keeper_name ~message:"hello" () in
  let log =
    Tui_types.turn_log_create ~keeper_name ~request_id:sent_request.request_id
      ~started_at
  in
  List.iteri
    (fun seq delta -> Tui_types.turn_log_add ~now:started_at log ~seq:(Some seq) delta)
    deltas;
  { Tui_types.sent_request
  ; submitted_at = started_at
  ; sent_at = started_at
     ; control_generation = 0
  ; phase = Tui_types.Turn_streaming
  ; log
  }
;;

let preflight_input ?(submission_seq = 0) () =
  let entry = inflight_with_log ~keeper_name:"alpha" ~started_at:1. [] in
  let request = {entry.sent_request with
    Keeper_chat.message = "unsent input";
    attachments = [{Keeper_chat.attachment_id="image-1"; name="draft.png";
      mime_type="image/png"; size=3; data="YWJj"}];
    references = [Keeper_chat.Ref_file_id "file-1"]} in
  let item : Masc_tui_keeper_chat_queue.item =
    {request; submitted_at=1.; submission_seq;
     intent=Masc_tui_keeper_chat_queue.Next; causal_parent_request_id=None} in
  {entry with sent_request=request; phase=Tui_types.Turn_preflight item}, item
;;

let test_withdrawal_restores_only_input_before_the_first_post () =
  let state = Tui_types.create_state ~workspace:"test" ~port:8935 ~refresh_interval:2. () in
  state.msg_target_keeper_name <- Some "alpha";
  let entry, _ = preflight_input () in
  state.msg_history <- [chat_entry ~request_id:entry.sent_request.request_id
    ~role:(Tui_types.Message_user (Tui_types.Sent_by_operator {surface=None}))
    ~text:"unsent input" ~at:1. ()];
  Tui_types.retain_preflight_inputs state [entry];
  check string "editable text restored" "unsent input" (Masc_tui_message_input.contents state.msg_input);
  check bool "attachment bytes retained" true
    (state.msg_attachments = entry.sent_request.attachments);
  check bool "references retained" true (state.msg_references = entry.sent_request.references);
  check int "unsent local YOU row removed" 0 (List.length state.msg_history);
  check bool "restored composer is not queued" true
    (Masc_tui_keeper_chat_queue.is_empty state.msg_queued);
  List.iter (fun phase ->
    Masc_tui_message_input.clear state.msg_input;
    state.msg_attachments <- []; state.msg_references <- [];
    Tui_types.retain_preflight_inputs state [{entry with phase}];
    check string "possibly sent input is never restored" "" (Masc_tui_message_input.contents state.msg_input);
    check bool "possibly sent input is never queued" true
      (Masc_tui_keeper_chat_queue.is_empty state.msg_queued))
    [Tui_types.Turn_streaming; Tui_types.Turn_reconciling]
;;

let test_preflight_recovery_keeps_newer_input_and_a_full_queue () =
  let module Q = Masc_tui_keeper_chat_queue in
  let state = Tui_types.create_state ~workspace:"test" ~port:8935 ~refresh_interval:2. () in
  state.msg_target_keeper_name <- Some "alpha";
  Masc_tui_message_input.insert state.msg_input "newer composer";
  state.msg_references <- [Keeper_chat.Ref_url "https://example.invalid/new.png"];
  let entry, item = preflight_input () in
  let staged = Q.restore_unsent Q.empty item in
  state.msg_queued <- (match Q.take staged ~request_id:item.request.request_id with
    | Some (_, rest) -> rest | None -> fail "preflight did not own its staged request");
  for i = 1 to Q.cap do
    let request = Keeper_chat.create_request ~keeper_name:"alpha"
      ~message:(Printf.sprintf "newer-%d" i) () in
    match Q.push state.msg_queued ~submitted_at:2. request with
    | Ok (queue, _) -> state.msg_queued <- queue
    | Error detail -> fail detail
  done;
  let newer = Q.waiting state.msg_queued in
  state.msg_history <- [chat_entry ~request_id:item.request.request_id
    ~role:(Tui_types.Message_user (Tui_types.Sent_by_operator {surface=None}))
    ~text:item.request.message ~at:1. ()];
  Tui_types.retain_preflight_inputs state [entry];
  check bool "retained queued input remains in recall history" true
    (List.exists (fun (row : Tui_types.msg_entry) -> row.me_request_id = item.request.request_id)
       state.msg_history);
  check string "newer composer untouched" "newer composer" (Masc_tui_message_input.contents state.msg_input);
  check bool "newer reference untouched" true
    (state.msg_references = [Keeper_chat.Ref_url "https://example.invalid/new.png"]);
  check int "admission cap cannot discard prior accepted input" (Q.cap + 1) (Q.length state.msg_queued);
  (match Q.waiting state.msg_queued with
   | restored :: rest ->
       check bool "original payload and order retained" true
         (restored.request = item.request && rest = newer);
       check bool "restored ordinal precedes newer input" true
         (List.for_all (fun (next : Q.item) -> restored.submission_seq < next.submission_seq) rest)
   | [] -> fail "previous input disappeared");
  check bool "restored input requires explicit resume" true
    (List.mem ("alpha", item.request.request_id, Tui_types.Retained_before_dispatch)
       state.keeper_interactive_waiting);
  (match Q.take_newest_for_keeper state.msg_queued ~keeper_name:"alpha" with
   | Some (newest, _) -> check string "recall still chooses newest input"
       (Printf.sprintf "newer-%d" Q.cap) newest.request.message
   | None -> fail "newer input disappeared")
;;

let test_preflight_recovery_preserves_order_and_steer_intent () =
  let module Q = Masc_tui_keeper_chat_queue in
  let state = Tui_types.create_state ~workspace:"test" ~port:8935 ~refresh_interval:2. () in
  state.msg_target_keeper_name <- Some "alpha";
  let older, older_item = preflight_input () in
  let newer, newer_item = preflight_input ~submission_seq:1 () in
  let steer_item = {newer_item with Q.intent=Q.Steer_after_interrupt;
    causal_parent_request_id=Some older_item.request.request_id; submission_seq=1} in
  let steer = {newer with Tui_types.phase=Tui_types.Turn_preflight steer_item} in
  Tui_types.retain_preflight_inputs state [steer];
  check string "steer is not converted to a plain composer message" "" (Masc_tui_message_input.contents state.msg_input);
  (match Q.waiting state.msg_queued with
   | [restored] -> check bool "steer intent and causal parent retained" true
       (restored.intent = Q.Steer_after_interrupt
        && restored.causal_parent_request_id = Some older_item.request.request_id)
   | _ -> fail "expected retained steer");
  state.msg_queued <- Q.empty;
  state.keeper_interactive_waiting <- [];
  Masc_tui_message_input.insert state.msg_input "newer draft";
  (* Inflight owners are stored newest first; restore them in that order so
     each earlier item precedes the items restored before it. *)
  Tui_types.retain_preflight_inputs state [newer; older];
  (match Q.waiting state.msg_queued with
   | [first; second] ->
       check string "oldest input remains first" older_item.request.request_id first.request.request_id;
       check string "newer input remains second" newer_item.request.request_id second.request.request_id;
       check bool "recall order agrees with submission order" true
         (first.submission_seq < second.submission_seq)
   | _ -> fail "expected both preflight inputs")
;;

let test_preflight_local_resume_keeps_fifo_and_respects_server_stop () =
  let module Q = Masc_tui_keeper_chat_queue in
  let state = Tui_types.create_state ~workspace:"test" ~port:8935 ~refresh_interval:2. () in
  state.msg_target_keeper_name <- Some "alpha";
  Masc_tui_message_input.insert state.msg_input "newer draft";
  let entry, item = preflight_input () in
  Tui_types.retain_preflight_inputs state [entry];
  let later = Keeper_chat.create_request ~keeper_name:"alpha" ~message:"later Enter" () in
  (match Q.push state.msg_queued ~submitted_at:2. later with
   | Ok (queue, _) -> state.msg_queued <- queue
   | Error detail -> fail detail);
  state.keeper_interactive_waiting <- ("alpha", later.request_id,
    Tui_types.Awaiting_control {generation=0; target=None}) :: state.keeper_interactive_waiting;
  check bool "later Enter cannot bypass retained first input" true
    (Option.is_none (Tui_types.next_authorized_keeper_input state "alpha"));
  check bool "an already-paused owner still needs a server resume" false
    (Tui_types.resume_preflight_keeper_input ~owner_paused:true state "alpha");
  check bool "paused owner refusal preserves the queued input hold" true
    (Option.is_none (Tui_types.next_authorized_keeper_input state "alpha"));
  check bool "operator can resume never-posted input locally" true
    (Tui_types.resume_preflight_keeper_input ~owner_paused:false state "alpha");
  (match Tui_types.next_authorized_keeper_input state "alpha" with
   | Some (first, _) -> check string "resume dispatches original input first"
       item.request.request_id first.request.request_id
   | None -> fail "local resume still blocked");
  check bool "local resume does not manufacture a server control token" true
    (state.keeper_chat_control_tokens = [] && state.keeper_chat_control_pending = []);
  state.keeper_interactive_waiting <- ["alpha", item.request.request_id,
    Tui_types.Retained_before_dispatch];
  ignore (Tui_types.begin_keeper_chat_control state "alpha" : int);
  check bool "a real stop still requires its server resume receipt" false
    (Tui_types.resume_preflight_keeper_input ~owner_paused:false state "alpha");
  check bool "server-stopped input remains held" true
    (Option.is_none (Tui_types.next_authorized_keeper_input state "alpha"))
;;

let test_workspace_suspension_preserves_real_stop_ownership () =
  let state = Tui_types.create_state ~workspace:"test" ~port:8935 ~refresh_interval:2. () in
  let entry, _ = preflight_input () in
  Tui_types.retain_preflight_inputs state [entry];
  let local = Tui_types.suspend_keeper_input state in
  Tui_types.withdraw_keeper_chat_requests state;
  Tui_types.restore_suspended_keeper_input state local;
  check bool "workspace return permits explicit local preflight resume" true
    (Tui_types.resume_preflight_keeper_input ~owner_paused:false state "alpha");
  ignore (Tui_types.begin_keeper_chat_control state "alpha" : int);
  let stopped = Tui_types.suspend_keeper_input state in
  Tui_types.withdraw_keeper_chat_requests state;
  Tui_types.restore_suspended_keeper_input state stopped;
  check bool "workspace return never converts a real stop to local resume" false
    (Tui_types.resume_preflight_keeper_input ~owner_paused:false state "alpha");
  check bool "real stopped input remains undispatchable" true
    (Option.is_none (Tui_types.next_authorized_keeper_input state "alpha"))
;;

let test_unmarked_input_cannot_escape_composer_or_recall_ownership () =
  let module Q = Masc_tui_keeper_chat_queue in
  let state = Tui_types.create_state ~workspace:"test" ~port:8935 ~refresh_interval:2. () in
  let _, item = preflight_input () in
  state.msg_queued <- Q.restore_unsent Q.empty item;
  state.msg_target_keeper_name <- Some "alpha";
  state.msg_recall_replaces <- Some item;
  check bool "background turn refresh cannot dispatch the recalled old body" true
    (Option.is_none (Tui_types.next_authorized_keeper_input state "alpha"));
  state.msg_recall_replaces <- None;
  state.view <- Tui_types.Keepers Tui_types.Keeper_message;
  state.composer_focused <- true;
  state.coalesce_queued_input <- true;
  Masc_tui_message_input.insert state.msg_input "still composing";
  check bool "unmarked fallback respects coalescing composer ownership" true
    (Option.is_none (Tui_types.next_authorized_keeper_input state "alpha"));
  state.keeper_interactive_waiting <- ["alpha", item.request.request_id,
    Tui_types.Awaiting_control {generation=0; target=None}];
  check bool "explicit Enter authorization still dispatches its accepted input" true
    (Option.is_some (Tui_types.next_authorized_keeper_input state "alpha"))
;;

let test_new_enter_can_bypass_an_explicitly_stopped_input () =
  let module Q = Masc_tui_keeper_chat_queue in
  let state = Tui_types.create_state ~workspace:"test" ~port:8935 ~refresh_interval:2. () in
  let _, item = preflight_input () in
  state.msg_queued <- Q.restore_unsent Q.empty item;
  let later = Keeper_chat.create_request ~keeper_name:"alpha" ~message:"explicit followup" () in
  (match Q.push state.msg_queued ~submitted_at:2. later with
   | Ok (queue, _) -> state.msg_queued <- queue
   | Error detail -> fail detail);
  state.keeper_interactive_waiting <-
    ["alpha", item.request.request_id, Tui_types.Retained_after_stop;
     "alpha", later.request_id, Tui_types.Awaiting_control {generation=0; target=None}];
  (match Tui_types.next_authorized_keeper_input state "alpha" with
   | Some (ready, _) -> check string "new Enter retains its separate authorization"
       later.request_id ready.request.request_id
   | None -> fail "Esc-retained input blocked a new Enter");
  check bool "older stopped input remains retained" true
    (Option.is_some (Q.find state.msg_queued ~request_id:item.request.request_id))
;;

let test_empty_composer_cannot_reverse_already_queued_input () =
  let module Q = Masc_tui_keeper_chat_queue in
  let state = Tui_types.create_state ~workspace:"test" ~port:8935 ~refresh_interval:2. () in
  state.msg_target_keeper_name <- Some "alpha";
  let entry, item = preflight_input () in
  let later = Keeper_chat.create_request ~keeper_name:"alpha" ~message:"later queued Enter" () in
  (match Q.push state.msg_queued ~submitted_at:2. later with
   | Ok (queue, _) -> state.msg_queued <- queue
   | Error detail -> fail detail);
  Tui_types.retain_preflight_inputs state [entry];
  check string "older input cannot move behind newer queue through the composer"
    "" (Masc_tui_message_input.contents state.msg_input);
  check bool "original input is retained ahead of newer input" true
    (List.map (fun (held : Q.item) -> held.request.request_id) (Q.waiting state.msg_queued)
      = [item.request.request_id; later.request_id]);
  check bool "neither input can auto-dispatch after recovery" true
    (Option.is_none (Tui_types.next_authorized_keeper_input state "alpha"))
;;

let test_preflight_restoration_preserves_submission_chronology () =
  let module Q = Masc_tui_keeper_chat_queue in
  let push queue message =
    let request = Keeper_chat.create_request ~keeper_name:"alpha" ~message () in
    match Q.push queue ~submitted_at:1. request with
    | Ok (queue, _) -> queue, request
    | Error detail -> fail detail in
  let take queue request = match Q.take queue ~request_id:request.Keeper_chat.request_id with
    | Some pair -> pair | None -> fail "staged input disappeared" in
  let queue, _older = push Q.empty "older stopped input" in
  let queue, newer = push queue "newer preflight" in
  let preflight, held = take queue newer in
  let restored = Q.restore_unsent held preflight in
  (match Q.take_newest_for_keeper restored ~keeper_name:"alpha" with
   | Some (latest, _) -> check string "Ctrl-P/Ctrl-K select the newer refused input"
       newer.request_id latest.request.request_id
   | None -> fail "restored input disappeared");
  let queue, first = push Q.empty "first preflight" in
  let preflight, empty_after_take = take queue first in
  let queue, later = push empty_after_take "later input" in
  let restored = Q.restore_unsent queue preflight in
  (match Q.take_newest_for_keeper restored ~keeper_name:"alpha" with
   | Some (latest, _) -> check string "extracting the last item does not restart chronology"
       later.request_id latest.request.request_id
   | None -> fail "later input disappeared")
;;

let test_offscreen_preflight_recovery_retains_its_owner () =
  let module Q = Masc_tui_keeper_chat_queue in
  let state = Tui_types.create_state ~workspace:"test" ~port:8935 ~refresh_interval:2. () in
  state.msg_target_keeper_name <- Some "beta";
  let entry, item = preflight_input () in
  Tui_types.retain_preflight_inputs state [entry];
  check string "alpha cannot fill beta's composer" "" (Masc_tui_message_input.contents state.msg_input);
  (match Q.waiting state.msg_queued with
   | [restored] -> check bool "alpha payload remains alpha's" true (restored.request = item.request)
   | _ -> fail "expected exactly one retained alpha input")
;;

let test_new_input_preserves_running_output () =
  let cache = Masc_tui_ansi.terminal_size_cache in
  let previous = Masc_tui_ansi.get_terminal_size () in
  let set_size size = ignore (Masc_tui_render_schedule.Terminal_size_cache.refresh
      cache ~probe:(fun () -> Some size)) in
  Fun.protect ~finally:(fun () -> set_size previous) (fun () ->
    set_size (50, 120);
    let state = Tui_types.create_state ~tool_visibility:Tui_types.Tools_full
        ~workspace:"test" ~port:8935 ~refresh_interval:2. () in
    state.view <- Tui_types.Keepers Tui_types.Keeper_message;
    state.roster_pane_preference <- Masc_tui_roster_pane.Hidden;
    state.msg_target_keeper_name <- Some "alpha";
    let occurrence : Live.tool_occurrence =
      {stream_scope=0; block_index=0; provider_message_id=None; tool_call_id=Some "call-old"} in
    let old = inflight_with_log ~keeper_name:"alpha" ~started_at:1.
        [Live.Run_started; Live.Text "OLD_RUNNING_TEXT";
         Live.Tool_started {occurrence; tool_name="read_file"}] in
    state.msg_inflight <- [old];
    state.msg_live <- Some old.log;
    let screen () =
      let frame, _ = Masc_tui_render_chat.render_keeper_message state in
      String.concat "\n" (List.map Masc_tui_theme.strip_sgr frame.Masc_tui_frame_presenter.lines) in
    let assert_old () =
      let text = screen () in
      List.iter (fun needle -> check bool needle true
          (Astring.String.is_infix ~affix:needle text)) ["OLD_RUNNING_TEXT"; "read_file"] in
    assert_old ();
    let queued = inflight_with_log ~keeper_name:"alpha" ~started_at:2.
        [Live.Accepted {admission=Live.Queued; queue_length=1; interactive=None}] in
    state.msg_inflight <- [queued; old];
    state.msg_live <- Some queued.log;
    assert_old ();
    let execution_id = old.sent_request.request_id in
    Tui_types.turn_log_add ~now:3. queued.log ~seq:(Some 1) Live.Run_started;
    Tui_types.turn_log_add ~now:3. queued.log ~seq:(Some 2)
      (Live.Batch_bound {operation_id=queued.sent_request.request_id; execution_id});
    assert_old ();
    Tui_types.turn_log_add ~now:3.5 old.log ~seq:None
      (Live.Text "OLD_REPLY_STRETCH");
    Tui_types.turn_log_add ~now:4. old.log ~seq:(Some 3)
      (Live.Reply_details {reply="OLD_FINAL_REPLY";
        turn_outcome=Masc.Keeper_turn_outcome.Visible_reply; turn_ref="trace-1#1"});
    Tui_types.turn_log_add ~now:4. old.log ~seq:(Some 4) Live.Run_finished;
    Tui_types.settle_turn_log state old;
    state.msg_inflight <- [queued];
    (* Settlement replaces the terminal text stretch; progress before the
       tool round remains part of the turn's visible work. *)
    let settled_screen = screen () in
    check bool "settling replaces the terminal stretch with the reply" true
      (Astring.String.is_infix ~affix:"OLD_FINAL_REPLY" settled_screen
       && not (Astring.String.is_infix ~affix:"OLD_REPLY_STRETCH" settled_screen));
    check bool "settling preserves progress before the tool round" true
      (Astring.String.is_infix ~affix:"OLD_RUNNING_TEXT" settled_screen);
    check bool "complete older batch log stays authoritative" true
      (Astring.String.is_infix ~affix:"OLD_FINAL_REPLY" settled_screen);
    state.keeper_turns <-
      [{Tui_decode.ktr_chat_control_token=None; ktr_keeper_name="alpha";
        ktr_state=Keeper_turn_running {lane=Turn_lane_autonomous; started_at_unix=1.;
          interrupt_token="fixture"; turn_ref=None; preview=Some {ktp_status_text="working";
            ktp_updated_at_unix=3.; ktp_text_tail="AUTONOMOUS_TAIL"; ktp_last_tool=None}}}];
    check bool "autonomous output survives a working chat subscription" true
      (Astring.String.is_infix ~affix:"AUTONOMOUS_TAIL" (screen ())))
;;

let visible_reply reply =
  Live.Reply_details
    { reply; turn_outcome = Masc.Keeper_turn_outcome.Visible_reply; turn_ref = "trace-1#1" }
;;

let test_queue_summary_follows_admission_and_execution () =
  let state = Tui_types.create_state ~workspace:"test" ~port:8935 ~refresh_interval:2. () in
  state.msg_tool_visibility <- Tui_types.Tools_full;
  let accepted keeper at = inflight_with_log ~keeper_name:keeper ~started_at:at
      [Live.Accepted {admission=Live.Queued; queue_length=99; interactive=None}] in
  let first = accepted "alpha" 1. and second = accepted "alpha" 2. in
  let other = accepted "beta" 3. in
  let unsent = Keeper_chat.create_request ~keeper_name:"alpha" ~message:"local" () in
  let local = match Masc_tui_keeper_chat_queue.push state.msg_queued
      ~submitted_at:4. unsent with
    | Ok (queue, _) -> queue | Error detail -> fail detail in
  state.msg_queued <- local;
  state.msg_inflight <- [other; second; first];
  let waiting keeper = Tui_types.keeper_message_waiting_requests state ~keeper_name:keeper
      |> List.map (fun (request, _) -> request.Keeper_chat.request_id) in
  check (list string) "accepted input stays ahead of local input; snapshot count is not current count"
    [first.sent_request.request_id; second.sent_request.request_id; unsent.request_id]
    (waiting "alpha");
  check (list string) "other Keeper has its own queue"
    [other.sent_request.request_id] (waiting "beta");
  state.msg_target_keeper_name <- Some "alpha";
  let rows = Tui_types.keeper_message_activity_rows state in
  check (list string) "queue status and local preview have separate rows"
    ["Queue (3 pending) · auto-next:off · Ctrl-T:queue"
    ; "2 queued at Keeper · /queue"; "Local NEXT: \"local\""]
    (List.map Masc_tui_answering.chat_activity_row_text rows);
  (match Masc_tui_keeper_chat_queue.push state.msg_queued ~submitted_at:1. first.sent_request with
   | Error detail -> fail detail
   | Ok (queue, _) -> state.msg_queued <- queue);
  check int "handoff cannot count one request twice" 3 (List.length (waiting "alpha"));
  state.msg_queued <- local;
  Tui_types.turn_log_add ~now:5. first.log ~seq:(Some 1) Live.Run_started;
  check (list string) "started request leaves queue even though its admission was Queued"
    [second.sent_request.request_id; unsent.request_id] (waiting "alpha");
  List.iteri (fun seq delta -> Tui_types.turn_log_add ~now:6. second.log ~seq:(Some (seq+1)) delta)
    [Live.Run_started;
     Live.Reply_details {reply=""; turn_outcome=Masc.Keeper_turn_outcome.Continuation_checkpoint;
       turn_ref="trace#1"}; Live.Run_finished];
  check (list string) "checkpoint wait is not a queued operator message"
    [unsent.request_id] (waiting "alpha");
  let excluded deltas =
    state.msg_queued <- Masc_tui_keeper_chat_queue.empty;
    state.msg_inflight <- [inflight_with_log ~keeper_name:"alpha" ~started_at:7. deltas];
    check (list string) "only confirmed queued requests appear" [] (waiting "alpha") in
  let starting = inflight_with_log ~keeper_name:"alpha" ~started_at:7.
      [Live.Accepted {admission=Live.Running; queue_length=3; interactive=None}] in
  state.msg_queued <- Masc_tui_keeper_chat_queue.empty;
  state.msg_inflight <- [starting];
  check (list string) "Running admission still waits for execution evidence"
    [starting.sent_request.request_id] (waiting "alpha");
  excluded [Live.Accepted {admission=Live.Settled; queue_length=3; interactive=None}];
  excluded [Live.Accepted {admission=Live.Queued; queue_length=3; interactive=None};
    Live.Run_started; visible_reply "done"; Live.Run_finished];
  let rejected = inflight_with_log ~keeper_name:"alpha" ~started_at:7.
      [Live.Accepted {admission=Live.Queued; queue_length=3; interactive=None};
       Live.Run_failed {message="cancelled before execution"}] in
  state.msg_inflight <- [rejected];
  check (list string) "failure before Run_started does not consume the input"
    [rejected.sent_request.request_id] (waiting "alpha");
  let promoted = inflight_with_log ~keeper_name:"alpha" ~started_at:8. [] in
  state.msg_inflight <- [promoted];
  let expect_delivery label expected =
    match Tui_types.keeper_message_waiting_requests state ~keeper_name:"alpha" with
    | [(_, delivery)] -> check bool label true (delivery = expected)
    | _ -> fail (label ^ ": expected one pending request") in
  check (list string) "local queue remains visible while POST awaits admission"
    [promoted.sent_request.request_id] (waiting "alpha");
  expect_delivery "POST without receipt is not confirmed queued" Tui_types.Awaiting_receipt;
  promoted.phase <- Tui_types.Turn_reconciling;
  expect_delivery "unacknowledged reconnect is explicitly uncertain" Tui_types.Rechecking_delivery;
  Tui_types.turn_log_add ~now:9. promoted.log ~seq:None
    (Live.Accepted {admission=Live.Queued;queue_length=1;interactive=None});
  expect_delivery "old admission does not claim current certainty during reconnect"
    Tui_types.Rechecking_delivery;
  promoted.phase <- Tui_types.Turn_streaming;
  expect_delivery "live queued receipt restores confirmed status" Tui_types.Keeper_queued;
  check (list string) "acceptance preserves the same queued request"
    [promoted.sent_request.request_id] (waiting "alpha");
  promoted.phase <- Tui_types.Turn_reconciling;
  Tui_types.turn_log_add ~now:10. promoted.log ~seq:None Live.Run_started;
  check (list string) "started execution leaves pending even while reconnecting"
    [] (waiting "alpha")
;;

(* Settling commits the log, keeps it when it has anything to draw, and
   stops treating it as live; an empty log is committed and let go. *)
let test_settle_turn_log_commits_holds_and_clears_live () =
  let state =
    Tui_types.create_state ~workspace:"test" ~port:8935 ~refresh_interval:2.0 ()
  in
  let entry =
    inflight_with_log ~keeper_name:"alpha" ~started_at:10.
      [ Live.Run_started; Live.Text "hi"; visible_reply "hi"; Live.Run_finished ]
  in
  state.msg_live <- Some entry.log;
  Tui_types.settle_turn_log state entry;
  check bool "committed" true (Log.committed entry.log.Tui_types.tl_log);
  check bool "held" true (List.memq entry.log state.msg_settled_logs);
  check bool "no longer live" true (Option.is_none state.msg_live);
  let empty = inflight_with_log ~keeper_name:"alpha" ~started_at:11. [] in
  let other =
    inflight_with_log ~keeper_name:"beta" ~started_at:12. [ Live.Run_started ]
  in
  state.msg_live <- Some other.log;
  Tui_types.settle_turn_log state empty;
  check bool "an empty log is committed" true (Log.committed empty.log.Tui_types.tl_log);
  check bool "but not held" false (List.memq empty.log state.msg_settled_logs);
  check bool "another keeper's live turn is left alone" true
    (match state.msg_live with Some live -> live == other.log | None -> false)
;;

let completed ?(outcome = Masc.Keeper_turn_outcome.Visible_reply) reply
    : Keeper_chat.completed_turn =
  { Keeper_chat.acceptance = { Keeper_chat.state = Keeper_chat.Succeeded; queued_count = 0; interactive = None }
  ; reply
  ; turn_outcome = outcome
  ; turn_ref = "trace-1#1"
  }
;;

(* The strict decode's reply row is for a turn whose log does not stand for
   it: no log, a log that never heard the end, a log that heard it before it
   was committed. A log that stands for the turn draws the reply itself. *)
let test_the_reply_row_defers_to_a_log_that_holds_the_turn () =
  let state =
    Tui_types.create_state ~workspace:"test" ~port:8935 ~refresh_interval:2.0 ()
  in
  let entry =
    inflight_with_log ~keeper_name:"alpha" ~started_at:10.
      [ Live.Run_started; Live.Text "hi"; visible_reply "hi"; Live.Run_finished ]
  in
  let request = entry.sent_request in
  let role_name = function
    | Tui_types.Message_keeper -> "keeper"
    | Tui_types.Message_status -> "status"
    | Tui_types.Message_user _ | Tui_types.Message_autonomous
    | Tui_types.Message_local | Tui_types.Message_error | Tui_types.Message_tool
    | Tui_types.Message_skill _ | Tui_types.Message_thinking
    | Tui_types.Message_memory ->
        "other"
  in
  let row request completed =
    Option.map
      (fun (role, text) -> (role_name role, text))
      (Tui_types.completed_turn_row state request completed)
  in
  check (option (pair string string)) "no log: the strict decode's row"
    (Some ("keeper", "hi"))
    (row request (completed "hi"));
  state.msg_settled_logs <- [ entry.log ];
  check bool "held but not committed: still the strict decode's row" true
    (Option.is_some (row request (completed "hi")));
  Log.commit entry.log.Tui_types.tl_log;
  check bool "committed and ended with a reply: the log draws it" true
    (Option.is_none (row request (completed "hi")));
  let cut =
    inflight_with_log ~keeper_name:"alpha" ~started_at:11.
      [ Live.Run_started; Live.Text "half" ]
  in
  Log.commit cut.log.Tui_types.tl_log;
  state.msg_settled_logs <- [ cut.log ];
  check bool "a log that never heard the end: the strict decode's row" true
    (Option.is_some (row cut.sent_request (completed "half and more")));
  let cancelled =
    inflight_with_log ~keeper_name:"alpha" ~started_at:12.
      [ Live.Run_started; Live.Text "some"; Live.Run_finished ]
  in
  Log.commit cancelled.log.Tui_types.tl_log;
  state.msg_settled_logs <- [ cancelled.log ];
  check bool "finished without a recorded reply: the log does not stand for the turn"
    false (Tui_types.turn_log_holds_the_turn cancelled.log);
  check (option (pair string string)) "a control outcome reads as its sentence"
    (Some ("status", "Continuation checkpoint recorded (turn trace-1#1)"))
    (row cancelled.sent_request
       (completed ~outcome:Masc.Keeper_turn_outcome.Continuation_checkpoint ""))

;;

(* What the server replays after since_seq overlaps what the cut stream had
   already delivered; the log's seq dedup is what absorbs it. *)
let test_replayed_frames_up_to_the_last_seq_are_not_added_twice () =
  let log =
    Tui_types.turn_log_create ~keeper_name:"alpha" ~request_id:"req-1"
      ~started_at:10.0
  in
  let add seq delta = Tui_types.turn_log_add ~now:11.0 log ~seq:(Some seq) delta in
  add 0 Live.Run_started;
  List.iteri (fun i word -> add (i + 1) (Live.Text word)) [ "a"; "b"; "c"; "d"; "e" ];
  check position "the cut stream left the log at seq 5"
    (Masc.Keeper_chat_event_log.After_seq 5)
    (Log.resume_position log.Tui_types.tl_log);
  (* The server replays from 3 (a generous since_seq) and continues live. *)
  List.iter
    (fun (seq, word) -> add seq (Live.Text word))
    [ (3, "c"); (4, "d"); (5, "e"); (6, "f"); (7, "g") ];
  check string "only the frames past the last seq are folded" "abcdefg"
    (Keeper_chat_transcript.text log.Tui_types.tl_transcript);
  check position "the log moved to the newest seq"
    (Masc.Keeper_chat_event_log.After_seq 7)
    (Log.resume_position log.Tui_types.tl_log)
;;

let settled_log ~request_id deltas =
  let log =
    Tui_types.turn_log_create ~keeper_name:"alpha" ~request_id ~started_at:100.0
  in
  List.iteri
    (fun seq delta -> Tui_types.turn_log_add ~now:101.0 log ~seq:(Some seq) delta)
    deltas;
  Log.commit log.Tui_types.tl_log;
  log
;;

let loaded_turn ~request_id =
  [ chat_entry ~request_id
      ~role:(Tui_types.Message_user (Tui_types.Sent_by_operator { surface = None }))
      ~text:"asked" ~at:100. ()
  ; chat_entry ~request_id ~role:Tui_types.Message_thinking
      ~text:"2 reasoning steps, content withheld" ~at:101. ()
  ; chat_entry ~request_id ~role:Tui_types.Message_tool ~text:"read_file a.ml"
      ~at:102. ()
  ; chat_entry ~request_id ~role:Tui_types.Message_status
      ~text:"Gate approved read_file" ~at:103. ()
  ; chat_entry ~request_id ~role:Tui_types.Message_keeper ~text:"answered"
      ~at:104. ()
  ; chat_entry ~request_id ~role:Tui_types.Message_error ~text:"delivery failed"
      ~at:105. ()
  ]
;;

module E = Masc.Keeper_chat_events
module Journal = Masc.Keeper_chat_event_log

let line seq ts event : Journal.journaled_event = { Journal.seq; ts; event }

let journal_reply reply =
  E.Reply_details
    { reply
    ; turn_outcome = Masc.Keeper_turn_outcome.Visible_reply
    ; turn_ref = Ids.Turn_ref.make ~trace_id:"trace-1" ~absolute_turn:1
    }
;;

(* Which loaded turns a refresh asks the journal for: each operation once,
   newest first by its earliest row, minus what the session already holds or
   the server has refused -- and every one of those. The rows are one page
   the server already cut, so how many are asked for follows the operations
   the rows name, not a number of this client's. *)
let test_journal_fetch_targets_choose_the_newest_unheld_turns () =
  let candidates =
    [ ("op-old", 10.); ("op-old", 12.); ("op-held", 20.); ("op-gone", 30.)
    ; ("op-new", 40.); ("op-new", 39.); ("op-mid", 25.) ]
  in
  check (list (pair journal_key_test (float 0.001))) "once each, newest first, by the earliest row"
    (operation_targets [ ("op-new", 39.); ("op-mid", 25.); ("op-old", 10.) ])
    (Tui_types.journal_fetch_targets ~held:[ operation_key "op-held" ] ~unavailable:[ operation_key "op-gone" ]
       (operation_targets candidates));
  check (list (pair journal_key_test (float 0.001))) "nothing named, nothing asked" []
    (Tui_types.journal_fetch_targets ~held:[] ~unavailable:[] []);
  (* Same instant: the order is the id's. *)
  check (list (pair journal_key_test (float 0.001))) "a tie is broken by id"
    (operation_targets [ ("op-a", 5.); ("op-b", 5.); ("op-c", 5.) ])
    (Tui_types.journal_fetch_targets ~held:[] ~unavailable:[]
       (operation_targets [ ("op-c", 5.); ("op-a", 5.); ("op-b", 5.) ]));
  (* A page of many operations, each named by two rows, a third of them held
     and a third refused: one target per operation that is neither, none
     skipped. The expectation is derived from the same input, so it holds
     for any page the server chooses to send. *)
  let named = List.init 64 (fun index -> operation_key (Printf.sprintf "op-%03d" index)) in
  let held = List.filteri (fun index _ -> index mod 3 = 0) named in
  let unavailable = List.filteri (fun index _ -> index mod 3 = 1) named in
  let rows = List.concat_map (fun id -> [ (id, 1.); (id, 2.) ]) named in
  let targets = Tui_types.journal_fetch_targets ~held ~unavailable rows in
  let expected = List.filteri (fun index _ -> index mod 3 = 2) named in
  check int "one target per named operation not held and not refused"
    (List.length expected) (List.length targets);
  check (list journal_key_test) "and each of them"
    (List.sort compare expected)
    (List.sort compare (List.map fst targets))
;;

(* Acceptance is HTTP metadata, not an execution journal entry. Re-POSTs
   refresh the snapshot without advancing the journal or starting the turn. *)
let test_the_acceptance_is_read_but_not_logged () =
  let log =
    Tui_types.turn_log_create ~keeper_name:"alpha" ~request_id:"req-1" ~started_at:1.
  in
  let accepted = Live.Accepted { admission = Live.Running; queue_length = 2; interactive = None } in
  Tui_types.turn_log_add ~now:1. log ~seq:None accepted;
  Tui_types.turn_log_add ~now:2. log ~seq:None accepted;
  check int "no entries" 0 (List.length (Log.entries log.Tui_types.tl_log));
  check (option (float 0.)) "first acceptance retains source time" (Some 1.)
    (Option.bind (Log.first_acceptance log.tl_log) (fun entry -> entry.Log.at));
  check (option (float 0.)) "latest acceptance is a separate snapshot" (Some 2.)
    (Option.bind (Log.latest_acceptance log.tl_log) (fun entry -> entry.Log.at));
  check bool "the transcript is still waiting for the run" true
    (Keeper_chat_transcript.phase log.Tui_types.tl_transcript
     = Keeper_chat_transcript.Waiting);
  Tui_types.turn_log_add ~now:3. log ~seq:(Some 0) Live.Run_started;
  check int "a wire frame is an entry" 1 (List.length (Log.entries log.Tui_types.tl_log))
;;

(* The HTTP route writes this seq-less prelude before replay/live handoff.
   Its timestamp may be newer than execution events buffered by the owner. *)
let acceptance_wire ~request_id ~at ?(state = "Queued") outcome =
  Ag_ui.of_custom ~timestamp:at ~name:"KEEPER_CHAT_OPERATION_ACCEPTED"
    (`Assoc ["operation_id", `String request_id; "state", `String state;
      "queued_count", `Int 1;
      "interactive", `Assoc ["outcome", `String outcome;
        "chat_control_token", `String "control-after-admission";
        "signalled", `Bool false; "resumed", `Bool false;
        "interrupt_error", `Null]])
  |> Ag_ui.event_to_sse
;;

let execution_wire lines =
  let _, frames = List.fold_left (fun (projection, frames) (line : Journal.journaled_event) ->
    let projection, event = Server_keeper_chat_agui_projection.project
        ~timestamp:line.ts ~redact_text:Fun.id projection line.event in
    projection, frames @ Option.to_list
      (Option.map (Ag_ui.event_to_sse ~id:line.seq) event))
    (Server_keeper_chat_agui_projection.initial, []) lines in
  String.concat "" frames
;;

let receive_chat_wire log wire =
  Live.feed (Live.create ()) wire
  |> List.iter (fun (item : Live.observed_delta) ->
      Tui_types.turn_log_add ~now:(Option.value item.at ~default:9999.)
        log ~seq:item.seq item.delta)
;;

let stale_admission_notice =
  "Message queued: chat controls changed after this input; the newer stop or resume remains in effect"
let paused_admission_notice = "Message queued: Keeper remains paused; inspect with /queue"

let test_admission_notice_precedes_earlier_buffered_reply () =
  let module Layout = Masc_tui_message_layout in
  let cache = Masc_tui_ansi.terminal_size_cache in
  let previous = Masc_tui_ansi.get_terminal_size () in
  let set_size size = ignore (Masc_tui_render_schedule.Terminal_size_cache.refresh
      cache ~probe:(fun () -> Some size)) in
  Fun.protect ~finally:(fun () -> set_size previous) (fun () ->
    List.iter (fun columns -> List.iter (fun origin ->
      set_size (60, columns);
      let state = Tui_types.create_state ~workspace:"test" ~port:8935 ~refresh_interval:2. () in
      state.view <- Tui_types.Keepers Tui_types.Keeper_message;
      state.roster_pane_preference <- Masc_tui_roster_pane.Hidden;
      state.msg_target_keeper_name <- Some "alpha";
      state.msg_origin_display <- origin;
      let entry = inflight_with_log ~keeper_name:"alpha" ~started_at:100. [] in
      let request = {entry.sent_request with Keeper_chat.message="아니야 진행해"} in
      let entry = {entry with Tui_types.sent_request=request} in
      let input = chat_entry ~request_id:request.request_id
          ~role:(Tui_types.Message_user (Sent_by_operator {surface=None}))
          ~text:request.message ~at:100. () in
      state.msg_history <- [{input with Tui_types.me_identity=Session_row
        {request_id=request.request_id; turn_phase=Turn_input; operation_seq=0}};
        chat_entry ~request_id:"foreign-status" ~role:Tui_types.Message_status
          ~text:"UNRELATED_STATUS" ~at:150. ()];
      state.msg_inflight <- [entry]; state.msg_live <- Some entry.log;
      receive_chat_wire entry.log
        (acceptance_wire ~request_id:request.request_id ~at:200. "stale_control");
      let entries () = Masc_tui_render_chat.keeper_message_layout_entries state
          ~keeper_name:"alpha" ~chat_cols:columns in
      let bodies () = List.map (fun (row : Layout.entry) -> row.body) (entries ()) in
      check (list string) "receipt alone draws no USER speech"
        ["UNRELATED_STATUS"; stale_admission_notice] (bodies ());
      check bool "receipt alone does not start execution" true
        (Keeper_chat_transcript.phase entry.log.tl_transcript = Waiting);
      check (list string) "original input remains in the separate pending area" [request.message]
        (Masc_tui_render_chat.chat_tail_entries state ~keeper_name:"alpha" ~role_label_column:20
         |> List.filter_map (fun (row : Layout.entry) -> if row.style=Local then Some row.body else None));
      check position "receipt cannot advance journal cursor" Journal.Whole_turn
        (Log.resume_position entry.log.tl_log);
      let lines = [line 0 110. (E.Run_started {run_id="receipt-run"; thread_id="keeper:alpha"});
        line 1 111. (E.Text_message_start {message_id="receipt-message"; role=E.Assistant});
        line 2 112. (E.Text_delta "계속할게요.");
        line 3 113. (journal_reply "계속할게요.");
        line 4 114. (E.Run_finished {run_id="receipt-run"})] in
      receive_chat_wire entry.log (execution_wire lines);
      let expected = [request.message; "UNRELATED_STATUS"; stale_admission_notice; "계속할게요."] in
      check (list string) "causal admission precedes earlier-clock execution, exact speech preserved"
        expected (bodies ());
      check bool "admission status does not claim an execution rail" true
        ((List.nth (entries ()) 2).turn_rail = Layout.Rail_none);
      let frame, _ = Masc_tui_render_chat.render_keeper_message state in
      let plain = List.map Masc_tui_theme.strip_sgr frame.Masc_tui_frame_presenter.lines in
      let row_of needle = List.find_index (Astring.String.is_infix ~affix:needle) plain in
      check bool "actual frame keeps receipt above reply" true
        (match row_of "Message queued:", row_of "계속할게요." with
         | Some receipt, Some reply -> receipt < reply | _ -> false);
      check int "original user body occurs once in actual frame" 1
        (List.length (List.filter (Astring.String.is_infix ~affix:request.message) plain));
      receive_chat_wire entry.log
        (acceptance_wire ~request_id:request.request_id ~at:400. ~state:"Succeeded" "replayed"
         ^ execution_wire lines);
      check (list string) "reconnect replay neither duplicates nor moves the first notice" expected (bodies ());
      let rebuilt = Keeper_chat_transcript.of_log ~now:9999. entry.log.tl_log in
      check bool "scalar receipt and execution rebuild exactly" true
        (Keeper_chat_transcript.drawn rebuilt = Keeper_chat_transcript.drawn entry.log.tl_transcript);
      check bool "latest receipt remains the current admission snapshot" true
        (Keeper_chat_transcript.admission rebuilt = Some (Live.Settled, 1));
      check (option (float 0.)) "notice retains source time, not reconnect or client time" (Some 200.)
        (Option.bind (Keeper_chat_transcript.admission_prelude rebuilt) (fun item -> item.at));
      (* A complete journal may win selection before the direct stream settles. *)
      let journal = Tui_types.turn_log_create ~keeper_name:"alpha"
          ~request_id:request.request_id ~started_at:100. in
      ignore (Tui_types.turn_log_add_journaled journal lines);
      Log.commit journal.tl_log; Tui_types.hold_settled_log state journal;
      Tui_types.settle_turn_log state entry;
      state.msg_inflight <- [];
      check (list string) "journal takeover keeps direct receipt without a session copy" expected (bodies ());
      check int "history contains no copied receipt row" 2 (List.length state.msg_history))
      [Layout.Origin_inline; Origin_bare; Origin_row]) [80; 140])
;;

let test_batch_receipts_survive_source_selection_and_continuation () =
  let module Layout = Masc_tui_message_layout in
  let state = Tui_types.create_state ~workspace:"test" ~port:8935 ~refresh_interval:2. () in
  let first = inflight_with_log ~keeper_name:"alpha" ~started_at:1. [] in
  let second = inflight_with_log ~keeper_name:"alpha" ~started_at:2. [] in
  let execution_id = first.sent_request.request_id in
  List.iter (fun (entry : Tui_types.inflight) ->
    Tui_types.turn_log_add ~now:10. entry.log ~seq:(Some 0)
      (Live.Batch_bound {operation_id=entry.sent_request.request_id; execution_id});
    Tui_types.turn_log_add ~now:11. entry.log ~seq:(Some 1) Live.Run_started) [first; second];
  receive_chat_wire second.log
    (acceptance_wire ~request_id:second.sent_request.request_id ~at:200. "stale_control");
  Tui_types.turn_log_add ~now:12. second.log ~seq:(Some 20) (Live.Text "BATCH_REPLY");
  state.msg_inflight <- [second; first]; state.msg_live <- Some first.log;
  let bodies () = Masc_tui_render_chat.keeper_message_layout_entries state
      ~keeper_name:"alpha" ~chat_cols:140
      |> List.map (fun (row : Layout.entry) -> row.body) in
  check (list string) "richer sibling owns execution" [stale_admission_notice; "BATCH_REPLY"] (bodies ());
  receive_chat_wire first.log
    (acceptance_wire ~request_id:execution_id ~at:300. "paused");
  let expected = [paused_admission_notice; stale_admission_notice; "BATCH_REPLY"] in
  check (list string) "hidden sibling receipt invalidates projection memo and stays request-owned"
    expected (bodies ());
  Tui_types.turn_log_add ~now:13. first.log ~seq:(Some 30) (Live.Text "BATCH_REPLY");
  check (list string) "source swap preserves both request receipts once" expected (bodies ());
  Tui_types.turn_log_add ~now:14. first.log ~seq:(Some 31) Live.Checkpoint;
  Tui_types.turn_log_add ~now:15. first.log ~seq:(Some 32) Live.Run_started;
  receive_chat_wire first.log
    (acceptance_wire ~request_id:execution_id ~at:400. ~state:"Running" "replayed");
  check int "continuation never re-emits the initial receipt" 1
    (List.length (List.filter (String.equal paused_admission_notice) (bodies ())));
  (* Opposite takeover direction: replacing a partial settled stream with a
     new journal source also transfers its non-journal receipt. *)
  Tui_types.settle_turn_log state first;
  let replacement = Tui_types.turn_log_create ~keeper_name:"alpha"
      ~request_id:execution_id ~started_at:1. in
  ignore (Tui_types.turn_log_add_journaled replacement
    [line 0 10. (E.Run_started {run_id="replacement"; thread_id="keeper:alpha"});
     line 1 11. (journal_reply "JOURNAL_REPLY");
     line 2 12. (E.Run_finished {run_id="replacement"})]);
  Log.commit replacement.tl_log; Tui_types.hold_settled_log state replacement;
  state.msg_inflight <- [second];
  check (list string) "replacement preserves first and sibling receipts ahead of its reply"
    [paused_admission_notice; stale_admission_notice; "JOURNAL_REPLY"] (bodies ())
;;

let test_priority_feedback_is_receipt_metadata () =
  let log = Tui_types.turn_log_create ~keeper_name:"alpha" ~request_id:"steer" ~started_at:1. in
  Tui_types.turn_log_note_priority_unavailable log;
  check bool "local intent alone cannot claim a control outcome" false
    (Log.priority_unavailable log.tl_log);
  let receipt = Ag_ui.of_custom ~timestamp:20. ~name:"KEEPER_CHAT_OPERATION_ACCEPTED"
      (`Assoc ["operation_id", `String "steer"; "state", `String "Running";
        "queued_count", `Int 0]) |> Ag_ui.event_to_sse in
  receive_chat_wire log (receipt ^ execution_wire
    [line 0 10. (E.Run_started {run_id="steer-run"; thread_id="keeper:alpha"});
     line 1 11. (journal_reply "ALREADY_RUNNING_REPLY");
     line 2 12. (E.Run_finished {run_id="steer-run"})]);
  Tui_types.turn_log_note_priority_unavailable log;
  Tui_types.turn_log_note_priority_unavailable log;
  let expected = "Submitted message already started or settled; no other turn was interrupted" in
  let check_projection transcript =
    match Keeper_chat_transcript.drawn transcript with
    | {origin=Admission_of_request "steer"; at=Some at; drawn=Drawn_status notice; _}
      :: [{drawn=Drawn_reply reply; _}] ->
        check (float 0.) "priority feedback uses receipt source time" 20. at;
        check string "priority feedback is kept" expected notice;
        check string "reply body unchanged" "ALREADY_RUNNING_REPLY" reply
    | _ -> fail "priority feedback must be one prelude before the original reply" in
  check_projection log.tl_transcript;
  check_projection (Keeper_chat_transcript.of_log ~now:9999. log.tl_log);
  check int "priority feedback adds no journal event" 3 (List.length (Log.entries log.tl_log))
;;

(* A journal page fills a turn log the way the wire does, at the lines' own
   times; a line that draws nothing still holds its position. *)
let test_a_journal_fills_a_turn_log_at_the_lines_own_times () =
  let log =
    Tui_types.turn_log_create ~keeper_name:"alpha" ~request_id:"op-1" ~started_at:100.
  in
  let _ = Tui_types.turn_log_add_journaled log
    [ line 0 100.5 (E.Run_started { run_id = "r"; thread_id = "keeper:alpha" })
    ; line 1 100.6 (E.Text_message_start { message_id = "m"; role = E.Assistant })
    ; line 2 100.7 (E.Text_delta "hel")
    ; line 3 100.8 (E.Text_delta "lo")
    ; line 4 100.85 (journal_reply "hello")
    ; line 5 100.9 (E.Run_finished { run_id = "r" })
    ] in
  check string "the text is the fold of the drawn lines" "hello"
    (Keeper_chat_transcript.text log.Tui_types.tl_transcript);
  check position "the undrawn line still counts" (Journal.After_seq 5)
    (Log.resume_position log.Tui_types.tl_log);
  check int "one entry per drawn line" 5 (List.length (Log.entries log.Tui_types.tl_log));
  check bool "the turn ended, so the log stands for it once committed" true
    (Log.commit log.Tui_types.tl_log;
     Tui_types.turn_log_holds_the_turn log)
;;

(* The observer's journal receipt drives dependent call-log reads. Overlap
   must update neither the transcript nor the receipt a second time. *)
let test_journal_receipts_only_name_newly_folded_results () =
  let log = Tui_types.turn_log_create ~keeper_name:"alpha" ~request_id:"observed"
      ~started_at:100. in
  let occurrence : E.tool_stream_occurrence =
    { stream_scope = 0; provider_message_id = None; block_index = 0 } in
  let result = line 3 100.3
      (E.Tool_result_ready { occurrence; tool_call_id = Some "call-observed";
        execution_id = Ids.Execution_id.of_string "exec-observed" }) in
  let first = Tui_types.turn_log_add_journaled log
      [ line 0 100. (E.Run_started { run_id = "r"; thread_id = "keeper:alpha" });
        line 1 100.1 (E.Tool_call_start { occurrence;
          tool_call_id = Some "call-observed"; tool_call_name = "Read" });
        line 2 100.2 (E.Tool_call_end { occurrence; tool_call_id = Some "call-observed" });
        result; result ] in
  let result_seqs accepted = List.filter_map
      (fun ((line : Journal.journaled_event), delta) -> match delta with
        | Live.Tool_result _ -> Some line.seq
        | _ -> None) accepted in
  check (list int) "one result receipt even with same-page overlap" [3]
    (result_seqs first);
  let replay = Tui_types.turn_log_add_journaled log
      [result; line 4 100.4 (E.Text_delta "still working")] in
  check (list int) "replayed result plus fresh text requests no calls" []
    (result_seqs replay);
  check string "the fresh text still reaches the observed transcript" "still working"
    (Keeper_chat_transcript.text log.Tui_types.tl_transcript);
  check bool "the result arrives before settlement" true
    (Keeper_chat_transcript.phase log.Tui_types.tl_transcript = Keeper_chat_transcript.Working);
  check int "an empty read produces no receipt" 0
    (List.length (Tui_types.turn_log_add_journaled log []));
  check (list int) "a later result is independent of the earlier receipt" [5]
    (result_seqs (Tui_types.turn_log_add_journaled log [{result with seq=5}]))
;;

let journal_log ~request_id ~started_at ?(finished = true) () =
  let log = Tui_types.turn_log_create ~keeper_name:"alpha" ~request_id ~started_at in
  let _ = Tui_types.turn_log_add_journaled log
    ([ line 0 started_at (E.Run_started { run_id = "r"; thread_id = "keeper:alpha" })
     ; line 1 (started_at +. 0.05)
         (E.Agent_core_thinking_delta { index = 0; delta = "thought about it" })
     ; line 2 (started_at +. 0.1) (E.Text_delta "said") ]
    @
    if finished
    then
      [ line 3 (started_at +. 0.15) (journal_reply "said")
      ; line 4 (started_at +. 0.2) (E.Run_finished { run_id = "r" }) ]
    else []) in
  Log.commit log.Tui_types.tl_log;
  log
;;

(* A journal read starts where the session's record of the turn ends: after a
   cut live stream's partial log, or from the beginning. *)
let test_a_journal_read_resumes_after_a_partial_log () =
  let state =
    Tui_types.create_state ~workspace:"test" ~port:8935 ~refresh_interval:2.0 ()
  in
  check position "nothing held: the whole journal" Journal.Whole_turn
    (Tui_types.journal_resume_position state ~keeper_name:"alpha" (Log.Operation "op-1"));
  let partial = journal_log ~request_id:"op-1" ~started_at:1. ~finished:false () in
  Tui_types.hold_settled_log state partial;
  check position "a partial log: after what it has" (Journal.After_seq 2)
    (Tui_types.journal_resume_position state ~keeper_name:"alpha" (Log.Operation "op-1"));
  check position "another keeper's record does not count" Journal.Whole_turn
    (Tui_types.journal_resume_position state ~keeper_name:"beta" (Log.Operation "op-1"));
  Tui_types.hold_settled_log state (journal_log ~request_id:"op-1" ~started_at:1. ());
  check position "a whole log is not read again" Journal.Whole_turn
    (Tui_types.journal_resume_position state ~keeper_name:"alpha" (Log.Operation "op-1"));
  Tui_types.journal_read_started state (operation_key "op-9");
  Tui_types.journal_read_started state (operation_key "op-9");
  check (list journal_key_test) "a read in flight is remembered once" [ operation_key "op-9" ]
    state.msg_journal_inflight;
  Tui_types.journal_read_finished state (operation_key "op-9");
  check (list journal_key_test) "and forgotten when it returns" [] state.msg_journal_inflight
;;

(* A rebuilt turn takes its place by when it started; a turn the session
   already holds whole is not held twice, and a cut stream's partial log gives
   way to the journal's whole one. *)
let test_hold_settled_log_orders_by_start_and_replaces_only_partial_logs () =
  let state =
    Tui_types.create_state ~workspace:"test" ~port:8935 ~refresh_interval:2.0 ()
  in
  let ids () = List.map Tui_types.turn_log_request_id state.msg_settled_logs in
  Tui_types.hold_settled_log state (journal_log ~request_id:"op-20" ~started_at:20. ());
  Tui_types.hold_settled_log state (journal_log ~request_id:"op-10" ~started_at:10. ());
  Tui_types.hold_settled_log state (journal_log ~request_id:"op-30" ~started_at:30. ());
  check (list string) "ordered by start" [ "op-10"; "op-20"; "op-30" ] (ids ());
  let whole = List.nth state.msg_settled_logs 1 in
  Tui_types.hold_settled_log state (journal_log ~request_id:"op-20" ~started_at:21. ());
  check bool "a whole log is kept as it was" true (List.memq whole state.msg_settled_logs);
  let partial = journal_log ~request_id:"op-15" ~started_at:15. ~finished:false () in
  Tui_types.hold_settled_log state partial;
  check bool "a partial log is held for now" true (List.memq partial state.msg_settled_logs);
  Tui_types.hold_settled_log state (journal_log ~request_id:"op-15" ~started_at:15. ());
  check bool "and gives way to the whole one" false (List.memq partial state.msg_settled_logs);
  check (list string) "still one log per turn, in order"
    [ "op-10"; "op-15"; "op-20"; "op-30" ] (ids ());
  Tui_types.remember_journal_unavailable state (operation_key "op-x");
  Tui_types.remember_journal_unavailable state (operation_key "op-x");
  check (list journal_key_test) "an unavailable journal is remembered once" [ operation_key "op-x" ]
    state.msg_journal_unavailable
;;

(* A turn rebuilt from its journal holds its turn in the timeline like one
   that settled live: the loaded rows the log draws leave. *)
let test_a_journal_built_log_holds_its_turn_in_the_timeline () =
  let state =
    Tui_types.create_state ~workspace:"test" ~port:8935 ~refresh_interval:2.0 ()
  in
  state.msg_target_keeper_name <- Some "alpha";
  state.msg_loaded_keeper <- Some "alpha";
  state.msg_loaded <- loaded_turn ~request_id:"op-1";
  Tui_types.hold_settled_log state (journal_log ~request_id:"op-1" ~started_at:100. ());
  check (list string) "the keeper's words, tools and reasoning are the log's now"
    [ "asked"; "Gate approved read_file"; "delivery failed" ]
    (Tui_types.chat_rows_for state "alpha"
     |> List.map (fun (row : Tui_types.msg_entry) -> row.me_text))
;;

(* A settled block goes after its request's last row of any phase before
   output: a failed turn's words sit above its own error row and above the
   turns that ran in between, not below both. The live block still follows
   every committed row of its request. *)
let test_a_settled_block_sits_before_its_requests_output_rows () =
  let user_b = chat_entry ~request_id:"B" ~role:(Tui_types.Message_user (Tui_types.Sent_by_operator { surface = None })) ~text:"uB" ~at:20. () in
  let user_a = chat_entry ~request_id:"A" ~role:(Tui_types.Message_user (Tui_types.Sent_by_operator { surface = None })) ~text:"uA" ~at:30. () in
  let err_b = chat_entry ~request_id:"B" ~role:Tui_types.Message_error ~text:"errB" ~at:50. () in
  let positioned = [ (user_b, Some 20.); (user_a, Some 30.); (err_b, Some 50.) ] in
  check int "settled B goes after uB, before uA and errB" 1
    (Tui_types.chat_settled_insertion_index ~request_id:"B" ~timeline_at:(Some 20.) positioned);
  check int "live B goes after everything of B" 3
    (Tui_types.chat_live_insertion_index ~request_id:"B" ~timeline_at:(Some 20.) positioned);
  check int "settled A goes after uA" 2
    (Tui_types.chat_settled_insertion_index ~request_id:"A" ~timeline_at:(Some 30.) positioned)
;;

(* The loaded tool row of a held turn leaves the timeline, and what it knew
   that the wire did not -- the call failed, and how long it took -- reaches
   the block through the log's transcript. *)
let test_loaded_tool_facts_are_folded_into_the_held_log () =
  let state =
    Tui_types.create_state ~workspace:"test" ~port:8935 ~refresh_interval:2.0 ()
  in
  let occurrence =
    { Live.stream_scope = 0; block_index = 1; provider_message_id = None; tool_call_id = Some "c1" }
  in
  let log =
    settled_log ~request_id:"op-1"
      [ Live.Run_started
      ; Live.Tool_started { occurrence; tool_name = "read_file" }
      ; Live.Tool_ended { occurrence }
      ; Live.Tool_result { occurrence; execution_id = "exec-1" }
      ; visible_reply "done"
      ; Live.Run_finished
      ]
  in
  state.msg_settled_logs <- [ log ];
  let durable =
    Keeper_chat_transcript.tool_block
      [ Keeper_chat_transcript.make_tool_activity ~execution_id:"exec-1"
          ~call_id:(Some "c1") ~tool_name:"read_file" ~args:"{}"
          ~outcome:Keeper_chat_transcript.Failed ~duration:(Some "32ms") () ]
  in
  let row =
    { (chat_entry ~request_id:"op-1" ~role:Tui_types.Message_tool ~text:"read_file" ~at:101. ())
      with me_tool_block = Some durable }
  in
  Tui_types.enrich_held_logs_from_rows state ~keeper_name:"alpha" [ row ];
  match Keeper_chat_transcript.tool_calls log.Tui_types.tl_transcript with
  | [ activity ] ->
      check bool "the block's call now says it failed" true
        (activity.Keeper_chat_transcript.outcome = Keeper_chat_transcript.Failed);
      check (option string) "and how long it took" (Some "32ms")
        activity.Keeper_chat_transcript.duration
  | other -> failf "expected one call, got %d" (List.length other)
;;

let drawn_skills_of (log : Tui_types.turn_log) =
  List.concat_map
    (fun (item : Keeper_chat_transcript.drawn_item) ->
      match item.Keeper_chat_transcript.drawn with
      | Keeper_chat_transcript.Drawn_skill skills -> skills
      | Keeper_chat_transcript.Drawn_thinking _ | Keeper_chat_transcript.Drawn_tools _
      | Keeper_chat_transcript.Drawn_text _ | Keeper_chat_transcript.Drawn_reply _
      | Keeper_chat_transcript.Drawn_status _ | Keeper_chat_transcript.Drawn_error _ ->
          [])
    (Keeper_chat_transcript.drawn log.Tui_types.tl_transcript)
;;

(* The loaded skill row of one turn as a cold history decodes it: the exact
   delivery record, the call the read led to, and the proof ids -- none of
   which the wire carries -- next to an evidence gap that names no read. *)
let skill_evidence_row ~request_id ~at =
  let evidence =
    Keeper_chat_transcript.make_skill_activity
      ~invocation:Keeper_chat_transcript.Instruction_read ~skill_tool_use_id:"c1"
      ~turn_ref:"trace-1#1" ~content_revision:"sha256:abc" ~runtime_id:"rt-1"
      ~skill_name:"ci-red-attribution" ~state:Keeper_chat_transcript.Skill_used
      ~actions:[ "read_file" ] ()
  in
  let gap =
    Keeper_chat_transcript.make_skill_activity ~skill_name:"Skill evidence"
      ~state:Keeper_chat_transcript.Skill_evidence_unavailable ~actions:[]
      ~detail:"Skill evidence schema is unavailable to this TUI" ()
  in
  { (chat_entry ~request_id
       ~role:(Tui_types.Message_skill Keeper_chat_transcript.Skill_used)
       ~text:"**ci-red-attribution**" ~at ())
    with me_skill_block = [ evidence; gap ] }
;;

(* The loaded skill row of a held turn leaves the timeline the way the tool
   row does, and what it knew has to reach the log's own skill row the same
   way -- or the log's copy stays at "읽음, 전달 확인 중", with no action and
   no proof, while the exact row is already gone (#36882). *)
let test_loaded_skill_evidence_is_folded_into_the_held_log () =
  let state =
    Tui_types.create_state ~workspace:"test" ~port:8935 ~refresh_interval:2.0 ()
  in
  let occurrence =
    { Live.stream_scope = 0; block_index = 1; provider_message_id = None; tool_call_id = Some "c1" }
  in
  let log =
    settled_log ~request_id:"op-1"
      [ Live.Run_started
      ; Live.Tool_started { occurrence; tool_name = "keeper_skill" }
      ; Live.Tool_ended { occurrence }
      ; Live.Tool_result { occurrence; execution_id = "exec-1" }
      ; visible_reply "done"
      ; Live.Run_finished
      ]
  in
  state.msg_settled_logs <- [ log ];
  (match drawn_skills_of log with
   | [ skill ] ->
       check bool "the wire alone leaves the delivery pending" true
         (skill.Keeper_chat_transcript.state = Keeper_chat_transcript.Skill_served_pending)
   | skills -> failf "expected one drawn skill, got %d" (List.length skills));
  Tui_types.enrich_held_logs_from_rows state ~keeper_name:"alpha"
    [ skill_evidence_row ~request_id:"op-1" ~at:101. ];
  match drawn_skills_of log with
  | [ skill ] ->
      check bool "the held log's skill row carries the exact state" true
        (skill.Keeper_chat_transcript.state = Keeper_chat_transcript.Skill_used);
      check (list string) "and the call the read led to" [ "read_file" ]
        skill.Keeper_chat_transcript.actions;
      check (option string) "and the proof's turn" (Some "trace-1#1")
        skill.Keeper_chat_transcript.turn_ref;
      check (option string) "on the same read call" (Some "c1")
        skill.Keeper_chat_transcript.skill_tool_use_id
  | skills -> failf "expected one drawn skill, got %d" (List.length skills)
;;

(* A log whose trail never saw the read -- a cut stream, a gap in the journal
   -- still draws the skill once the exact record arrives, ahead of the reply:
   the loaded row the log leaves out cannot take the skill with it. *)
let test_skill_evidence_stands_for_a_read_the_trail_missed () =
  let state =
    Tui_types.create_state ~workspace:"test" ~port:8935 ~refresh_interval:2.0 ()
  in
  let log =
    settled_log ~request_id:"op-1"
      [ Live.Run_started; Live.Text "done"; visible_reply "done"; Live.Run_finished ]
  in
  state.msg_settled_logs <- [ log ];
  check int "the trail has nothing to draw the skill from" 0
    (List.length (drawn_skills_of log));
  Tui_types.enrich_held_logs_from_rows state ~keeper_name:"alpha"
    [ skill_evidence_row ~request_id:"op-1" ~at:101. ];
  (match drawn_skills_of log with
   | [ skill ] ->
       check bool "the skill is drawn from the record" true
         (skill.Keeper_chat_transcript.state = Keeper_chat_transcript.Skill_used);
       check (list string) "with its action" [ "read_file" ]
         skill.Keeper_chat_transcript.actions
   | skills -> failf "expected one drawn skill, got %d" (List.length skills));
  match
    List.map
      (fun (item : Keeper_chat_transcript.drawn_item) -> item.Keeper_chat_transcript.drawn)
      (Keeper_chat_transcript.drawn log.Tui_types.tl_transcript)
  with
  | [ Keeper_chat_transcript.Drawn_skill _; Keeper_chat_transcript.Drawn_reply reply ] ->
      check string "the turn still ends on its reply" "done" reply
  | drawn -> failf "expected the skill then the reply, got %d rows" (List.length drawn)
;;

(* A composition writes its activation before its plan runs, and the server
   counts the error tool result of a failed plan as a delivery, so the exact
   record says delivered for a call the stream saw fail. The failure is the
   fact about that call, and it stands. *)
let test_a_failed_skill_call_keeps_its_failure () =
  let state =
    Tui_types.create_state ~workspace:"test" ~port:8935 ~refresh_interval:2.0 ()
  in
  let occurrence =
    { Live.stream_scope = 0; block_index = 1; provider_message_id = None; tool_call_id = Some "c1" }
  in
  let log =
    settled_log ~request_id:"op-1"
      [ Live.Run_started
      ; Live.Tool_started { occurrence; tool_name = "keeper_skill" }
      ; Live.Tool_ended { occurrence }
      ; Live.Tool_result { occurrence; execution_id = "exec-1" }
      ; visible_reply "done"
      ; Live.Run_finished
      ]
  in
  state.msg_settled_logs <- [ log ];
  let failed_call =
    { (chat_entry ~request_id:"op-1" ~role:Tui_types.Message_tool
         ~text:"keeper_skill" ~at:101. ())
      with
      me_tool_block =
        Some
          (Keeper_chat_transcript.tool_block
             [ Keeper_chat_transcript.make_tool_activity ~execution_id:"exec-1"
                 ~call_id:(Some "c1") ~tool_name:"keeper_skill" ~args:"{}"
                 ~outcome:Keeper_chat_transcript.Failed ~duration:(Some "32ms") () ])
    }
  in
  Tui_types.enrich_held_logs_from_rows state ~keeper_name:"alpha"
    [ failed_call; skill_evidence_row ~request_id:"op-1" ~at:102. ];
  match drawn_skills_of log with
  | [ skill ] ->
      check bool "the failed read is not drawn as a delivered one" true
        (skill.Keeper_chat_transcript.state = Keeper_chat_transcript.Skill_failed);
      check (list string) "and the record's actions do not land on it" []
        skill.Keeper_chat_transcript.actions
  | skills -> failf "expected one drawn skill, got %d" (List.length skills)

;;

(* A turn the settled log holds has one source. The loaded transcript's rows
   the log draws itself -- the keeper's words, tools, reasoning -- leave the
   timeline; what a person said, what the server said about the turn, and a
   failure stay, because the log draws none of them. Another turn's rows are
   untouched, and a later reload does not bring the suppressed rows back. *)
let test_a_settled_log_holds_its_turn_in_the_timeline () =
  let state =
    Tui_types.create_state ~workspace:"test" ~port:8935 ~refresh_interval:2.0 ()
  in
  state.msg_target_keeper_name <- Some "alpha";
  state.msg_loaded_keeper <- Some "alpha";
  state.msg_loaded <-
    loaded_turn ~request_id:"held"
    @ [ chat_entry ~request_id:"other" ~role:Tui_types.Message_keeper
          ~text:"other turn" ~at:200. () ];
  state.msg_settled_logs <-
    [ settled_log ~request_id:"held"
        [ Live.Run_started
        ; Live.Thinking "thought about it"
        ; Live.Text "answered"
        ; Live.Reply_details
            { reply = "answered"
            ; turn_outcome = Masc.Keeper_turn_outcome.Visible_reply
            ; turn_ref = "trace-1#1"
            }
        ; Live.Run_finished
        ] ];
  let texts () =
    Tui_types.chat_rows_for state "alpha"
    |> List.map (fun (row : Tui_types.msg_entry) -> row.me_text)
  in
  check (list string) "the log's rows leave; the rest stay"
    [ "asked"; "Gate approved read_file"; "delivery failed"; "other turn" ]
    (texts ());
  (* A reload replaces the loaded page, not the settled logs. *)
  state.msg_loaded <- loaded_turn ~request_id:"held";
  check (list string) "after a reload the held turn is still the log's"
    [ "asked"; "Gate approved read_file"; "delivery failed" ]
    (texts ())
;;

(* A runtime that streams no reasoning leaves the durable trace row -- "N
   reasoning steps, content withheld" -- as the only record that the keeper
   thought; a log without reasoning does not take it away. *)
let test_a_log_without_reasoning_leaves_the_trace_row () =
  let state =
    Tui_types.create_state ~workspace:"test" ~port:8935 ~refresh_interval:2.0 ()
  in
  state.msg_target_keeper_name <- Some "alpha";
  state.msg_loaded_keeper <- Some "alpha";
  state.msg_loaded <- loaded_turn ~request_id:"held";
  state.msg_settled_logs <-
    [ settled_log ~request_id:"held"
        [ Live.Run_started; Live.Text "answered"; visible_reply "answered"; Live.Run_finished ]
    ];
  check (list string) "the trace row stays beside the log's rows"
    [ "asked"; "2 reasoning steps, content withheld"; "Gate approved read_file"
    ; "delivery failed" ]
    (Tui_types.chat_rows_for state "alpha"
     |> List.map (fun (row : Tui_types.msg_entry) -> row.me_text))
;;

(* A log that never heard how the turn ended holds part of it at most; the
   committed rows keep saying the rest. *)
let test_an_unfinished_settled_log_suppresses_nothing () =
  let state =
    Tui_types.create_state ~workspace:"test" ~port:8935 ~refresh_interval:2.0 ()
  in
  state.msg_target_keeper_name <- Some "alpha";
  state.msg_loaded_keeper <- Some "alpha";
  state.msg_loaded <- loaded_turn ~request_id:"cut";
  state.msg_settled_logs <-
    [ settled_log ~request_id:"cut" [ Live.Run_started; Live.Text "half" ] ];
  check bool "the log does not stand for the turn" false
    (Tui_types.turn_log_holds_the_turn (List.hd state.msg_settled_logs));
  check int "every loaded row is still drawn" 6
    (List.length (Tui_types.chat_rows_for state "alpha"))
;;

(* Two turns settled in one session, one of them for another keeper: only
   alpha's held turn is suppressed from alpha's rows. *)
let test_settled_logs_are_read_per_keeper () =
  let state =
    Tui_types.create_state ~workspace:"test" ~port:8935 ~refresh_interval:2.0 ()
  in
  state.msg_target_keeper_name <- Some "alpha";
  state.msg_loaded_keeper <- Some "alpha";
  state.msg_loaded <-
    [ chat_entry ~request_id:"shared-id" ~role:Tui_types.Message_keeper
        ~text:"alpha said" ~at:100. () ];
  let beta =
    Tui_types.turn_log_create ~keeper_name:"beta" ~request_id:"shared-id"
      ~started_at:100.0
  in
  Tui_types.turn_log_add ~now:101.0 beta ~seq:(Some 0) Live.Run_started;
  Tui_types.turn_log_add ~now:101.0 beta ~seq:(Some 1) (visible_reply "beta said");
  Tui_types.turn_log_add ~now:101.0 beta ~seq:(Some 2) Live.Run_finished;
  Log.commit beta.Tui_types.tl_log;
  state.msg_settled_logs <- [ beta ];
  check int "beta's log does not hold alpha's row" 1
    (List.length (Tui_types.chat_rows_for state "alpha"));
  check (list string) "beta's log is beta's" [ "shared-id" ]
    (Tui_types.settled_logs_for_keeper state "beta"
     |> List.map Tui_types.turn_log_request_id);
  check (list string) "alpha holds none" []
    (Tui_types.settled_logs_for_keeper state "alpha"
     |> List.map Tui_types.turn_log_request_id)
;;

let test_pending_input_enters_transcript_only_when_execution_is_observed () =
  let state =
    Tui_types.create_state ~workspace:"test" ~port:8935 ~refresh_interval:2.0 ()
  in
  let request =
    Keeper_chat.create_request ~keeper_name:"alpha" ~message:"queued input" ()
  in
  let log =
    Tui_types.turn_log_create ~keeper_name:"alpha"
      ~request_id:request.request_id ~started_at:43.0
  in
  state.msg_target_keeper_name <- Some "alpha";
  let user =
    chat_entry ~request_id:request.request_id
        ~role:(Tui_types.Message_user (Tui_types.Sent_by_operator { surface = None }))
        ~text:"queued input" ~at:42.0 () in
  let user = {user with me_identity = Tui_types.Session_row
      {request_id=request.request_id; turn_phase=Turn_input; operation_seq=0}} in
  state.msg_history <- [user];
  let queue = match Masc_tui_keeper_chat_queue.push state.msg_queued
      ~submitted_at:42. request with
    | Ok (queue, _) -> queue | Error error -> fail error in
  state.msg_queued <- queue;
  let waiting () = Tui_types.keeper_message_waiting_requests state ~keeper_name:"alpha" in
  let assert_pending stage =
    check (list string) (stage ^ ": input remains outside conversation") []
      (Tui_types.chat_rows_for state "alpha"
       |> List.map (fun row -> row.Tui_types.me_text));
    check (list string) (stage ^ ": exact input remains in pending lane")
      [request.request_id]
      (waiting () |> List.map (fun (request, _) -> request.Keeper_chat.request_id)) in
  assert_pending "local queue";
  let promoted, empty = match Masc_tui_keeper_chat_queue.take queue ~request_id:request.request_id with
    | Some pair -> pair | None -> fail "pending request was lost" in
  state.msg_queued <- empty;
  let entry : Tui_types.inflight =
      { Tui_types.sent_request = request
      ; submitted_at = 42.0
      ; sent_at = 43.0
      ; control_generation = 0
      ; phase = Tui_types.Turn_preflight promoted
      ; log
      } in
  state.msg_inflight <- [entry];
  assert_pending "promoted before HTTP POST";
  entry.phase <- Tui_types.Turn_streaming;
  assert_pending "POST before acceptance";
  Tui_types.turn_log_add ~now:44. log ~seq:None
    (Live.Accepted {admission=Live.Queued; queue_length=1; interactive=None});
  assert_pending "accepted into server queue";
  entry.phase <- Tui_types.Turn_reconciling;
  assert_pending "unconfirmed delivery while reconnecting";
  entry.phase <- Tui_types.Turn_streaming;
  Tui_types.turn_log_add ~now:45. log ~seq:(Some 0) Live.Run_started;
  check (list string) "execution evidence promotes exactly one original input" [ "queued input" ]
    (Tui_types.chat_rows_for state "alpha"
     |> List.map (fun row -> row.Tui_types.me_text));
  check int "started input leaves pending lane" 0 (List.length (waiting ()));
  check string "promotion preserves exact request identity" request.request_id
    entry.sent_request.request_id;
  check (float 0.001) "promotion preserves submitted_at" 42.0 entry.submitted_at;
  (* A reconnect can load authoritative history before its event replay. *)
  let lagging = Tui_types.turn_log_create ~keeper_name:"alpha"
      ~request_id:request.request_id ~started_at:43. in
  Tui_types.turn_log_add ~now:44. lagging ~seq:None
    (Live.Accepted {admission=Live.Queued; queue_length=1; interactive=None});
  state.msg_inflight <- [{entry with phase=Turn_reconciling; log=lagging}];
  state.msg_loaded_keeper <- Some "alpha";
  state.msg_loaded <- [{user with me_identity=Persisted_row "persisted-input"; me_at=45.}];
  check (list string) "persisted input survives an older queued receipt" ["queued input"]
    (Tui_types.chat_rows_for state "alpha" |> List.map (fun row -> row.Tui_types.me_text));
  check int "authoritative input is not also shown pending" 0 (List.length (waiting ()))
;;

(* Exercise the actual frame, not only the delta fold: a promoted request
   used to collect every delta correctly while the renderer hid its block. *)
let test_parallel_blocks_share_a_chronological_insertion_slot () =
  let cache = Masc_tui_ansi.terminal_size_cache in
  let previous_size = Masc_tui_ansi.get_terminal_size () in
  let set_size size =
    match Masc_tui_render_schedule.Terminal_size_cache.refresh cache
            ~probe:(fun () -> Some size) with
    | Changed _ | Unchanged _ -> () in
  Fun.protect ~finally:(fun () -> set_size previous_size) (fun () ->
    set_size (70, 120);
    let state = Tui_types.create_state ~workspace:"test" ~port:8935 ~refresh_interval:2. () in
    state.view <- Tui_types.Keepers Tui_types.Keeper_message;
    state.roster_pane_preference <- Masc_tui_roster_pane.Hidden;
    state.msg_target_keeper_name <- Some "alpha";
    let entries = List.init 4 (fun i ->
      inflight_with_log ~keeper_name:"alpha"
        ~started_at:(1_790_053_724. +. 60. *. float_of_int i)
        [Live.Run_started; Live.Text (Printf.sprintf "ORDER_%d" i)]) in
    List.iter (fun order ->
      (* No durable rows: all blocks share insertion slot zero. *)
      state.msg_inflight <- List.map (List.nth entries) order;
      state.msg_live <- Some (List.nth entries 3).log;
      let frame, _ = Masc_tui_render_chat.render_keeper_message state in
      let plain = List.map Masc_tui_theme.strip_sgr frame.Masc_tui_frame_presenter.lines in
      let shown = List.filter_map (fun line ->
        List.find_opt (fun i -> Astring.String.is_infix
          ~affix:(Printf.sprintf "ORDER_%d" i) line) [0;1;2;3]) plain in
      check (list int) "four parallel blocks follow time, not subscription order"
        [0;1;2;3] shown)
      [[0;1;2;3]; [3;2;1;0]; [2;0;3;1]])
;;

let test_live_gutter_clock_matches_its_causal_frontier () =
  let cache = Masc_tui_ansi.terminal_size_cache in
  let previous_size = Masc_tui_ansi.get_terminal_size () in
  let set_size size =
    match Masc_tui_render_schedule.Terminal_size_cache.refresh cache
            ~probe:(fun () -> Some size) with
    | Changed _ | Unchanged _ -> () in
  Fun.protect ~finally:(fun () -> set_size previous_size) (fun () ->
    set_size (70, 120);
    let state = Tui_types.create_state ~workspace:"test" ~port:8935 ~refresh_interval:2. () in
    let start = 1_790_053_724. in
    let frontier = start +. 240. in
    let entry = inflight_with_log ~keeper_name:"alpha" ~started_at:start [] in
    let request_id = entry.sent_request.request_id in
    state.view <- Tui_types.Keepers Tui_types.Keeper_message;
    state.roster_pane_preference <- Masc_tui_roster_pane.Hidden;
    state.msg_origin_display <- Masc_tui_message_layout.Origin_row;
    state.msg_target_keeper_name <- Some "alpha";
    state.msg_inflight <- [entry];
    state.msg_live <- Some entry.log;
    state.msg_history <-
      [chat_entry ~request_id
         ~role:(Tui_types.Message_user (Tui_types.Sent_by_operator {surface=None}))
         ~text:"CLOCK_INPUT" ~at:start ();
       chat_entry ~request_id ~turn_phase:Tui_types.Turn_progress
         ~role:Tui_types.Message_status ~text:"CLOCK_FRONTIER" ~at:frontier ()];
    Tui_types.turn_log_add ~now:start entry.log ~seq:(Some 0) Live.Run_started;
    Tui_types.turn_log_add ~now:frontier entry.log ~seq:(Some 1) (Live.Text "CLOCK_OUTPUT");
    let frame, _ = Masc_tui_render_chat.render_keeper_message state in
    let plain = List.map Masc_tui_theme.strip_sgr frame.Masc_tui_frame_presenter.lines in
    let clock = Masc_tui_render_chat.keeper_message_clock frontier in
    (* The live heading has an empty speaker. Locate its clock between the
       progress body and output body rather than guessing a keeper label. *)
    let rec between active selected = function
      | [] -> fail "CLOCK_OUTPUT was not rendered"
      | line :: _ when Astring.String.is_infix ~affix:"CLOCK_OUTPUT" line ->
          List.rev selected
      | line :: rest when Astring.String.is_infix ~affix:"CLOCK_FRONTIER" line ->
          between true [] rest
      | line :: rest -> between active (if active then line :: selected else selected) rest in
    let output_heading = between false [] plain in
    check bool "keeper heading uses frontier clock" true
      (List.exists (fun line ->
        Astring.String.is_suffix ~affix:clock (String.trim line)) output_heading);
    let old_clock = Masc_tui_render_chat.keeper_message_clock start in
    check bool "keeper heading does not revert to dispatch clock" false
      (List.exists (fun line ->
        Astring.String.is_suffix ~affix:old_clock (String.trim line)) output_heading);
    check bool "dispatch span is never prepended to speech" false
      (List.exists (Astring.String.is_infix ~affix:(old_clock ^ "→")) plain))
;;

let test_promoted_live_output_survives_settlement_and_replay () =
  let cache = Masc_tui_ansi.terminal_size_cache in
  let previous_size = Masc_tui_ansi.get_terminal_size () in
  let set_size size =
    match Masc_tui_render_schedule.Terminal_size_cache.refresh cache
            ~probe:(fun () -> Some size) with
    | Changed _ | Unchanged _ -> ()
  in
  Fun.protect ~finally:(fun () -> set_size previous_size) (fun () ->
    set_size (70, 120);
    List.iter (fun failure ->
      let state =
        Tui_types.create_state ~workspace:"test" ~port:8935 ~refresh_interval:2. ()
      in
      let entry = inflight_with_log ~keeper_name:"alpha" ~started_at:42. [] in
      state.view <- Tui_types.Keepers Tui_types.Keeper_message;
      state.roster_pane_preference <- Masc_tui_roster_pane.Hidden;
      state.msg_target_keeper_name <- Some "alpha";
      state.msg_live <- Some entry.log;
      state.msg_inflight <- [entry];
      state.msg_history <-
        [chat_entry ~request_id:entry.sent_request.request_id
           ~role:(Tui_types.Message_user (Tui_types.Sent_by_operator {surface=None}))
           ~text:"PROMOTED_QUESTION" ~at:42. ()];
      let occurrence : Live.tool_occurrence =
        {stream_scope=0; block_index=1; provider_message_id=None;
         tool_call_id=Some "read-1"}
      in
      let deltas =
        [ Live.Run_started; Live.Text "EARLY_ANSWER";
          Live.Tool_started {occurrence; tool_name="read_file"};
          Live.Tool_ended {occurrence}; Live.Text "LATER_ANSWER" ]
      in
      List.iteri (fun seq delta ->
        Tui_types.turn_log_add ~now:(43. +. float_of_int seq)
          entry.log ~seq:(Some seq) delta) deltas;
      let count needle text =
        Astring.String.cuts ~sep:needle text |> List.length |> fun n -> n - 1
      in
      let frame () =
        let frame, _ = Masc_tui_render_chat.render_keeper_message state in
        String.concat "\n" frame.Masc_tui_frame_presenter.lines
      in
      let start_clock = Masc_tui_render_chat.keeper_message_clock 42. in
      let running_span = start_clock ^ "→" in
      let settled_span =
        running_span ^ Masc_tui_render_chat.keeper_message_clock 49.
      in
      let check_output ?(ended = false) stage span =
        let screen = frame () in
        List.iter (fun marker -> check int (stage ^ ": " ^ marker) 1
          (count marker screen))
          ["PROMOTED_QUESTION"; "EARLY_ANSWER"; "LATER_ANSWER"];
        check bool (stage ^ ": tool remains visible") true
          (count "read_file" screen > 0);
        check int (stage ^ ": no request span added to speech") 0 (count running_span screen);
        check int (stage ^ ": no timing added to speech") 0 (count span screen);
        Option.iter (fun message ->
          check int (stage ^ ": failure appears once after settlement")
            (if ended then 1 else 0) (count message screen)) failure
      in
      check_output "still running" running_span;
      (* A run that finished records its reply first (KEEPER_REPLY_DETAILS),
         and the record is the last stretch of the attempt -- here the text
         after the tool round. A finish with no reply is how a cancelled
         stream ends, and a log that ends there does not stand for its turn:
         the decoded row speaks for it, so the frame keeps no block to draw. *)
      let terminal = match failure with
        | None -> [ visible_reply "LATER_ANSWER"; Live.Run_finished ]
        | Some message -> [ Live.Run_failed {message} ]
      in
      List.iteri (fun step delta ->
        Tui_types.turn_log_add ~now:49. entry.log ~seq:(Some (5 + step)) delta)
        terminal;
      Tui_types.settle_turn_log state entry;
      state.msg_inflight <- [];
      check_output ~ended:true "settled" settled_span;
      (* A durable page overlaps already streamed text. The frame must keep
         each source once, including after cancellation or a failed run. *)
      let replay : Masc.Keeper_chat_event_log.journaled_event list =
        [ {seq=1; ts=44.; event=Masc.Keeper_chat_events.Text_delta "EARLY_ANSWER"};
          {seq=4; ts=47.; event=Masc.Keeper_chat_events.Text_delta "LATER_ANSWER"} ]
      in
      let _ = Tui_types.turn_log_add_journaled entry.log replay in
      let _ = Tui_types.turn_log_add_journaled entry.log replay in
      check_output ~ended:true "overlapping replay" settled_span;
      Option.iter (fun message ->
        state.msg_history <- state.msg_history @
          [chat_entry ~request_id:entry.sent_request.request_id
             ~role:Tui_types.Message_error ~text:message ~at:49. ()];
        check_output ~ended:true "session error is not duplicated" settled_span)
        failure;
      (* A fresh history-only view has no transcript timing authority. *)
      state.msg_live <- None;
      state.msg_settled_logs <- [];
      state.msg_history <-
        state.msg_history @
        [chat_entry ~request_id:entry.sent_request.request_id
           ~role:Tui_types.Message_keeper ~text:"DURABLE_REPLY" ~at:49. ()];
      check int "durable history does not invent a running span" 0
        (count running_span (frame ())))
      [None; Some "provider failed"; Some "operator interrupted the turn"])
;;

(* A cold pane knows only the accepted user row and the operation journal.
   A failure before the first token must still close that conversation with a
   visible error; partial text remains above the same terminal on replay. *)
let test_replayed_chat_failure_is_visible_without_a_history_error () =
  let cache = Masc_tui_ansi.terminal_size_cache in
  let previous_size = Masc_tui_ansi.get_terminal_size () in
  let set_size size =
    match Masc_tui_render_schedule.Terminal_size_cache.refresh cache
            ~probe:(fun () -> Some size) with
    | Changed _ | Unchanged _ -> ()
  in
  Fun.protect ~finally:(fun () -> set_size previous_size) (fun () ->
    set_size (40, 120);
    List.iter (fun partial ->
      let state = Tui_types.create_state
        ~workspace:"test" ~port:8935 ~refresh_interval:2. () in
      state.view <- Tui_types.Keepers Tui_types.Keeper_message;
      state.roster_pane_preference <- Masc_tui_roster_pane.Hidden;
      state.msg_target_keeper_name <- Some "alpha";
      state.msg_loaded_keeper <- Some "alpha";
      state.msg_loaded <-
        [chat_entry ~request_id:"cancelled-replay"
           ~role:(Tui_types.Message_user
             (Tui_types.Sent_by_operator {surface=None}))
           ~text:"QUESTION_AWAITING_REPLY" ~at:42. ()];
      let log = Tui_types.turn_log_create ~keeper_name:"alpha"
        ~request_id:"cancelled-replay" ~started_at:42. in
      let events =
        [Masc.Keeper_chat_events.Run_started
           {run_id="cancelled-run"; thread_id="keeper:alpha"}]
        @ (if partial then [Masc.Keeper_chat_events.Text_delta "PARTIAL_REPLY"] else [])
        @ [Masc.Keeper_chat_events.Event_error
             {message="operator interrupted the turn"}]
      in
      let journal : Masc.Keeper_chat_event_log.journaled_event list =
        List.mapi
          (fun seq event ->
            {Masc.Keeper_chat_event_log.seq = seq; ts=42. +. float_of_int seq; event})
          events
      in
      let _ = Tui_types.turn_log_add_journaled log journal in
      Log.commit log.tl_log;
      Tui_types.hold_settled_log state log;
      let count needle text =
        List.length (Astring.String.cuts ~sep:needle text) - 1
      in
      let check_frame stage =
        let frame, _ = Masc_tui_render_chat.render_keeper_message state in
        let screen = String.concat "\n" frame.Masc_tui_frame_presenter.lines in
        check int (stage ^ ": accepted question remains") 1
          (count "QUESTION_AWAITING_REPLY" screen);
        check int (stage ^ ": partial text remains") (if partial then 1 else 0)
          (count "PARTIAL_REPLY" screen);
        check int (stage ^ ": the failure is visible exactly once") 1
          (count "operator interrupted the turn" screen);
        check int (stage ^ ": the failure uses the error role") 1
          (count "ERROR" screen)
      in
      check_frame "cold replay";
      let _ = Tui_types.turn_log_add_journaled log journal in
      check_frame "same journal replayed again";
      state.msg_loaded <- state.msg_loaded @
        [chat_entry ~request_id:"cancelled-replay" ~role:Tui_types.Message_error
           ~text:"operator interrupted the turn" ~at:45. ()];
      check_frame "history error arrives afterwards")
      [false; true])
;;

let test_failed_live_sibling_stays_visible_when_focus_changes () =
  let cache = Masc_tui_ansi.terminal_size_cache in
  let previous_size = Masc_tui_ansi.get_terminal_size () in
  let set_size size =
    match Masc_tui_render_schedule.Terminal_size_cache.refresh cache
            ~probe:(fun () -> Some size) with
    | Changed _ | Unchanged _ -> ()
  in
  Fun.protect ~finally:(fun () -> set_size previous_size) (fun () ->
    set_size (40, 120);
    let state = Tui_types.create_state
      ~workspace:"test" ~port:8935 ~refresh_interval:2. () in
    let failed = inflight_with_log ~keeper_name:"alpha" ~started_at:42.
      [Live.Run_started; Live.Run_failed {message="SIBLING_FAILED"}] in
    let other = inflight_with_log ~keeper_name:"alpha" ~started_at:43.
      [Live.Run_started] in
    state.view <- Tui_types.Keepers Tui_types.Keeper_message;
    state.roster_pane_preference <- Masc_tui_roster_pane.Hidden;
    state.msg_target_keeper_name <- Some "alpha";
    state.msg_inflight <- [failed; other];
    state.msg_history <- List.map (fun (item : Tui_types.inflight) ->
      chat_entry ~request_id:item.sent_request.request_id
        ~role:(Tui_types.Message_user
          (Tui_types.Sent_by_operator {surface=None}))
        ~text:"queued question" ~at:item.submitted_at ()) [failed; other];
    let check_failure stage =
      let frame, _ = Masc_tui_render_chat.render_keeper_message state in
      let screen = String.concat "\n" frame.Masc_tui_frame_presenter.lines in
      check int stage 1
        (List.length (Astring.String.cuts ~sep:"SIBLING_FAILED" screen) - 1)
    in
    state.msg_live <- Some failed.log;
    check_failure "focused failure appears once in the live status";
    state.msg_live <- Some other.log;
    check_failure "focus change reveals the sibling failure in its transcript";
    state.msg_live <- Some failed.log;
    check_failure "focus return does not duplicate the failure")
;;

(* An Execute call under tools:full: how the command ended and what it
   printed, and nothing of the envelope around them -- where it ran, the
   sandbox, the capture mode. Output too large to ride inline is named by the
   artifact that holds it. *)
let test_an_execute_call_leads_with_its_exit_and_output () =
  let cache = Masc_tui_ansi.terminal_size_cache in
  let previous_size = Masc_tui_ansi.get_terminal_size () in
  let set_size size =
    match Masc_tui_render_schedule.Terminal_size_cache.refresh cache
            ~probe:(fun () -> Some size) with
    | Changed _ | Unchanged _ -> ()
  in
  Fun.protect ~finally:(fun () -> set_size previous_size) (fun () ->
    set_size (60, 120);
    let draw ?(columns = 120) ?(tool_visibility = Tui_types.Tools_full)
        ?(outcome = Masc_tui_keeper_chat_transcript.Returned)
        ?(execution_id = Some "exec-1") ?(tool_name = "Execute")
        ?(wire_outcome = "ok") ?disposition ?refresh_error
        ?(recorded = true) ?(raw = false) result =
      set_size (60, columns);
      let state =
        Tui_types.create_state ~workspace:"test" ~port:8935 ~refresh_interval:2. ()
      in
      state.view <- Tui_types.Keepers Tui_types.Keeper_message;
      state.roster_pane_preference <- Masc_tui_roster_pane.Hidden;
      state.msg_target_keeper_name <- Some "alpha";
      state.msg_tool_visibility <- tool_visibility;
      let calls =
        `Assoc
          [ "keeper", `String "alpha"; "count", `Int 1; "health", `String "ok"
          ; ( "entries"
            , `List
                [ `Assoc
                    ([ "ts", `Float 1_790_053_724.; "keeper", `String "alpha"
                    ; "tool", `String "Execute"
                    ; "input", `Assoc [ "argv", `List [ `String "git"; `String "log" ] ]
                    ; "output", (if recorded then `String result else `Null)
                    ; "wire_outcome", `String wire_outcome
                    ; "duration_ms", `Float 808.; "execution_id", `String "exec-1"
                    ; "tool_use_id", `String "call-1"; "result_bytes", `Int 1405
                    ] @ (match disposition with
                         | Some value -> ["disposition", `String value]
                         | None -> [])) ] ) ]
      in
      (match Tui_decode.decode_keeper_calls_snapshot ~requested_keeper:"alpha" calls with
       | Ok snapshot ->
           state.keeper_calls_keeper <- Some "alpha";
           state.keeper_calls <- Some snapshot
       | Error detail -> fail ("the calls fixture did not decode: " ^ detail));
      state.keeper_calls_error <- refresh_error;
      let activity =
        Masc_tui_keeper_chat_transcript.make_tool_activity ?execution_id
          ~call_id:(Some "call-1") ~tool_name
          ~args:{|{"argv":["git","log"]}|} ~outcome
          ~duration:None ()
      in
      state.msg_history <-
        [ { (chat_entry ~request_id:"tui-01a0c788-43a7" ~role:Tui_types.Message_tool
               ~text:"Execute git log" ~at:1_790_053_724. ())
            with Tui_types.me_keeper_name = "alpha"
               ; me_tool_block =
                   Some (Masc_tui_keeper_chat_transcript.tool_block [ activity ]) } ];
      let frame, _ = Masc_tui_render_chat.render_keeper_message state in
      let lines = frame.Masc_tui_frame_presenter.lines in
      if raw then lines else List.map Masc_tui_theme.strip_sgr lines
    in
    let plain =
      draw
        {|{"ok":true,"status":{"kind":"exit","code":0},"cwd":"/p/alpha","output_completeness":"capture_only","output":"9feab5497  fix(test): pass\n272394615  feat(keeper): trim","typed":true,"execution_time_ms":808,"via":"microvm"}|}
    in
    let has affix = List.exists (Astring.String.is_infix ~affix) plain in
    let screen = String.concat "\n" plain in
    check bool ("how it ended and how long it ran:\n" ^ screen) true
      (has "exit 0 \xc2\xb7 808 ms");
    check bool "each line it printed" true
      (has "9feab5497  fix(test): pass" && has "272394615  feat(keeper): trim");
    List.iter
      (fun member ->
        check bool (member ^ " is not drawn:\n" ^ screen) false (has member))
      [ "context"; "output_completeness"; "capture_only"; "microvm"; "/p/alpha" ];
    let digest = "9f3a12c4d5e6" ^ String.make 52 '0' in
    let plain =
      draw
        (Printf.sprintf
           {|{"ok":true,"status":{"kind":"exit","code":0},"output_completeness":"complete","output_artifact":{"_blob":{"sha256":%S,"bytes":48213,"mime":"text/plain","preview":"a"}},"typed":true,"execution_time_ms":2400}|}
           digest)
    in
    let screen = String.concat "\n" plain in
    check bool ("a stored output names its artifact:\n" ^ screen) true
      (List.exists
         (Astring.String.is_infix
            ~affix:"artifact sha256:9f3a12c4d5e6\xe2\x80\xa6 \xc2\xb7 48213 bytes")
         plain);
    (* A long output keeps its head; the rest is a count and where to read
       it whole. *)
    let printed = String.concat "\\n" (List.init 30 (Printf.sprintf "row %02d")) in
    let plain =
      draw
        (Printf.sprintf
           {|{"ok":true,"status":{"kind":"exit","code":0},"output":"%s","typed":true,"execution_time_ms":5}|}
           printed)
    in
    let screen = String.concat "\n" plain in
    let has affix = List.exists (Astring.String.is_infix ~affix) plain in
    check bool ("the head is drawn:\n" ^ screen) true (has "row 07");
    check bool "the rest is not" false (has "row 08");
    check bool "the fold says how much and where" true
      (has "\xe2\x80\xa6 +22 lines \xc2\xb7 Keeper Calls (t)");
    let plain =
      draw ~tool_visibility:Tui_types.Tools_results
        {|{"ok":true,"status":{"kind":"exit","code":0},"output":"RESULT_PREVIEW_123","typed":true,"execution_time_ms":5}|}
    in
    let has affix = List.exists (Astring.String.is_infix ~affix) plain in
    check bool "results mode shows the call and its short output" true
      (has "↩ Execute" && has "RESULT_PREVIEW_123");
    List.iter
      (fun field ->
        check bool ("results mode omits " ^ field) false (has field))
      [ "schedule"; "input"; "identity"; "execution=" ];
    let plain =
      draw ~tool_visibility:Tui_types.Tools_results
        ~outcome:Masc_tui_keeper_chat_transcript.Never_returned
        {|{"ok":true,"status":{"kind":"exit","code":0},"output":"LATE_RESULT_456","typed":true,"execution_time_ms":5}|}
    in
    let has affix = List.exists (Astring.String.is_infix ~affix) plain in
    check bool ("a call-log result is named despite a missing turn result:\n" ^ String.concat "\n" plain) true
      (has "in call log" && has "LATE_RESULT_456");
    let plain =
      draw ~tool_visibility:Tui_types.Tools_results ~execution_id:None
        {|{"ok":true,"status":{"kind":"exit","code":0},"output":"UNJOINED_RESULT","typed":true}|}
    in
    let has affix = List.exists (Astring.String.is_infix ~affix) plain in
    check bool "unjoined result explains why no preview appears" true
      (has "no execution id" && not (has "UNJOINED_RESULT"));
    let plain =
      draw ~tool_visibility:Tui_types.Tools_results
        {|{"ok":false,"status":{"kind":"exit","code":1},"output":"command failed","typed":true,"execution_time_ms":5}|}
    in
    let has affix = List.exists (Astring.String.is_infix ~affix) plain in
    check bool "a received failing Execute result has a neutral mark" true
      (has "↩ Execute" && has "exit 1" && not (has "✓ Execute"));
    List.iter (fun outcome ->
      List.iter (fun (wire_outcome, disposition) ->
        let plain = draw ~tool_visibility:Tui_types.Tools_results ~outcome
          ~wire_outcome ?disposition "DURABLE_FAILURE" in
        let screen = String.concat "\n" plain in
        check bool ("durable failure precedes transcript receipt:\n" ^ screen) true
          (List.exists (Astring.String.is_infix ~affix:"✗ Execute") plain
           && List.exists (Astring.String.is_infix ~affix:"failed") plain
           && not (List.exists (Astring.String.is_infix ~affix:"↩ Execute") plain)))
        [ "error", None; "ok", Some "failed" ])
      [ Masc_tui_keeper_chat_transcript.Returned; Masc_tui_keeper_chat_transcript.Never_returned ];
    let full_failure =
      draw ~tool_visibility:Tui_types.Tools_full
        ~outcome:Masc_tui_keeper_chat_transcript.Never_returned
        ~wire_outcome:"error" "DURABLE_FAILURE"
    in
    check bool
      ("full detail preserves the exact durable failure:\n"
       ^ String.concat "\n" full_failure)
      true
      (List.exists (Astring.String.is_infix ~affix:"FAILED · CALL LOG")
         full_failure);
    List.iter (fun (output, recorded, expected) ->
      let plain = draw ~tool_visibility:Tui_types.Tools_results ~tool_name:"Read"
        ~recorded output in
      check bool ("output presence survives decode and render: " ^ String.concat "\n" plain) true
        (List.exists (Astring.String.is_infix ~affix:expected) plain))
      [ "", true, "(empty result)"; "   ", true, "(empty result)";
        "", false, "result text not recorded" ];
    let plain = draw ~tool_visibility:Tui_types.Tools_results ~tool_name:"Read"
      ~refresh_error:"HTTP 503" "RETAINED_RESULT" in
    check bool "failed refresh retains exact preview and identifies stale evidence" true
      (List.exists (Astring.String.is_infix ~affix:"RETAINED_RESULT") plain
       && List.exists (Astring.String.is_infix ~affix:"results stale") plain);
    List.iter (fun columns ->
      let payload = "0 failed checks · ✗ simulated failure" in
      let rows = draw ~columns ~tool_visibility:Tui_types.Tools_results
        ~tool_name:"Read" ~raw:true payload in
      check bool ("payload is not split into styled status clauses: " ^ String.concat "\n" rows) true
        (List.exists (Astring.String.is_infix ~affix:payload) rows)) [ 90; 140 ];
    List.iter (fun (outcome, stale_status, label) ->
      let plain = draw ~tool_visibility:Tui_types.Tools_results ~tool_name:"Read"
        ~outcome ~raw:true "RECORDED_BEFORE_STREAM_EVENT" in
      let screen = String.concat "\n" plain in
      check bool ("recorded output precedes a stale " ^ label ^ " marker:\n" ^ screen) true
        (List.exists (Astring.String.is_infix ~affix:"in call log") plain
         && List.exists (Astring.String.is_infix ~affix:"RECORDED_BEFORE_STREAM_EVENT") plain
         && not (List.exists (Astring.String.is_infix ~affix:stale_status) plain)))
      [ Masc_tui_keeper_chat_transcript.Started, "starting", "start"
      ; Masc_tui_keeper_chat_transcript.Awaiting_result, "waiting", "wait" ];
    let plain =
      draw ~columns:50 ~tool_visibility:Tui_types.Tools_results
        ~execution_id:None
        ~tool_name:"keeper_artifact_read_with_a_very_long_name"
        {|{"ok":true,"status":{"kind":"exit","code":0},"output":"UNJOINED_RESULT","typed":true}|}
    in
    let has affix = List.exists (Astring.String.is_infix ~affix) plain in
    check bool "narrow results view preserves status and missing-result reason" true
      (has "received" && has "no execution id"))
;;

let test_mismatched_keeper_rows_make_results_incomplete () =
  let cache = Masc_tui_ansi.terminal_size_cache in
  let previous_size = Masc_tui_ansi.get_terminal_size () in
  let set_size size =
    match Masc_tui_render_schedule.Terminal_size_cache.refresh cache
      ~probe:(fun () -> Some size) with Changed _ | Unchanged _ -> ()
  in
  Fun.protect ~finally:(fun () -> set_size previous_size) (fun () ->
    set_size (60, 120);
    let state =
      Tui_types.create_state ~workspace:"test" ~port:8935 ~refresh_interval:2. ()
    in
    state.view <- Tui_types.Keepers Tui_types.Keeper_message;
    state.roster_pane_preference <- Masc_tui_roster_pane.Hidden;
    state.msg_target_keeper_name <- Some "alpha";
    state.msg_tool_visibility <- Tui_types.Tools_results;
    let calls =
      `Assoc
        [ "keeper", `String "alpha"; "count", `Int 1; "health", `String "ok"
        ; ( "entries"
          , `List
              [ `Assoc
                  [ "ts", `Float 1_790_053_724.; "keeper", `String "analyst"
                  ; "tool", `String "Read"; "input", `String "{}"
                  ; "output", `String "FOREIGN_RESULT"
                  ; "wire_outcome", `String "ok"; "duration_ms", `Float 12.
                  ; "execution_id", `String "shadow-exec"
                  ; "tool_use_id", `String "call-shadow"
                  ; "result_bytes", `Int 14
                  ]
              ] )
        ]
    in
    (match Tui_decode.decode_keeper_calls_snapshot ~requested_keeper:"alpha" calls with
     | Ok snapshot ->
         state.keeper_calls_keeper <- Some "alpha";
         state.keeper_calls <- Some snapshot
     | Error detail -> fail ("the calls fixture did not decode: " ^ detail));
    let activity =
      Masc_tui_keeper_chat_transcript.make_tool_activity ?execution_id:(Some "shadow-exec")
        ~call_id:(Some "call-shadow") ~tool_name:"Read" ~args:"{}"
        ~outcome:Masc_tui_keeper_chat_transcript.Returned ~duration:None ()
    in
    state.msg_history <-
      [ { (chat_entry ~request_id:"tui-mismatch" ~role:Tui_types.Message_tool
             ~text:"Read shadow" ~at:1_790_053_724. ()) with
          Tui_types.me_keeper_name = "alpha"
        ; me_tool_block =
            Some (Masc_tui_keeper_chat_transcript.tool_block [ activity ])
        }
      ];
    let frame, _ = Masc_tui_render_chat.render_keeper_message state in
    let plain = List.map Masc_tui_theme.strip_sgr frame.Masc_tui_frame_presenter.lines in
    let screen = String.concat "\n" plain in
    check bool ("a filtered row cannot prove absence:\n" ^ screen) true
      (List.exists (Astring.String.is_infix ~affix:"call log incomplete") plain
       && not (List.exists (Astring.String.is_infix ~affix:"no call-log row") plain)
       && not (List.exists (Astring.String.is_infix ~affix:"FOREIGN_RESULT") plain)))
;;

let test_held_tool_results_follow_async_snapshot_changes () =
  let cache = Masc_tui_ansi.terminal_size_cache in
  let previous_size = Masc_tui_ansi.get_terminal_size () in
  let set_size size =
    match Masc_tui_render_schedule.Terminal_size_cache.refresh cache
      ~probe:(fun () -> Some size) with Changed _ | Unchanged _ -> ()
  in
  Fun.protect ~finally:(fun () -> set_size previous_size) (fun () ->
    set_size (40, 140);
    let state = Tui_types.create_state ~workspace:"test" ~port:8935 ~refresh_interval:2. () in
    state.view <- Tui_types.Keepers Tui_types.Keeper_message;
    state.roster_pane_preference <- Masc_tui_roster_pane.Hidden;
    state.msg_target_keeper_name <- Some "alpha";
    state.msg_tool_visibility <- Tui_types.Tools_results;
    state.keeper_calls_keeper <- Some "alpha";
    state.keeper_calls_loading <- true;
    let occurrence = { Live.stream_scope=0; block_index=0;
      provider_message_id=None; tool_call_id=Some "memo-call" } in
    let log = settled_log ~request_id:"results-memo"
      [ Live.Run_started; Live.Tool_started {occurrence; tool_name="Read"};
        Live.Tool_ended {occurrence}; Live.Tool_result {occurrence; execution_id="memo-exec"};
        visible_reply "MEMO_REPLY"; Live.Run_finished ] in
    state.msg_settled_logs <- [log];
    let render () =
      let frame, _ = Masc_tui_render_chat.render_keeper_message state in
      String.concat "\n" (List.map Masc_tui_theme.strip_sgr frame.Masc_tui_frame_presenter.lines)
    in
    let before = render () in
    check bool ("held result starts loading: " ^ before) true
      (Astring.String.is_infix ~affix:"loading result preview" before);
    let snapshot output =
      match Tui_decode.decode_keeper_calls_snapshot ~requested_keeper:"alpha"
        (`Assoc ["keeper", `String "alpha"; "count", `Int 1; "health", `String "ok";
          "entries", `List [`Assoc ["ts", `Float 101.; "keeper", `String "alpha";
            "tool", `String "Read"; "input", `String "{}"; "output", `String output;
            "wire_outcome", `String "ok"; "execution_id", `String "memo-exec"]]]) with
      | Ok value -> value
      | Error detail -> fail detail
    in
    state.keeper_calls <- Some (snapshot "ASYNC_RESULT_ONE");
    state.keeper_calls_loading <- false;
    check bool "held projection redraws after first async response" true
      (Astring.String.is_infix ~affix:"ASYNC_RESULT_ONE" (render ()));
    state.keeper_calls <- Some (snapshot "ASYNC_RESULT_TWO");
    let updated = render () in
    check bool "new snapshot replaces old held preview without a transcript edit" true
      (Astring.String.is_infix ~affix:"ASYNC_RESULT_TWO" updated
       && not (Astring.String.is_infix ~affix:"ASYNC_RESULT_ONE" updated));
    state.keeper_calls_error <- Some "HTTP 503";
    let stale = render () in
    check bool "retained held result survives a failed refresh" true
      (Astring.String.is_infix ~affix:"ASYNC_RESULT_TWO" stale
       && Astring.String.is_infix ~affix:"results stale" stale))
;;

(* A Librarian that keeps failing is named once on the header while it
   lasts; in summary mode the failures are not rows between the turns. A
   commit after them ends the run, and the header says nothing. *)
let test_a_failing_librarian_is_named_on_the_header () =
  let cache = Masc_tui_ansi.terminal_size_cache in
  let previous_size = Masc_tui_ansi.get_terminal_size () in
  let set_size size =
    match Masc_tui_render_schedule.Terminal_size_cache.refresh cache
            ~probe:(fun () -> Some size) with
    | Changed _ | Unchanged _ -> ()
  in
  Fun.protect ~finally:(fun () -> set_size previous_size) (fun () ->
    set_size (40, 140);
    let state =
      Tui_types.create_state ~workspace:"test" ~port:8935 ~refresh_interval:2. ()
    in
    state.view <- Tui_types.Keepers Tui_types.Keeper_message;
    state.roster_pane_preference <- Masc_tui_roster_pane.Hidden;
    state.msg_target_keeper_name <- Some "alpha";
    let failed at =
      { (chat_entry ~request_id:"" ~role:Tui_types.Message_memory
           ~memory_summary:"Librarian failed \xc2\xb7 exact_execution_failure"
           ~text:"Librarian failed \xc2\xb7 exact_execution_failure" ~at ())
        with Tui_types.me_memory_pass =
               Masc_tui_message_layout.Pass_failed { kind = "exact_execution_failure" } }
    in
    let committed at =
      { (chat_entry ~request_id:"" ~role:Tui_types.Message_memory
           ~memory_summary:"Librarian \xc2\xb7 revision 9" ~text:"revision 9" ~at ())
        with Tui_types.me_memory_pass = Masc_tui_message_layout.Pass_committed }
    in
    let said at text =
      chat_entry ~request_id:(Printf.sprintf "tui-%.0f" at) ~role:Tui_types.Message_keeper
        ~text ~at ()
    in
    let draw history =
      state.msg_history <- history;
      let frame, _ = Masc_tui_render_chat.render_keeper_message state in
      List.map Masc_tui_theme.strip_sgr frame.Masc_tui_frame_presenter.lines
    in
    let at = 1_790_053_724. in
    let plain =
      draw
        [ committed at; said (at +. 10.) "FIRST_TURN"; failed (at +. 20.)
        ; said (at +. 30.) "SECOND_TURN"; failed (at +. 40.) ]
    in
    let screen = String.concat "\n" plain in
    let saying affix = List.filter (Astring.String.is_infix ~affix) plain in
    check int ("the header names the run once:\n" ^ screen) 1
      (List.length (saying "Librarian failing \xc3\x972 since"));
    check bool "with the server's word for how" true
      (List.exists (Astring.String.is_infix ~affix:"exact_execution_failure")
         (saying "Librarian failing"));
    check (list string) "no failure is a row between the turns" []
      (saying "Librarian failed");
    let plain =
      draw [ failed at; said (at +. 10.) "FIRST_TURN"; committed (at +. 20.) ]
    in
    check (list string) "a commit ends the run" []
      (List.filter (Astring.String.is_infix ~affix:"Librarian failing") plain))
;;

(* A committed Memory revision under journal:full: the one-line summary, then
   each fact with its sign and category in a column and the claim wrapped
   under itself. The fence it replaced wrapped every claim back to the sign's
   column, so a revision read as one wall of text. *)
let test_a_journal_revision_draws_its_facts_in_columns () =
  let cache = Masc_tui_ansi.terminal_size_cache in
  let previous_size = Masc_tui_ansi.get_terminal_size () in
  let set_size size =
    match Masc_tui_render_schedule.Terminal_size_cache.refresh cache
            ~probe:(fun () -> Some size) with
    | Changed _ | Unchanged _ -> ()
  in
  Fun.protect ~finally:(fun () -> set_size previous_size) (fun () ->
    set_size (40, 72);
    let state =
      Tui_types.create_state ~workspace:"test" ~port:8935 ~refresh_interval:2. ()
    in
    state.view <- Tui_types.Keepers Tui_types.Keeper_message;
    state.roster_pane_preference <- Masc_tui_roster_pane.Hidden;
    state.msg_target_keeper_name <- Some "alpha";
    let summary = "Librarian \xc2\xb7 revision 454 \xc2\xb7 +1 \xe2\x88\x920 \xc2\xb7 63 retained" in
    let claim =
      "verifier_exact cannot read the GitHub Actions job log, so ancestry alone \
       never satisfies the ran-on-main contract"
    in
    state.msg_history <-
      [ { (chat_entry ~request_id:"" ~role:Tui_types.Message_memory
             ~text:(summary ^ "\n+ [lesson] " ^ claim) ~at:1_790_053_724. ())
          with Tui_types.me_memory_summary = Some summary
             ; me_journal =
                 [ Masc_tui_message_layout.Journal_fact
                     { sign = Journal_added; category = "lesson"; tone = Tone_learning; claim } ] } ];
    let draw visibility =
      state.msg_memory_visibility <- visibility;
      let frame, _ = Masc_tui_render_chat.render_keeper_message state in
      List.map Masc_tui_theme.strip_sgr frame.Masc_tui_frame_presenter.lines
    in
    let full = draw Tui_types.Memory_full in
    let row_with affix = List.find_opt (Astring.String.is_infix ~affix) full in
    (match row_with "+ lesson  verifier_exact", row_with "the ran-on-main contract" with
     | Some first, Some wrapped ->
         let column row affix =
           match Astring.String.find_sub ~sub:affix row with
           | Some index -> Masc_tui_message_layout.display_width (String.sub row 0 index)
           | None -> -1
         in
         check int "the wrapped claim starts under the claim, not under the sign"
           (column first "verifier_exact")
           (column wrapped "the ran-on-main")
     | _ -> fail ("the fact did not draw in columns: " ^ String.concat "\n" full));
    (* The summary wraps at this width; its head is what the row opens on. *)
    check bool "the summary heads the revision" true
      (Option.is_some (row_with "Librarian \xc2\xb7 revision 454"));
    check bool "no bracketed category from the old fence" false
      (Option.is_some (row_with "[lesson]"));
    let summarised = draw Tui_types.Memory_summary in
    check bool "the summary mode draws the one line alone" false
      (List.exists (Astring.String.is_infix ~affix:"verifier_exact") summarised))
;;

(* A keeper's turn heading is its mark, the rule and the clock. It drew the
   request id after the mark, and since #37754 took the name away that id
   inherited the mark's bold colour. The id groups the rows of a turn, which
   the rows already show; the mark's style ends at the mark. *)
let test_a_nameless_heading_is_the_mark_and_the_rule () =
  let cache = Masc_tui_ansi.terminal_size_cache in
  let previous_size = Masc_tui_ansi.get_terminal_size () in
  let set_size size =
    match Masc_tui_render_schedule.Terminal_size_cache.refresh cache
            ~probe:(fun () -> Some size) with
    | Changed _ | Unchanged _ -> ()
  in
  Fun.protect ~finally:(fun () -> set_size previous_size) (fun () ->
    set_size (40, 96);
    let state =
      Tui_types.create_state ~workspace:"test" ~port:8935 ~refresh_interval:2. ()
    in
    state.view <- Tui_types.Keepers Tui_types.Keeper_message;
    state.roster_pane_preference <- Masc_tui_roster_pane.Hidden;
    state.msg_target_keeper_name <- Some "alpha";
    state.msg_origin_display <- Masc_tui_message_layout.Origin_row;
    let request = "tui-01a0c788-43a7" in
    state.msg_history <-
      [ { (chat_entry ~request_id:request ~role:Tui_types.Message_keeper
             ~text:"REPLY" ~at:1_790_053_724. ())
          with Tui_types.me_keeper_name = "alpha" } ];
    let frame, _ = Masc_tui_render_chat.render_keeper_message state in
    let lines = frame.Masc_tui_frame_presenter.lines in
    check bool "no row spells the request id" false
      (List.exists (Astring.String.is_infix ~affix:request) lines);
    let mark = "\xe2\x97\x8f" in
    match
      List.find_opt
        (fun line ->
          String.starts_with ~prefix:mark (String.trim (Masc_tui_theme.strip_sgr line)))
        lines
    with
    | None -> fail "no heading opens the turn"
    | Some line -> (
        match
          Astring.String.find_sub ~sub:mark line,
          Astring.String.find_sub ~sub:Masc_tui_theme.Box.h line
        with
        | Some at_mark, Some at_rule when at_mark < at_rule ->
            let between = String.sub line at_mark (at_rule - at_mark) in
            check bool "the mark's style ends before the rule" true
              (Astring.String.is_infix ~affix:"\027[0m" between
               || not (String.contains between '\027'))
        | _ -> fail ("the heading does not run from its mark into a rule: " ^ String.escaped line)))
;;

(* A line someone else wrote is set apart from the operator and the keeper
   talking by a bar down its left edge and a two-cell step (RFC
   chat-turn-rail-and-side-lanes §4.6), at any width. *)
let test_an_arrival_reads_behind_a_bar () =
  let cache = Masc_tui_ansi.terminal_size_cache in
  let previous_size = Masc_tui_ansi.get_terminal_size () in
  let set_size size =
    match Masc_tui_render_schedule.Terminal_size_cache.refresh cache
            ~probe:(fun () -> Some size) with
    | Changed _ | Unchanged _ -> ()
  in
  Fun.protect ~finally:(fun () -> set_size previous_size) (fun () ->
    let state =
      Tui_types.create_state ~workspace:"test" ~port:8935 ~refresh_interval:2. ()
    in
    state.view <- Tui_types.Keepers Tui_types.Keeper_message;
    state.roster_pane_preference <- Masc_tui_roster_pane.Hidden;
    state.msg_target_keeper_name <- Some "alpha";
    state.msg_history <-
      [ { (chat_entry ~request_id:"tui-01a0c788-0001"
             ~role:(Tui_types.Message_user (Tui_types.Sent_by_operator { surface = None }))
             ~text:"OPERATOR_ASKS" ~at:1_790_053_724. ())
          with Tui_types.me_keeper_name = "alpha" }
      ; { (chat_entry ~request_id:"tui-01a0c788-0002"
             ~role:
               (Tui_types.Message_user
                  (Tui_types.Sent_by_other { speaker = "pangyo"; surface = None }))
             ~text:"ARRIVAL_SAYS" ~at:1_790_053_784. ())
          with Tui_types.me_keeper_name = "alpha" } ];
    let row_of cols needle =
      set_size (40, cols);
      let frame, _ = Masc_tui_render_chat.render_keeper_message state in
      let plain = List.map Masc_tui_theme.strip_sgr frame.Masc_tui_frame_presenter.lines in
      match List.find_opt (Astring.String.is_infix ~affix:needle) plain with
      | Some row -> row
      | None -> fail (needle ^ " was not drawn: " ^ String.concat "\n" plain)
    in
    let bar = "\xe2\x96\x8e" in
    List.iter
      (fun cols ->
        check bool "the arrival reads behind the bar" true
          (Astring.String.is_infix ~affix:(bar ^ "ARRIVAL_SAYS") (row_of cols "ARRIVAL_SAYS"));
        check bool "the operator draws no bar" false
          (Astring.String.is_infix ~affix:bar (row_of cols "OPERATOR_ASKS")))
      [ 140; 90 ])
;;

(* The origin heading under Ctrl-F's metadata:full: the name whole at the
   left, the clock at the right edge, a rule between. The pane's own keeper
   is not named on its headings -- the breadcrumb says whose chat it is -- so
   its turn opens on the mark and the rule, and a later minute of the same
   turn is the rule and the clock alone. *)
let test_origin_row_heading_spells_the_name_and_ends_on_the_clock () =
  let cache = Masc_tui_ansi.terminal_size_cache in
  let previous_size = Masc_tui_ansi.get_terminal_size () in
  let set_size size =
    match Masc_tui_render_schedule.Terminal_size_cache.refresh cache
            ~probe:(fun () -> Some size) with
    | Changed _ | Unchanged _ -> ()
  in
  Fun.protect ~finally:(fun () -> set_size previous_size) (fun () ->
    let rows, cols = 40, 96 in
    set_size (rows, cols);
    let keeper = "goo-yang-bong" in
    let other = "e-masc-the-leader-of-this-workspace" in
    let state =
      Tui_types.create_state ~workspace:"test" ~port:8935 ~refresh_interval:2. ()
    in
    state.view <- Tui_types.Keepers Tui_types.Keeper_message;
    state.roster_pane_preference <- Masc_tui_roster_pane.Hidden;
    state.msg_target_keeper_name <- Some keeper;
    state.msg_origin_display <- Masc_tui_message_layout.Origin_row;
    let at = 1_790_053_724. in
    let clock_of at =
      let t = Unix.localtime at in
      Printf.sprintf "%02d:%02d:%02d" t.Unix.tm_hour t.Unix.tm_min t.Unix.tm_sec
    in
    let request = "tui-01a0c788-43a7" in
    let inbound_row ~speaker ~request_id ~at text =
      { (chat_entry ~request_id
           ~role:
             (Tui_types.Message_user
                (Tui_types.Sent_by_other { speaker; surface = None }))
           ~text ~at ())
        with Tui_types.me_keeper_name = keeper }
    in
    let keeper_row ~at text =
      { (chat_entry ~request_id:request ~role:Tui_types.Message_keeper ~text ~at ())
        with Tui_types.me_keeper_name = keeper }
    in
    (* A minute and seven seconds later: inside one turn the clock row is
       drawn where the minute moved. *)
    let later = at +. 67. in
    state.msg_history <-
      [ inbound_row ~speaker:other ~request_id:"tui-01a0c788-0000" ~at "ASKED";
        keeper_row ~at "FIRST_PART";
        keeper_row ~at:later "SECOND_PART" ];
    let frame, _ = Masc_tui_render_chat.render_keeper_message state in
    let plain = List.map Masc_tui_theme.strip_sgr frame.Masc_tui_frame_presenter.lines in
    let inner = Masc_tui_ansi.framed_inner_width cols in
    let heading_ending_on clock =
      List.filter
        (fun line -> Astring.String.is_suffix ~affix:clock (String.trim line))
        plain
      |> List.map String.trim
    in
    (* The breadcrumb above the pane names the keepers too; the heading is
       the row that names one and ends on the clock. *)
    let trimmed =
      match
        List.find_opt (Astring.String.is_infix ~affix:other) (heading_ending_on (clock_of at))
      with
      | Some line -> line
      | None -> fail ("no heading spells the sender's name whole: " ^ String.concat "\n" plain)
    in
    check bool "the heading does not open on the clock" false
      (String.starts_with ~prefix:"[" trimmed);
    (* The arrival steps in and draws its bar; the trim takes the step and
       the space in front of the bar, and the rule still runs to the clock at
       the pane's edge. *)
    let arrival_step = Masc_tui_message_layout.inbound_indent_cells in
    let arrival_blank = arrival_step + 1 in
    check int "the rule fills the row to the clock" inner
      (arrival_blank + Masc_tui_message_layout.display_width trimmed);
    check bool "the name and the clock are joined by a rule" true
      (Astring.String.is_infix ~affix:(Masc_tui_theme.Box.h ^ " " ^ clock_of at) trimmed);
    let own =
      match
        List.find_opt
          (String.starts_with ~prefix:"\xe2\x97\x8f")
          (heading_ending_on (clock_of at))
      with
      | Some line -> line
      | None -> fail ("no heading opens the keeper's turn: " ^ String.concat "\n" plain)
    in
    check bool "the pane's own keeper is not named on its heading" false
      (Astring.String.is_infix ~affix:keeper own);
    check bool "no heading spells a request id" false
      (List.exists (Astring.String.is_infix ~affix:request) (heading_ending_on (clock_of at)));
    check bool "the mark runs straight into the rule" true
      (String.starts_with ~prefix:("\xe2\x97\x8f " ^ Masc_tui_theme.Box.h) own);
    let continuation =
      match heading_ending_on (clock_of later) with
      | [ line ] -> line
      | lines ->
          fail
            (Printf.sprintf "expected one row saying when the turn went on, got %d: %s"
               (List.length lines) (String.concat "\n" plain))
    in
    check bool "a continuation is the rule and the clock alone" true
      (String.starts_with ~prefix:Masc_tui_theme.Box.h continuation);
    check int "a continuation also fills the row" inner
      (Masc_tui_message_layout.display_width continuation);
    (* A lead one cell short of the room has no cell for a rule and still
       fills the row: the clock stays in the column every other heading
       puts it in. The lead is mark, space and name, so the name is sized to
       land at room - 1. *)
    let clock_cells = String.length (clock_of at) + 1 in
    let room = inner - clock_cells in
    let bar_cells = Masc_tui_message_layout.display_width " \xe2\x96\x8e" in
    let exact = String.make (room - 1 - 2 - arrival_step - bar_cells) 'k' in
    state.msg_history <- [ inbound_row ~speaker:exact ~request_id:request ~at "EXACT_BODY" ];
    let frame, _ = Masc_tui_render_chat.render_keeper_message state in
    let plain = List.map Masc_tui_theme.strip_sgr frame.Masc_tui_frame_presenter.lines in
    (match
       List.find_opt
         (fun line ->
           Astring.String.is_infix ~affix:exact line
           && Astring.String.is_suffix ~affix:(clock_of at) (String.trim line))
         plain
     with
     | Some line ->
         check int "a lead one short of the room still fills the row" inner
           (arrival_blank + Masc_tui_message_layout.display_width (String.trim line))
     | None -> fail "no heading spells the exact-width name");
    (* A turn that opens on a tool block names its activity lane. Origin_row
       uses the Keeper's turn mark, then TOOLS and the right-aligned clock. *)
    state.msg_history <-
      [ { (chat_entry ~request_id:request ~role:Tui_types.Message_tool
             ~text:"read_file a.ml" ~at ())
          with Tui_types.me_keeper_name = keeper } ];
    let frame, _ = Masc_tui_render_chat.render_keeper_message state in
    let plain = List.map Masc_tui_theme.strip_sgr frame.Masc_tui_frame_presenter.lines in
    (match
       List.find_opt
         (fun line -> Astring.String.is_suffix ~affix:(clock_of at) (String.trim line))
         plain
     with
     | Some line ->
         check bool "the tool heading has no spurious separator" false
           (Astring.String.is_infix ~affix:"\xc2\xb7" line);
         check bool "the turn mark and tool lane name precede the rule" true
           (String.starts_with ~prefix:("● TOOLS " ^ Masc_tui_theme.Box.h)
              (String.trim line))
     | None -> fail "no heading for the tool row"))
;;

(* A folded reasoning block is one short row: the count and the key. It was
   a 61-cell sentence drawn once a round, the widest row of a turn that
   reasons between every call. *)
let test_a_folded_reasoning_block_is_the_count_and_the_key () =
  let cache = Masc_tui_ansi.terminal_size_cache in
  let previous_size = Masc_tui_ansi.get_terminal_size () in
  let set_size size =
    match Masc_tui_render_schedule.Terminal_size_cache.refresh cache
            ~probe:(fun () -> Some size) with
    | Changed _ | Unchanged _ -> ()
  in
  Fun.protect ~finally:(fun () -> set_size previous_size) (fun () ->
    set_size (40, 100);
    let state =
      Tui_types.create_state ~workspace:"test" ~port:8935 ~refresh_interval:2. ()
    in
    state.view <- Tui_types.Keepers Tui_types.Keeper_message;
    state.roster_pane_preference <- Masc_tui_roster_pane.Hidden;
    state.msg_target_keeper_name <- Some "alpha";
    state.msg_reasoning_visibility <- Tui_types.Reasoning_folded;
    state.msg_history <-
      [ chat_entry ~request_id:"tui-01a0c788-43a7" ~role:Tui_types.Message_thinking
          ~text:"read the caller\n\nthen the test\ncheck main" ~at:1_790_053_724. () ];
    let frame, _ = Masc_tui_render_chat.render_keeper_message state in
    let plain = List.map Masc_tui_theme.strip_sgr frame.Masc_tui_frame_presenter.lines in
    let has affix = List.exists (Astring.String.is_infix ~affix) plain in
    check bool "the count of lines with text and the key" true
      (has "Reasoning \xc2\xb7 3 lines folded \xc2\xb7 Ctrl-R");
    check bool "no sentence about how to expand it" false (has "/thinking");
    check bool "the reasoning itself stays folded" false (has "then the test"))
;;

(* A turn this pane did not open -- a TUI restarted mid-turn, a turn another
   surface opened -- is drawn from its journal while it runs. The journal
   reads fed a log that was held and drawn nowhere until the turn ended, so
   the operator read the reply one line at a time off the footer's turn
   preview (#36244). Now the log is an open block in the pane, the preview's
   tail is left out of the footer while the pane draws the same text, and
   the moment the journal says the turn ended the block is a settled one. *)
let test_an_observed_running_turn_is_drawn_from_its_journal () =
  let cache = Masc_tui_ansi.terminal_size_cache in
  let previous_size = Masc_tui_ansi.get_terminal_size () in
  let set_size size =
    match Masc_tui_render_schedule.Terminal_size_cache.refresh cache
            ~probe:(fun () -> Some size) with
    | Changed _ | Unchanged _ -> ()
  in
  Fun.protect ~finally:(fun () -> set_size previous_size) (fun () ->
    set_size (40, 100);
    let state =
      Tui_types.create_state ~tool_visibility:Tui_types.Tools_full
        ~workspace:"test" ~port:8935 ~refresh_interval:2. ()
    in
    state.view <- Tui_types.Keepers Tui_types.Keeper_message;
    state.roster_pane_preference <- Masc_tui_roster_pane.Hidden;
    state.msg_target_keeper_name <- Some "alpha";
    state.msg_loaded_keeper <- Some "alpha";
    state.msg_loaded <-
      [ chat_entry ~request_id:"op-1"
          ~role:(Tui_types.Message_user (Tui_types.Sent_by_operator { surface = None }))
          ~text:"asked" ~at:100. () ];
    let running = journal_log ~request_id:"op-1" ~started_at:100. ~finished:false () in
    Tui_types.hold_settled_log state running;
    let preview : Tui_decode.keeper_turn_preview =
      { ktp_status_text = "glm · receiving response"; ktp_updated_at_unix = 130.
      ; ktp_text_tail = "said"; ktp_last_tool = None }
    in
    state.keeper_turns <-
      [ { Tui_decode.ktr_chat_control_token = None; ktr_keeper_name = "alpha"
        ; ktr_state = Tui_decode.Keeper_turn_running
            { lane = Tui_decode.Turn_lane_chat_operation; started_at_unix = 100.
            ; interrupt_token = "t"; turn_ref = None; preview = Some preview } } ];
    check (list string) "the running turn's log is observed, not settled"
      [ "op-1" ]
      (List.map Tui_types.turn_log_request_id
         (Tui_types.observed_logs_for_keeper state "alpha"));
    let count needle text =
      Astring.String.cuts ~sep:needle text |> List.length |> fun n -> n - 1
    in
    let screen () =
      let frame, _ = Masc_tui_render_chat.render_keeper_message state in
      String.concat "\n"
        (List.map Masc_tui_theme.strip_sgr frame.Masc_tui_frame_presenter.lines)
    in
    let running_screen = screen () in
    check int "the question stays" 1 (count "asked" running_screen);
    check bool "the pane draws the turn's text" true
      (Tui_types.observed_turn_text_drawn state "alpha");
    check int "the journal's reply text is in the pane once" 1
      (count "said" running_screen);
    check int "the footer does not repeat the tail as Latest output" 0
      (count "Latest output" running_screen);
    check bool "the footer still says a turn is running, by lane and age" true
      (Astring.String.is_infix ~affix:"chat_operation \xc2\xb7 " running_screen);
    check int "the turn's rail has not closed" 0
      (count (Masc_tui_message_layout.turn_rail_glyph Masc_tui_message_layout.Rail_closes)
         running_screen);
    state.msg_tool_visibility <- Tui_types.Tools_compact;
    let compact_screen = screen () in
    check bool "compact status still reports the observed running turn" true
      (Astring.String.is_infix ~affix:"기존 작업 처리 중" compact_screen);
    check int "compact mode keeps the journal reply once" 1
      (count "said" compact_screen);
    state.msg_tool_visibility <- Tui_types.Tools_full;
    (* The next journal read brings the end of the turn: the log now stands
       for it, leaves the observed set, and is drawn as a settled block. *)
    let _ = Tui_types.turn_log_add_journaled running
      [ line 3 100.15 (journal_reply "said"); line 4 100.2 (E.Run_finished { run_id = "r" }) ] in
    Tui_types.hold_settled_log state running;
    check (list string) "a finished turn is no longer observed" []
      (List.map Tui_types.turn_log_request_id
         (Tui_types.observed_logs_for_keeper state "alpha"));
    state.keeper_turns <-
      [ { Tui_decode.ktr_chat_control_token = None; ktr_keeper_name = "alpha"
        ; ktr_state = Tui_decode.Keeper_turn_idle } ];
    let settled_screen = screen () in
    check int "the reply is still drawn once" 1 (count "said" settled_screen);
    check bool "and the turn's rail closes" true
      (count (Masc_tui_message_layout.turn_rail_glyph Masc_tui_message_layout.Rail_closes)
         settled_screen > 0
       || count (Masc_tui_message_layout.turn_rail_glyph Masc_tui_message_layout.Rail_stands)
            settled_screen > 0))
;;

(* The pane's own turn is the live block while its request is in flight, and
   is not observed beside it. A stream the pane opened and lost settles
   without hearing the end, [msg_live] lets go of it, and from then on it is
   observed: the journal reads feed that log in place until the turn ends. *)
let test_the_panes_own_turn_is_live_in_flight_and_observed_once_cut () =
  let state =
    Tui_types.create_state ~workspace:"test" ~port:8935 ~refresh_interval:2. ()
  in
  state.msg_target_keeper_name <- Some "alpha";
  let entry =
    inflight_with_log ~keeper_name:"alpha" ~started_at:10.
      [ Live.Run_started; Live.Text "partial" ]
  in
  state.msg_live <- Some entry.log;
  state.msg_inflight <- [ entry ];
  check (list string) "in flight: the live block, not observed" []
    (List.map Tui_types.turn_log_request_id
       (Tui_types.observed_logs_for_keeper state "alpha"));
  Tui_types.settle_turn_log state entry;
  state.msg_inflight <- [];
  check bool "the cut log is held" true (List.memq entry.log state.msg_settled_logs);
  check bool "the pane let go of it" true (Option.is_none state.msg_live);
  check (list string) "cut and settled: observed, for the journal reads to feed"
    [ entry.sent_request.request_id ]
    (List.map Tui_types.turn_log_request_id
       (Tui_types.observed_logs_for_keeper state "alpha"))
;;

(* A durable final row can arrive before the journal's terminal page, and a
   pruned journal can never supply that page. Both retain the earlier observed
   content; completion and observation availability are independent facts. *)
let test_partial_observation_survives_history_ending_and_unavailable_journal () =
  let observed state =
    List.map Tui_types.turn_log_request_id
      (Tui_types.observed_logs_for_keeper state "alpha")
  in
  let fresh () =
    let state =
      Tui_types.create_state ~workspace:"test" ~port:8935 ~refresh_interval:2. ()
    in
    state.msg_target_keeper_name <- Some "alpha";
    state.msg_loaded_keeper <- Some "alpha";
    Tui_types.hold_settled_log state
      (journal_log ~request_id:"op-1" ~started_at:100. ~finished:false ());
    state
  in
  let state = fresh () in
  check (list string) "running: observed" [ "op-1" ] (observed state);
  Tui_types.remember_journal_unavailable state (operation_key "op-1");
  check (list string) "unavailable journal retains the observed content" ["op-1"]
    (observed state);
  let log = List.hd state.msg_settled_logs in
  check bool "unavailability does not claim completion" false
    (Tui_types.observed_log_has_ended state log);
  check bool "unavailability is explicit" true
    (Tui_types.observed_log_is_unavailable state log);
  let state = fresh () in
  state.msg_loaded <-
    [ chat_entry ~request_id:"op-1" ~role:Tui_types.Message_error
        ~text:"provider failed at settle" ~at:130. () ];
  check (list string) "failure retains the earlier observed content" ["op-1"] (observed state);
  check bool "durable failure alone does not close journal observation" false
    (Tui_types.observed_log_has_ended state (List.hd state.msg_settled_logs));
  let state = fresh () in
  state.msg_loaded <-
    [ chat_entry ~request_id:"op-1" ~role:Tui_types.Message_keeper
        ~text:"the recorded reply" ~at:130. () ];
  check (list string) "reply retains the earlier observed content" ["op-1"] (observed state);
  check bool "durable reply alone does not close journal observation" false
    (Tui_types.observed_log_has_ended state (List.hd state.msg_settled_logs))
;;

let test_observed_history_handoff_keeps_progress_and_one_final_reply () =
  let cache = Masc_tui_ansi.terminal_size_cache in
  let previous_size = Masc_tui_ansi.get_terminal_size () in
  let set_size size =
    match Masc_tui_render_schedule.Terminal_size_cache.refresh cache
            ~probe:(fun () -> Some size) with
    | Changed _ | Unchanged _ -> ()
  in
  Fun.protect ~finally:(fun () -> set_size previous_size) (fun () ->
    set_size (60, 120);
    let state = Tui_types.create_state ~workspace:"test" ~port:8935
        ~refresh_interval:2. () in
    state.view <- Tui_types.Keepers Tui_types.Keeper_message;
    state.roster_pane_preference <- Masc_tui_roster_pane.Hidden;
    state.msg_target_keeper_name <- Some "alpha";
    state.msg_loaded_keeper <- Some "alpha";
    let occurrence : Live.tool_occurrence =
      {stream_scope = 0; block_index = 0; provider_message_id = None
      ; tool_call_id = Some "handoff-tool"} in
    let log = settled_log ~request_id:"handoff"
        [Live.Run_started; Live.Text "earlier progress stays visible"
        ; Live.Tool_started {occurrence; tool_name = "read_handoff_evidence"}
        ; Live.Tool_ended {occurrence}] in
    Tui_types.hold_settled_log state log;
    state.msg_loaded <-
      [chat_entry ~request_id:"handoff" ~role:Tui_types.Message_keeper
         ~text:"final answer stays once" ~at:130. ()];
    let screen () =
      let frame, _ = Masc_tui_render_chat.render_keeper_message state in
      String.concat "\n"
        (List.map Masc_tui_theme.strip_sgr frame.Masc_tui_frame_presenter.lines)
    in
    let count needle text =
      List.length (Astring.String.cuts ~sep:needle text) - 1
    in
    let assert_handoff label =
      let text = screen () in
      check int (label ^ ": earlier progress survives") 1
        (count "earlier progress stays visible" text);
      check int (label ^ ": final reply appears once") 1
        (count "final answer stays once" text);
      check bool (label ^ ": tools remain visible") true
        (Astring.String.is_infix ~affix:"read_handoff_evidence" text);
      check bool (label ^ ": an old partial block does not hide new progress") false
        (Tui_types.observed_turn_text_drawn state "alpha")
    in
    assert_handoff "durable reply before ending journal";
    Tui_types.remember_journal_unavailable state (operation_key "handoff");
    assert_handoff "unavailable journal";
    (* The tool round separates earlier progress from the terminal stretch.
       Reply_details replaces only the latter, even before finish. *)
    Tui_types.turn_log_add ~now:130. log ~seq:None
      (Live.Text "terminal stretch");
    Tui_types.turn_log_add ~now:130. log ~seq:None
      (visible_reply "final answer stays once");
    Tui_types.hold_settled_log state log;
    assert_handoff "reply details before finish";
    Tui_types.turn_log_add ~now:131. log ~seq:None Live.Run_finished;
    Tui_types.hold_settled_log state log;
    assert_handoff "finished journal")
;;

(* A journal log bound to the execution the pane's live turn is bound to is
   that turn, drawn already as the live block. The settled blocks apply the
   same test. *)
let test_a_journal_log_of_the_live_execution_is_not_observed () =
  let state =
    Tui_types.create_state ~workspace:"test" ~port:8935 ~refresh_interval:2. ()
  in
  state.msg_target_keeper_name <- Some "alpha";
  let live =
    inflight_with_log ~keeper_name:"alpha" ~started_at:10.
      [ Live.Run_started; Live.Text "shared answer" ]
  in
  let execution_id = live.sent_request.request_id in
  Tui_types.turn_log_add ~now:11. live.log ~seq:(Some 2)
    (Live.Batch_bound { operation_id = execution_id; execution_id });
  state.msg_live <- Some live.log;
  state.msg_inflight <- [ live ];
  let follower =
    Tui_types.turn_log_create ~keeper_name:"alpha" ~request_id:"batch-follower"
      ~started_at:10.
  in
  List.iteri
    (fun seq delta -> Tui_types.turn_log_add ~now:10. follower ~seq:(Some seq) delta)
    [ Live.Run_started
    ; Live.Batch_bound { operation_id = "batch-follower"; execution_id }
    ; Live.Text "shared answer" ];
  Log.commit follower.Tui_types.tl_log;
  Tui_types.hold_settled_log state follower;
  check string "the follower is bound to the live execution" execution_id
    (Tui_types.turn_log_execution_id follower);
  check (list string) "and is not observed beside the live block" []
    (List.map Tui_types.turn_log_request_id
       (Tui_types.observed_logs_for_keeper state "alpha"))
;;

let test_hidden_partial_reply_cannot_remove_the_durable_reply () =
  let state = Tui_types.create_state ~workspace:"test" ~port:8935
      ~refresh_interval:2. () in
  state.msg_target_keeper_name <- Some "alpha";
  state.msg_loaded_keeper <- Some "alpha";
  let live = inflight_with_log ~keeper_name:"alpha" ~started_at:100.
      [Live.Run_started; Live.Text "still catching up"] in
  let execution_id = live.sent_request.request_id in
  (* This follower is hidden because the live stream has greater coverage,
     not merely because both are bound to the same execution. *)
  Tui_types.turn_log_add ~now:110. live.log ~seq:(Some 3) (Live.Text "");
  let follower = Tui_types.turn_log_create ~keeper_name:"alpha"
      ~request_id:"hidden-follower" ~started_at:100. in
  List.iteri
    (fun seq delta -> Tui_types.turn_log_add ~now:110. follower
        ~seq:(Some seq) delta)
    [Live.Run_started
    ; Live.Batch_bound {operation_id = "hidden-follower"; execution_id}
    ; visible_reply "durable final answer"];
  Log.commit follower.Tui_types.tl_log;
  Tui_types.hold_settled_log state follower;
  state.msg_loaded <-
    [chat_entry ~request_id:execution_id ~role:Tui_types.Message_keeper
       ~text:"durable final answer" ~at:110. ()];
  state.msg_live <- Some live.log;
  state.msg_inflight <- [live];
  let rows = Tui_types.chat_rows_for state "alpha" in
  check (list string) "hidden follower cannot suppress the only final reply"
    ["durable final answer"] (List.map (fun row -> row.Tui_types.me_text) rows);
  check bool "unchanged ownership reuses the memo" true
    (rows == Tui_types.chat_rows_for state "alpha");
  state.msg_live <- None;
  state.msg_inflight <- [];
  let observed_rows = Tui_types.chat_rows_for state "alpha" in
  check bool "observed ownership invalidates the rows memo" false
    (rows == observed_rows);
  check int "visible follower now owns the final reply" 0 (List.length observed_rows);
  state.msg_live <- Some live.log;
  state.msg_inflight <- [live];
  let reclaimed_rows = Tui_types.chat_rows_for state "alpha" in
  check bool "reclaimed ownership invalidates the rows memo" false
    (observed_rows == reclaimed_rows);
  check (list string) "durable final reply returns when follower is hidden"
    ["durable final answer"]
    (List.map (fun row -> row.Tui_types.me_text) reclaimed_rows)
;;

let fresh_state_with_running_log () =
  let state =
    Tui_types.create_state ~workspace:"test" ~port:8935 ~refresh_interval:2. ()
  in
  state.msg_target_keeper_name <- Some "alpha";
  Tui_types.hold_settled_log state
    (journal_log ~request_id:"op-1" ~started_at:100. ~finished:false ());
  state
;;

(* A stream frame of a turn this pane did not open is the fact that the
   turn's journal grew; the answer is a read from where the pane's record
   ends, not a fold of the frame. What the frame asks depends on what the
   pane already knows about the operation. *)
let test_a_stream_frame_asks_for_a_journal_read_from_where_the_record_ends () =
  let follow ?(seq = Some 7) ?(at = 300.) state =
    Tui_types.journal_follow_for_source state ~keeper_name:"alpha"
      ~source:(Log.Operation "op-1") ~seq ~at
  in
  let fresh () =
    let state =
      Tui_types.create_state ~workspace:"test" ~port:8935 ~refresh_interval:2. ()
    in
    state.msg_target_keeper_name <- Some "alpha";
    state
  in
  (match follow (fresh ()) with
   | Tui_types.Follow_read { started_at; since_seq } ->
       (* The frame's clock is the fallback the read carries; the log the
          read creates takes the journal head's own time
          ([journal_log_started_at]). *)
       check (float 0.) "an operation the pane knows nothing of: the whole journal" 300. started_at;
       check bool "from the start" true (since_seq = Masc.Keeper_chat_event_log.Whole_turn)
   | Follow_nothing | Follow_read_after_inflight -> fail "a fresh operation is read");
  let held_state = fresh_state_with_running_log in
  (match follow ~seq:(Some 2) (held_state ()) with
   | Tui_types.Follow_nothing -> ()
   | Follow_read _ | Follow_read_after_inflight ->
       fail "a seq the log already holds asks for nothing");
  (match follow ~seq:(Some 3) (held_state ()) with
   | Tui_types.Follow_read { started_at; since_seq } ->
       check (float 0.) "a held log keeps its own start" 100. started_at;
       check bool "and the read resumes after what it holds" true
         (since_seq = Masc.Keeper_chat_event_log.After_seq 2)
   | Follow_nothing | Follow_read_after_inflight ->
       fail "a seq past the record is read");
  (match follow ~seq:None (held_state ()) with
   | Tui_types.Follow_read _ -> ()
   | Follow_nothing | Follow_read_after_inflight ->
       fail "a frame with no seq (the settle-time terminal) is read");
  let inflight_state = held_state () in
  Tui_types.journal_read_started inflight_state (operation_key "op-1");
  (match follow inflight_state with
   | Tui_types.Follow_read_after_inflight -> ()
   | Follow_nothing | Follow_read _ -> fail "a read in flight is not doubled");
  let finished_state = fresh () in
  Tui_types.hold_settled_log finished_state
    (journal_log ~request_id:"op-1" ~started_at:100. ());
  (match follow finished_state with
   | Tui_types.Follow_nothing -> ()
   | Follow_read _ | Follow_read_after_inflight -> fail "a turn that ended is over");
  let unavailable_state = fresh () in
  Tui_types.remember_journal_unavailable unavailable_state (operation_key "op-1");
  (match follow unavailable_state with
   | Tui_types.Follow_nothing -> ()
   | Follow_read _ | Follow_read_after_inflight ->
       fail "a journal the server cannot serve is not asked for");
  let refused_state = fresh () in
  refused_state.msg_journal_reads_refused <- true;
  (match follow refused_state with
   | Tui_types.Follow_nothing -> ()
   | Follow_read _ | Follow_read_after_inflight ->
       fail "a refused credential asks for nothing");
  let own_state = fresh () in
  let entry = inflight_with_log ~keeper_name:"alpha" ~started_at:10. [ Live.Run_started ] in
  own_state.msg_inflight <- [ entry ];
  (match
     Tui_types.journal_follow_for_source own_state ~keeper_name:"alpha"
       ~source:(Log.Operation entry.sent_request.request_id) ~seq:(Some 7) ~at:300.
   with
   | Tui_types.Follow_nothing -> ()
   | Follow_read _ | Follow_read_after_inflight ->
       fail "the pane's own stream feeds its own request")
;;

(* One wanted mark per operation carrying the highest seq the frames named,
   taken once. A read that lands having reached that seq ends the chain; the
   seq-less settle terminal never lowers it. *)
let test_a_wanted_journal_read_is_remembered_once_and_taken_once () =
  let state =
    Tui_types.create_state ~workspace:"test" ~port:8935 ~refresh_interval:2. ()
  in
  Tui_types.journal_read_wanted state (operation_key "op-1") (Some 4);
  Tui_types.journal_read_wanted state (operation_key "op-1") (Some 9);
  Tui_types.journal_read_wanted state (operation_key "op-1") None;
  Tui_types.journal_read_wanted state (operation_key "op-2") None;
  check (list journal_key_test) "one entry per operation" [ operation_key "op-2"; operation_key "op-1" ]
    (List.map fst state.msg_journal_wanted);
  (match Tui_types.take_journal_wanted state (operation_key "op-1") with
   | Tui_types.Wanted { highest_seq } ->
       check (option int) "the highest seq named" (Some 9) highest_seq
   | Not_wanted -> fail "op-1 was wanted");
  check bool "taken once" true
    (Tui_types.take_journal_wanted state (operation_key "op-1") = Tui_types.Not_wanted);
  check (list journal_key_test) "the other stays" [ operation_key "op-2" ] (List.map fst state.msg_journal_wanted);
  (* The landed read reached the line the frames named: the pane holds
     seq 2 of op-1 and the frames named 2, so nothing more is read. *)
  let held = fresh_state_with_running_log () in
  (match
     Tui_types.journal_follow_for_source held ~keeper_name:"alpha"
       ~source:(Log.Operation "op-1") ~seq:(Some 2) ~at:300.
   with
   | Tui_types.Follow_nothing -> ()
   | Follow_read _ | Follow_read_after_inflight ->
       fail "a read that reached the named seq ends the chain")
;;

let test_history_cannot_retire_a_partial_journal () =
  let state = Tui_types.create_state ~workspace:"test" ~port:8935 ~refresh_interval:2. () in
  let source = Log.Operation "reply-op" in
  let key = "alpha", source in
  state.msg_loaded_keeper <- Some "alpha";
  state.msg_loaded <- [chat_entry ~request_id:"reply-op" ~role:Tui_types.Message_keeper
      ~text:"final answer" ~at:110. ()];
  let receive lines =
    match Tui_types.receive_journal_result state ~keeper_name:"alpha" ~source
        ~started_at:100. (Ok lines) with
    | Ok (log, _) -> log
    | Error error -> fail (Log.events_error_to_string error) in
  let follow () = Tui_types.journal_follow_for_source state ~keeper_name:"alpha"
      ~source ~seq:(Some 3) ~at:110. in
  Tui_types.journal_read_started state key;
  Tui_types.journal_read_wanted state key (Some 3);
  let log = receive
      [line 0 100. (E.Run_started {run_id="reply-run"; thread_id="keeper:alpha"});
       line 1 101. (E.Text_delta "partial answer")] in
  check (list journal_key_test) "valid history-before-terminal read is not unavailable"
    [] state.msg_journal_unavailable;
  check bool "history alone cannot close journal observation" false
    (Tui_types.observed_log_has_ended state log);
  (match Tui_types.take_journal_wanted state key, follow () with
   | Tui_types.Wanted {highest_seq=Some 3}, Follow_read {since_seq=Journal.After_seq 1; _} -> ()
   | _ -> fail "terminal notification cannot resume after the partial page");
  ignore (receive []);
  (match follow () with
   | Tui_types.Follow_read {since_seq=Journal.After_seq 1; _} -> ()
   | _ -> fail "empty read retired the still-open journal");
  ignore (receive [line 2 110. (journal_reply "final answer");
                  line 3 111. (E.Run_finished {run_id="reply-run"})]);
  check bool "terminal events complete the same held log" true
    (Tui_types.turn_log_holds_the_turn log);
  check bool "terminal event stops observer follow" true (follow () = Tui_types.Follow_nothing);
  check (list journal_key_test) "completion is distinct from unavailable" [] state.msg_journal_unavailable;
  check int "terminal journal now owns the stored reply" 0
    (List.length (Tui_types.chat_rows_for state "alpha"))
;;

let test_journal_endpoints_preserve_terminal_and_failure_boundaries () =
  let fresh () = Tui_types.create_state ~workspace:"test" ~port:8935 ~refresh_interval:2. () in
  let source = Log.Operation "boundary" in
  let follow state = Tui_types.journal_follow_for_source state ~keeper_name:"alpha"
      ~source ~seq:None ~at:3. in
  let receive state result = Tui_types.receive_journal_result state ~keeper_name:"alpha"
      ~source ~started_at:1. result in
  let start = line 0 1. (E.Run_started {run_id="boundary"; thread_id="keeper:alpha"}) in
  let state = fresh () in
  let cancelled = match receive state (Ok [start; line 1 2. (E.Run_finished {run_id="boundary"})]) with
    | Ok (log, _) -> log | Error error -> fail (Log.events_error_to_string error) in
  check bool "cancellation is terminal without a reply" true (Tui_types.turn_log_has_ended cancelled);
  check bool "cancelled journal cannot replace durable conversation" false
    (Tui_types.turn_log_holds_the_turn cancelled);
  check bool "cancelled journal is not polled again" true (follow state = Tui_types.Follow_nothing);
  check (list journal_key_test) "cancelled journal is not unavailable" [] state.msg_journal_unavailable;
  check (list (pair journal_key_test (float 0.001))) "history also excludes terminal cancellation" []
    (Tui_types.journal_fetch_targets ~held:(Tui_types.journal_held_keys state "alpha")
       ~unavailable:[] [(("alpha", source), 1.)]);
  let state = fresh () in
  let failed = match receive state (Ok [start; line 1 2. (E.Event_error {message="provider failed"})]) with
    | Ok (log, _) -> log | Error error -> fail (Log.events_error_to_string error) in
  check bool "journal failure is terminal evidence" true (Tui_types.turn_log_has_ended failed);
  check bool "failure remains available as the recorded outcome" true
    (Tui_types.turn_log_holds_the_turn failed);
  check bool "failed execution is not polled again" true (follow state = Tui_types.Follow_nothing);
  let state = fresh () in
  let checkpoint = E.Reply_details {reply=""; turn_outcome=Masc.Keeper_turn_outcome.Continuation_checkpoint;
      turn_ref=Ids.Turn_ref.make ~trace_id:"boundary" ~absolute_turn:1} in
  ignore (receive state (Ok [start; line 1 2. checkpoint; line 2 3. (E.Run_finished {run_id="boundary"})]));
  (match follow state with
   | Tui_types.Follow_read {since_seq=Journal.After_seq 2; _} -> ()
   | _ -> fail "continuation checkpoint was treated as a terminal operation");
  List.iter (fun (error, unavailable) ->
    let state = fresh () in
    let log = match receive state (Ok [start; line 1 2. (E.Text_delta "observed evidence")]) with
      | Ok (log, _) -> log | Error error -> fail (Log.events_error_to_string error) in
    Tui_types.journal_read_started state ("alpha", source);
    ignore (receive state (Error error));
    check (list journal_key_test) "failed read releases only its read marker" [] state.msg_journal_inflight;
    check string "endpoint failure preserves earlier journal text" "observed evidence"
      (Keeper_chat_transcript.text log.tl_transcript);
    check bool "endpoint evidence owns availability" unavailable
      (Tui_types.observed_log_is_unavailable state log);
    check bool "unavailability does not invent termination" false (Tui_types.turn_log_has_ended log);
    check bool "transient failures remain followable" unavailable (follow state = Tui_types.Follow_nothing))
    [Log.Journal_pruned, true; Journal_missing, true; Unknown_operation, true;
     Journal_unavailable "read failed", true; Events_denied "denied", true;
     Events_undecodable "invalid page", true; Events_transport "offline", false]
;;

let test_journal_tracking_keeps_keeper_and_source_identity () =
  let state = Tui_types.create_state ~workspace:"test" ~port:8935 ~refresh_interval:2. () in
  let source = Log.Operation "daily-review" in
  let alpha = "alpha", source and beta = "beta", source in
  let follow keeper = Tui_types.journal_follow_for_source state ~keeper_name:keeper
      ~source ~seq:(Some 9) ~at:10. in
  Tui_types.journal_read_started state alpha;
  Tui_types.journal_read_started state beta;
  Tui_types.journal_read_wanted state alpha (Some 4);
  Tui_types.journal_read_wanted state beta (Some 9);
  ignore (Tui_types.receive_journal_result state ~keeper_name:"alpha" ~source ~started_at:1.
      (Error Log.Journal_pruned));
  check (list journal_key_test) "alpha result cannot release beta read" [beta] state.msg_journal_inflight;
  check bool "beta still waits for its own in-flight read" true
    (follow "beta" = Tui_types.Follow_read_after_inflight);
  (match Tui_types.take_journal_wanted state alpha, Tui_types.take_journal_wanted state beta with
   | Wanted {highest_seq=Some 4}, Wanted {highest_seq=Some 9} -> ()
   | _ -> fail "same-named Keepers shared a wanted cursor");
  Tui_types.journal_read_finished state beta;
  (match follow "beta" with Follow_read _ -> () | _ -> fail "alpha unavailability blocked beta");
  check (list (pair journal_key_test (float 0.001))) "history retains beta's same-named source"
    [beta, 2.] (Tui_types.journal_fetch_targets ~held:[] ~unavailable:state.msg_journal_unavailable
      [alpha, 1.; beta, 2.]);
  let own = inflight_with_log ~keeper_name:"alpha" ~started_at:3. [Live.Run_started] in
  let beta_source = Log.Operation own.sent_request.request_id in
  state.msg_inflight <- [own];
  let beta_log = match Tui_types.receive_journal_result state ~keeper_name:"beta" ~source:beta_source
      ~started_at:3. (Ok [line 0 3. (E.Run_started {run_id="beta"; thread_id="keeper:beta"})]) with
    | Ok (log, _) -> log | Error error -> fail (Log.events_error_to_string error) in
  check bool "alpha's own stream does not hide beta's observed journal" true
    (List.memq beta_log (Tui_types.observed_logs_for_keeper state "beta"));
  (match Tui_types.journal_follow_for_source state ~keeper_name:"beta" ~source:beta_source
      ~seq:(Some 1) ~at:4. with Follow_read _ -> () | _ -> fail "alpha's POST excluded beta's journal");
  check bool "alpha's own stream does not exclude beta from history fetches" false
    (List.mem ("beta", beta_source) (Tui_types.journal_held_keys state "beta"));
  let turn = Ids.Turn_ref.make ~trace_id:"same-key" ~absolute_turn:7 in
  let autonomous = Log.Autonomous_turn turn in
  let operation = Log.Operation (Log.source_key autonomous) in
  Tui_types.remember_journal_unavailable state ("beta", operation);
  List.iter (fun source -> ignore (Tui_types.receive_journal_result state ~keeper_name:"beta"
    ~source ~started_at:5. (Ok [line 0 5. (E.Run_started {run_id="typed"; thread_id="keeper:beta"})])))
    [operation; autonomous];
  (match Tui_types.journal_follow_for_source state ~keeper_name:"beta" ~source:autonomous
      ~seq:(Some 1) ~at:6. with Follow_read _ -> () | _ -> fail "operation display key blocked autonomous source");
  check int "typed sources with equal display keys remain distinct held sources" 2
    (Tui_types.selected_source_logs_for_keeper state "beta"
     |> List.filter (fun log -> List.mem (Log.source log.Tui_types.tl_log) [operation; autonomous])
     |> List.length)
;;

(* A log built from a journal read stands at the journal head's own time,
   not at the moment the read was asked for. *)
let test_a_journal_built_log_starts_at_the_journal_head () =
  let head = line 0 100. (E.Run_started { run_id = "r"; thread_id = "keeper:alpha" }) in
  let later = line 3 100.3 (E.Text_delta "said") in
  check (float 0.) "a read from the head takes the head's time" 100.
    (Tui_types.journal_log_started_at ~fallback:300. [ head; later ]);
  check (float 0.) "a read that resumes past the head keeps the fallback" 300.
    (Tui_types.journal_log_started_at ~fallback:300. [ later ]);
  check (float 0.) "an empty read keeps the fallback" 300.
    (Tui_types.journal_log_started_at ~fallback:300. [])

;;

(* The renderer knows the wrapped transcript's real maximum only after it has
   laid the rows out. That clamped value must come back into state; otherwise
   PgUp can leave [msg_scroll] above the maximum and Up/Down appear frozen
   until enough keys have burned through the invisible excess. *)
let test_message_scroll_accepts_the_rendered_clamp () =
  let state =
    Tui_types.create_state ~workspace:"test" ~port:8935 ~refresh_interval:2.0 ()
  in
  state.msg_scroll <- 30;
  Tui_types.apply_clamped_scroll state (Tui_types.Message_scroll {scroll=7; pin=None});
  check int "requested scroll is normalized to the drawn row" 7 state.msg_scroll
;;

(* Resources and Approval detail worked the drawable row out and then threw
   it away: the drawing clamped for display while the stored value kept
   climbing, so j past the end cost one k per step to undo. Both now report
   the row they drew, the same way the transcript already does. *)
let test_resource_scroll_accepts_the_rendered_clamp () =
  let state =
    Tui_types.create_state ~workspace:"test" ~port:8935 ~refresh_interval:2.0 ()
  in
  state.resource_scroll <- 42;
  Tui_types.apply_clamped_scroll state (Tui_types.Resource_scroll 5);
  check int "requested scroll is normalized to the drawn row" 5
    state.resource_scroll
;;

let test_approval_detail_scroll_accepts_the_rendered_clamp () =
  let state =
    Tui_types.create_state ~workspace:"test" ~port:8935 ~refresh_interval:2.0 ()
  in
  state.approval_detail_scroll <- 42;
  Tui_types.apply_clamped_scroll state (Tui_types.Approval_detail_scroll 3);
  check int "requested scroll is normalized to the drawn row" 3
    state.approval_detail_scroll
;;

(* The header names what is unusual, not what is normal.

   Reasoning folded and tools compact are the defaults: observed work stays
   identifiable while its details remain one shortcut away. Spelling those modes in every header
   would spend width to describe the ordinary case.

   Every combination is listed rather than described, because the rule is
   about which of eight cases produce which string. *)
let test_the_header_names_only_unusual_modes () =
  let summary ?(origin = Masc_tui_message_layout.Origin_inline) memory
      reasoning tools =
    Tui_types.chat_visibility_summary ~memory ~reasoning ~tools ~origin
  in
  let memory_summary = Tui_types.Memory_summary in
  let memory_hidden = Tui_types.Memory_hidden in
  let memory_full = Tui_types.Memory_full in
  let full = Tui_types.Reasoning_full and folded = Tui_types.Reasoning_folded in
  let hidden = Tui_types.Reasoning_hidden in
  let tools_full = Tui_types.Tools_full and compact = Tui_types.Tools_compact in
  (* The header says nothing for the state the TUI actually starts in, so the
     default has to be read rather than restated here. *)
  let started =
    Tui_types.create_state ~workspace:"test" ~port:8935 ~refresh_interval:2.0 ()
  in
  check
    bool
    "the pane starts with the short clock"
    true
    (started.Tui_types.msg_origin_display
     = Masc_tui_message_layout.Origin_inline);
  check string "everything at its default says nothing" ""
    (summary ~origin:started.Tui_types.msg_origin_display memory_summary
       started.msg_reasoning_visibility compact);
  (* Both ends of the axis are named, because both are a choice now. A pane
     with no clock in it says so rather than looking like one whose keeper
     stopped stamping rows. *)
  check string "the bare gutter is named" "metadata:off"
    (summary ~origin:Masc_tui_message_layout.Origin_bare memory_summary folded
       compact);
  check string "full metadata is named" "metadata:full"
    (summary ~origin:Masc_tui_message_layout.Origin_row memory_summary folded
       compact);
  check string "full reasoning alone" "reasoning:full"
    (summary memory_summary full compact);
  check string "hidden reasoning is explicit" "reasoning:hidden"
    (summary memory_summary hidden compact);
  check string "full tools alone" "tools:full"
    (summary memory_summary folded tools_full);
  check string "short results mode is named" "tools:results"
    (summary memory_summary folded Tui_types.Tools_results);
  check string "journal off alone" "journal:off"
    (summary memory_hidden folded compact);
  check string "full journal alone" "journal:full"
    (summary memory_full folded compact);
  check string "two of them" "reasoning:full tools:full"
    (summary memory_summary full tools_full);
  check string "all three, in a fixed order"
    "journal:off reasoning:full tools:full"
    (summary memory_hidden full tools_full);
  check int "at rest it now costs nothing" 0
    (String.length (summary memory_summary folded compact));
  check int "all three deviations still fit as one compact label" 37
    (String.length (summary memory_hidden full tools_full))
;;

let test_chat_header_resolves_the_effective_modes () =
  let labels ?keeper ?workspace yolo =
    Tui_types.keeper_chat_mode_labels ~yolo ~keeper_gate_mode:keeper
      ~workspace_gate_mode:workspace
  in
  let mode m = Tui_decode.Gate_mode m in
  (* The words are the chooser's, not the wire's: [w] offers "manual, Auto
     Judge or allow-all" and this row names the stance it left behind. *)
  check (pair string (option string)) "defaults are explicit"
    ("AUTO", Some "Auto Judge")
    (labels ~workspace:(mode Masc.Keeper_gate_mode.Auto_judge) false);
  check (pair string (option string)) "YOLO does not hide inherited Gate mode"
    ("YOLO", Some "manual")
    (labels ~workspace:(mode Masc.Keeper_gate_mode.Manual) true);
  check (pair string (option string)) "Keeper override wins"
    ("AUTO", Some "allow-all")
    (labels ~keeper:(mode Masc.Keeper_gate_mode.Always_allow)
       ~workspace:(mode Masc.Keeper_gate_mode.Manual) false);
  (* A stance this build does not know keeps the server's spelling; only an
     unobserved one answers [None], which the header draws as "(not loaded)". *)
  check (pair string (option string)) "an unknown stance is shown as sent"
    ("AUTO", Some "escalate_to_human")
    (labels ~workspace:(Tui_decode.Unrecognised_gate_mode "escalate_to_human") false);
  check (pair string (option string)) "unread Gate mode is not a stance"
    ("AUTO", None) (labels false)
;;

let test_skill_usage_time_does_not_invent_never () =
  check string "observed time stays exact" "2026-08-28T03:04:05Z"
    (Tui_types.skill_last_used_label (Some "2026-08-28T03:04:05Z"));
  check string "missing retained coverage is not lifetime absence"
    "time unavailable" (Tui_types.skill_last_used_label None)
;;

(* The header names a mode; the footer names the key that changes it. A reader
   who presses a key and looks for what moved has to find the same word in
   both places, and three of the four axes did. The journal's did not: the
   header said "memory", the footer "journal", the help "memory detail" and
   the rows "JOURNAL" -- one axis under three spellings across four files.

   Reads the header's own output rather than a list written here, so an axis
   added to [chat_visibility_summary] without a footer hint fails this. *)
let test_every_header_mode_is_named_by_a_footer_key () =
  let summary =
    Tui_types.chat_visibility_summary ~memory:Tui_types.Memory_hidden
      ~reasoning:Tui_types.Reasoning_full ~tools:Tui_types.Tools_full
      (* Every axis away from its default, which is the only state that names
         all four. The short clock is the resting one now, so this reaches
         for the row projection to move the metadata axis off it. *)
      ~origin:Masc_tui_message_layout.Origin_row
  in
  let axis_of part =
    match String.index_opt part ':' with
    | Some at -> String.sub part 0 at
    | None -> part
  in
  let axes =
    String.split_on_char ' ' summary
    |> List.filter (fun part -> String.trim part <> "")
    |> List.map axis_of
  in
  let hints =
    Masc_tui_footer.chat_hints ~enter_hint:"" ~scroll_hint:"" ~switch_hint:""
      ~escape_hint:"" ~leave_hint:""
  in
  let names hint axis =
    let axis_length = String.length axis in
    let rec search from =
      match String.index_from_opt hint from ':' with
      | None -> false
      | Some at ->
          (at + 1 + axis_length <= String.length hint
           && String.equal (String.sub hint (at + 1) axis_length) axis)
          || search (at + 1)
    in
    search 0
  in
  check int "the header can name four modes" 4 (List.length axes);
  List.iter
    (fun axis ->
      check bool ("the footer names the key for " ^ axis) true
        (names hints axis))
    axes
;;

let test_chat_visibility_defaults_and_cycles () =
  let default =
    Tui_types.create_state ~workspace:"test" ~port:8935 ~refresh_interval:2.0 ()
  in
  check string "reasoning starts visibly folded" "folded"
    (Tui_types.reasoning_visibility_to_string default.msg_reasoning_visibility);
  check string "tool calls start as one activity summary" "compact"
    (Tui_types.tool_visibility_to_string default.msg_tool_visibility);
  check string "Memory journal starts as one line per pass" "summary"
    (Tui_types.memory_visibility_to_string default.msg_memory_visibility);
  (* The walk is unchanged; where it starts is not. One press from rest gives
     the full row, a second the bare gutter, a third comes home -- so both
     ends stay one press from the resting state in one direction or the
     other. *)
  check (list string) "the walk starts at the short clock and comes back"
    [ "inline"; "row"; "off"; "inline" ]
    (let rec collect count mode =
       if count = 0
       then [ Tui_types.origin_display_to_string mode ]
       else
         Tui_types.origin_display_to_string mode
         :: collect (count - 1) (Tui_types.next_origin_display mode)
     in
     collect 3 default.msg_origin_display);
  let configured =
    Tui_types.create_state
      ~reasoning_visibility:Tui_types.Reasoning_hidden
      ~tool_visibility:Tui_types.Tools_compact
      ~workspace:"test"
      ~port:8935
      ~refresh_interval:2.0
      ()
  in
  check string "configured reasoning default" "hidden"
    (Tui_types.reasoning_visibility_to_string configured.msg_reasoning_visibility);
  check string "configured tool default" "compact"
    (Tui_types.tool_visibility_to_string configured.msg_tool_visibility);
  check (list string) "reasoning cycles through all three states"
    [ "hidden"; "folded"; "full"; "hidden" ]
    (let rec collect count mode =
       if count = 0
       then [ Tui_types.reasoning_visibility_to_string mode ]
       else
         Tui_types.reasoning_visibility_to_string mode
         :: collect (count - 1) (Tui_types.next_reasoning_visibility mode)
     in
     collect 3 Tui_types.Reasoning_hidden);
  check (list string) "Memory detail cycles through all three states"
    [ "summary"; "full"; "hidden"; "summary" ]
    (let rec collect count mode =
       if count = 0
       then [ Tui_types.memory_visibility_to_string mode ]
       else
         Tui_types.memory_visibility_to_string mode
         :: collect (count - 1) (Tui_types.next_memory_visibility mode)
     in
     collect 3 Tui_types.Memory_summary);
  check (list string) "Ctrl-D cycles summary, results, full, summary"
    [ "compact"; "results"; "full"; "compact" ]
    (let rec collect count mode =
       if count = 0 then [ Tui_types.tool_visibility_to_string mode ]
       else
         Tui_types.tool_visibility_to_string mode
         :: collect (count - 1) (Tui_types.toggle_tool_visibility mode)
     in
     collect 3 Tui_types.Tools_compact)

;;

(* Cancel (Ctrl-K) and edit (Ctrl-P) both act on the newest waiting line, so
   the take-newest operation has to return exactly the last-pushed pair and
   leave the drain order of everything older untouched. *)
let test_take_newest_returns_last_and_keeps_order () =
  check bool "empty queue has no newest" true
    (Masc_tui_keeper_chat_queue.take_newest
       Masc_tui_keeper_chat_queue.empty
     = None);
  (* [fun q -> match …] in a [|>] chain swallows the rest of the chain into
     the match, so the stages are a plain application instead. *)
  let push_ok queue keeper text =
    let request =
      Masc_tui_keeper_chat_projection.create_request ~attachments:[]
        ~keeper_name:keeper ~message:text ()
    in
    match
      Masc_tui_keeper_chat_queue.push queue ~submitted_at:42. request
    with
    | Ok (next, _) -> next
    | Error detail -> failf "push failed: %s" detail
  in
  let queue =
    push_ok
      (push_ok
         (push_ok Masc_tui_keeper_chat_queue.empty "a" "first")
         "b" "second")
      "c" "third"
  in
  match Masc_tui_keeper_chat_queue.take_newest queue with
  | None -> failf "take_newest returned None with three waiting"
  | Some (newest_item, rest) ->
      let newest = newest_item.Masc_tui_keeper_chat_queue.request in
      check string "newest request is the last pushed" "c"
        newest.Masc_tui_keeper_chat_projection.keeper_name;
      check string "newest text is the last pushed" "third"
        newest.Masc_tui_keeper_chat_projection.message;
      check int "drain order of the rest is untouched" 2
        (Masc_tui_keeper_chat_queue.length rest);
      (match
         Masc_tui_keeper_chat_queue.take_first_sendable rest
           ~sendable:(fun _ -> true)
       with
       | Some (oldest_item, remaining) ->
           let oldest = oldest_item.Masc_tui_keeper_chat_queue.request in
           check string "oldest still drains first" "a"
             oldest.Masc_tui_keeper_chat_projection.keeper_name;
           check (list string) "and what is left keeps its order" [ "second" ]
             (Masc_tui_keeper_chat_queue.waiting remaining
              |> List.map (fun item ->
                     item.Masc_tui_keeper_chat_queue.request.message))
       | None -> failf "oldest no longer drains first after take_newest")
;;

let test_pending_preview_is_bounded_and_keeps_the_newest_submission () =
  let queue =
    List.fold_left
      (fun queue index ->
        let request =
          Keeper_chat.create_request ~keeper_name:"alpha"
            ~message:(string_of_int index) ()
        in
        match
          Masc_tui_keeper_chat_queue.push queue
            ~submitted_at:(float_of_int index) request
        with
        | Ok (queue, _) -> queue
        | Error detail -> fail detail)
      Masc_tui_keeper_chat_queue.empty
      [ 1; 2; 3; 4; 5; 6 ]
  in
  let preview =
    Masc_tui_keeper_chat_queue.waiting queue
    |> Tui_types.keeper_message_pending_preview
  in
  check int "bounded rows including omission" 4 (List.length preview);
  check int "three USER-shaped slots plus one omission row" 7
    (Tui_types.keeper_message_pending_status_rows
       (Masc_tui_keeper_chat_queue.waiting queue));
  match preview with
  | [ Tui_types.Pending_preview_item (1, first)
    ; Tui_types.Pending_preview_item (2, second)
    ; Tui_types.Pending_preview_omitted 3
    ; Tui_types.Pending_preview_item (6, newest)
    ] ->
      check (list string) "first dispatch positions and newest input"
        [ "1"; "2"; "6" ]
        [ first.request.message; second.request.message; newest.request.message ]
  | _ -> fail "pending preview shape changed"

;;

let test_the_support_threshold_reserves_the_scrollback_row () =
  let state =
    Tui_types.create_state ~workspace:"test" ~port:8935 ~refresh_interval:2.0 ()
  in
  let newest_status_rows = Tui_types.keeper_message_status_rows state ~terminal_cols:80 in
  let newest =
    Tui_types.keeper_message_support_status_rows state
      ~status_rows:newest_status_rows
  in
  state.msg_scroll <- 1;
  let reading_back_status_rows = Tui_types.keeper_message_status_rows state ~terminal_cols:80 in
  let reading_back =
    Tui_types.keeper_message_support_status_rows state
      ~status_rows:reading_back_status_rows
  in
  check int "PgUp does not move the viewport support threshold" newest reading_back

;;

(* The compose hold (#33047) keeps a settle from sending a keeper's waiting
   line out from under the line being typed. It is a hold on typing, not on
   a draft: the pane left with the draft still in the composer, or the
   composer row released, is text nobody is typing, and an idle keeper has
   no settle coming to send the line -- so the hold has to end there. *)
let test_composing_holds_only_while_the_composer_is_live () =
  let state =
    Tui_types.create_state ~workspace:"test" ~port:8935 ~refresh_interval:2.0 ()
  in
  state.coalesce_queued_input <- true;
  state.msg_target_keeper_name <- Some "alpha";
  state.view <- Tui_types.Keepers Tui_types.Keeper_message;
  Masc_tui_message_input.insert state.msg_input "half a";
  check bool "typing in the pane holds alpha's line" true
    (Tui_types.composing_for_keeper state "alpha");
  check bool "and nobody else's" false (Tui_types.composing_for_keeper state "beta");
  (* Leaving saves the draft and changes the surface; the buffer still holds
     the text, as it does after [leave_keeper_message]. *)
  state.view <- Tui_types.Keepers Tui_types.Keeper_list;
  check bool "the pane left releases the hold, draft or no draft" false
    (Tui_types.composing_for_keeper state "alpha");
  (* The composer row on another surface is the composer once it has focus. *)
  state.view <- Tui_types.Overview;
  state.composer_focused <- true;
  check bool "the focused row holds again" true
    (Tui_types.composing_for_keeper state "alpha");
  state.composer_focused <- false;
  check bool "the row released does not" false
    (Tui_types.composing_for_keeper state "alpha");
  state.view <- Tui_types.Keepers Tui_types.Keeper_message;
  Masc_tui_message_input.clear state.msg_input;
  check bool "an empty composer holds nothing" false
    (Tui_types.composing_for_keeper state "alpha");
  Masc_tui_message_input.insert state.msg_input "half a";
  state.coalesce_queued_input <- false;
  check bool "with coalescing off there is no hold at all" false
    (Tui_types.composing_for_keeper state "alpha")

;;

(* The rows that say a request is being sent have to say how long for. A turn
   running minutes is ordinary, and without an age those rows read the same at
   three seconds and at thirteen minutes -- which is the difference between
   slow and stuck. The age is computed where it can be tested; this pins that
   the pane actually asks for it. *)
let test_the_sending_rows_show_an_age () =
  List.iter (fun keeper_name ->
    let state = Tui_types.create_state ~tool_visibility:Tui_types.Tools_full
        ~workspace:"test" ~port:8935 ~refresh_interval:2. () in
    state.msg_target_keeper_name <- Some "alpha";
    state.msg_inflight <- [inflight_with_log ~keeper_name ~started_at:2. [Live.Run_started]];
    let summary ~now =
      match List.rev (Tui_types.keeper_message_inflight_rows state ~chat_cols:80 ~now) with
      | (_, text) :: _ -> text
      | [] -> fail "an in-flight request lost its status row"
    in
    check bool "three-second request displays its age" true
      (String.ends_with ~suffix:" · 3s)" (summary ~now:5.));
    check bool "thirteen-minute request displays its changed age" true
      (String.ends_with ~suffix:" · 13m00s)" (summary ~now:782.));
    state.msg_tool_visibility <- Tui_types.Tools_compact;
    if keeper_name = "alpha" then begin
      check (list (pair bool string)) "compact mode has no duplicate own request row" []
        (Tui_types.keeper_message_inflight_rows state ~chat_cols:80 ~now:5.);
      check (list string) "compact status retains the running request" ["기존 작업 처리 중"]
        (List.map Masc_tui_answering.chat_activity_row_text
           (Tui_types.keeper_message_activity_rows state))
    end else
      check bool "compact mode retains the other Keeper request age" true
        (String.ends_with ~suffix:" · 3s)" (summary ~now:5.)))
    ["alpha"; "beta"]

;;

let test_checkpoint_watcher_allows_new_input () =
  let state = Tui_types.create_state ~workspace:"test" ~port:8935 ~refresh_interval:2.0 () in
  let request = Keeper_chat.create_request ~keeper_name:"alpha" ~message:"original" () in
  let log = Tui_types.turn_log_create ~keeper_name:"alpha" ~request_id:request.request_id ~started_at:1. in
  state.msg_inflight <- [{Tui_types.sent_request=request; submitted_at=1.; sent_at=1.; control_generation=0;
    phase=Tui_types.Turn_streaming; log}];
  List.iter (fun delta -> Tui_types.turn_log_add ~now:2. log ~seq:None delta)
    [Masc_tui_keeper_chat_live.Run_started;
     Masc_tui_keeper_chat_live.Reply_details {reply=""; turn_outcome=Masc.Keeper_turn_outcome.Continuation_checkpoint; turn_ref="trace#1"};
     Masc_tui_keeper_chat_live.Run_finished];
  check bool "watcher remains attached" true (Option.is_some (Tui_types.inflight_for_keeper state "alpha"));
  check bool "new operator input can be sent" true
    (Tui_types.send_disposition state ~keeper_name:"alpha" = Masc_tui_send_disposition.Sends)
;;

let test_old_queued_watcher_does_not_rearm_esc () =
  let state = Tui_types.create_state ~workspace:"test" ~port:8935 ~refresh_interval:2. () in
  let working = inflight_with_log ~keeper_name:"alpha" ~started_at:1. [Live.Run_started] in
  let queued = inflight_with_log ~keeper_name:"alpha" ~started_at:2. [] in
  state.msg_inflight <- [queued; working];
  let stop = Tui_types.begin_keeper_chat_control state "alpha" in
  ignore (Tui_types.finish_keeper_chat_control state "alpha" ~generation:stop);
  Masc_tui_keeper_chat_transcript.note_interrupt working.log.tl_transcript
    (Signal_sent {turn_id=None;signalled_at_ns=0L});
  let now_ns = Int64.succ Masc_tui_esc_interrupt.grace_window_ns in
  check bool "old queued watcher cannot keep signalling after stop acknowledgement" true
    (Tui_types.working_chat_interrupt_action ~now_ns state "alpha" working = Masc_tui_esc_interrupt.Leave);
  let generation = Tui_types.advance_keeper_chat_control state "alpha" in
  state.msg_inflight <- [{queued with control_generation=generation}; working];
  check bool "a fresh input epoch can request another exact stop" true
    (Tui_types.working_chat_interrupt_action ~now_ns state "alpha" working = Masc_tui_esc_interrupt.Launch_interrupt)
;;

(* Four subscriptions may retain different portions of one execution. Source
   selection must happen before settled/observed classification, and changing
   the selected subscriber cannot rewind the transcript. *)
let test_batch_source_selection_preserves_four_request_history () =
  let cache = Masc_tui_ansi.terminal_size_cache in
  let previous = Masc_tui_ansi.get_terminal_size () in
  let set_size size = ignore (Masc_tui_render_schedule.Terminal_size_cache.refresh
      cache ~probe:(fun () -> Some size)) in
  Fun.protect ~finally:(fun () -> set_size previous) (fun () ->
    set_size (60, 120);
    let state = Tui_types.create_state ~workspace:"test" ~port:8935 ~refresh_interval:2. () in
    state.view <- Tui_types.Keepers Tui_types.Keeper_message;
    state.roster_pane_preference <- Masc_tui_roster_pane.Hidden;
    state.msg_target_keeper_name <- Some "alpha";
    let n = inflight_with_log ~keeper_name:"alpha" ~started_at:1. [Live.Run_started] in
    let execution_id = n.sent_request.request_id in
    let bind (entry : Tui_types.inflight) = Tui_types.turn_log_add ~now:2. entry.Tui_types.log ~seq:(Some 2)
        (Live.Batch_bound {operation_id=entry.sent_request.request_id; execution_id}) in
    bind n;
    Tui_types.turn_log_add ~now:2. n.log ~seq:(Some 20) (Live.Text "PARTIAL_CANONICAL");
    let next = inflight_with_log ~keeper_name:"alpha" ~started_at:2. [Live.Run_started] in
    bind next;
    Tui_types.turn_log_add ~now:3. next.log ~seq:(Some 80) (Live.Text "RICH_OBSERVED_OUTPUT");
    let n2 = inflight_with_log ~keeper_name:"alpha" ~started_at:3.
        [Live.Accepted {admission=Live.Queued; queue_length=1; interactive=None}] in
    let n3 = inflight_with_log ~keeper_name:"alpha" ~started_at:4.
        [Live.Run_started; Live.Text "INDEPENDENT_OUTPUT"] in
    let beta = inflight_with_log ~keeper_name:"beta" ~started_at:5. [Live.Run_started] in
    bind beta;
    Tui_types.turn_log_add ~now:5. beta.log ~seq:(Some 100) (Live.Text "BETA_ONLY_OUTPUT");
    Log.commit next.log.tl_log;
    Tui_types.hold_settled_log state next.log;
    Log.commit beta.log.tl_log;
    Tui_types.hold_settled_log state beta.log;
    state.msg_inflight <- [n3; n2; n];
    state.msg_live <- Some n.log;
    let screen () =
      let frame, _ = Masc_tui_render_chat.render_keeper_message state in
      String.concat "\n" (List.map Masc_tui_theme.strip_sgr frame.Masc_tui_frame_presenter.lines) in
    let contains needle = Astring.String.is_infix ~affix:needle (screen ()) in
    check (list string) "seq80 observed sibling survives seq20 live subscriber"
      [next.sent_request.request_id]
      (List.map Tui_types.turn_log_request_id (Tui_types.observed_logs_for_keeper state "alpha"));
    check bool "richer held output drawn" true (contains "RICH_OBSERVED_OUTPUT");
    check bool "weaker live output omitted" false (contains "PARTIAL_CANONICAL");
    check bool "independent fourth execution retained" true (contains "INDEPENDENT_OUTPUT");
    check bool "different Keeper cannot win same execution selection" false (contains "BETA_ONLY_OUTPUT");
    Tui_types.turn_log_add ~now:5. n.log ~seq:(Some 85) (Live.Text "LIVE_CAUGHT_UP");
    check (list string) "caught-up live subscriber now dominates the partial observer" []
      (List.map Tui_types.turn_log_request_id (Tui_types.observed_logs_for_keeper state "alpha"));
    check bool "late live coverage is selected" true (contains "LIVE_CAUGHT_UP");
    Tui_types.turn_log_add ~now:6. next.log ~seq:(Some 81) (visible_reply "COMPLETED_SIBLING_REPLY");
    Tui_types.turn_log_add ~now:6. next.log ~seq:(Some 82) Live.Run_finished;
    Tui_types.hold_settled_log state next.log;
    Tui_types.settle_turn_log state n;
    state.msg_inflight <- [n3; n2];
    check (list string) "complete sibling wins over partial canonical after settle"
      [next.sent_request.request_id]
      (List.map Tui_types.turn_log_request_id (Tui_types.settled_logs_for_keeper state "alpha"));
    check bool "completed reply remains drawn" true (contains "COMPLETED_SIBLING_REPLY");
    state.msg_history <- [chat_entry ~request_id:execution_id
      ~role:Tui_types.Message_keeper ~text:"COMPLETED_SIBLING_REPLY" ~at:6. ()];
    check bool "durable canonical reply suppressed by selected complete sibling" false
      (List.exists (fun (row : Tui_types.msg_entry) -> row.me_role = Tui_types.Message_keeper)
         (Tui_types.chat_rows_for state "alpha"));
    Tui_types.turn_log_add ~now:7. n.log ~seq:(Some 90) (Live.Text "LATE_PARTIAL_UPDATE");
    Tui_types.hold_settled_log state n.log;
    check bool "higher partial seq cannot displace authoritative ending" false (contains "LATE_PARTIAL_UPDATE");
    check bool "authoritative ending survives late partial update" true (contains "COMPLETED_SIBLING_REPLY");
    state.msg_target_keeper_name <- Some "beta";
    state.msg_live <- None;
    check bool "other Keeper retains its own held source" true (contains "BETA_ONLY_OUTPUT"))
;;

let test_history_and_renderer_share_all_inflight_candidates () =
  let cache = Masc_tui_ansi.terminal_size_cache in
  let previous = Masc_tui_ansi.get_terminal_size () in
  let set_size size = ignore (Masc_tui_render_schedule.Terminal_size_cache.refresh
      cache ~probe:(fun () -> Some size)) in
  Fun.protect ~finally:(fun () -> set_size previous) (fun () ->
    set_size (60, 120);
    let state = Tui_types.create_state ~workspace:"test" ~port:8935 ~refresh_interval:2. () in
    state.view <- Tui_types.Keepers Tui_types.Keeper_message;
    state.roster_pane_preference <- Masc_tui_roster_pane.Hidden;
    state.msg_target_keeper_name <- Some "alpha";
    let n = inflight_with_log ~keeper_name:"alpha" ~started_at:1. [Live.Run_started] in
    let execution_id = n.sent_request.request_id in
    let bind (entry : Tui_types.inflight) =
      Tui_types.turn_log_add ~now:2. entry.log ~seq:(Some 2)
        (Live.Batch_bound {operation_id=entry.sent_request.request_id; execution_id}) in
    let observed = inflight_with_log ~keeper_name:"alpha" ~started_at:2. [Live.Run_started] in
    bind observed;
    Tui_types.turn_log_add ~now:3. observed.log ~seq:(Some 80) (visible_reply "SAVED_FINAL");
    Log.commit observed.log.tl_log;
    Tui_types.hold_settled_log state observed.log;
    let competitor = inflight_with_log ~keeper_name:"alpha" ~started_at:3. [Live.Run_started] in
    bind competitor;
    Tui_types.turn_log_add ~now:4. competitor.log ~seq:(Some 90) (Live.Text "GAPPED_PROGRESS");
    let n3 = inflight_with_log ~keeper_name:"alpha" ~started_at:4.
        [Live.Accepted {admission=Live.Queued; queue_length=1; interactive=None}] in
    state.msg_live <- Some n3.log;
    state.msg_inflight <- [n3; competitor; n];
    state.msg_loaded_keeper <- Some "alpha";
    state.msg_loaded <- [chat_entry ~request_id:execution_id ~role:Tui_types.Message_keeper
        ~text:"SAVED_FINAL" ~at:5. ()];
    let screen () =
      let frame, _ = Masc_tui_render_chat.render_keeper_message state in
      String.concat "\n" (List.map Masc_tui_theme.strip_sgr frame.Masc_tui_frame_presenter.lines) in
    let final_count () = List.length (Astring.String.cuts ~sep:"SAVED_FINAL" (screen ())) - 1 in
    check int "losing observed reply cannot suppress durable final" 1 (final_count ());
    let before = Tui_types.chat_rows_for state "alpha" in
    check int "durable final retained beside selected gapped inflight" 1 (List.length before);
    Tui_types.turn_log_add ~now:6. competitor.log ~seq:(Some 80) (visible_reply "SAVED_FINAL");
    let after = Tui_types.chat_rows_for state "alpha" in
    check bool "selected inflight revision invalidates history memo" false (before == after);
    check int "selected inflight reply owns durable suppression" 0 (List.length after);
    check int "late lower-seq reply draws exactly once" 1 (final_count ());
    Tui_types.turn_log_add ~now:7. observed.log ~seq:(Some 100) (Live.Text "OBSERVED_CAUGHT_UP");
    Tui_types.hold_settled_log state observed.log;
    check int "candidate catch-up preserves one final reply" 1 (final_count ()))
;;

let test_batch_watchers_render_one_shared_settled_turn () =
  let state = Tui_types.create_state ~workspace:"test" ~port:8935 ~refresh_interval:2. () in
  let make request_id execution_id =
    let log = Tui_types.turn_log_create ~keeper_name:"alpha" ~request_id ~started_at:1. in
    List.iter (fun delta -> Tui_types.turn_log_add ~now:2. log ~seq:None delta)
      [Live.Run_started; Live.Batch_bound {operation_id=request_id; execution_id};
       Live.Text "shared answer";
       Live.Reply_details {reply="shared answer"; turn_outcome=Masc.Keeper_turn_outcome.Visible_reply; turn_ref="batch#1"};
       Live.Run_finished];
    log in
  let leader = make "batch-owner" "batch-owner" in
  let follower = make "batch-follower" "batch-owner" in
  let independent = make "different-request" "different-request" in
  state.msg_settled_logs <- [follower; independent; leader];
  let visible = Tui_types.settled_logs_for_keeper state "alpha" in
  check (list string) "shared execution draws once; independent identical text is retained"
    ["batch-owner"; "different-request"] (List.map Tui_types.turn_log_request_id visible);
  check bool "follower watcher retains its own request lookup" true
    (Option.is_some (Tui_types.settled_log_for_request state ~keeper_name:"alpha" "batch-follower"));
  check string "held transcript suppresses only the canonical owner's persisted reply"
    "batch-owner" (Tui_types.held_turn_of_log follower).ht_request_id;
  let invalid = make "unrelated-request" "unrelated-request" in
  Tui_types.turn_log_add ~now:3. invalid ~seq:None
    (Live.Batch_bound {operation_id="other-request"; execution_id="batch-owner"});
  check string "mismatched binding cannot hide another request"
    "unrelated-request" (Tui_types.turn_log_execution_id invalid)
;;

let test_batch_reply_follows_all_original_inputs () =
  let cache = Masc_tui_ansi.terminal_size_cache in
  let previous = Masc_tui_ansi.get_terminal_size () in
  let set_size size = ignore (Masc_tui_render_schedule.Terminal_size_cache.refresh
      cache ~probe:(fun () -> Some size)) in
  Fun.protect ~finally:(fun () -> set_size previous) (fun () ->
    set_size (65, 140);
    let state = Tui_types.create_state ~workspace:"test" ~port:8935 ~refresh_interval:2. () in
    state.view <- Tui_types.Keepers Tui_types.Keeper_message;
    state.roster_pane_preference <- Masc_tui_roster_pane.Hidden;
    state.msg_target_keeper_name <- Some "alpha";
    state.msg_loaded_keeper <- Some "alpha";
    let member request_id at =
      let log = Tui_types.turn_log_create ~keeper_name:"alpha" ~request_id ~started_at:1. in
      Tui_types.turn_log_add ~now:at log ~seq:(Some 0) Live.Run_started;
      Tui_types.turn_log_add ~now:at log ~seq:(Some 1)
        (Live.Batch_bound {operation_id=request_id; execution_id="batch-owner"});
      log in
    let owner = member "batch-owner" 1. in
    let second = member "batch-second" 2. in
    let follower = Tui_types.turn_log_create ~keeper_name:"alpha"
        ~request_id:"batch-third" ~started_at:1. in
    Tui_types.turn_log_add ~now:3. follower ~seq:(Some 0) Live.Run_started;
    let user request_id text at =
      chat_entry ~request_id
        ~role:(Tui_types.Message_user (Tui_types.Sent_by_operator {surface=None}))
        ~text ~at () in
    state.msg_loaded <-
      [user "batch-owner" "FIRST_ORIGINAL_INPUT" 1.;
       user "batch-second" "REPEATED_ORIGINAL_INPUT" 2.;
       user "batch-third" "REPEATED_ORIGINAL_INPUT" 3.];
    state.msg_settled_logs <- [follower; second; owner];
    let layouts () = Masc_tui_render_chat.keeper_message_layout_entries state
        ~keeper_name:"alpha" ~chat_cols:140 in
    let before_binding = layouts () in
    Tui_types.turn_log_add ~now:3. follower ~seq:(Some 1)
      (Live.Batch_bound {operation_id="batch-third"; execution_id="batch-owner"});
    check bool "binding without output invalidates layout identity" false
      (before_binding == layouts ());
    let verify_bound_inputs () =
      let entries = layouts () in
      check (list string) "all bound inputs use the full canonical grouping key"
        ["batch-owner"; "batch-owner"; "batch-owner"]
        (List.map (fun (entry : Masc_tui_message_layout.entry) -> entry.request_label) entries);
      check bool "unchanged aliases preserve layout identity" true (entries == layouts ());
      let frame, _ = Masc_tui_render_chat.render_keeper_message state in
      let screen = String.concat "\n"
          (List.map Masc_tui_theme.strip_sgr frame.Masc_tui_frame_presenter.lines) in
      check int "first bound input keeps its original body" 1
        (List.length (Astring.String.cuts ~sep:"FIRST_ORIGINAL_INPUT" screen) - 1);
      check int "separate identical bound inputs both remain" 2
        (List.length (Astring.String.cuts ~sep:"REPEATED_ORIGINAL_INPUT" screen) - 1);
      List.iter (fun metadata -> check bool "batch metadata is not speech" false
        (Astring.String.is_infix ~affix:metadata screen))
        ["입력 반영됨"; "요청 batch-owner"; "입력 3건"];
      check bool "raw invalid binding cannot rename the group" false
        (Astring.String.is_infix ~affix:"forged-owner" screen)
    in
    verify_bound_inputs ();
    state.msg_reasoning_visibility <- Tui_types.Reasoning_hidden;
    Tui_types.turn_log_add ~now:3. owner ~seq:None (Live.Thinking "hidden thought");
    verify_bound_inputs ();
    let invalid = Tui_types.turn_log_create ~keeper_name:"alpha"
        ~request_id:"unrelated-request" ~started_at:3. in
    Tui_types.turn_log_add ~now:3. invalid ~seq:None
      (Live.Batch_bound {operation_id="batch-third"; execution_id="forged-owner"});
    state.msg_settled_logs <- invalid :: state.msg_settled_logs;
    verify_bound_inputs ();
    let complete log ~seq =
      Tui_types.turn_log_add ~now:4. log ~seq:(Some seq) (visible_reply "ONE_BATCH_ANSWER");
      Tui_types.turn_log_add ~now:4. log ~seq:(Some (seq+1)) Live.Run_finished;
      Log.commit log.Tui_types.tl_log in
    complete follower ~seq:2;
    List.iter (fun log -> Log.commit log.Tui_types.tl_log) [owner; second];
    state.msg_settled_logs <- [follower; second; owner];
    let verify stage =
      let frame, _ = Masc_tui_render_chat.render_keeper_message state in
      let screen = String.concat "\n"
          (List.map Masc_tui_theme.strip_sgr frame.Masc_tui_frame_presenter.lines) in
      let pieces = Astring.String.cuts ~sep:"ONE_BATCH_ANSWER" screen in
      check int (stage ^ ": one selected answer") 2 (List.length pieces);
      let before = match pieces with
        | [before; _] -> before | _ -> fail "batch answer was absent or duplicated" in
      check bool (stage ^ ": first input precedes answer") true
        (Astring.String.is_infix ~affix:"FIRST_ORIGINAL_INPUT" before);
      check int (stage ^ ": both separately submitted identical inputs precede answer") 2
        (List.length (Astring.String.cuts ~sep:"REPEATED_ORIGINAL_INPUT" before) - 1);
      check (list string) (stage ^ ": original identities are preserved")
        ["batch-owner"; "batch-second"; "batch-third"]
        (Tui_types.chat_rows_for state "alpha" |> List.map (fun row -> row.Tui_types.me_request_id))
    in
    verify "follower journal owns the answer";
    complete owner ~seq:4;
    verify "owner journal catches up";
    (* A refresh overlaps the selected journal with its durable reply. *)
    state.msg_loaded <- state.msg_loaded @
      [chat_entry ~request_id:"batch-owner" ~role:Tui_types.Message_keeper
         ~text:"ONE_BATCH_ANSWER" ~at:4. ()];
    verify "history overlaps the answer")
;;

let test_observed_checkpoint_retains_earlier_output () =
  let cache = Masc_tui_ansi.terminal_size_cache in
  let previous = Masc_tui_ansi.get_terminal_size () in
  let set_size size = ignore (Masc_tui_render_schedule.Terminal_size_cache.refresh
      cache ~probe:(fun () -> Some size)) in
  Fun.protect ~finally:(fun () -> set_size previous) (fun () ->
    set_size (65, 140);
    let state = Tui_types.create_state ~workspace:"test" ~port:8935 ~refresh_interval:2. () in
    state.view <- Tui_types.Keepers Tui_types.Keeper_message;
    state.roster_pane_preference <- Masc_tui_roster_pane.Hidden;
    state.msg_target_keeper_name <- Some "alpha";
    state.msg_reasoning_visibility <- Tui_types.Reasoning_full;
    state.msg_tool_visibility <- Tui_types.Tools_full;
    let occurrence : Live.tool_occurrence =
      {stream_scope=0; block_index=1; provider_message_id=None; tool_call_id=Some "before-checkpoint"} in
    let log = settled_log ~request_id:"observed-checkpoint"
        [Live.Run_started; Live.Thinking "THINKING_BEFORE_CHECKPOINT";
         Live.Tool_started {occurrence; tool_name="Inspect_before_checkpoint"};
         Live.Tool_ended {occurrence}; Live.Text "TEXT_BEFORE_CHECKPOINT";
         Live.Reply_details {reply=""; turn_outcome=Masc.Keeper_turn_outcome.Continuation_checkpoint;
           turn_ref="trace-1#1"}; Live.Checkpoint; Live.Run_finished] in
    state.msg_settled_logs <- [log];
    let screen () =
      let frame, _ = Masc_tui_render_chat.render_keeper_message state in
      String.concat "\n" (List.map Masc_tui_theme.strip_sgr frame.Masc_tui_frame_presenter.lines) in
    let retained stage =
      let text = screen () in
      List.iter (fun marker -> check bool (stage ^ ": " ^ marker) true
          (Astring.String.is_infix ~affix:marker text))
        ["TEXT_BEFORE_CHECKPOINT"; "THINKING_BEFORE_CHECKPOINT"; "Inspect_before_checkpoint"] in
    retained "observed continuation waits";
    check bool "checkpoint remains open to later journal events" false
      (Tui_types.turn_log_holds_the_turn log);
    Tui_types.turn_log_add ~now:110. log ~seq:(Some 8) Live.Run_started;
    Tui_types.turn_log_add ~now:111. log ~seq:(Some 9) (Live.Text "TEXT_AFTER_CHECKPOINT");
    retained "continuation starts";
    check bool "new continuation text also appears" true
      (Astring.String.is_infix ~affix:"TEXT_AFTER_CHECKPOINT" (screen ())))
;;

let test_continuation_output_interleaves_at_its_event_time () =
  let cache = Masc_tui_ansi.terminal_size_cache in
  let previous = Masc_tui_ansi.get_terminal_size () in
  let set_size size = ignore (Masc_tui_render_schedule.Terminal_size_cache.refresh
      cache ~probe:(fun () -> Some size)) in
  Fun.protect ~finally:(fun () -> set_size previous) (fun () ->
    set_size (65, 140);
    let state = Tui_types.create_state ~workspace:"test" ~port:8935 ~refresh_interval:2. () in
    state.view <- Tui_types.Keepers Tui_types.Keeper_message;
    state.roster_pane_preference <- Masc_tui_roster_pane.Hidden;
    state.msg_target_keeper_name <- Some "alpha";
    state.msg_loaded_keeper <- Some "alpha";
    let user = Tui_types.Message_user (Tui_types.Sent_by_operator {surface=None}) in
    state.msg_loaded <-
      [chat_entry ~request_id:"continuing-operation" ~role:user
         ~text:"ORIGINAL_INPUT" ~at:50. ();
       chat_entry ~request_id:"continuing-operation" ~turn_phase:Tui_types.Turn_output
         ~role:Tui_types.Message_status ~text:"DURABLE_CHECKPOINT" ~at:110. ();
       chat_entry ~request_id:"intervening-operation" ~role:user
         ~text:"INTERVENING_INPUT" ~at:150. ()];
    let log = Tui_types.turn_log_create ~keeper_name:"alpha"
        ~request_id:"continuing-operation" ~started_at:90. in
    let add seq now delta = Tui_types.turn_log_add ~now log ~seq:(Some seq) delta in
    add 0 90. Live.Run_started;
    add 1 100. (Live.Text "BEFORE_CHECKPOINT");
    add 2 110. (Live.Reply_details {reply="";
      turn_outcome=Masc.Keeper_turn_outcome.Continuation_checkpoint; turn_ref="trace-1#1"});
    add 3 111. Live.Run_finished;
    add 4 190. Live.Run_started;
    add 5 200. (Live.Text "AFTER_CHECKPOINT");
    Log.commit log.tl_log;
    state.msg_settled_logs <- [log];
    let verify stage =
      let frame, _ = Masc_tui_render_chat.render_keeper_message state in
      let screen = String.concat "\n"
          (List.map Masc_tui_theme.strip_sgr frame.Masc_tui_frame_presenter.lines) in
      let position marker = match Astring.String.find_sub ~sub:marker screen with
        | Some offset -> offset | None -> fail (stage ^ ": missing " ^ marker) in
      let markers = ["ORIGINAL_INPUT"; "BEFORE_CHECKPOINT"; "DURABLE_CHECKPOINT";
        "INTERVENING_INPUT"; "AFTER_CHECKPOINT"] in
      let rec ordered = function
        | left :: ((right :: _) as rest) ->
            check bool (stage ^ ": " ^ left ^ " precedes " ^ right) true
              (position left < position right);
            ordered rest
        | [] | [_] -> () in
      ordered markers;
      List.iter (fun marker -> check int (stage ^ ": one " ^ marker) 1
          (List.length (Astring.String.cuts ~sep:marker screen) - 1)) markers
    in
    verify "resumed execution is still streaming";
    add 6 210. (visible_reply "AFTER_CHECKPOINT");
    add 7 211. Live.Run_finished;
    verify "completed replay preserves the same order")
;;

(* Every request of a batch the session holds is held for journal reads, not
   only the one that draws the batch. The follower used to be asked for again
   on every history load. *)
let test_every_request_of_a_held_batch_is_held_for_journal_reads () =
  let state = Tui_types.create_state ~workspace:"test" ~port:8935 ~refresh_interval:2. () in
  let make request_id execution_id =
    let log = Tui_types.turn_log_create ~keeper_name:"alpha" ~request_id ~started_at:1. in
    List.iter (fun delta -> Tui_types.turn_log_add ~now:2. log ~seq:None delta)
      [Live.Run_started; Live.Batch_bound {operation_id=request_id; execution_id};
       Live.Text "shared answer";
       Live.Reply_details {reply="shared answer"; turn_outcome=Masc.Keeper_turn_outcome.Visible_reply; turn_ref="batch#1"};
       Live.Run_finished];
    Log.commit log.Tui_types.tl_log;
    log in
  state.msg_settled_logs <-
    [ make "batch-follower" "batch-owner"; make "batch-owner" "batch-owner" ];
  check (list string) "the batch draws once"
    [ "batch-owner" ]
    (List.map Tui_types.turn_log_request_id (Tui_types.settled_logs_for_keeper state "alpha"));
  let held = Tui_types.journal_held_keys state "alpha" in
  check (list journal_key_test) "both requests are held"
    [ operation_key "batch-follower"; operation_key "batch-owner" ] (List.sort compare held);
  check (list (pair journal_key_test (float 0.001))) "neither journal is asked for again" []
    (Tui_types.journal_fetch_targets ~held ~unavailable:[]
       (operation_targets [ ("batch-owner", 1.); ("batch-follower", 1.) ]));
  check (list journal_key_test) "another keeper holds nothing" []
    (Tui_types.journal_held_keys state "beta");
  Tui_types.journal_read_started state (operation_key "being-read");
  check bool "a journal being read is held" true
    (List.mem (operation_key "being-read") (Tui_types.journal_held_keys state "alpha"))
;;

let test_link_cards_use_actual_message_body_width () =
  let module Layout = Masc_tui_message_layout in
  let module Render = Masc_tui_render_chat in
  let module Preview = Masc_tui_link_preview in
  let state = Tui_types.create_state ~workspace:"test" ~port:8935 ~refresh_interval:2.0 () in
  let url = "https://github.com/jeong-sik/masc/pull/37632" in
  let message = { (entry_at 42.0) with me_text = url } in
  let messages = [message] in
  let entries () = Render.keeper_message_layout_entries ~messages
      state ~keeper_name:"alpha" ~chat_cols:120 in
  let entry = List.hd (entries ()) in
  let theme = Masc_tui_ansi.Chat_theme.snapshot () in
  List.iter (fun inner_width ->
    List.iter (fun origin ->
      List.iter (fun turn_rail ->
        let entry = { entry with Layout.timestamp = "12:34:56"; turn_rail } in
        let markdown ~entry ~width =
          let source = Render.chat_body_with_previews ~preview:Preview.get_preview ~mode:`Rich ~entry ~width in
          let cards = List.tl (String.split_on_char '\n' source) in
          check bool "preview present" true (cards <> []);
          List.iter (fun line ->
            check bool "card fits actual body budget" true
              (Layout.display_width line <= width)) cards;
          let rendered = Render.cached_chat_markdown ~link_previews_mode:`Rich
              ~theme ~entry ~width in
          List.iter (fun border ->
            check bool "complete border survives Markdown without wrapping" true
              (List.exists (fun line -> Astring.String.is_infix ~affix:border line) rendered))
            [List.hd cards; List.hd (List.rev cards)];
          rendered
        in
        ignore (Layout.total_rows ~markdown ~origin ~inner_width [entry]))
        [Layout.Rail_none; Rail_opens; Rail_says; Rail_does])
      [Layout.Origin_row; Origin_inline; Origin_bare])
    [20; 40; 80; 120; 160];
  let render mode entry = Render.cached_chat_markdown ~link_previews_mode:mode
      ~theme ~entry ~width:90 in
  let plain = render `Off entry in
  let rich = render `Rich entry in
  check bool "mode changes invalidate Markdown" true (plain <> rich);
  check (list string) "return to off restores plain rendering" plain (render `Off entry);
  let preview = Preview.get_preview url in
  let frame = Render.cached_chat_markdown ~link_previews_mode:`Rich ~theme in
  let measured = frame ~entry ~width:90 in
  Preview.cache_store { preview with title = Some "Changed preview metadata" };
  check (list string) "one frame freezes preview metadata between measure and draw"
    measured (frame ~entry ~width:90);
  check bool "metadata changes invalidate Markdown" true (rich <> render `Rich entry);
  List.iter (fun style ->
    let excluded = { entry with Layout.style } in
    check (list string) "tool and skill remain plain" (render `Off excluded) (render `Rich excluded))
    [Layout.Tool; Skill Layout.Skill_settled];
  List.iter (fun markdown_source ->
    let growing = { entry with Layout.markdown_source } in
    check (list string) "unsettled source retains original rendering"
      (render `Off growing) (render `Rich growing))
    [Layout.Markdown_streaming;
     Markdown_growing {keeper_name="alpha"; request_id=""; entry_index=0}];
  let before = entries () in
  check bool "unchanged metadata reuses layout identity" true (before == entries ());
  state.link_previews_mode <- `Off;
  check bool "mode invalidates layout identity" false (before == entries ());
  let before = entries () in
  Preview.cache_store { preview with title = Some "Another metadata update" };
  check bool "metadata invalidates layout identity" false (before == entries ())

(* The words on a Skill row and the mark beside it answer different
   questions: the words say how far the skill got, the mark says whether the
   reader is looking at something still moving. [Skill_delivered] -- a
   finished life that ended without a tool call -- was mapped to the live
   tone, so a settled history line wore the hollow diamond and read as a turn
   still working. It weighed more once #36870 took the SKILL word off the row
   and left the mark alone on that axis.

   Both names are spelled out by an exhaustive match, so a new state or a new
   tone stops compiling here rather than inheriting a mark by accident. *)
let skill_state_name (state : Keeper_chat_transcript.skill_state) =
  match state with
  | Keeper_chat_transcript.Skill_calling -> "calling"
  | Keeper_chat_transcript.Skill_served_pending -> "served_pending"
  | Keeper_chat_transcript.Skill_served_only -> "served_only"
  | Keeper_chat_transcript.Skill_delivered -> "delivered"
  | Keeper_chat_transcript.Skill_used -> "used"
  | Keeper_chat_transcript.Skill_failed -> "failed"
  | Keeper_chat_transcript.Skill_evidence_missing -> "evidence_missing"
  | Keeper_chat_transcript.Skill_evidence_unavailable -> "evidence_unavailable"

let skill_tone_name (tone : Masc_tui_message_layout.skill_tone) =
  match tone with
  | Masc_tui_message_layout.Skill_live -> "live"
  | Masc_tui_message_layout.Skill_settled -> "settled"
  | Masc_tui_message_layout.Skill_attention -> "attention"
  | Masc_tui_message_layout.Skill_failure -> "failure"

let test_every_skill_state_chooses_its_tone () =
  check (list string) "one tone per state, in the order of the skill's life"
    [ "calling -> live"
    ; "served_pending -> live"
    ; "served_only -> attention"
    ; "delivered -> settled"
    ; "used -> settled"
    ; "failed -> failure"
    ; "evidence_missing -> attention"
    ; "evidence_unavailable -> failure"
    ]
    (List.map
       (fun state ->
         skill_state_name state ^ " -> "
         ^ skill_tone_name (Masc_tui_render_chat.skill_tone_of_state state))
       Keeper_chat_transcript.all_skill_states)

(* The rule the table above has to keep. Said on its own because the table is
   a list of values and this is the reason behind them -- a state moved to
   some other settled tone would still be wrong, but differently. *)
let test_only_a_moving_skill_wears_the_live_mark () =
  check (list string) "the read and the delivery check; nothing else"
    [ "calling"; "served_pending" ]
    (List.filter_map
       (fun state ->
         match Masc_tui_render_chat.skill_tone_of_state state with
         | Masc_tui_message_layout.Skill_live -> Some (skill_state_name state)
         | Masc_tui_message_layout.Skill_settled
         | Masc_tui_message_layout.Skill_attention
         | Masc_tui_message_layout.Skill_failure -> None)
       Keeper_chat_transcript.all_skill_states)

let test_roster_starts_hidden_until_explicitly_opened () =
  let state = Tui_types.create_state ~workspace:"test" ~port:0 ~refresh_interval:2. () in
  check bool "default is hidden outside chat" true (Tui_types.roster_pane_hidden state);
  state.view <- Tui_types.Keepers Tui_types.Keeper_message;
  check bool "entering chat keeps the roster closed" true (Tui_types.roster_pane_hidden state);
  state.view <- Tui_types.Keepers Tui_types.Keeper_detail;
  check bool "detail keeps the roster closed" true (Tui_types.roster_pane_hidden state);
  List.iter (fun (preference, hidden) ->
    state.roster_pane_preference <- preference;
    List.iter (fun surface ->
      state.view <- surface;
      check bool "explicit preference survives navigation" hidden
        (Tui_types.roster_pane_hidden state))
      [Tui_types.Keepers Tui_types.Keeper_message; Tui_types.Keepers Tui_types.Keeper_detail])
    [Masc_tui_roster_pane.Hidden, true; Masc_tui_roster_pane.Shown, false]

let test_hidden_chat_roster_releases_focus_without_changing_conversation () =
  let state = Tui_types.create_state ~workspace:"test" ~port:0 ~refresh_interval:2. () in
  state.view <- Tui_types.Keepers Tui_types.Keeper_message;
  state.msg_target_keeper_name <- Some "alpha";
  state.keeper_cursor <- 1;
  Masc_tui_message_input.insert state.msg_input "alpha's unsent draft";
  let threshold = Masc_tui_roster_pane.threshold_cols in
  List.iter (fun (preference, cols) ->
    state.roster_pane_preference <- preference;
    state.keeper_message_focus <- Tui_types.Left_pane;
    Tui_types.reconcile_keeper_message_focus state ~cols;
    check bool "hidden roster releases focus" true
      (state.keeper_message_focus = Tui_types.Right_pane);
    check (option string) "conversation preserved" (Some "alpha") state.msg_target_keeper_name;
    check int "roster selection preserved" 1 state.keeper_cursor;
    check string "draft preserved" "alpha's unsent draft" (Masc_tui_message_input.contents state.msg_input);
    check bool "visibility preference preserved" true (state.roster_pane_preference = preference);
    state.roster_pane_preference <- Masc_tui_roster_pane.Shown;
    Tui_types.reconcile_keeper_message_focus state ~cols:threshold;
    check bool "returning roster does not steal focus" true
      (state.keeper_message_focus = Tui_types.Right_pane))
    [Masc_tui_roster_pane.Hidden, threshold - 1;
     Masc_tui_roster_pane.Shown, threshold - 1;
     Masc_tui_roster_pane.Hidden, threshold];
  state.keeper_message_focus <- Tui_types.Left_pane;
  Tui_types.reconcile_keeper_message_focus state ~cols:threshold;
  check bool "visible roster retains deliberate focus" true
    (state.keeper_message_focus = Tui_types.Left_pane)

let test_priority_completion_survives_controls () =
  let state = Tui_types.create_state ~workspace:"test" ~port:8935 ~refresh_interval:2. () in
  let alpha = inflight_with_log ~keeper_name:"alpha" ~started_at:1. [] in
  let beta = inflight_with_log ~keeper_name:"beta" ~started_at:1. [] in
  state.msg_inflight <- [alpha; beta];
  state.keeper_run_next_inflight <- [alpha.sent_request; beta.sent_request];
  let generation = Tui_types.begin_keeper_chat_control state "alpha" in
  check bool "old HTTP remains tracked while control is pending" true
    (List.exists (Keeper_chat.same_request_identity alpha.sent_request) state.keeper_run_next_inflight);
  Tui_types.settle_keeper_priority_control state "alpha" ~generation
    ~outcome:Tui_types.Priority_superseded;
  check bool "successful control retires receipt without redisplaying" true
    (Tui_types.settle_keeper_run_next state alpha.sent_request (Ok "old priority") = Tui_types.Run_next_retired);
  check bool "retired request leaves tracking" false
    (List.exists (Keeper_chat.same_request_identity alpha.sent_request) state.keeper_run_next_inflight);
  check bool "controlled receipt is absent" false
    (List.exists (fun (request, _) -> Keeper_chat.same_request_identity alpha.sent_request request) state.keeper_run_next_receipts);
  ignore (Tui_types.advance_keeper_chat_control state "beta");
  check bool "ordinary admission advancement retains the existing request receipt" true
    (Tui_types.settle_keeper_run_next state beta.sent_request (Ok "current priority") = Tui_types.Run_next_received);
  check bool "current receipt is retained" true
    (List.exists (fun (request, result) -> Keeper_chat.same_request_identity beta.sent_request request && result = Ok "current priority") state.keeper_run_next_receipts);
  check bool "duplicate callback has no effect" true
    (Tui_types.settle_keeper_run_next state beta.sent_request (Error "duplicate") = Tui_types.Run_next_untracked)

let test_priority_workspace_withdrawal () =
  let state = Tui_types.create_state ~workspace:"test" ~port:8935 ~refresh_interval:2. () in
  let old = inflight_with_log ~keeper_name:"alpha" ~started_at:1. [] in
  state.msg_inflight <- [old];
  state.keeper_run_next_inflight <- [old.sent_request];
  ignore (Tui_types.settle_keeper_run_next state old.sent_request (Ok "old receipt"));
  let generation = Tui_types.begin_keeper_chat_control state "alpha" in
  check bool "receipt is held by the pending control" true
    (Tui_types.keeper_run_next_receipt_provisional state old.sent_request);
  state.keeper_run_next_retired <- [old.sent_request];
  Tui_types.withdraw_keeper_chat_requests state;
  check bool "A receipts disappear when B becomes authoritative" true
    (state.keeper_run_next_receipts = []);
  check bool "pending control ownership disappears" true
    (state.keeper_priority_controls = [] && state.keeper_run_next_retired = []);
  Tui_types.withdraw_keeper_chat_requests state;
  let fresh = inflight_with_log ~keeper_name:"alpha" ~started_at:2. [] in
  state.msg_inflight <- [fresh];
  state.keeper_run_next_inflight <- [fresh.sent_request];
  let fresh_generation = Tui_types.begin_keeper_chat_control state "alpha" in
  Tui_types.settle_keeper_priority_control state "alpha" ~generation
    ~outcome:Tui_types.Priority_superseded;
  check bool "old A control cannot settle returned A control" true
    (Tui_types.keeper_run_next_receipt_provisional state fresh.sent_request);
  check bool "old A callback stays untracked after returning to A" true
    (Tui_types.settle_keeper_run_next state old.sent_request (Ok "late") = Tui_types.Run_next_untracked);
  Tui_types.settle_keeper_priority_control state "alpha" ~generation:fresh_generation
    ~outcome:Tui_types.Priority_unconfirmed;
  check bool "new A receipt is accepted" true
    (Tui_types.settle_keeper_run_next state fresh.sent_request (Ok "fresh") = Tui_types.Run_next_received);
  check bool "only the new receipt is present" true
    (state.keeper_run_next_receipts = [fresh.sent_request, Ok "fresh"])

let test_fusion_workspace_withdrawal () =
  let module F = Masc_tui_fetched in
  let state = Tui_types.create_state ~workspace:"test" ~port:8935 ~refresh_interval:2. () in
  let run : Masc.Tui_decode_fusion.fusion_run =
    { fur_run_id = "same-run"; fur_keeper = "alpha"; fur_preset = "A-only";
      fur_topology = Fusion_types.Simple; fur_started_at = 1.;
      fur_finished_at = Some 2.; fur_status = Masc.Tui_decode_fusion.Fusion_completed;
      fur_stage = Masc.Tui_decode_fusion.Fusion_stage_completed;
      fur_decision = None; fur_summary = None } in
  let snapshot : Masc.Tui_decode_fusion.fusion_snapshot =
    { fus_generated_at = "workspace A"; fus_runs = [run];
      fus_replay = Masc.Tui_decode_fusion.Fusion_not_replayed;
      fus_historical_evidence = [] } in
  let start () = match F.start ~equal:Unit.equal state.fusion_runs ~key:() with
    | F.Already_loading -> fail "withdrawal did not release the read owner"
    | F.Started (next, request) -> state.fusion_runs <- next; request in
  let initial = start () in
  state.fusion_runs <- F.complete ~equal:Unit.equal state.fusion_runs initial (Ok snapshot);
  let held = start () in
  let generation = state.fusion_detail_generation in
  state.fusion_mode <- Tui_types.Fusion_detail "same-run";
  state.fusion_detail_inflight <- Some (generation, "same-run");
  let reference : Masc.Tui_decode_fusion.fusion_historical_evidence =
    { fhe_run_id = "same-run"; fhe_post_id = "same-post";
      fhe_title = "A evidence"; fhe_created_at = 1. } in
  state.fusion_historical_inflight <- Some (generation, reference);
  Tui_types.withdraw_fusion_workspace state;
  check bool "B has no retained A snapshot" true
    (Option.is_none (Masc_tui_fetched.current state.fusion_runs));
  check bool "both detail owners are released" true
    (state.fusion_detail_inflight = None && state.fusion_historical_inflight = None);
  check bool "held detail answers lose their generation" true
    (generation <> state.fusion_detail_generation);
  let b = start () in
  state.fusion_runs <- F.complete ~equal:Unit.equal state.fusion_runs held (Ok snapshot);
  check bool "late A cannot release B's list owner" true
    (F.is_current ~equal:Unit.equal state.fusion_runs b);
  state.fusion_runs <- F.complete ~equal:Unit.equal state.fusion_runs b (Error "B failed");
  check bool "failed B refresh cannot retain A data" true
    (Masc_tui_fusion_model.fusion_runs_view state = F.Failed "B failed");
  Tui_types.withdraw_fusion_workspace state;
  state.fusion_mode <- Tui_types.Fusion_detail "same-run";
  check bool "returning to the same A run does not revive old detail generation" true
    (generation <> state.fusion_detail_generation);
  let current = start () in
  state.fusion_runs <- F.complete ~equal:Unit.equal state.fusion_runs held (Ok snapshot);
  check bool "late A cannot release returned A's list owner" true
    (F.is_current ~equal:Unit.equal state.fusion_runs current);
  state.fusion_runs <- F.complete ~equal:Unit.equal state.fusion_runs current (Ok snapshot);
  check bool "a new authoritative A read is accepted" true
    (match Masc_tui_fetched.current state.fusion_runs with
     | Some (_, F.Ready data) -> data = snapshot
     | _ -> false)

let test_status_details_and_fold_counts_reach_the_frame () =
  let cache = Masc_tui_ansi.terminal_size_cache in
  let previous = Masc_tui_ansi.get_terminal_size () in
  let set_size size = ignore (Masc_tui_render_schedule.Terminal_size_cache.refresh cache ~probe:(fun () -> Some size)) in
  Fun.protect ~finally:(fun () -> set_size previous) (fun () ->
    set_size (40, 160);
    let state = Tui_types.create_state ~workspace:"test" ~port:8935 ~refresh_interval:2. () in
    state.view <- Tui_types.Keepers Tui_types.Keeper_message;
    state.roster_pane_preference <- Masc_tui_roster_pane.Hidden;
    state.msg_target_keeper_name <- Some "alpha";
    let entry = inflight_with_log ~keeper_name:"alpha" ~started_at:1. [Live.Run_started] in
    state.msg_inflight <- [entry];
    state.msg_tool_visibility <- Tui_types.Tools_full;
    let unsent = Keeper_chat.create_request ~keeper_name:"alpha" ~message:"LOCAL_PREVIEW_DETAIL" () in
    (match Masc_tui_keeper_chat_queue.push state.msg_queued ~submitted_at:2. unsent with
     | Error detail -> fail detail | Ok (queue, _) -> state.msg_queued <- queue);
    state.keeper_run_next_receipts <- [entry.sent_request, Ok "ACKNOWLEDGED_PRIORITY_DETAIL"];
    let lines () = let frame, _ = Masc_tui_render_chat.render_keeper_message state in
      List.map Masc_tui_theme.strip_sgr frame.Masc_tui_frame_presenter.lines in
    let has_detail lead detail = List.exists (fun line ->
      Astring.String.is_infix ~affix:lead line && Astring.String.is_infix ~affix:detail line) (lines ()) in
    check bool "Full execution detail remains beside its lead" true
      (has_detail "Current direct conversation" (Tui_types.turn_log_execution_id entry.log));
    check bool "Full local preview remains beside its lead" true
      (has_detail "Local NEXT" "LOCAL_PREVIEW_DETAIL");
    check bool "Full priority receipt remains beside its lead" true
      (has_detail "Priority " "ACKNOWLEDGED_PRIORITY_DETAIL");
    state.msg_live <- Some entry.log;
    state.msg_queued <- Masc_tui_keeper_chat_queue.empty;
    List.iteri (fun i delta -> Tui_types.turn_log_add ~now:2. entry.log ~seq:(Some (i+1)) delta)
      [Live.Approval_requested {call_id="fold-call";tool_name="Execute";args="";question="Approve?";because="fixture"};
       Live.Approval_settled {call_id="fold-call";outcome="approved"};
       Live.Stream_protocol_error {quarantined_occurrence=None;detail="fixture unreadable event"}];
    state.msg_turn_folded <- true;
    List.iter (fun mode ->
      state.msg_tool_visibility <- mode;
      check int "only fold-hidden Approval and Attention rows are counted" 2
        (Tui_types.keeper_message_folded_status_count state entry.log.tl_transcript ~now:3.);
      check bool "compact summary offers hidden rows and expansion" true
        (has_detail "+2" Masc_tui_keys.expand_turn_label);
      state.msg_turn_folded <- false;
      check bool "unfolded status does not retain hidden count" false
        (List.exists (Astring.String.is_infix ~affix:"+2") (lines ()));
      state.msg_turn_folded <- true)
      [Tui_types.Tools_compact; Tui_types.Tools_results])

let test_verified_rejection_is_visible_without_mutating_original_input () =
  let state = Tui_types.create_state ~workspace:"test" ~port:8935 ~refresh_interval:2. () in
  let request_id = "rejected-input" in
  let row = chat_entry ~request_id
      ~role:(Tui_types.Message_user (Tui_types.Sent_by_operator {surface=None}))
      ~text:"Original request" ~at:100. () in
  state.msg_history <- [row];
  let log = Tui_types.turn_log_create ~keeper_name:"alpha" ~request_id ~started_at:100. in
  Keeper_chat_transcript.note_rejection ~now:101. log.tl_transcript "HTTP 401";
  Log.commit log.tl_log;
  Tui_types.hold_settled_log state log;
  let projected = Tui_types.chat_rows_for state "alpha" in
  check (list string) "refused input remains original speech"
    ["Original request"] (List.map (fun (row : Tui_types.msg_entry) -> row.me_text) projected);
  state.view <- Tui_types.Keepers Tui_types.Keeper_message;
  state.msg_target_keeper_name <- Some "alpha";
  state.roster_pane_preference <- Masc_tui_roster_pane.Hidden;
  let frame, _ = Masc_tui_render_chat.render_keeper_message state in
  check bool "rejection remains an explicit error" true
    (List.exists (fun line -> Astring.String.is_infix ~affix:"HTTP 401"
       (Masc_tui_theme.strip_sgr line)) frame.Masc_tui_frame_presenter.lines);
  check string "recall keeps the operator's original text" "Original request"
    (List.hd state.msg_history).me_text
;;

let test_delivery_states_and_observed_work_are_identifiable () =
  let module Layout = Masc_tui_message_layout in
  let cache = Masc_tui_ansi.terminal_size_cache in
  let previous = Masc_tui_ansi.get_terminal_size () in
  let set_size size = ignore (Masc_tui_render_schedule.Terminal_size_cache.refresh
      cache ~probe:(fun () -> Some size)) in
  Fun.protect ~finally:(fun () -> set_size previous) (fun () ->
    List.iter (fun columns ->
      set_size (60, columns);
      let state = Tui_types.create_state ~workspace:"test" ~port:8935 ~refresh_interval:2. () in
      state.view <- Tui_types.Keepers Tui_types.Keeper_message;
      state.roster_pane_preference <- Masc_tui_roster_pane.Hidden;
      state.msg_target_keeper_name <- Some "alpha";
      let entry, item = preflight_input () in
      let request = {entry.sent_request with Keeper_chat.message = "아니야 진행해"} in
      let entry = {entry with Tui_types.sent_request = request} in
      let input = chat_entry ~request_id:request.request_id
          ~role:(Tui_types.Message_user (Tui_types.Sent_by_operator {surface=None}))
          ~text:request.message ~at:1. () in
      let input = {input with Tui_types.me_identity = Session_row
          {request_id=request.request_id; turn_phase=Turn_input; operation_seq=0}} in
      state.msg_history <- [input];
      state.msg_inflight <- [entry];
      state.msg_live <- Some entry.log;
      entry.phase <- Tui_types.Turn_preflight {item with request};
      let screen () =
        let frame, _ = Masc_tui_render_chat.render_keeper_message state in
        String.concat "\n" (List.map Masc_tui_theme.strip_sgr frame.Masc_tui_frame_presenter.lines) in
      let has text needle = Astring.String.is_infix ~affix:needle text in
      let count text needle = List.length (Astring.String.cuts ~sep:needle text) - 1 in
      let pending label =
        List.iter (fun tools ->
          state.msg_tool_visibility <- tools;
          List.iter (fun origin ->
          state.msg_origin_display <- origin;
          let text = screen () in
          check int "pending input is displayed exactly once" 1 (count text "아니야 진행해");
          check bool "pending area is explicit" true (has text "대기 입력 1건");
          check bool "delivery state is explicit" true (has text label);
          check bool "pending is never claimed as reflected" false (has text "입력 반영됨");
          let bodies = Masc_tui_render_chat.chat_tail_entries state ~keeper_name:"alpha"
              ~role_label_column:20
            |> List.filter_map (fun (entry : Layout.entry) ->
                if entry.style = Layout.Local then Some entry.body else None) in
          check (list string) "pending body stays exactly as typed" ["아니야 진행해"] bodies;
          if tools = Tui_types.Tools_compact then
            check bool "technical id is not displayed" false (has text request.request_id))
          [Layout.Origin_inline; Origin_bare; Origin_row])
          [Tui_types.Tools_compact; Tools_full];
        state.msg_tool_visibility <- Tui_types.Tools_compact in
      pending "전송 대기";
      entry.phase <- Tui_types.Turn_streaming;
      pending "전송 중";
      Tui_types.turn_log_add ~now:2. entry.log ~seq:None
        (Live.Accepted {admission=Queued; queue_length=1; interactive=None});
      pending "처리 대기";
      entry.phase <- Tui_types.Turn_reconciling;
      pending "전송 확인 중";
      entry.phase <- Tui_types.Turn_streaming;
      Tui_types.turn_log_add ~now:3. entry.log ~seq:(Some 0) Live.Run_started;
      List.iter (fun origin ->
        state.msg_origin_display <- origin;
        let started = screen () in
        check int "run start promotes original input exactly once" 1 (count started "아니야 진행해");
        check bool "conversation does not add a receipt to speech" false (has started "입력 반영됨");
        check bool "started input leaves pending area" false (has started "대기 입력 1건");
        check bool "started turn has broad work status" true (has started "기존 작업 처리 중");
        List.iter (fun activity -> check bool "work alone does not invent a provider activity" false
          (has started activity)) ["THINKING"; "STREAMING"];
        let bodies = Masc_tui_render_chat.keeper_message_layout_entries state
            ~keeper_name:"alpha" ~chat_cols:columns in
        check (list string) "conversation body is original input" ["아니야 진행해"]
          (List.map (fun (entry : Layout.entry) -> entry.body) bodies))
        [Layout.Origin_inline; Origin_bare; Origin_row];
      state.msg_origin_display <- Layout.Origin_inline;
      Tui_types.turn_log_add ~now:4. entry.log ~seq:(Some 1) (Live.Thinking "OBSERVED_THOUGHT");
      let thought = screen () in
      check bool "default reasoning lane has its name" true (has thought "THINKING");
      let occurrence : Live.tool_occurrence =
        {stream_scope=0; block_index=1; provider_message_id=None; tool_call_id=Some "native-read"} in
      Tui_types.turn_log_add ~now:5. entry.log ~seq:(Some 2)
        (Live.Native_tool_started {occurrence; tool_name=Some "Read"});
      Tui_types.turn_log_add ~now:6. entry.log ~seq:(Some 3) (Live.Native_tool_ended {occurrence; completion=Runtime_native_tools.end_observed});
      Tui_types.turn_log_add ~now:7. entry.log ~seq:(Some 4) (Live.Text "OBSERVED_ANSWER");
      let streaming = screen () in
      List.iter (fun marker -> check bool ("default work label: " ^ marker) true (has streaming marker))
        ["THINKING"; "TOOLS"; "STREAMING"; "OBSERVED_ANSWER"];
      check string "display annotations do not alter recall" "아니야 진행해"
        (List.hd state.msg_history).me_text)
      [80; 140])
;;

let test_speech_keeps_original_words_across_metadata_and_retry () =
  let module Layout = Masc_tui_message_layout in
  let cache = Masc_tui_ansi.terminal_size_cache in
  let previous = Masc_tui_ansi.get_terminal_size () in
  let set_size size = ignore (Masc_tui_render_schedule.Terminal_size_cache.refresh
      cache ~probe:(fun () -> Some size)) in
  Fun.protect ~finally:(fun () -> set_size previous) (fun () ->
    List.iter (fun columns ->
      set_size (60, columns);
      List.iter (fun origin ->
        let state = Tui_types.create_state ~workspace:"test" ~port:8935 ~refresh_interval:2. () in
        state.view <- Tui_types.Keepers Tui_types.Keeper_message;
        state.roster_pane_preference <- Masc_tui_roster_pane.Hidden;
        state.msg_target_keeper_name <- Some "alpha";
        state.msg_origin_display <- origin;
        let first_id = "tui-12-first-345678901234" in
        let second_id = "tui-12-second-345678901234" in
        let user = Tui_types.Message_user (Tui_types.Sent_by_operator {surface=None}) in
        let bodies = ["엉..."; "계속할게요."; "아니야 진행해";
          "요청 tui-원문\n입력 반영됨\nTURN #123"] in
        let ids = [first_id; first_id; second_id; second_id] in
        state.msg_history <- List.mapi (fun index text ->
          let row = chat_entry ~request_id:(List.nth ids index)
              ~role:(if index mod 2 = 0 then user else Tui_types.Message_keeper)
              ~turn_sequence:(index / 2 + 1) ~text ~at:(100. +. float_of_int index) () in
          {row with Tui_types.me_identity=Persisted_row (Printf.sprintf "original-%d" index)}) bodies;
        let entries = Masc_tui_render_chat.keeper_message_layout_entries state
            ~keeper_name:"alpha" ~chat_cols:columns in
        check (list string) "recorded speech is exact, including diagnostic-looking words"
          bodies (List.map (fun (entry : Layout.entry) -> entry.body) entries);
        check (list string) "visually similar ids retain distinct full grouping keys"
          ids (List.map (fun (entry : Layout.entry) -> entry.request_label) entries);
        let live = inflight_with_log ~keeper_name:"alpha" ~started_at:110.
            [ Live.Run_started
            ; Live.Runtime_attempt_started {runtime_id=Some "codex-original"; attempt_index=Some 0}
            ; Live.Text "처음 답변 그대로"
            ; Live.Runtime_attempt_started {runtime_id=Some "claude-retry"; attempt_index=Some 1}
            ; Live.Text "이어서 답변 그대로" ] in
        state.msg_inflight <- [live];
        state.msg_live <- Some live.log;
        let frame, _ = Masc_tui_render_chat.render_keeper_message state in
        let plain = List.map Masc_tui_theme.strip_sgr frame.Masc_tui_frame_presenter.lines in
        let screen = String.concat "\n" plain in
        let count needle = List.length (Astring.String.cuts ~sep:needle screen) - 1 in
        List.iter (fun body ->
          List.iter (fun line -> check int ("exact original screen text: " ^ line) 1 (count line))
            (String.split_on_char '\n' body))
          (bodies @ ["처음 답변 그대로"; "이어서 답변 그대로"]);
        List.iter (fun metadata -> check int "no generated metadata in speech" 0 (count metadata))
          [first_id; second_id; "TURN #1 ·"; "TURN #2 ·"; "attempt 1:"];
        let pending_request = Keeper_chat.create_request ~keeper_name:"alpha"
            ~message:"요청 문구도 원문\n입력 반영됨도 원문" () in
        (match Masc_tui_keeper_chat_queue.push state.msg_queued ~submitted_at:111. pending_request with
         | Error detail -> fail detail
         | Ok (queue, _) -> state.msg_queued <- queue);
        let pending = Masc_tui_render_chat.chat_tail_entries state ~keeper_name:"alpha"
            ~role_label_column:(Layout.chat_role_label_width ~pane_cells:columns) in
        check (list string) "pending diagnostic-looking words are not removed"
          [pending_request.message]
          (List.filter_map (fun (entry : Layout.entry) ->
            if entry.style = Layout.Local then Some entry.body else None) pending);
        let frame, _ = Masc_tui_render_chat.render_keeper_message state in
        let screen = String.concat "\n"
            (List.map Masc_tui_theme.strip_sgr frame.Masc_tui_frame_presenter.lines) in
        List.iter (fun line -> check int "pending literal original is drawn once" 1
          (List.length (Astring.String.cuts ~sep:line screen) - 1))
          (String.split_on_char '\n' pending_request.message);
        state.msg_history <- [];
        state.msg_inflight <- [];
        state.msg_live <- None;
        state.msg_queued <- Masc_tui_keeper_chat_queue.empty;
        state.keeper_turns <- [{Tui_decode.ktr_keeper_name="alpha"; ktr_chat_control_token=None;
          ktr_state=Keeper_turn_running {lane=Turn_lane_maintenance; started_at_unix=120.;
            interrupt_token="preview-stop"; turn_ref=None;
            preview=Some {ktp_status_text="working"; ktp_updated_at_unix=121.;
              ktp_text_tail="관측 답변 원문"; ktp_last_tool=None}}}];
        let preview = Masc_tui_render_chat.polled_turn_output_entries state ~keeper_name:"alpha"
            ~role_label_column:(Layout.chat_role_label_width ~pane_cells:columns) in
        check (list string) "polled speech separates its observation status"
          ["관측 답변 원문"]
          (List.filter_map (fun (entry : Layout.entry) ->
            if entry.style = Layout.Keeper then Some entry.body else None) preview);
        let frame, _ = Masc_tui_render_chat.render_keeper_message state in
        let plain = List.map Masc_tui_theme.strip_sgr frame.Masc_tui_frame_presenter.lines in
        check int "polled original appears once" 1
          (List.length (List.filter (Astring.String.is_infix ~affix:"관측 답변 원문") plain));
        check bool "polled observation retains its separate status" true
          (List.exists (Astring.String.is_infix ~affix:"최근 출력 발췌") plain))
        [Layout.Origin_inline; Origin_bare; Origin_row])
      [80; 140])
;;

let test_search_measures_original_message_rows () =
  let cache = Masc_tui_ansi.terminal_size_cache in
  let previous = Masc_tui_ansi.get_terminal_size () in
  let set_size size = ignore (Masc_tui_render_schedule.Terminal_size_cache.refresh
      cache ~probe:(fun () -> Some size)) in
  Fun.protect ~finally:(fun () -> set_size previous) (fun () ->
    List.iter (fun columns ->
    set_size (24, columns);
    List.iter (fun origin ->
    let state = Tui_types.create_state ~workspace:"test" ~port:8935 ~refresh_interval:2. () in
    state.view <- Tui_types.Keepers Tui_types.Keeper_message;
    state.roster_pane_preference <- Masc_tui_roster_pane.Hidden;
    state.msg_target_keeper_name <- Some "alpha";
    state.msg_origin_display <- origin;
    state.msg_history <- List.init 24 (fun index ->
      let id = Printf.sprintf "search-%d" index in
      let row = chat_entry ~request_id:id
          ~role:(Tui_types.Message_user (Tui_types.Sent_by_operator {surface=None}))
          ~text:(if index = 0 then "SEARCH_TARGET" else Printf.sprintf "newer input %d" index)
          ~at:(100. +. float_of_int index) () in
      let reply = chat_entry ~request_id:id ~turn_sequence:(index + 1)
          ~role:Tui_types.Message_keeper ~text:"recorded reply"
          ~at:(100.5 +. float_of_int index) () in
      [{row with Tui_types.me_identity=Persisted_row id};
       {reply with Tui_types.me_identity=Persisted_row (id ^ "-reply")}]) |> List.concat;
    let newest, _ = Masc_tui_render_chat.render_keeper_message state in
    check bool "turn metadata is not added to speech" false
      (List.exists (fun line -> Astring.String.is_infix ~affix:"TURN #24"
          (Masc_tui_theme.strip_sgr line)) newest.Masc_tui_frame_presenter.lines);
    match Masc_tui_render_chat.keeper_message_find_scroll state ~keeper_name:"alpha"
        ~needle:"SEARCH_TARGET" ~older_than:None with
    | None -> fail "search lost the original input"
    | Some (position, _) ->
        Tui_types.apply_clamped_scroll state (Tui_types.Message_scroll position);
        let frame, _ = Masc_tui_render_chat.render_keeper_message state in
        check bool "search uses the same original message rows as the frame" true
          (List.exists (fun line -> Astring.String.is_infix ~affix:"SEARCH_TARGET"
              (Masc_tui_theme.strip_sgr line)) frame.Masc_tui_frame_presenter.lines))
      [Masc_tui_message_layout.Origin_inline; Origin_bare; Origin_row])
      [80; 140])
;;

let () =
  run
    "tui_chat_queue_wiring"
    [ ( "visible delivery",
        [ test_case "pending to observed work" `Quick test_delivery_states_and_observed_work_are_identifiable
        ; test_case "speech preserves original words" `Quick test_speech_keeps_original_words_across_metadata_and_retry
        ; test_case "search measures original rows" `Quick test_search_measures_original_message_rows ] )
    ; ( "rejected input", [test_case "refusal preserves original input" `Quick test_verified_rejection_is_visible_without_mutating_original_input] )
    ; ( "status ownership",
        [ test_case "withdrawal restores only input before the first POST" `Quick test_withdrawal_restores_only_input_before_the_first_post
        ; test_case "preflight recovery keeps newer input and full queue" `Quick test_preflight_recovery_keeps_newer_input_and_a_full_queue
        ; test_case "preflight recovery preserves order and steer intent" `Quick test_preflight_recovery_preserves_order_and_steer_intent
        ; test_case "preflight local resume preserves FIFO and server stops" `Quick test_preflight_local_resume_keeps_fifo_and_respects_server_stop
        ; test_case "workspace suspension preserves real stop ownership" `Quick test_workspace_suspension_preserves_real_stop_ownership
        ; test_case "unmarked input respects composer and recall ownership" `Quick test_unmarked_input_cannot_escape_composer_or_recall_ownership
        ; test_case "new Enter bypasses an explicit stop hold" `Quick test_new_enter_can_bypass_an_explicitly_stopped_input
        ; test_case "empty composer preserves already queued input order" `Quick test_empty_composer_cannot_reverse_already_queued_input
        ; test_case "preflight restoration preserves submission chronology" `Quick test_preflight_restoration_preserves_submission_chronology
        ; test_case "offscreen preflight recovery retains its owner" `Quick test_offscreen_preflight_recovery_retains_its_owner
        ; test_case "priority workspace withdrawal" `Quick test_priority_workspace_withdrawal
        ; test_case "Fusion workspace withdrawal" `Quick test_fusion_workspace_withdrawal
        ; test_case "priority completions survive controls" `Quick test_priority_completion_survives_controls
        ; test_case "status details and fold counts reach the frame" `Quick test_status_details_and_fold_counts_reach_the_frame ] )
    ; ( "link card layout", [test_case "actual body width and preview cache changes" `Quick test_link_cards_use_actual_message_body_width] )
    ; ( "wiring"
      , [ test_case "queue summary follows admission and execution" `Quick test_queue_summary_follows_admission_and_execution
        ; test_case "checkpoint watcher allows new input" `Quick test_checkpoint_watcher_allows_new_input
        ; test_case "older queued watcher cannot rearm acknowledged stop" `Quick
            test_old_queued_watcher_does_not_rearm_esc
        ; test_case "four request batch source selection" `Quick
            test_batch_source_selection_preserves_four_request_history
        ; test_case "history and renderer share inflight candidates" `Quick
            test_history_and_renderer_share_all_inflight_candidates
        ; test_case "batch watchers render one shared turn" `Quick test_batch_watchers_render_one_shared_settled_turn
        ; test_case "batch reply follows all original inputs" `Quick test_batch_reply_follows_all_original_inputs
        ; test_case "observed checkpoint retains earlier output" `Quick test_observed_checkpoint_retains_earlier_output
        ; test_case "continuation output interleaves at event time" `Quick
            test_continuation_output_interleaves_at_its_event_time
        ; test_case "every request of a held batch is held for journal reads" `Quick
            test_every_request_of_a_held_batch_is_held_for_journal_reads
        ; test_case "observed interrupt response identity" `Quick test_observed_interrupt_response_identity
        ; test_case "an interrupt receipt is bound to the exact request" `Quick
            test_interrupt_receipt_is_bound_to_the_exact_request
        ; test_case "pending admission pause is not cancellation" `Quick
            test_pending_admission_pause_is_not_a_cancellation_claim
        ; test_case "stop acknowledgement releases only later input" `Quick
            test_stop_ack_releases_only_input_after_that_stop
        ; test_case "late interrupt outcomes cannot mark newer controls" `Quick
            test_late_interrupt_outcome_cannot_mark_newer_control
        ; test_case "control receipts are per Keeper" `Quick
            test_control_receipts_are_scoped_to_each_keeper
        ; test_case "new control discards only its Keeper priority intents" `Quick
            test_new_control_discards_only_its_keeper_priority_intents
        ; test_case "another keeper's request does not pin this pane" `Quick
            test_a_request_to_another_keeper_does_not_pin_this_pane
        ; test_case "live transcripts are kept per Keeper" `Quick
            test_live_transcripts_are_kept_per_keeper
        ; test_case "a turn log folds each accepted delta once" `Quick
            test_a_turn_log_folds_each_accepted_delta_once
        ; test_case "replayed frames up to the last seq are not added twice" `Quick
            test_replayed_frames_up_to_the_last_seq_are_not_added_twice
        ; test_case "the reply row defers to a log that holds the turn" `Quick
            test_the_reply_row_defers_to_a_log_that_holds_the_turn
        ; test_case "a settled log holds its turn in the timeline" `Quick
            test_a_settled_log_holds_its_turn_in_the_timeline
        ; test_case "a log without reasoning leaves the trace row" `Quick
            test_a_log_without_reasoning_leaves_the_trace_row
        ; test_case "an unfinished settled log suppresses nothing" `Quick
            test_an_unfinished_settled_log_suppresses_nothing
        ; test_case "settle_turn_log commits, holds and clears live" `Quick
            test_settle_turn_log_commits_holds_and_clears_live
        ; test_case "a settled block sits before its request's output rows" `Quick
            test_a_settled_block_sits_before_its_requests_output_rows
        ; test_case "loaded tool facts are folded into the held log" `Quick
            test_loaded_tool_facts_are_folded_into_the_held_log
        ; test_case "loaded skill evidence is folded into the held log" `Quick
            test_loaded_skill_evidence_is_folded_into_the_held_log
        ; test_case "skill evidence stands for a read the trail missed" `Quick
            test_skill_evidence_stands_for_a_read_the_trail_missed
        ; test_case "a failed skill call keeps its failure" `Quick
            test_a_failed_skill_call_keeps_its_failure
        ; test_case "settled logs are read per keeper" `Quick
            test_settled_logs_are_read_per_keeper
        ; test_case "journal fetch targets choose the newest unheld turns" `Quick
            test_journal_fetch_targets_choose_the_newest_unheld_turns
        ; test_case "the acceptance is read but not logged" `Quick
            test_the_acceptance_is_read_but_not_logged
        ; test_case "admission notice precedes earlier buffered reply" `Quick
            test_admission_notice_precedes_earlier_buffered_reply
        ; test_case "batch receipts survive source selection and continuation" `Quick
            test_batch_receipts_survive_source_selection_and_continuation
        ; test_case "priority feedback is receipt metadata" `Quick test_priority_feedback_is_receipt_metadata
        ; test_case "a journal read resumes after a partial log" `Quick
            test_a_journal_read_resumes_after_a_partial_log
        ; test_case "a journal fills a turn log at the lines' own times" `Quick
            test_a_journal_fills_a_turn_log_at_the_lines_own_times
        ; test_case "journal receipts only name newly folded results" `Quick
            test_journal_receipts_only_name_newly_folded_results
        ; test_case "hold_settled_log orders by start and replaces only partial logs"
            `Quick test_hold_settled_log_orders_by_start_and_replaces_only_partial_logs
        ; test_case "a journal-built log holds its turn in the timeline" `Quick
            test_a_journal_built_log_holds_its_turn_in_the_timeline
        ; test_case "promoted live output survives settlement and replay" `Quick
            test_promoted_live_output_survives_settlement_and_replay
        ; test_case "replayed chat failure is visible without a history error" `Quick
            test_replayed_chat_failure_is_visible_without_a_history_error
        ; test_case "failed live sibling stays visible when focus changes" `Quick
            test_failed_live_sibling_stays_visible_when_focus_changes
        ; test_case "a journal revision draws its facts in columns" `Quick
            test_a_journal_revision_draws_its_facts_in_columns
        ; test_case "a failing librarian is named on the header" `Quick
            test_a_failing_librarian_is_named_on_the_header
        ; test_case "a folded reasoning block is the count and the key" `Quick
            test_a_folded_reasoning_block_is_the_count_and_the_key
        ; test_case "an arrival reads behind a bar" `Quick
            test_an_arrival_reads_behind_a_bar
        ; test_case "an execute call leads with its exit and output" `Quick
            test_an_execute_call_leads_with_its_exit_and_output
        ; test_case "mismatched rows make results incomplete" `Quick
            test_mismatched_keeper_rows_make_results_incomplete
        ; test_case "held results follow async snapshots" `Quick
            test_held_tool_results_follow_async_snapshot_changes
        ; test_case "a nameless heading is the mark and the rule" `Quick
            test_a_nameless_heading_is_the_mark_and_the_rule
        ; test_case "the origin heading spells the name and ends on the clock" `Quick
            test_origin_row_heading_spells_the_name_and_ends_on_the_clock
        ; test_case "new input preserves running output" `Quick test_new_input_preserves_running_output
        ; test_case "an observed running turn is drawn from its journal" `Quick
            test_an_observed_running_turn_is_drawn_from_its_journal
        ; test_case "the pane's own turn is live in flight and observed once cut" `Quick
            test_the_panes_own_turn_is_live_in_flight_and_observed_once_cut
        ; test_case "partial observation survives history ending and unavailable journal" `Quick
            test_partial_observation_survives_history_ending_and_unavailable_journal
        ; test_case "observed handoff retains progress and one final reply" `Quick
            test_observed_history_handoff_keeps_progress_and_one_final_reply
        ; test_case "a journal log of the live execution is not observed" `Quick
            test_a_journal_log_of_the_live_execution_is_not_observed
        ; test_case "hidden partial reply cannot remove durable final reply" `Quick
            test_hidden_partial_reply_cannot_remove_the_durable_reply
        ; test_case "a stream frame asks for a journal read from where the record ends" `Quick
            test_a_stream_frame_asks_for_a_journal_read_from_where_the_record_ends
        ; test_case "a wanted journal read is remembered once and taken once" `Quick
            test_a_wanted_journal_read_is_remembered_once_and_taken_once
        ; test_case "history cannot retire a partial journal" `Quick
            test_history_cannot_retire_a_partial_journal
        ; test_case "journal endpoint and terminal boundaries" `Quick
            test_journal_endpoints_preserve_terminal_and_failure_boundaries
        ; test_case "journal tracking keeps keeper and source identity" `Quick
            test_journal_tracking_keeps_keeper_and_source_identity
        ; test_case "a journal-built log starts at the journal head" `Quick
            test_a_journal_built_log_starts_at_the_journal_head
        ; test_case "pending input enters transcript on execution evidence" `Quick
            test_pending_input_enters_transcript_only_when_execution_is_observed
        ; test_case "message scroll accepts the rendered clamp" `Quick
            test_message_scroll_accepts_the_rendered_clamp
        ; test_case "resource scroll accepts the rendered clamp" `Quick
            test_resource_scroll_accepts_the_rendered_clamp
        ; test_case "approval detail scroll accepts the rendered clamp" `Quick
            test_approval_detail_scroll_accepts_the_rendered_clamp
        ; test_case "chat visibility defaults and cycles" `Quick
            test_chat_visibility_defaults_and_cycles
        ; test_case "the header names only unusual modes" `Quick
            test_the_header_names_only_unusual_modes
        ; test_case "every header mode is named by a footer key" `Quick
            test_every_header_mode_is_named_by_a_footer_key
        ; test_case "chat header resolves effective modes" `Quick
            test_chat_header_resolves_the_effective_modes
        ; test_case "Skill usage time stays honest" `Quick
            test_skill_usage_time_does_not_invent_never
        ; test_case "composing holds only while the composer is live" `Quick
            test_composing_holds_only_while_the_composer_is_live
        ; test_case "the support threshold reserves the scrollback row" `Quick
            test_the_support_threshold_reserves_the_scrollback_row
        ; test_case "the sending rows show an age" `Quick
            test_the_sending_rows_show_an_age
        ; test_case "a refresh keeps what was paged back to" `Quick
            test_a_refresh_keeps_what_was_paged_back_to
        ; test_case "a refresh does not double the overlap" `Quick
            test_a_refresh_does_not_double_the_overlap
        ; test_case "a row the window evicted stays visible" `Quick
            test_a_row_the_window_evicted_stays_visible
        ; test_case "an empty refresh keeps the transcript" `Quick
            test_an_empty_refresh_keeps_the_transcript
        ; test_case "oldest_at reports the cursor" `Quick
            test_oldest_at_reports_the_cursor
        ; test_case "visible clock stays monotonic inside one turn" `Quick
            test_visible_clock_stays_monotonic_inside_one_causal_turn
        ; test_case "Journal interleaves one request by displayed time" `Quick
            test_journal_interleaves_request_and_reply_by_displayed_time
        ; test_case "same request normalizes exact-clock turn sequence" `Quick
            test_same_request_exact_clock_normalizes_the_turn_sequence
        ; test_case "distinct requests retain exact-clock producer order" `Quick
            test_distinct_requests_keep_producer_order_on_exact_clock_tie
        ; test_case "turn sequence breaks equal-clock ties" `Quick
            test_absolute_turn_sequence_breaks_equal_clock_ties
        ; test_case "running turn shares displayed time" `Quick
            test_running_turn_does_not_escape_the_displayed_time_axis
        ; test_case "parallel blocks order a shared insertion slot" `Quick
            test_parallel_blocks_share_a_chronological_insertion_slot
        ; test_case "live gutter follows causal frontier" `Quick
            test_live_gutter_clock_matches_its_causal_frontier
        ; test_case "uncommitted live shares visible clock" `Quick
            test_uncommitted_live_turn_inserts_on_the_visible_clock_axis
        ; test_case "live uses latest committed causal frontier" `Quick
            test_live_turn_uses_its_latest_committed_causal_frontier
        ; test_case "live follows clockless same-request input" `Quick
            test_live_turn_follows_an_unknown_same_request_row
        ; test_case "hidden phase keeps timeline projection" `Quick
            test_hidden_phase_keeps_its_timeline_projection
        ; test_case "unknown phase inherits causal frontier" `Quick
            test_unknown_phase_clock_inherits_the_causal_frontier
        ; test_case "producer append keeps scroll pin" `Quick
            test_producer_append_keeps_a_structural_scroll_pin
        ; test_case "find anchor survives producer prepend" `Quick
            test_find_anchor_survives_a_producer_prepend
        ; test_case "scroll anchor follows structure" `Quick
            test_scroll_anchor_follows_structure_not_clock
        ; test_case "scroll anchor distinguishes duplicate text" `Quick
            test_scroll_anchor_distinguishes_duplicate_text_in_one_turn
        ; test_case "scroll anchor survives USER persistence" `Quick
            test_scroll_anchor_survives_session_user_persistence
        ] )
    ; ( "roster default"
      , [ test_case "chat default preserves explicit preference" `Quick
            test_roster_starts_hidden_until_explicitly_opened
        ; test_case "hidden roster releases focus and retains the conversation" `Quick
            test_hidden_chat_roster_releases_focus_without_changing_conversation ] )
    ; ( "queue"
      , [ test_case "take_newest returns the last and keeps order" `Quick
            test_take_newest_returns_last_and_keeps_order
        ; test_case "pending preview is bounded" `Quick
            test_pending_preview_is_bounded_and_keeps_the_newest_submission
        ] )
    ; ( "skill marks"
      , [ test_case "every state chooses its tone" `Quick
            test_every_skill_state_chooses_its_tone
        ; test_case "only a moving skill wears the live mark" `Quick
            test_only_a_moving_skill_wears_the_live_mark
        ] )
    ]
;;

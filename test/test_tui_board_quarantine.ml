(* The Info tab's Board-attention rows: the inventory codec round trip the TUI
   decode rests on, the decode that keeps a row it cannot read, and the lines
   and requeue target the tab draws from them. *)

open Alcotest
module Command = Masc.Keeper_board_attention_quarantine_command
module Candidate = Masc.Keeper_board_attention_candidate
module Quarantine = Masc_tui_board_quarantine

let item ?(phase = Command.Inventory_quarantined)
    ?(category = Candidate.Exact_execution_quarantined) ?(requested_at = None)
    ?(requeued_at = None) ~partition_id ~quarantined_at () : Command.inventory_item =
  { Command.keeper_name = "alpha"
  ; partition_id
  ; candidate_id = "cand-" ^ partition_id
  ; quarantine_id = "q-" ^ partition_id
  ; phase
  ; failure_category = category
  ; attempt_provenance =
      Some
        { Candidate.slot_id = "slot-1"
        ; call_id = "call-1"
        ; plan_fingerprint = "plan-1"
        ; request_body_sha256 = "sha-1"
        }
  ; quarantined_at
  ; requested_at
  ; requeued_at
  }
;;

let inventory_json items errors =
  Command.inventory_to_json { Command.items; errors }
;;

let items_of_json json =
  match json with
  | `Assoc fields ->
    (match List.assoc_opt "items" fields with
     | Some (`List items) -> items
     | _ -> fail "inventory json has no items list")
  | _ -> fail "inventory json is not an object"
;;

let test_inventory_item_round_trips () =
  let items =
    [ item ~partition_id:"ba-root-a" ~quarantined_at:100.0 ()
    ; item ~phase:Command.Inventory_requeue_requested
        ~category:Candidate.Domain_output_invalid ~requested_at:(Some 150.0)
        ~partition_id:"ba-root-b" ~quarantined_at:120.0 ()
    ; { (item ~phase:Command.Inventory_requeued ~requeued_at:(Some 160.0)
           ~partition_id:"ba-root-c" ~quarantined_at:130.0 ())
        with
        Command.attempt_provenance = None
      }
    ]
  in
  let decoded =
    inventory_json items []
    |> items_of_json
    |> List.map Command.inventory_item_of_json
  in
  check bool "every item reads back as the item written" true
    (decoded = List.map (fun item -> Ok item) items)
;;

let test_inventory_item_rejects_an_unknown_category () =
  let json =
    match items_of_json (inventory_json [ item ~partition_id:"p" ~quarantined_at:1.0 () ] []) with
    | [ `Assoc fields ] ->
      `Assoc
        (("failure_category", `String "a_category_from_a_newer_server")
         :: List.remove_assoc "failure_category" fields)
    | _ -> fail "expected one item"
  in
  check bool "an unknown category is an error, not a default" true
    (Result.is_error (Command.inventory_item_of_json json))
;;

let test_request_body_is_what_the_route_parses () =
  let request = Quarantine.requeue_request (item ~partition_id:"p" ~quarantined_at:1.0 ()) in
  check bool "the body the TUI sends parses back to the same request" true
    (Command.parse_request (Command.request_to_json request) = Ok request);
  check string "fenced by the quarantine id the row was read with" "q-p"
    request.Command.expected_quarantine_id;
  check string "names the row's candidate" "cand-p" request.Command.candidate_id
;;

let decode_ok json =
  match Quarantine.decode json with
  | Ok decoded -> decoded
  | Error detail -> fail detail
;;

let test_decode_keeps_a_row_it_cannot_read () =
  let json =
    match inventory_json [ item ~partition_id:"good" ~quarantined_at:1.0 () ] [] with
    | `Assoc fields ->
      let items =
        items_of_json (`Assoc fields) @ [ `Assoc [ "partition_id", `String "bad" ] ]
      in
      `Assoc (("items", `List items) :: List.remove_assoc "items" fields)
    | _ -> fail "inventory json is not an object"
  in
  let decoded = decode_ok json in
  check int "both rows are kept" 2 (List.length decoded.Quarantine.rows);
  check int "the readable one is still waiting" 1
    (List.length (Quarantine.waiting decoded));
  check bool "a body that is not the inventory is an error" true
    (Result.is_error (Quarantine.decode (`List [])))
;;

let test_decode_reads_ledger_errors () =
  let decoded =
    decode_ok
      (inventory_json []
         [ { Command.keeper_name = "alpha"
           ; kind = Command.Inventory_candidate_ledger_unavailable
           }
         ])
  in
  check int "one ledger error" 1 (List.length decoded.Quarantine.errors);
  check int "no unreadable error rows" 0
    (List.length decoded.Quarantine.unreadable_errors)
;;

let fixture_quarantines () =
  decode_ok
    (inventory_json
       [ item ~partition_id:"ba-root-new" ~quarantined_at:900.0 ()
       ; item ~partition_id:"ba-root-old" ~quarantined_at:100.0 ()
       ; item ~phase:Command.Inventory_requeued ~requeued_at:(Some 950.0)
           ~partition_id:"ba-root-done" ~quarantined_at:50.0 ()
       ]
       [])
;;

let test_the_requeue_key_takes_the_oldest_waiting_row () =
  let quarantines = fixture_quarantines () in
  check (list string) "waiting rows, oldest first, requeued left out"
    [ "ba-root-old"; "ba-root-new" ]
    (List.map
       (fun (item : Command.inventory_item) -> item.Command.partition_id)
       (Quarantine.waiting quarantines));
  check (option string) "the key's target" (Some "ba-root-old")
    (Option.map
       (fun (item : Command.inventory_item) -> item.Command.partition_id)
       (Quarantine.oldest_waiting quarantines))
;;

let ready_fetched ~keeper_name value =
  match Masc_tui_fetched.start ~equal:String.equal Masc_tui_fetched.initial ~key:keeper_name with
  | Masc_tui_fetched.Already_loading -> fail "a fresh read cannot already be loading"
  | Masc_tui_fetched.Started (next, request) ->
    Masc_tui_fetched.complete ~equal:String.equal next request value
;;

let contains ~needle haystack =
  let n = String.length needle and h = String.length haystack in
  let rec at i = i + n <= h && (String.sub haystack i n = needle || at (i + 1)) in
  at 0
;;

let texts lines = List.map snd lines

let test_lines_say_how_many_are_blocked_and_why () =
  let fetched = ready_fetched ~keeper_name:"alpha" (Ok (fixture_quarantines ())) in
  let lines = Quarantine.lines ~now:1000.0 fetched ~keeper_name:"alpha" in
  (match lines with
   | (Quarantine.Warn, summary) :: _ ->
     check bool "the count leads" true (contains ~needle:"2 blocked" summary);
     check bool "and names the key" true (contains ~needle:"Q requeues" summary)
   | _ -> fail "the first line is not the warning summary");
  let body = String.concat "\n" (texts lines) in
  check bool "the oldest row gives its age" true (contains ~needle:"15m ago" body);
  check bool "the reason is in words" true
    (contains ~needle:(Quarantine.category_words Candidate.Exact_execution_quarantined) body);
  check bool "the partition id is shown" true (contains ~needle:"ba-root-old" body);
  check bool "the requeued row is counted apart" true
    (contains ~needle:"1 requeued" body);
  check bool "a requeued row is not listed as blocked" false
    (contains ~needle:"ba-root-done" body)
;;

let test_lines_for_every_read_state () =
  let absent = Quarantine.lines ~now:0.0 Masc_tui_fetched.initial ~keeper_name:"alpha" in
  check (list string) "never read" [ "not read yet" ] (texts absent);
  let failed =
    Quarantine.lines ~now:0.0
      (ready_fetched ~keeper_name:"alpha" (Error "HTTP 503"))
      ~keeper_name:"alpha"
  in
  (match failed with
   | [ (Quarantine.Bad, text) ] ->
     check bool "a failed read says so" true (contains ~needle:"HTTP 503" text)
   | _ -> fail "a failed read is one Bad line");
  let other_keeper =
    Quarantine.lines ~now:0.0
      (ready_fetched ~keeper_name:"alpha" (Ok (fixture_quarantines ())))
      ~keeper_name:"beta"
  in
  check bool "another Keeper's rows are not drawn as this one's" false
    (contains ~needle:"blocked," (String.concat "\n" (texts other_keeper)));
  let empty =
    Quarantine.lines ~now:0.0
      (ready_fetched ~keeper_name:"alpha" (Ok (decode_ok (inventory_json [] []))))
      ~keeper_name:"alpha"
  in
  check (list string) "nothing to requeue" [ "nothing blocked" ] (texts empty)
;;

let test_wire_strings_are_sanitized () =
  let quarantines =
    decode_ok
      (inventory_json
         [ item ~partition_id:"ba-root-\x1b[2Jevil" ~quarantined_at:1.0 () ]
         [ { Command.keeper_name = "alpha\x1b]0;title\x07"
           ; kind = Command.Inventory_candidate_ledger_unavailable
           }
         ])
  in
  let lines =
    Quarantine.lines ~now:2.0
      (ready_fetched ~keeper_name:"alpha" (Ok quarantines))
      ~keeper_name:"alpha"
  in
  List.iter
    (fun (_, text) ->
       check bool ("no raw escape in " ^ String.escaped text) false
         (String.contains text '\x1b'))
    lines
;;

let () =
  run "tui-board-quarantine"
    [ ( "codec"
      , [ test_case "inventory item round trips" `Quick test_inventory_item_round_trips
        ; test_case "unknown category is an error" `Quick
            test_inventory_item_rejects_an_unknown_category
        ; test_case "request body parses back" `Quick
            test_request_body_is_what_the_route_parses
        ] )
    ; ( "decode"
      , [ test_case "keeps an unreadable row" `Quick test_decode_keeps_a_row_it_cannot_read
        ; test_case "reads ledger errors" `Quick test_decode_reads_ledger_errors
        ] )
    ; ( "lines"
      , [ test_case "requeue takes the oldest waiting row" `Quick
            test_the_requeue_key_takes_the_oldest_waiting_row
        ; test_case "count and reason" `Quick test_lines_say_how_many_are_blocked_and_why
        ; test_case "every read state" `Quick test_lines_for_every_read_state
        ; test_case "wire strings are sanitized" `Quick test_wire_strings_are_sanitized
        ] )
    ]
;;

(* The newest turns of one Keeper, read from a turn-records page (RFC-0515
   section 2.5). The screen text is not tested; which turns come back, in what
   order, and what each one says about how it stopped are. *)

open Alcotest
module Turns = Masc_tui_keeper_turns

let record ?finish_reason ~turn ~ts () : Turn_record.t =
  { request_observations = []
  ; execution_ids = []
  ; keeper = "omega"
  ; agent_name = "keeper-omega"
  ; turn_kind = Direct
  ; trace_id = "trace-story"
  ; absolute_turn = turn
  ; turn_ref = Ids.Turn_ref.make ~trace_id:"trace-story" ~absolute_turn:turn
  ; blocks = []
  ; input_components = None
  ; tool_surface_ref = None
  ; runtime_profile = "glm-coding"
  ; selected_model = Some "glm-5.3"
  ; finish_reason
  ; context_window = Some 200_000
  ; provider_context_window = None
  ; price_input_per_million = None
  ; price_output_per_million = None
  ; request_latency_ms = Some 1200
  ; ttfrc_ms = Some 80.
  ; request_wire_observation = None
  ; model_input_window = None
  ; response_observed_model_input = None
  ; refused_model_input = None
  ; raw_trace_run_ref = None
  ; sampling =
      { temperature = Some 0.2
      ; top_p = None
      ; max_tokens = None
      ; enable_thinking = Some true
      }
  ; usage =
      { input_tokens = Some 1000
      ; output_tokens = Some 200
      ; cache_creation_input_tokens = None
      ; cache_read_input_tokens = Some 500
      ; scope = Runtime_usage_scope.Per_request
      ; input_provenance = None
      }
  ; turn_output_tokens = None
  ; ts
  }
;;

let page ?(keeper = "omega") ?(skipped = 0) records =
  `Assoc
    [ "keeper", `String keeper
    ; "skipped_rows", `Int skipped
    ; "entries", `List (List.map (fun r -> `Assoc [ "record", Turn_record.to_json r ]) records)
    ]
;;

let read records =
  match Turns.decode ~keeper:"omega" (page records) with
  | Ok turns -> turns
  | Error reason -> fail reason
;;

let stop_to_string = function
  | Turns.Stopped reason -> "stopped:" ^ reason
  | Turns.No_stop_reason -> "no stop reason"
;;

let stop_testable =
  testable (fun ppf stop -> Format.pp_print_string ppf (stop_to_string stop)) ( = )
;;

let test_stop_reason_is_kept_as_written () =
  let turns =
    read
      [ record ~turn:1 ~ts:1_787_600_000.5 ~finish_reason:"end_turn" ()
      ; record ~turn:2 ~ts:1_787_600_100.5 ()
      ; record ~turn:3 ~ts:1_787_600_200.5 ~finish_reason:"a_reason_no_one_listed" ()
      ]
  in
  check (list stop_testable) "each turn says how it stopped, as recorded"
    [ Turns.Stopped "end_turn"
    ; Turns.No_stop_reason
    ; Turns.Stopped "a_reason_no_one_listed"
    ]
    (List.map (fun (turn : Turns.turn) -> turn.stop) turns);
  check (list (float 0.)) "each turn is placed at its record time"
    [ 1_787_600_000.5; 1_787_600_100.5; 1_787_600_200.5 ]
    (List.map (fun (turn : Turns.turn) -> turn.at) turns)
;;

let test_turns_are_ordered_by_time_not_page_order () =
  let turns =
    read
      [ record ~turn:3 ~ts:300.5 ~finish_reason:"c" ()
      ; record ~turn:1 ~ts:100.5 ~finish_reason:"a" ()
      ; record ~turn:2 ~ts:200.5 ~finish_reason:"b" ()
      ]
  in
  check (list stop_testable) "oldest first whatever order the page came in"
    [ Turns.Stopped "a"; Turns.Stopped "b"; Turns.Stopped "c" ]
    (List.map (fun (turn : Turns.turn) -> turn.stop) turns)
;;

let test_equal_times_keep_the_page_order () =
  let turns =
    read
      [ record ~turn:1 ~ts:100.5 ~finish_reason:"first" ()
      ; record ~turn:2 ~ts:100.5 ~finish_reason:"second" ()
      ]
  in
  check (list stop_testable) "records written at one instant keep the page's order"
    [ Turns.Stopped "first"; Turns.Stopped "second" ]
    (List.map (fun (turn : Turns.turn) -> turn.stop) turns)
;;

let test_empty_page () =
  check int "an empty page holds no turns" 0 (List.length (read []))
;;

let test_refuses_partial_or_other_keeper () =
  let r = record ~turn:1 ~ts:100.5 ~finish_reason:"end_turn" () in
  List.iter
    (fun (label, json) ->
       match Turns.decode ~keeper:"omega" json with
       | Error _ -> ()
       | Ok _ -> fail (label ^ " became the newest turns"))
    [ "a page with an unreadable row", page ~skipped:1 [ r ]
    ; "a record of another Keeper", page [ { r with keeper = "another" } ]
    ; "a page of another Keeper", page ~keeper:"another" [ r ]
    ; "a page without a skipped-row count",
      `Assoc [ "keeper", `String "omega"; "entries", `List [] ]
    ; "an entry without a readable record",
      `Assoc
        [ "keeper", `String "omega"
        ; "skipped_rows", `Int 0
        ; "entries", `List [ `Assoc [ "record", `Assoc [] ] ]
        ]
    ]
;;

let () =
  run "tui_keeper_turns"
    [ ( "decode"
      , [ test_case "stop reason is kept as written" `Quick test_stop_reason_is_kept_as_written
        ; test_case "ordered by time, not page order" `Quick
            test_turns_are_ordered_by_time_not_page_order
        ; test_case "equal times keep the page order" `Quick
            test_equal_times_keep_the_page_order
        ; test_case "empty page" `Quick test_empty_page
        ; test_case "refuse partial or misattributed pages" `Quick
            test_refuses_partial_or_other_keeper
        ] )
    ]
;;

(** The two [projection_status] axes of a dashboard schedule row
    ([keeper_queue_evidence] and [keeper_reaction_evidence]) have one table
    each in [Schedule_contract_values]. The server writes through
    [*_to_string], the TUI reads through [*_of_string], and the dashboard's
    string-literal unions are checked against the fixture below by its own
    vitest suite. This test binds the fixture to the OCaml table, so a value
    added, renamed or removed on the server fails here until the fixture
    follows, and the fixture then fails the dashboard until its union
    follows (#36009). *)

open Alcotest
module C = Schedule_contract_values

let fixture_path = "../dashboard/src/api/fixtures/schedule-projection-statuses.json"

let fixture_list key =
  match
    In_channel.with_open_text fixture_path In_channel.input_all
    |> Yojson.Safe.from_string
  with
  | `Assoc fields ->
    (match List.assoc_opt key fields with
     | Some (`List items) ->
       List.mapi
         (fun index -> function
            | `String value -> value
            | other ->
              failf "%s item %d is not a string: %s" key index
                (Yojson.Safe.to_string other))
         items
     | Some other -> failf "%s is not a list: %s" key (Yojson.Safe.to_string other)
     | None -> failf "fixture has no %s" key)
  | other -> failf "fixture is not an object: %s" (Yojson.Safe.to_string other)
;;

let test_fixture_holds_every_queue_status () =
  check (list string) "queue statuses, in declaration order"
    C.queue_projection_status_strings
    (fixture_list "queue_projection_statuses")
;;

let test_fixture_holds_every_reaction_status () =
  check (list string) "reaction statuses, in declaration order"
    C.reaction_projection_status_strings
    (fixture_list "reaction_projection_statuses")
;;

(* Every spelling decodes back to the value that wrote it, so the table has no
   two values sharing a spelling. *)
let test_round_trip () =
  List.iter
    (fun word ->
      match C.queue_projection_status_of_string word with
      | Ok status ->
        check string "queue round trip" word (C.queue_projection_status_to_string status)
      | Error error -> fail (C.decode_error_to_string error))
    C.queue_projection_status_strings;
  List.iter
    (fun word ->
      match C.reaction_projection_status_of_string word with
      | Ok status ->
        check string "reaction round trip" word
          (C.reaction_projection_status_to_string status)
      | Error error -> fail (C.decode_error_to_string error))
    C.reaction_projection_status_strings
;;

(* An unknown word is a decode error on both axes, and a word that belongs
   only to the other axis is unknown here too. *)
let test_unknown_is_refused () =
  let refused name = function
    | Ok _ -> failf "%s was admitted" name
    | Error (_ : C.decode_error) -> ()
  in
  refused "queue future_value" (C.queue_projection_status_of_string "future_value");
  refused "reaction future_value" (C.reaction_projection_status_of_string "future_value");
  refused "queue matched_consumed_ack"
    (C.queue_projection_status_of_string "matched_consumed_ack");
  refused "reaction matched_pending"
    (C.reaction_projection_status_of_string "matched_pending");
  refused "queue empty" (C.queue_projection_status_of_string "")
;;

let () =
  run "schedule_projection_status_contract"
    [ ( "contract"
      , [ test_case "fixture holds every queue status" `Quick
            test_fixture_holds_every_queue_status
        ; test_case "fixture holds every reaction status" `Quick
            test_fixture_holds_every_reaction_status
        ; test_case "every spelling round-trips" `Quick test_round_trip
        ; test_case "unknown spelling is refused" `Quick test_unknown_is_refused
        ] )
    ]
;;

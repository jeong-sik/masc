(** Keeper attention reasons: the dashboard's fixture holds every reason and
    first action the status bridge writes. *)

open Alcotest
module R = Masc.Keeper_attention_reason

let strings_of name = function
  | `List items ->
    List.mapi
      (fun index -> function
         | `String value -> value
         | other ->
           failf "%s item %d is not a string: %s" name index
             (Yojson.Safe.to_string other))
      items
  | other -> failf "%s is not a list: %s" name (Yojson.Safe.to_string other)
;;

(* [Paused_on_blocker] and [Paused] write the same reason, so the reason list
   keeps each string once, where it first appears. *)
let first_appearances values =
  List.fold_left
    (fun seen value -> if List.mem value seen then seen else value :: seen)
    [] values
  |> List.rev
;;

(* The dashboard labels these strings from its own wider lists. Its vitest
   suite checks that those lists contain this fixture, and this test checks
   the fixture against every reason here, so a reason or action added,
   renamed or removed here fails until the fixture and the dashboard follow. *)
let test_dashboard_fixture_holds_every_reason () =
  let fixture =
    In_channel.with_open_text
      "../dashboard/src/api/fixtures/keeper-attention-reasons.json"
      In_channel.input_all
    |> Yojson.Safe.from_string
  in
  let field key =
    match fixture with
    | `Assoc fields ->
      (match List.assoc_opt key fields with
       | Some value -> strings_of key value
       | None -> failf "fixture has no %s" key)
    | other -> failf "fixture is not an object: %s" (Yojson.Safe.to_string other)
  in
  check (list string) "one attention reason per wire string, in declaration order"
    (first_appearances (List.map R.to_wire R.all))
    (field "attention_reasons");
  check (list string) "one first action per reason, in declaration order"
    (List.map R.next_human_action R.all)
    (field "next_human_actions")
;;

let () =
  run
    "keeper_attention_reason"
    [ ( "wire"
      , [ test_case "dashboard fixture holds every reason" `Quick
            test_dashboard_fixture_holds_every_reason
        ] )
    ]
;;

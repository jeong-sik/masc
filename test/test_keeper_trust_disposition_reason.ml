(** Keeper trust disposition reasons: the dashboard's fixture holds every
    string the trust snapshot writes as a disposition reason. *)

open Alcotest
module Core = Masc.Keeper_runtime_trust_snapshot_core

let fixture_path = "../dashboard/src/api/fixtures/keeper-trust-disposition-reasons.json"
let fixture_key = "disposition_reasons"

(* A blocker class and a receipt reason can write the same string, so the
   list keeps each string once, where it first appears. *)
let first_appearances values =
  List.fold_left
    (fun seen value -> if List.mem value seen then seen else value :: seen)
    [] values
  |> List.rev
;;

let fixture_reasons () =
  let fixture =
    In_channel.with_open_text fixture_path In_channel.input_all
    |> Yojson.Safe.from_string
  in
  match fixture with
  | `Assoc fields ->
    (match List.assoc_opt fixture_key fields with
     | Some (`List items) ->
       List.mapi
         (fun index -> function
            | `String value -> value
            | other ->
              failf "%s item %d is not a string: %s" fixture_key index
                (Yojson.Safe.to_string other))
         items
     | Some other ->
       failf "%s is not a list: %s" fixture_key (Yojson.Safe.to_string other)
     | None -> failf "fixture has no %s" fixture_key)
  | other -> failf "fixture is not an object: %s" (Yojson.Safe.to_string other)
;;

(* The dashboard's vitest suite checks that every string in this fixture has
   a label, and this test checks the fixture against every reason the type
   holds. A reason added, renamed or removed in the snapshot, in the blocker
   classes or in the receipt reasons fails here until the fixture follows,
   and the fixture then fails the dashboard until a label follows. *)
let test_dashboard_fixture_holds_every_reason () =
  check (list string) "one disposition reason per wire string, in declaration order"
    (first_appearances
       (List.map Core.disposition_reason_to_wire Core.all_of_disposition_reason))
    (fixture_reasons ())
;;

let () =
  run
    "keeper_trust_disposition_reason"
    [ ( "wire"
      , [ test_case "dashboard fixture holds every reason" `Quick
            test_dashboard_fixture_holds_every_reason
        ] )
    ]
;;

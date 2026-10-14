(** Keeper trust disposition: every value reads back from its own wire
    string, and the dashboard's fixture holds every value the server sends. *)

open Alcotest
module D = Masc.Keeper_trust_disposition

let test_each_wire_string_reads_back () =
  List.iter
    (fun disposition ->
       let wire = D.to_wire disposition in
       check bool
         (Printf.sprintf "%s reads back as itself" wire)
         true
         (D.of_wire wire = Some disposition))
    D.all
;;

(* The dashboard narrows [disposition] to its own closed list. Its vitest
   suite checks that list against this fixture, and this test checks the
   fixture against every disposition here, so a value added, renamed or
   removed on one side fails until both sides and the fixture agree. *)
let test_dashboard_fixture_holds_every_value () =
  let fixture =
    In_channel.with_open_text
      "../dashboard/src/api/fixtures/trust-dispositions.json"
      In_channel.input_all
    |> Yojson.Safe.from_string
  in
  let values =
    match fixture with
    | `List items ->
      List.mapi
        (fun index -> function
           | `String value -> value
           | other ->
             failf "fixture item %d is not a string: %s" index
               (Yojson.Safe.to_string other))
        items
    | other -> failf "fixture is not a list: %s" (Yojson.Safe.to_string other)
  in
  check (list string) "fixture holds one value per disposition, in declaration order"
    (List.map D.to_wire D.all)
    values
;;

let () =
  run
    "keeper_trust_disposition"
    [ ( "wire"
      , [ test_case "each wire string reads back" `Quick
            test_each_wire_string_reads_back
        ; test_case "dashboard fixture holds every value" `Quick
            test_dashboard_fixture_holds_every_value
        ] )
    ]
;;

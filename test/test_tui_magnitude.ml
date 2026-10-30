module Magnitude = Masc_tui_magnitude

let band = Alcotest.testable
  (fun fmt b ->
    Format.pp_print_string fmt
      (match b with
       | Magnitude.Leading -> "Leading"
       | Magnitude.Ordinary -> "Ordinary"
       | Magnitude.Below_even_share -> "Below_even_share"))
  ( = )

let bands counts =
  Magnitude.of_counts counts |> List.map (fun (label, _, b) -> (label, b))

let check name expected counts =
  Alcotest.(check (list (pair string band))) name expected (bands counts)

(* The live task backlog. 486 todo against 9 running read alike in one tone
   until the digits were compared. *)
let test_a_skewed_distribution_names_its_leader () =
  check "the backlog points at what it is full of"
    [ "todo", Magnitude.Leading
    ; "claimed", Magnitude.Below_even_share
    ; "running", Magnitude.Below_even_share
    ; "done", Magnitude.Ordinary
    ; "cancelled", Magnitude.Below_even_share
    ]
    [ "todo", 486; "claimed", 0; "running", 9; "done", 174; "cancelled", 32 ]

(* The live goal rollup: 26, 0, 26, 27. Nothing leads a distribution this
   flat, and marking three of four as leaders is emphasis with no reading
   behind it -- the failure this guard exists for. *)
let test_a_flat_distribution_points_at_nothing () =
  check "counts all of a size are all ordinary"
    [ "active", Magnitude.Ordinary
    ; "verifying", Magnitude.Ordinary
    ; "done", Magnitude.Ordinary
    ; "dropped", Magnitude.Ordinary
    ]
    [ "active", 26; "verifying", 0; "done", 26; "dropped", 27 ]

(* Bands come off the distribution, so a caller cannot band an entry against a
   whole it does not belong to: the total, the count and the largest are all
   read from the list handed in. *)
let test_the_whole_is_the_list_itself () =
  Alcotest.(check int) "the total is the sum of what was given" 701
    (List.fold_left (fun sum (_, value) -> sum + value) 0
       [ "todo", 486; "claimed", 0; "running", 9; "done", 174; "cancelled", 32 ]);
  check "one entry leads nothing" [ "only", Magnitude.Ordinary ]
    [ "only", 9 ];
  check "an empty whole ranks nothing"
    [ "a", Magnitude.Ordinary; "b", Magnitude.Ordinary ]
    [ "a", 0; "b", 0 ]

(* A boundary lands on one side, not on whichever side integer division
   rounded it to: the comparisons multiply out rather than divide. *)
let test_a_boundary_lands_on_one_side () =
  (* largest 10, entries 2, total 15 -> skewed (10*2 >= 15*2 is false)... a
     flat pair stays ordinary, which is the point of the guard above. *)
  check "an even pair is flat" [ "a", Magnitude.Ordinary; "b", Magnitude.Ordinary ]
    [ "a", 8; "b", 7 ];
  (* Exactly half the largest is leading, by the rule as stated. *)
  check "exactly half the largest leads"
    [ "a", Magnitude.Leading
    ; "b", Magnitude.Leading
    ; "c", Magnitude.Below_even_share
    ; "d", Magnitude.Below_even_share
    ]
    [ "a", 100; "b", 50; "c", 1; "d", 1 ]

let () =
  Alcotest.run
    "tui magnitude"
    [ ( "bands"
      , [ Alcotest.test_case "a skewed distribution names its leader" `Quick
            test_a_skewed_distribution_names_its_leader
        ; Alcotest.test_case "a flat distribution points at nothing" `Quick
            test_a_flat_distribution_points_at_nothing
        ; Alcotest.test_case "the whole is the list itself" `Quick
            test_the_whole_is_the_list_itself
        ; Alcotest.test_case "a boundary lands on one side" `Quick
            test_a_boundary_lands_on_one_side
        ] )
    ]

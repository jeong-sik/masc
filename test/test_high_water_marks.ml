(* High_water_marks keeps the highest number recorded per name (RFC-0474 L4d
   follow-up). A goals tree generation filled late must not replace a newer
   one that finished first. *)
open Alcotest

let test_a_lower_number_recorded_later_changes_nothing () =
  let t = High_water_marks.create () in
  check (option int) "nothing recorded" None (High_water_marks.find t "ws");
  High_water_marks.raise_to t "ws" 2;
  High_water_marks.raise_to t "ws" 1;
  check (option int) "generation 2 finished first, then 1" (Some 2) (High_water_marks.find t "ws");
  High_water_marks.raise_to t "ws" 3;
  check (option int) "a higher one replaces it" (Some 3) (High_water_marks.find t "ws")
;;

let test_names_are_kept_apart () =
  let t = High_water_marks.create () in
  High_water_marks.raise_to t "a" 5;
  High_water_marks.raise_to t "b" 1;
  check (option int) "a" (Some 5) (High_water_marks.find t "a");
  check (option int) "b" (Some 1) (High_water_marks.find t "b")
;;

(* Four domains record interleaved numbers for one name, each finishing on a
   different one; the highest of all of them is what remains. *)
let test_racing_domains_leave_the_highest () =
  let t = High_water_marks.create () in
  let per_domain = 2_000 in
  let domains =
    List.init 4 (fun d ->
      Domain.spawn (fun () ->
        for i = 0 to per_domain - 1 do
          High_water_marks.raise_to t "ws" ((i * 4) + d)
        done))
  in
  List.iter Domain.join domains;
  check (option int) "the highest recorded" (Some (((per_domain - 1) * 4) + 3))
    (High_water_marks.find t "ws")
;;

let () =
  run "High_water_marks"
    [ ( "high water"
      , [ test_case "a lower number recorded later changes nothing" `Quick
            test_a_lower_number_recorded_later_changes_nothing
        ; test_case "names are kept apart" `Quick test_names_are_kept_apart
        ; test_case "racing domains leave the highest" `Quick
            test_racing_domains_leave_the_highest
        ] )
    ]
;;

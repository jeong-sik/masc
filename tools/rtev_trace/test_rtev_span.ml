open Alcotest
module S = Rtev_span

let finished = function
  | Some sp -> sp
  | None -> fail "a section was open and leave found none"
;;

let wait_of sp reason = Option.value ~default:0L (Hashtbl.find_opt sp.S.waits reason)

(* One fiber runs 0..3, waits on [io] 3..4 and runs 4..6, with the outer
   section entered at 1, the inner at 2, the inner left at 5 and the outer at
   6. The outer section is open the whole time from 1 to 6, so it ran 1..3 and
   4..6, 4 in all; the inner ran 2..3 and 4..5, 2 in all. *)
let nested_run book =
  S.enter book ~fiber:1 ~domain:0 ~name:"outer" ~ts:1L ~segment_start:0L;
  S.enter book ~fiber:1 ~domain:0 ~name:"inner" ~ts:2L ~segment_start:0L;
  S.ran book ~fiber:1 ~dur:3L;
  S.waited book ~fiber:1 ~reason:"io" ~dur:1L;
  let inner = finished (S.leave book ~fiber:1 ~ts:5L ~segment_start:4L) in
  let outer = finished (S.leave book ~fiber:1 ~ts:6L ~segment_start:4L) in
  inner, outer
;;

let test_a_suspend_inside_a_nested_section_keeps_the_outer_run_time () =
  let inner, outer = nested_run (S.create ()) in
  check int64 "inner ran 2..3 and 4..5" 2L inner.S.run_ns;
  check int64 "outer ran 1..3 and 4..6" 4L outer.S.run_ns
;;

let test_a_wait_inside_a_nested_section_counts_in_the_outer () =
  let inner, outer = nested_run (S.create ()) in
  check int64 "inner waited 3..4" 1L (wait_of inner "io");
  check int64 "outer waited 3..4" 1L (wait_of outer "io")
;;

let test_a_section_names_the_one_around_it () =
  let book = S.create () in
  S.enter book ~fiber:1 ~domain:0 ~name:"outer" ~ts:1L ~segment_start:0L;
  S.enter book ~fiber:1 ~domain:0 ~name:"inner" ~ts:2L ~segment_start:0L;
  let inner = finished (S.leave book ~fiber:1 ~ts:3L ~segment_start:0L) in
  let outer = finished (S.leave book ~fiber:1 ~ts:4L ~segment_start:0L) in
  check (option string) "inner is inside outer" (Some "outer")
    (Option.map (fun sp -> sp.S.span_name) inner.S.parent);
  check bool "outer is inside nothing" true (Option.is_none outer.S.parent)
;;

let test_a_fiber_created_inside_a_nested_section_counts_in_every_section_around_it () =
  let book = S.create () in
  S.enter book ~fiber:1 ~domain:0 ~name:"outer" ~ts:1L ~segment_start:0L;
  S.enter book ~fiber:1 ~domain:0 ~name:"inner" ~ts:2L ~segment_start:0L;
  S.inherit_from book ~creator:1 ~child:2;
  S.ran book ~fiber:2 ~dur:7L;
  S.waited book ~fiber:2 ~reason:"lock" ~dur:5L;
  let inner = finished (S.leave book ~fiber:1 ~ts:3L ~segment_start:0L) in
  let outer = finished (S.leave book ~fiber:1 ~ts:4L ~segment_start:0L) in
  (* The creator ran 0..4 and the child 7: each section counts its own part
     of the creator (inner 1, outer 3) and all of the child. *)
  check int64 "inner" 8L inner.S.run_ns;
  check int64 "outer" 10L outer.S.run_ns;
  check int64 "child wait in inner" 5L (wait_of inner "lock");
  check int64 "child wait in outer" 5L (wait_of outer "lock")
;;

let test_only_the_part_of_a_run_after_the_section_began_counts () =
  let book = S.create () in
  S.enter book ~fiber:1 ~domain:0 ~name:"job" ~ts:5L ~segment_start:2L;
  S.ran book ~fiber:1 ~dur:4L;
  let job = finished (S.leave book ~fiber:1 ~ts:6L ~segment_start:6L) in
  check int64 "ran 5..6" 1L job.S.run_ns
;;

let test_a_fiber_without_a_section_counts_nowhere () =
  let book = S.create () in
  S.ran book ~fiber:1 ~dur:9L;
  S.waited book ~fiber:1 ~reason:"io" ~dur:9L;
  check bool "leave finds none" true
    (Option.is_none (S.leave book ~fiber:1 ~ts:1L ~segment_start:0L));
  check bool "no active section" true (Option.is_none (S.active book 1))
;;

let () =
  run
    "rtev_span"
    [ ( "nested sections"
      , [ test_case "a suspend inside a nested section keeps the outer run time" `Quick
            test_a_suspend_inside_a_nested_section_keeps_the_outer_run_time
        ; test_case "a wait inside a nested section counts in the outer" `Quick
            test_a_wait_inside_a_nested_section_counts_in_the_outer
        ; test_case "a section names the one around it" `Quick
            test_a_section_names_the_one_around_it
        ; test_case "a child fiber counts in every section around it" `Quick
            test_a_fiber_created_inside_a_nested_section_counts_in_every_section_around_it
        ] )
    ; ( "single sections"
      , [ test_case "only the part of a run after the section began counts" `Quick
            test_only_the_part_of_a_run_after_the_section_began_counts
        ; test_case "a fiber without a section counts nowhere" `Quick
            test_a_fiber_without_a_section_counts_nowhere
        ] )
    ]
;;

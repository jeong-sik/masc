(* The order [masc browser-lane-setup] writes its runtime.toml tables in, and
   what it answers when one refuses. What these tests fix: a refusal keeps the
   tables written before it in the answer, the steps after it do not run, and a
   step is told to plan again only when a table before it was written. *)
open Alcotest

module W = Masc.Browser_lane_table_writes

(* A step that records that it ran and whether it was told to plan again. *)
let step name answer calls ~after_write =
  calls := (name, after_write) :: !calls;
  answer

let calls_in_order calls = List.rev !calls
let pair = pair string bool

let test_every_step_writes_and_is_told_about_the_ones_before () =
  let calls = ref [] in
  let { W.written; refusal } =
    W.write
      ~bidi:(Some (fun () -> step "bidi" (Ok "b") calls ~after_write:false))
      ~ego:(Some (step "ego" (Ok "e") calls))
  in
  check (option string) "no refusal" None refusal;
  check (list (option string)) "both written" [ Some "b"; Some "e" ]
    [ written.bidi; written.ego ];
  check (list pair) "the later step plans again"
    [ "bidi", false; "ego", true ] (calls_in_order calls)

let test_a_refusal_keeps_what_was_written_before_it_and_stops () =
  let calls = ref [] in
  let { W.written; refusal } =
    W.write
      ~bidi:(Some (fun () -> step "bidi" (Ok "b") calls ~after_write:false))
      ~ego:(Some (step "ego" (Error "ego refused") calls))
  in
  check (option string) "the refusal is the ego step's" (Some "ego refused") refusal;
  check (list (option string)) "bidi stays written" [ Some "b"; None ]
    [ written.bidi; written.ego ];
  let calls = ref [] in
  let { W.written; refusal } =
    W.write
      ~bidi:(Some (fun () -> step "bidi" (Error "bidi refused") calls ~after_write:false))
      ~ego:(Some (step "ego" (Ok "e") calls))
  in
  check (option string) "the first table's refusal" (Some "bidi refused") refusal;
  check (list (option string)) "nothing written" [ None; None ] [ written.bidi; written.ego ];
  check (list pair) "nothing after it runs" [ "bidi", false ] (calls_in_order calls)

let test_a_step_plans_again_only_after_a_write () =
  let calls = ref [] in
  ignore (W.write ~bidi:None ~ego:(Some (step "ego" (Ok ()) calls)));
  check (list pair) "ego alone keeps its plan" [ "ego", false ] (calls_in_order calls)

let () =
  run "browser_lane_table_writes"
    [ ( "order"
      , [ test_case "every step writes and is told about the ones before" `Quick
            test_every_step_writes_and_is_told_about_the_ones_before
        ; test_case "a refusal keeps what was written before it and stops" `Quick
            test_a_refusal_keeps_what_was_written_before_it_and_stops
        ; test_case "a step plans again only after a write" `Quick
            test_a_step_plans_again_only_after_a_write ] ) ]

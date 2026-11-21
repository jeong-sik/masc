open Alcotest

module Closed = Masc_tui_closed_rows

let test_a_held_prefix_reads_the_same_after_appends () =
  let rows = Closed.create () in
  List.iter (Closed.append rows) [ "a"; "b"; "c" ];
  let held = Closed.prefix rows in
  for index = 0 to 999 do Closed.append rows (string_of_int index) done;
  check int "the held length" 3 (Closed.length held);
  check (list string) "the held cells" [ "a"; "b"; "c" ] (Closed.to_list held);
  let later = Closed.prefix rows in
  check int "the later length" 1003 (Closed.length later);
  check (list string) "the later cells start with the held ones" [ "a"; "b"; "c"; "0" ]
    (Closed.sub_list later ~start:0 ~stop:4);
  check string "the last cell" "999" (Closed.get later 1002)

let test_each_growth_keeps_every_cell () =
  let rows = Closed.create () in
  let held = ref [] in
  for index = 0 to 299 do
    Closed.append rows index;
    held := Closed.prefix rows :: !held
  done;
  List.iter (fun prefix ->
    let length = Closed.length prefix in
    check (list int) (Printf.sprintf "prefix of %d" length) (List.init length Fun.id)
      (Closed.to_list prefix))
    !held

let test_extends_asks_for_the_same_writer () =
  let rows = Closed.create () and other = Closed.create () in
  List.iter (fun value -> Closed.append rows value; Closed.append other value) [ 1; 2 ];
  let kept = Closed.prefix rows in
  Closed.append rows 3;
  check bool "a longer prefix of the same writer" true (Closed.extends (Closed.prefix rows) ~kept);
  check bool "the same prefix" true (Closed.extends kept ~kept);
  check bool "a prefix of another writer with the same cells" false
    (Closed.extends (Closed.prefix other) ~kept);
  check bool "a shorter prefix" false (Closed.extends kept ~kept:(Closed.prefix rows));
  check bool "same is the same writer and length" true (Closed.same kept kept);
  check bool "a longer prefix is not the same" false (Closed.same kept (Closed.prefix rows))

let test_get_refuses_cells_past_the_length () =
  let rows = Closed.create () in
  Closed.append rows "a";
  let held = Closed.prefix rows in
  Closed.append rows "b";
  check bool "past the held length" true
    (match Closed.get held 1 with _ -> false | exception Invalid_argument _ -> true)

let () =
  run "closed rows"
    [ ( "prefix",
        [ test_case "a held prefix reads the same after appends" `Quick
            test_a_held_prefix_reads_the_same_after_appends;
          test_case "each growth keeps every cell" `Quick test_each_growth_keeps_every_cell;
          test_case "extends asks for the same writer" `Quick test_extends_asks_for_the_same_writer;
          test_case "get refuses cells past the length" `Quick test_get_refuses_cells_past_the_length ] ) ]

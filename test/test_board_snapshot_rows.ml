(** [Board_snapshot_rows.render] writes the board's posts and comments
    snapshots. These cases pin that a snapshot is exactly the rows of the
    table's values, that a value is rendered only when the table holds a
    value no earlier snapshot rendered, and that [rows] keeps one row per key
    the table holds. *)

open Alcotest
module Rows = Masc_board_handlers.Board_snapshot_rows

(* A value replaced, never changed in place, like a post. *)
type item =
  { id : string
  ; text : string
  }

let item_to_json { id; text } = `Assoc [ ("id", `String id); ("text", `String text) ]

(* Renders counted per call. *)
let counting () =
  let renders = ref 0 in
  let to_json value =
    incr renders;
    item_to_json value
  in
  to_json, renders
;;

let table_of items =
  let table = Hashtbl.create 8 in
  List.iter (fun item -> Hashtbl.replace table item.id item) items;
  table
;;

(* The snapshot written the plain way: every value rendered, in the table's
   iteration order. *)
let rendered_in_full table =
  let buf = Buffer.create 256 in
  Hashtbl.iter
    (fun _ value ->
       Buffer.add_string buf (Yojson.Safe.to_string (item_to_json value));
       Buffer.add_char buf '\n')
    table;
  Buffer.contents buf
;;

let items n = List.init n (fun i -> { id = Printf.sprintf "item-%d" i; text = "first" })

let test_the_first_snapshot_renders_every_value () =
  let table = table_of (items 5) in
  let rows = Hashtbl.create 8 in
  let to_json, renders = counting () in
  check string "the rows in table order" (rendered_in_full table) (Rows.render ~rows ~to_json table);
  check int "each value rendered once" 5 !renders
;;

let test_an_unchanged_table_renders_nothing () =
  let table = table_of (items 5) in
  let rows = Hashtbl.create 8 in
  let to_json, renders = counting () in
  let first = Rows.render ~rows ~to_json table in
  let second = Rows.render ~rows ~to_json table in
  check string "the same snapshot" first second;
  check int "no value rendered again" 5 !renders
;;

(* The replacement has the same contents as the value it replaces: a row is
   kept for the physical value, not for equal contents. The replacement's row
   takes the old one's place, so the next snapshot renders nothing. *)
let test_a_replaced_value_is_rendered_again () =
  let table = table_of (items 5) in
  let rows = Hashtbl.create 8 in
  let to_json, renders = counting () in
  ignore (Rows.render ~rows ~to_json table : string);
  let replaced = Hashtbl.find table "item-2" in
  Hashtbl.replace table "item-2" { replaced with text = "second" };
  Hashtbl.replace table "item-3" { (Hashtbl.find table "item-3") with id = "item-3" };
  check string "the rows show the replacement" (rendered_in_full table)
    (Rows.render ~rows ~to_json table);
  check int "only the two replaced values rendered again" 7 !renders;
  check int "one row per key" 5 (Hashtbl.length rows);
  ignore (Rows.render ~rows ~to_json table : string);
  check int "the replacements are not rendered a third time" 7 !renders
;;

let test_a_removed_value_leaves_the_snapshot_and_its_row () =
  let table = table_of (items 5) in
  let rows = Hashtbl.create 8 in
  let to_json, renders = counting () in
  ignore (Rows.render ~rows ~to_json table : string);
  Hashtbl.remove table "item-1";
  check string "the rows without it" (rendered_in_full table) (Rows.render ~rows ~to_json table);
  check int "its row is dropped" 4 (Hashtbl.length rows);
  check int "nothing rendered again" 5 !renders;
  Hashtbl.replace table "item-1" { id = "item-1"; text = "back" };
  check string "a value added back under its key is rendered" (rendered_in_full table)
    (Rows.render ~rows ~to_json table);
  check int "once" 6 !renders
;;

let test_an_emptied_table_is_an_empty_snapshot () =
  let table = table_of (items 5) in
  let rows = Hashtbl.create 8 in
  let to_json, renders = counting () in
  ignore (Rows.render ~rows ~to_json table : string);
  Hashtbl.reset table;
  check string "no rows" "" (Rows.render ~rows ~to_json table);
  check int "no row kept" 0 (Hashtbl.length rows);
  check int "nothing rendered again" 5 !renders
;;

let () =
  run
    "board snapshot rows"
    [ ( "render"
      , [ test_case "the first snapshot renders every value" `Quick
            test_the_first_snapshot_renders_every_value
        ; test_case "an unchanged table renders nothing" `Quick
            test_an_unchanged_table_renders_nothing
        ; test_case "a replaced value is rendered again" `Quick
            test_a_replaced_value_is_rendered_again
        ; test_case "a removed value leaves the snapshot and its row" `Quick
            test_a_removed_value_leaves_the_snapshot_and_its_row
        ; test_case "an emptied table is an empty snapshot" `Quick
            test_an_emptied_table_is_an_empty_snapshot
        ] )
    ]
;;

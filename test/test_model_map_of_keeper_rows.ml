(** Regression test: model_map_of_keeper_rows must insert into the Hashtbl.
    Bug: all four match arms ended in () (no Hashtbl.add), so agents[].model
    was permanently null in the dashboard execution JSON. *)

open Alcotest

let check_equal ~label actual expected =
  check (option string) label actual expected

let test_inserts_name_and_model () =
  let keepers =
    [ `Assoc [ ("name", `String "alice"); ("active_model", `String "gpt-4o") ]
    ; `Assoc [ ("name", `String "bob"); ("active_model", `String "claude-3.5") ]
    ; `Assoc [ ("name", `String "carol"); ("active_model", `String "") ]
    ; `Assoc [ ("name", `String "dave") ]
    ; `Assoc [("active_model", `String "no-name")]
    ; `Null
    ]
  in
  let map = Dashboard_execution.model_map_of_keeper_rows keepers in
  check_equal ~label:"alice model"
    (Hashtbl.find_opt map "alice") (Some "gpt-4o");
  check_equal ~label:"bob model"
    (Hashtbl.find_opt map "bob") (Some "claude-3.5");
  check_equal ~label:"carol empty model"
    (Hashtbl.find_opt map "carol") None;
  check_equal ~label:"dave no model"
    (Hashtbl.find_opt map "dave") None;
  check_equal ~label:"no-name row"
    (Hashtbl.find_opt map "") None;
  let n = ref 0 in
  Hashtbl.iter (fun _ _ -> incr n) map;
  check int "hashtbl length" !n 2

let () =
  run "model_map_of_keeper_rows"
    [ test_case "inserts name and active_model into hashtbl" `Quick
        test_inserts_name_and_model
    ]

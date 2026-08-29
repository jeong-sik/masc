open Alcotest

module KAP = Masc.Keeper_alerting_path

let make_meta ~name () =
  let json =
    `Assoc
      [
        ("name", `String name);
        ("trace_id", `String ("trace-" ^ name));
      ]
  in
  match Masc_test_deps.meta_of_json_fixture json with
  | Ok meta -> meta
  | Error err -> fail ("make_meta: " ^ err)

(* The sandbox is the whole path boundary: reads and writes resolve against
   the keeper's sandbox root and nothing else. There is no per-keeper path
   allowlist on top of it. *)
let test_roots_are_the_sandbox_root () =
  let meta = make_meta ~name:"keeper" () in
  let expected = [ KAP.sandbox_path_of_meta ~meta ] in
  check (list string) "sandbox roots" expected (KAP.sandbox_roots ~meta)

let test_playground_path_sanitizes_name () =
  let path = KAP.playground_path_of_keeper "my keeper/../../etc" in
  check string "special chars sanitized"
    ".masc/playground/my_keeper_.._.._etc/" path

let () =
  run "Keeper_sandbox_roots"
    [
      ( "sandbox_roots",
        [
          test_case "roots are the sandbox root" `Quick
            test_roots_are_the_sandbox_root;
          test_case "playground path sanitizes name" `Quick
            test_playground_path_sanitizes_name;
        ] );
    ]

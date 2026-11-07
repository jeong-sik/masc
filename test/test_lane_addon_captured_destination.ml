open Alcotest
open Masc
module D = Lane_addon_captured_destination

let context = "fixture destination"

let sample : D.t =
  {
    installation_id = "configuration:librarian";
    package_id = "package";
    tool = "admit";
    source_revision = "source-1";
    configuration_revision = "config-1";
  }

let sample_members =
  match D.to_json sample with `Assoc members -> members | _ -> fail "destination JSON is not an object"

let destination =
  testable
    (fun ppf (value : D.t) -> Format.pp_print_string ppf (Yojson.Safe.to_string (D.to_json value)))
    ( = )

let decode json = D.of_json ~context json

let replaced name value =
  `Assoc (List.map (fun (key, current) -> if key = name then (key, value) else (key, current)) sample_members)

let test_json_shape () =
  check string "the five members in field order"
    {|{"installation_id":"configuration:librarian","package_id":"package","tool":"admit","source_revision":"source-1","configuration_revision":"config-1"}|}
    (Yojson.Safe.to_string (D.to_json sample))

let test_round_trip () =
  check (result destination string) "decoding what was written returns the destination" (Ok sample)
    (decode (D.to_json sample));
  check (result destination string) "the order of the members does not matter" (Ok sample)
    (decode (`Assoc (List.rev sample_members)))

let test_refusals () =
  let refused label message json = check (result destination string) label (Error message) (decode json) in
  refused "a member is missing" "fixture destination is missing field tool"
    (`Assoc (List.remove_assoc "tool" sample_members));
  refused "a member repeats" "fixture destination has duplicate field tool"
    (`Assoc (sample_members @ [ ("tool", `String "other") ]));
  refused "an unknown member" "fixture destination has unknown field extra"
    (`Assoc (sample_members @ [ ("extra", `Null) ]));
  refused "no object" "fixture destination must be a JSON object" (`List []);
  refused "a member is not text" "fixture destination: field tool must be a string" (replaced "tool" (`Int 1));
  refused "a member is blank" "fixture destination: field tool is blank" (replaced "tool" (`String " "));
  List.iter
    (fun (name, _) ->
      List.iter
        (fun (label, json) ->
          check bool (label ^ " " ^ name) true (Result.is_error (decode json)))
        [
          ("missing", `Assoc (List.remove_assoc name sample_members));
          ("empty", replaced name (`String ""));
          ("null", replaced name `Null);
        ])
    sample_members

let test_same_semantic () =
  check bool "the source revision is not compared" true
    (D.same_semantic sample { sample with source_revision = "source-2" });
  List.iter
    (fun (label, other) -> check bool label false (D.same_semantic sample other))
    [
      ("another installation", { sample with installation_id = "configuration:other" });
      ("another package", { sample with package_id = "other" });
      ("another tool", { sample with tool = "other" });
      ("another configuration revision", { sample with configuration_revision = "config-2" });
    ]

let () =
  run "Lane add-on captured destination"
    [
      ( "json",
        [
          test_case "shape" `Quick test_json_shape;
          test_case "round trip" `Quick test_round_trip;
          test_case "refusals" `Quick test_refusals;
        ] );
      ("comparison", [ test_case "same semantic" `Quick test_same_semantic ]);
    ]

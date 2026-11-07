open Alcotest

let members body =
  Result.map
    (List.map (fun (key, value) -> key, Yojson.Safe.to_string value))
    (Server_json_object_body.fields body)

let members_t = result (list (pair string string)) string

let parser_detail body =
  match Yojson.Safe.from_string body with
  | _ -> fail "the fixture parses"
  | exception Yojson.Json_error detail -> detail

let test_members_keep_order_and_duplicates () =
  check members_t "members" (Ok [ "b", "1"; "a", {|"x"|}; "b", "2" ])
    (members {|{"b":1,"a":"x","b":2}|});
  check members_t "empty object" (Ok []) (members "{}")

let test_other_json_is_not_an_object () =
  List.iter
    (fun body -> check members_t body (Error "JSON object body required") (members body))
    [ "[]"; "[{}]"; {|"text"|}; "1"; "null"; "true" ]

let test_text_that_does_not_parse () =
  List.iter
    (fun body ->
      check members_t (String.escaped body)
        (Error ("invalid json: " ^ parser_detail body))
        (members body))
    [ ""; "{"; {|{"a":}|}; "{} x" ]

let () =
  run "Server json object body"
    [ ( "fields",
        [ test_case "members keep order and duplicates" `Quick test_members_keep_order_and_duplicates
        ; test_case "other json is not an object" `Quick test_other_json_is_not_an_object
        ; test_case "text that does not parse" `Quick test_text_that_does_not_parse
        ] )
    ]

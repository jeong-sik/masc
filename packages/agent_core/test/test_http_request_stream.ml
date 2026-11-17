open Llm_provider
module Stream = Http_request_stream

let policies = [ Stream.Stream_only; Stream.Stream_with_usage ]

type outcome =
  | Returned of (string, Http_client.body_injection_error) result
  | Json_error of string
  | Invalid_argument_error of string

let observe operation =
  try Returned (operation ()) with
  | Yojson.Json_error detail -> Json_error detail
  | Invalid_argument detail -> Invalid_argument_error detail
;;

let textual_oracle fields json =
  let body = Yojson.Safe.to_string json in
  match fields with
  | Stream.Stream_only -> Http_client.inject_stream_param body
  | Stream.Stream_with_usage -> Http_client.inject_stream_and_options body
;;

let check_parity label json =
  List.iter
    (fun fields ->
       Alcotest.(check bool) label true
         (observe (fun () -> textual_oracle fields json)
          = observe (fun () -> Stream.encode ~fields json)))
    policies
;;

let test_final_fields_and_order () =
  let json = `Assoc [ "messages", `List [] ] in
  Alcotest.(check (option string)) "stream field order"
    (Some {|{"stream":true,"messages":[]}|})
    (Result.to_option (Stream.encode ~fields:Stream.Stream_only json));
  Alcotest.(check (option string)) "usage and stream field order"
    (Some {|{"stream_options":{"include_usage":true},"stream":true,"messages":[]}|})
    (Result.to_option (Stream.encode ~fields:Stream.Stream_with_usage json));
  List.iter (check_parity "ordinary request")
    [ json
    ; `Assoc []
    ; `Assoc [ "stream", `Bool false; "stream", `Null
             ; "stream_options", `Assoc [ "include_usage", `Bool false ]
             ; "stream_options", `List []; "messages", `List [] ]
    ; `Assoc [ "value", `String "quote\" slash\\ line\n\r\000 한글"
             ; "value", `List [ `Null; `Bool true; `Int min_int; `Int max_int ] ]
    ; `Assoc [ "value", `List
                 [ `Float (-0.); `Float 1e-320; `Float max_float
                 ; `Float min_float; `Float infinity; `Float neg_infinity; `Float nan ] ]
    ]
;;

let test_nonobject_refusal () =
  List.iter
    (fun json ->
       check_parity "nonobject refusal" json;
       List.iter (fun fields ->
         Alcotest.(check bool) "nonobject stays an error" true
           (Stream.encode ~fields json = Error Http_client.Body_not_object))
         policies)
    [ `Null; `Bool false; `Int 1; `Float 1.25; `String "{}"; `List [] ]
;;

let test_literal_validation_and_normalization () =
  List.iter
    (fun source ->
       check_parity "root literal" (`Intlit source);
       check_parity "schema literal" (`Assoc [ "schema", `Assoc [ "default", `Intlit source ] ]))
    [ "0"; "-0"; "123"; "00123"; "1e3"; "1.0"; "-0.0"
    ; "999999999999999999999999999999999999999999999"
    ; "NaN"; "Infinity"; "invalid"; ""
    ; {|{"messages":[]}|}; {|[1,2]|}; {|"text"|}
    ; {|0,"injected":1|}
    ];
  List.iter (fun fields ->
    let json = `Assoc [ "schema", `Assoc [ "default", `Intlit "00123" ] ] in
    Alcotest.(check bool) "malformed literal cannot bypass refusal" true
      (Stream.encode ~fields json = Error Http_client.Body_not_json)) policies
;;

let test_overwritten_literals_are_still_validated () =
  List.iter (fun key ->
    List.iter (fun value ->
      check_parity "validate before dropping streaming fields"
        (`Assoc [ key, `List [ `Assoc [ "raw", `Intlit value ] ]; "messages", `List [] ]))
      [ "invalid"; "00123"; "1e3"; {|0,"extra":1|} ];
    List.iter (fun value ->
      check_parity "validate nonfinite values before dropping streaming fields"
        (`Assoc [ key, `List [ `Float value ]; "messages", `List [] ]))
      [ nan; infinity; neg_infinity ])
    [ "stream"; "stream_options" ]
;;

let () =
  Alcotest.run "http_request_stream"
    [ "wire boundary",
      [ Alcotest.test_case "final fields and byte order" `Quick test_final_fields_and_order
      ; Alcotest.test_case "nonobject refusal" `Quick test_nonobject_refusal
      ; Alcotest.test_case "literal validation and normalization" `Quick test_literal_validation_and_normalization
      ; Alcotest.test_case "overwritten literals are validated" `Quick test_overwritten_literals_are_still_validated
      ] ]

(** [Task.History_page.cursor_of_string] on hand-built continuation tokens.

    A client hands back whatever string it holds, so the decoder accepts the
    bytes [cursor_to_string] produces and refuses every other spelling of the
    same fields. The round trip from a real read lives in test_h2_journal.ml.
    These cases build the payloads by hand. *)

module Page = Masc.Task.History_page

let encode text = Base64.encode_string ~pad:false ~alphabet:Base64.uri_safe_alphabet text
let activity_file = "activity-events/2026-11/05.jsonl"
let audit_file = "events/2026-11/05.jsonl"
let audit_next_day_file = "events/2026-11/06.jsonl"

(* November has 30 days. *)
let november_31st = "events/2026-11/31.jsonl"
let thirteenth_month = "events/2026-13/05.jsonl"
let ceiling file size : Yojson.Safe.t = `Assoc [ "file", `String file; "size", `Int size ]

(* The ten fields in the order [cursor_to_string] writes them. *)
let fields
      ?(schema = "masc.task-history.cursor/v2")
      ?(task_id = "task-1")
      ?(ceilings : Yojson.Safe.t = `List [ ceiling audit_file 10 ])
      ?(file = audit_file)
      ?(before = 3)
      ()
  : (string * Yojson.Safe.t) list
  =
  [ "schema", `String schema
  ; "task_id", `String task_id
  ; "workspace", `String "ws"
  ; "ceilings", ceilings
  ; "inventory", `String "inv"
  ; "file", `String file
  ; "device", `Int 1
  ; "inode", `Int 2
  ; "before", `Int before
  ; "anchor", `String "anchor"
  ]
;;

let token fields = encode (Yojson.Safe.to_string (`Assoc fields))

let is_invalid_cursor = function
  | Error Page.Invalid_cursor -> true
  | Ok _
  | Error
      ( Page.Invalid_request
      | Page.Source_changed
      | Page.Invalid_event _
      | Page.Invalid_layout _
      | Page.Source_unavailable ) -> false
;;

let check_accepted name encoded =
  match Page.cursor_of_string encoded with
  | Ok cursor ->
    Alcotest.(check string)
      (name ^ ": re-encodes to the same token")
      encoded
      (Page.cursor_to_string cursor)
  | Error _ -> Alcotest.failf "%s: a canonical token was refused" name
;;

let check_refused (name, encoded) =
  Alcotest.(check bool)
    (name ^ ": refused as Invalid_cursor")
    true
    (is_invalid_cursor (Page.cursor_of_string encoded))
;;

let test_canonical_single_source () = check_accepted "one ceiling" (token (fields ()))

let test_canonical_both_sources () =
  check_accepted
    "activity and audit ceilings"
    (token
       (fields ~ceilings:(`List [ ceiling activity_file 4; ceiling audit_file 10 ]) ()))
;;

let test_transport_and_shape () =
  List.iter
    check_refused
    [ "not base64", "!!!"
    ; "base64 of text that is not JSON", encode "not json"
    ; "JSON array instead of an object", encode "[]"
    ; ( "nine fields"
      , token (List.filter (fun (name, _) -> not (String.equal name "anchor")) (fields ()))
      )
    ; "unknown schema", token (fields ~schema:"masc.task-history.cursor/v1" ())
    ]
;;

let test_field_values () =
  List.iter
    check_refused
    [ "task id with surrounding space", token (fields ~task_id:" task-1" ())
    ; "empty task id", token (fields ~task_id:"" ())
    ; "negative row offset", token (fields ~before:(-1) ())
    ; "position names a month that does not exist", token (fields ~file:thirteenth_month ())
    ]
;;

let test_ceilings () =
  List.iter
    check_refused
    [ "ceilings is not a list", token (fields ~ceilings:(`String "events") ())
    ; "no ceilings", token (fields ~ceilings:(`List []) ())
    ; ( "negative ceiling size"
      , token (fields ~ceilings:(`List [ ceiling audit_file (-1) ]) ()) )
    ; ( "ceiling row with an extra field"
      , token
          (fields
             ~ceilings:
               (`List
                   [ `Assoc
                       [ "file", `String audit_file; "size", `Int 10; "extra", `Int 0 ]
                   ])
             ()) )
    ; ( "ceiling row with fields in another order"
      , token
          (fields
             ~ceilings:
               (`List [ `Assoc [ "size", `Int 10; "file", `String audit_file ] ])
             ()) )
    ; ( "two ceilings for one source"
      , token
          (fields
             ~ceilings:
               (`List [ ceiling audit_file 10; ceiling audit_next_day_file 20 ])
             ()) )
    ; ( "ceiling names a day that does not exist"
      , token (fields ~ceilings:(`List [ ceiling november_31st 10 ]) ()) )
    ]
;;

let test_non_canonical_spelling () =
  List.iter
    check_refused
    [ "pretty-printed JSON", encode (Yojson.Safe.pretty_to_string (`Assoc (fields ())))
    ; "fields in another order", token (List.rev (fields ()))
    ]
;;

let () =
  Alcotest.run
    "task_history_page_cursor"
    [ ( "canonical token"
      , [ Alcotest.test_case "one source" `Quick test_canonical_single_source
        ; Alcotest.test_case "both sources" `Quick test_canonical_both_sources
        ] )
    ; ( "refused token"
      , [ Alcotest.test_case "transport and shape" `Quick test_transport_and_shape
        ; Alcotest.test_case "field values" `Quick test_field_values
        ; Alcotest.test_case "ceilings" `Quick test_ceilings
        ; Alcotest.test_case "non-canonical spelling" `Quick test_non_canonical_spelling
        ] )
    ]
;;

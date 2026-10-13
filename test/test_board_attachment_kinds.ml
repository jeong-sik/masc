(* Typed board attachment kinds and the optional [name] field.

   [parse_args] is the only reader of the typed attachments argument. These
   cases pin the extended kind set (file/audio/score/midi), strict rejection
   of unknown kinds (never coerced to a default), and the optional string
   [name] carried verbatim through [resolve] into the stored wire form. *)

let sha256 = String.make 64 'a'

let parse entries =
  Board_tool_attachment.parse_args (`Assoc [ "attachments", `List entries ])
;;

let test_score_artifact_with_name () =
  match
    parse
      [ `Assoc
          [ "kind", `String "score"
          ; "sha256", `String sha256
          ; "name", `String "a.gp"
          ]
      ]
  with
  | Ok
      [ { Board_tool_attachment.kind = Board_tool_attachment.Score
        ; source = Board_tool_attachment.Artifact_sha256 stored
        ; name = Some "a.gp"
        }
      ] -> Alcotest.(check string) "sha256 carried" sha256 stored
  | Ok _ -> Alcotest.fail "score entry parsed to an unexpected shape"
  | Error error ->
    Alcotest.failf "score entry rejected: %s"
      (Board_tool_attachment.error_to_string error)
;;

let test_score_artifact_without_name () =
  match
    parse [ `Assoc [ "kind", `String "score"; "sha256", `String sha256 ] ]
  with
  | Ok
      [ { Board_tool_attachment.kind = Board_tool_attachment.Score
        ; source = Board_tool_attachment.Artifact_sha256 _
        ; name = None
        }
      ] -> ()
  | Ok _ -> Alcotest.fail "score entry parsed to an unexpected shape"
  | Error error ->
    Alcotest.failf "nameless score entry rejected: %s"
      (Board_tool_attachment.error_to_string error)
;;

let test_new_kinds_parse_from_url () =
  List.iter
    (fun (wire, expected) ->
      match
        parse
          [ `Assoc
              [ "kind", `String wire
              ; "url", `String "https://cdn.example.test/blob"
              ]
          ]
      with
      | Ok [ { Board_tool_attachment.kind; name = None; _ } ] ->
        Alcotest.(check bool) (wire ^ " parses") true (kind = expected)
      | Ok _ -> Alcotest.fail (wire ^ " parsed to an unexpected shape")
      | Error error ->
        Alcotest.failf "%s rejected: %s" wire
          (Board_tool_attachment.error_to_string error))
    [ "file", Board_tool_attachment.File
    ; "audio", Board_tool_attachment.Audio
    ; "score", Board_tool_attachment.Score
    ; "midi", Board_tool_attachment.Midi
    ]
;;

let test_unknown_kind_rejected () =
  match
    parse
      [ `Assoc
          [ "kind", `String "hologram"
          ; "url", `String "https://cdn.example.test/holo"
          ]
      ]
  with
  | Error (Board_tool_attachment.Invalid_kind 0) -> ()
  | Error error ->
    Alcotest.failf "hologram rejected with the wrong error: %s"
      (Board_tool_attachment.error_to_string error)
  | Ok _ -> Alcotest.fail "unknown kind was accepted"
;;

let test_non_string_name_rejected () =
  match
    parse
      [ `Assoc
          [ "kind", `String "score"; "sha256", `String sha256; "name", `Int 42 ]
      ]
  with
  | Error (Board_tool_attachment.Invalid_name 0) -> ()
  | Error error ->
    Alcotest.failf "non-string name rejected with the wrong error: %s"
      (Board_tool_attachment.error_to_string error)
  | Ok _ -> Alcotest.fail "non-string name was accepted"
;;

let test_empty_name_carried_verbatim () =
  match
    parse
      [ `Assoc
          [ "kind", `String "file"
          ; "url", `String "https://cdn.example.test/empty"
          ; "name", `String ""
          ]
      ]
  with
  | Ok [ { Board_tool_attachment.name = Some ""; _ } ] -> ()
  | Ok _ -> Alcotest.fail "empty name was coerced instead of carried"
  | Error error ->
    Alcotest.failf "empty name rejected: %s"
      (Board_tool_attachment.error_to_string error)
;;

let test_unknown_extra_field_still_rejected () =
  match
    parse
      [ `Assoc
          [ "kind", `String "image"
          ; "url", `String "https://cdn.example.test/a.png"
          ; "caption", `String "hi"
          ]
      ]
  with
  | Error (Board_tool_attachment.Invalid_entry_fields 0) -> ()
  | Error error ->
    Alcotest.failf "extra field rejected with the wrong error: %s"
      (Board_tool_attachment.error_to_string error)
  | Ok _ -> Alcotest.fail "an unknown extra field was accepted"
;;

let test_resolve_and_to_json_preserve_name () =
  let entries =
    [ { Board_tool_attachment.kind = Board_tool_attachment.Score
      ; source = Board_tool_attachment.Https_url "https://cdn.example.test/a.gp"
      ; name = Some "a.gp"
      }
    ; { Board_tool_attachment.kind = Board_tool_attachment.Image
      ; source = Board_tool_attachment.Https_url "https://cdn.example.test/b.png"
      ; name = None
      }
    ]
  in
  (* Url entries touch no blob I/O, so the base path is never read. *)
  match
    Board_tool_attachment.resolve
      ~base_path:"/nonexistent-masc-base"
      ~max_artifact_bytes:1024
      entries
  with
  | Error error ->
    Alcotest.failf "url entries failed to resolve: %s"
      (Board_tool_attachment.error_to_string error)
  | Ok resolved ->
    let json = `List (List.map Board_tool_attachment.to_json resolved) in
    (match json with
     | `List [ `Assoc named; `Assoc unnamed ] ->
       Alcotest.(check string)
         "name stored"
         "a.gp"
         Yojson.Safe.Util.(List.assoc "name" named |> to_string);
       Alcotest.(check string)
         "kind stored"
         "score"
         Yojson.Safe.Util.(List.assoc "kind" named |> to_string);
       Alcotest.(check bool)
         "nameless entry keeps the old two-key wire shape"
         false
         (List.mem_assoc "name" unnamed)
     | _ -> Alcotest.fail "resolved wire shape malformed")
;;

let () =
  Alcotest.run
    "board_attachment_kinds"
    [ ( "kinds"
      , [ Alcotest.test_case "score artifact with name" `Quick
            test_score_artifact_with_name
        ; Alcotest.test_case "score artifact without name" `Quick
            test_score_artifact_without_name
        ; Alcotest.test_case "new kinds parse from url" `Quick
            test_new_kinds_parse_from_url
        ; Alcotest.test_case "unknown kind rejected" `Quick
            test_unknown_kind_rejected
        ]
      )
    ; ( "name"
      , [ Alcotest.test_case "non-string name rejected" `Quick
            test_non_string_name_rejected
        ; Alcotest.test_case "empty name carried verbatim" `Quick
            test_empty_name_carried_verbatim
        ; Alcotest.test_case "unknown extra field still rejected" `Quick
            test_unknown_extra_field_still_rejected
        ; Alcotest.test_case "resolve and to_json preserve name" `Quick
            test_resolve_and_to_json_preserve_name
        ]
      )
    ]
;;

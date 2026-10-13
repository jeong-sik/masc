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

(* A name is a file's name, printed and used for the download: empty,
   multi-line, longer than a file name, or naming a directory is refused
   where it enters, so no reader has to clean it. *)
let test_unprintable_name_rejected () =
  List.iter
    (fun (label, name) ->
      match
        parse
          [ `Assoc
              [ "kind", `String "file"
              ; "url", `String "https://cdn.example.test/f"
              ; "name", `String name
              ]
          ]
      with
      | Error (Board_tool_attachment.Invalid_name 0) -> ()
      | Error error ->
        Alcotest.failf "%s rejected with the wrong error: %s" label
          (Board_tool_attachment.error_to_string error)
      | Ok _ -> Alcotest.failf "%s was accepted" label)
    [ "an empty name", ""
    ; "a name with a newline", "a\nb"
    ; "a name with an escape character", "a\027[2Jb"
    ; ( "a name one byte too long"
      , String.make (Board_tool_attachment.max_name_bytes + 1) 'a' )
    ; "a name with a path separator", "riffs/take1.mid"
    ; "a name with a backslash", "riffs\\take1.mid"
    ; "the parent directory", ".."
    ; "a name that is not UTF-8", "riff\xff\xfe.gp5"
    ]
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

(* The path file sharing uses: a stored blob attached by digest with a name.
   Each kind that takes an artifact keeps its own word and the name through
   resolve and to_json. *)
let test_stored_artifact_keeps_kind_and_name () =
  let base_path = Filename.temp_dir "board-attachment-kinds" "" in
  let stored =
    Tool_blob_store.put_durable
      (Tool_blob_store.create ~base_path)
      ~bytes:"riff bytes"
      ~mime:"application/octet-stream"
  in
  let kinds =
    Board_tool_attachment.
      [ File, "file"; Audio, "audio"; Score, "score"; Midi, "midi" ]
  in
  Eio_main.run
  @@ fun _env ->
  match
    Board_tool_attachment.resolve
      ~base_path
      ~max_artifact_bytes:1024
      (List.map
         (fun (kind, word) ->
           { Board_tool_attachment.kind
           ; source = Board_tool_attachment.Artifact_sha256 stored.Tool_output.sha256
           ; name = Some (word ^ ".bin")
           })
         kinds)
  with
  | Error error ->
    Alcotest.failf "stored artifact failed to resolve: %s"
      (Board_tool_attachment.error_to_string error)
  | Ok resolved ->
    Alcotest.(check (list (pair string string)))
      "each entry's kind word and name"
      (List.map (fun (_, word) -> word, word ^ ".bin") kinds)
      (List.map
         (fun entry ->
           let json = Board_tool_attachment.to_json entry in
           Yojson.Safe.Util.(
             ( member "kind" json |> to_string
             , member "name" json |> to_string )))
         resolved);
    Alcotest.(check bool) "the entry points at the stored blob" true
      (List.for_all
         (function
           | Board_tool_attachment.Artifact { reference; _ } ->
             String.equal reference.Tool_output.sha256 stored.Tool_output.sha256
           | Board_tool_attachment.Url _ -> false)
         resolved)
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
        ; Alcotest.test_case "unprintable name rejected" `Quick
            test_unprintable_name_rejected
        ; Alcotest.test_case "unknown extra field still rejected" `Quick
            test_unknown_extra_field_still_rejected
        ; Alcotest.test_case "resolve and to_json preserve name" `Quick
            test_resolve_and_to_json_preserve_name
        ; Alcotest.test_case "a stored artifact keeps its kind and name" `Quick
            test_stored_artifact_keeps_kind_and_name
        ]
      )
    ]
;;

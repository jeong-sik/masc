(* Board post attachments decode from [meta.attachments] per entry, with
   explicit failure carried on the entry rather than failing the post
   (spec decision 5). The wire writer is the board post handler
   (lib/board_tool_adapter/board_tool_attachment.ml): a stored entry is
   [{"kind", "url"|"artifact", "name"?}]. These pin the read side: a kind
   this build does not know is carried as [Ak_unknown] and still decodes, a
   broken entry is an [Error] carrying why, and the rest of the entries and
   the post decode normally. *)

open Masc_tui_types

let sha256 = String.make 64 'a'

let url_entry ?name kind url =
  `Assoc
    ([ "kind", `String kind; "url", `String url ]
     @ match name with Some name -> [ "name", `String name ] | None -> [])
;;

let artifact_entry ?name kind digest =
  `Assoc
    ([ ( "kind", `String kind )
     ; ( "artifact"
       , `Assoc
           [ ( "_blob"
             , `Assoc
                 [ "sha256", `String digest
                 ; "bytes", `Int 42
                 ; "mime", `String "application/octet-stream"
                 ; "preview", `String ""
                 ] )
           ] )
     ]
     @ match name with Some name -> [ "name", `String name ] | None -> [])
;;

let post_json ?meta () =
  `Assoc
    ([ "id", `String "p1"
     ; "author", `String "keeper"
     ; "title", `String "t"
     ; "body", `String "b"
     ; "votes", `Int 0
     ; "comment_count", `Int 0
     ; "created_at", `String "2026-10-13"
     ]
     @ match meta with Some meta -> [ "meta", meta ] | None -> [])
;;

let decode = decode_board_attachments

let check_entry name (expected : board_attachment_entry) actual =
  Alcotest.(check bool) name true (expected = actual)
;;

let check_broken name (entry : board_attachment_entry) =
  Alcotest.(check bool) name true (Result.is_error entry)
;;

let attachments entries = post_json ~meta:(`Assoc [ "attachments", entries ]) ()

let test_meta_attachments_decode () =
  match
    decode
      (attachments
         (`List
           [ url_entry "image" "https://example.com/a.png"
           ; artifact_entry ~name:"riff.gp" "score" sha256
           ]))
  with
  | [ image; score ] ->
      check_entry "url entry decodes kind, source, no name"
        (Ok
           { ba_kind = Ak_image
           ; ba_source = As_url "https://example.com/a.png"
           ; ba_name = None
           })
        image;
      check_entry "artifact entry decodes to the digest, the size and the name"
        (Ok
           { ba_kind = Ak_score
           ; ba_source = As_artifact { sha256; bytes = 42 }
           ; ba_name = Some "riff.gp"
           })
        score
  | other ->
      Alcotest.failf "expected two attachments, decoded %d" (List.length other)
;;

let test_unknown_kind_is_carried () =
  match decode (attachments (`List [ url_entry "hologram" "https://example.com/h" ])) with
  | [ entry ] ->
      check_entry "the unknown kind keeps the wire's word and still decodes"
        (Ok
           { ba_kind = Ak_unknown "hologram"
           ; ba_source = As_url "https://example.com/h"
           ; ba_name = None
           })
        entry
  | other ->
      Alcotest.failf "unknown kind not carried: decoded %d entries"
        (List.length other)
;;

let test_malformed_entry_does_not_fail_the_rest () =
  match
    decode
      (attachments
         (`List
           [ artifact_entry "file" sha256
           ; `Assoc [ "kind", `String "image" ] (* source missing *)
           ; `String "not an object"
           ; `Assoc
               [ "kind", `String "audio"
               ; "url", `String "https://example.com/a.mp3"
               ; "name", `Int 42 (* name must be a string *)
               ]
           ; `Assoc
               [ "kind", `String "audio"
               ; "kind", `String "midi" (* which one is it *)
               ; "url", `String "https://example.com/a.mp3"
               ]
           ]))
  with
  | [ fine; missing_source; not_object; bad_name; two_kinds ] ->
      check_entry "the well-formed entry still decodes"
        (Ok
           { ba_kind = Ak_file
           ; ba_source = As_artifact { sha256; bytes = 42 }
           ; ba_name = None
           })
        fine;
      check_broken "missing source is broken, not dropped" missing_source;
      check_broken "non-object entry is broken, not dropped" not_object;
      check_broken "non-string name is broken, not dropped" bad_name;
      check_broken "a kind said twice is broken, not read as the first" two_kinds
  | other ->
      Alcotest.failf "expected five attachments, decoded %d" (List.length other)
;;

let test_no_meta_means_no_attachments () =
  Alcotest.(check int) "no meta" 0 (List.length (decode (post_json ())));
  Alcotest.(check int)
    "meta without attachments" 0
    (List.length (decode (post_json ~meta:(`Assoc [ "source", `String "x" ]) ())))
;;

let test_non_list_attachments_is_one_broken_entry () =
  match decode (attachments (`String "oops")) with
  | [ broken ] -> check_broken "one broken entry stands for the claim" broken
  | other ->
      Alcotest.failf "expected one broken entry, decoded %d" (List.length other)
;;

(* A stored artifact is the handler's wrapper: a digest and an integer size.
   Each of these is some other shape under [artifact], and none of them reads
   as an attachment. The bare [sha256] form is what a client sends, never
   what a post holds. *)
let test_only_the_handlers_wrapper_is_an_artifact () =
  let wrapper fields = `Assoc [ "_blob", `Assoc fields ] in
  let broken label source =
    match decode (attachments (`List [ `Assoc (("kind", `String "file") :: source) ])) with
    | [ entry ] -> check_broken label entry
    | other -> Alcotest.failf "%s: decoded %d entries" label (List.length other)
  in
  broken "a size that is not an integer"
    [ "artifact", wrapper [ "sha256", `String sha256; "bytes", `String "42" ] ];
  broken "no size"
    [ "artifact", wrapper [ "sha256", `String sha256 ] ];
  broken "a digest that is not a sha256"
    [ "artifact", wrapper [ "sha256", `String "abc"; "bytes", `Int 42 ] ];
  broken "a bare digest" [ "sha256", `String sha256 ]
;;

let () =
  Alcotest.run "tui_board_attachments"
    [ ( "decode"
      , [ Alcotest.test_case "meta.attachments decode" `Quick
            test_meta_attachments_decode
        ; Alcotest.test_case "unknown kind is carried" `Quick
            test_unknown_kind_is_carried
        ; Alcotest.test_case "malformed entry does not fail the rest" `Quick
            test_malformed_entry_does_not_fail_the_rest
        ; Alcotest.test_case "no meta means no attachments" `Quick
            test_no_meta_means_no_attachments
        ; Alcotest.test_case "non-list attachments is one broken entry" `Quick
            test_non_list_attachments_is_one_broken_entry
        ; Alcotest.test_case "only the handler's wrapper is an artifact" `Quick
            test_only_the_handlers_wrapper_is_an_artifact
        ] )
    ]

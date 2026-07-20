(** Unit tests for Board_render — the connector-agnostic board post
    projection (RFC-0000 §3.1).

    Pure fixtures, no store: posts are built as records the same way
    test_board_sort does. *)

open Alcotest
open Masc
module Board_render = Masc_board_handlers.Board_render
module BAM = Board_attachment_meta

let () = Mirage_crypto_rng_unix.use_default ()

let post_id_exn s =
  match Board.Post_id.of_string s with
  | Ok id -> id
  | Error _ -> Alcotest.fail (Printf.sprintf "invalid post_id fixture: %s" s)

let agent_id_exn s =
  match Board.Agent_id.of_string s with
  | Ok id -> id
  | Error _ -> Alcotest.fail (Printf.sprintf "invalid agent_id fixture: %s" s)

let make_post ?(title = "Deploy retro") ?(body = "shipped the thing")
      ?(hearth = None) ?(meta_json = None) ~id () : Board.post =
  { id = post_id_exn id
  ; author = agent_id_exn "render-test-author"
  ; title
  ; body
  ; content = body
  ; post_kind = Board.Human_post
  ; meta_json
  ; visibility = Board.Public
  ; created_at = 1_714_989_600.0
  ; updated_at = 1_714_989_600.0
  ; expires_at = 1_717_081_200.0
  ; votes_up = 0
  ; votes_down = 0
  ; reply_count = 0
  ; pinned = false
  ; hearth
  ; thread_id = None
  ; origin = None
  }

let attachment_json ~id ~kind ~url ?(name = "file.bin") ?(size = 128)
    ?(mime = "application/octet-stream") ?width ?height () : Yojson.Safe.t =
  `Assoc
    [ "id", `String id
    ; "kind", `String kind
    ; "origin_url", `String url
    ; "origin_name", `String name
    ; "origin_size_bytes", `Int size
    ; "mime_type", `String mime
    ; ( "width"
      , match width with Some w -> `Int w | None -> `Null )
    ; ( "height"
      , match height with Some h -> `Int h | None -> `Null )
    ; "created_at", `Float 1_714_989_600.0
    ]

let meta_with attachments =
  Some (BAM.attach_to_post_meta ~existing:None attachments)

let meta_with_raw entries : Yojson.Safe.t option =
  Some (`Assoc [ BAM.meta_json_key, `List entries ])

let attachment_id_exn s =
  match BAM.Id.of_string s with
  | Ok id -> id
  | Error _ -> Alcotest.fail (Printf.sprintf "invalid attachment id fixture: %s" s)

let sample_attachment ~id ~kind ~url ?(name = "file.bin") () : BAM.t =
  { id = attachment_id_exn id
  ; kind
  ; origin_url = url
  ; origin_name = name
  ; origin_size_bytes = 128
  ; mime_type = "application/octet-stream"
  ; width = None
  ; height = None
  ; created_at = 1_714_989_600.0
  }

let document_testable =
  testable
    (fun fmt doc -> Format.fprintf fmt "%s" (Board_render.show_document doc))
    Board_render.equal_document

(* --- document_of_post --- *)

let test_post_without_meta_renders_header_and_body () =
  let post = make_post ~id:"p-render-1" () in
  let doc = Board_render.document_of_post post in
  let expected : Board_render.document =
    { post_id = "p-render-1"
    ; blocks =
        [ Header
            { title = "Deploy retro"; author = "render-test-author"
            ; hearth = None }
        ; Body "shipped the thing"
        ]
    }
  in
  check document_testable "header+body only" expected doc

let test_blank_body_is_omitted () =
  let post = make_post ~id:"p-render-2" ~body:"   " () in
  let doc = Board_render.document_of_post post in
  match doc.blocks with
  | [ Header _ ] -> ()
  | blocks ->
    failf "expected header-only document, got %s"
      (Board_render.show_document { doc with blocks })

let test_all_four_attachment_kinds_render_in_order () =
  let open BAM in
  let attachments =
    [ { (sample_attachment ~id:"a-img" ~kind:Image ~url:"https://cdn.example.com/a.png" ~name:"a.png" ()) with
        width = Some 640
      ; height = Some 480
      ; mime_type = "image/png"
      }
    ; { (sample_attachment ~id:"a-vid" ~kind:Video ~url:"https://cdn.example.com/b.mp4" ~name:"b.mp4" ()) with
        mime_type = "video/mp4"
      }
    ; sample_attachment ~id:"a-yt" ~kind:Youtube
        ~url:"https://www.youtube.com/watch?v=abc123def45" ~name:"demo" ()
    ; sample_attachment ~id:"a-link" ~kind:External_link
        ~url:"https://example.com/spec" ~name:"spec" ()
    ]
  in
  let post = make_post ~id:"p-render-3" ~meta_json:(meta_with attachments) () in
  let doc = Board_render.document_of_post post in
  let expected_blocks : Board_render.block list =
    [ Header
        { title = "Deploy retro"; author = "render-test-author"; hearth = None }
    ; Body "shipped the thing"
    ; Attachment
        (Image
           { url = "https://cdn.example.com/a.png"; name = "a.png"
           ; width = Some 640; height = Some 480 })
    ; Attachment
        (Video
           { url = "https://cdn.example.com/b.mp4"; name = "b.mp4"
           ; mime_type = "video/mp4" })
    ; Attachment
        (Youtube
           { url = "https://www.youtube.com/watch?v=abc123def45"
           ; name = "demo" })
    ; Attachment
        (External_link { url = "https://example.com/spec"; name = "spec" })
    ]
  in
  let expected : Board_render.document = { post_id = "p-render-3"; blocks = expected_blocks } in
  check document_testable "4 kinds in stored order" expected doc

let test_malformed_attachment_becomes_explicit_invalid_block () =
  (* Missing [origin_url] — fails the typed BAM decode. *)
  let bad = `Assoc [ "id", `String "a-bad"; "kind", `String "image" ] in
  let post = make_post ~id:"p-render-4" ~meta_json:(meta_with_raw [ bad ]) () in
  let doc = Board_render.document_of_post post in
  match doc.blocks with
  | [ Header _; Body _; Attachment (Invalid_attachment { detail }) ] ->
    check bool "detail names the missing field" true
      (String_util.contains_substring detail "origin_url")
  | blocks ->
    failf "expected explicit invalid attachment block, got %s"
      (Board_render.show_document { doc with blocks })

let test_non_list_attachments_key_becomes_explicit_invalid_block () =
  let meta = Some (`Assoc [ BAM.meta_json_key, `String "not-a-list" ]) in
  let post = make_post ~id:"p-render-5" ~meta_json:meta () in
  let doc = Board_render.document_of_post post in
  match doc.blocks with
  | [ Header _; Body _; Attachment (Invalid_attachment { detail }) ] ->
    check bool "detail names the attachments key" true
      (String_util.contains_substring detail BAM.meta_json_key)
  | blocks ->
    failf "expected explicit invalid block for non-list carrier, got %s"
      (Board_render.show_document { doc with blocks })

let test_unknown_kind_becomes_explicit_invalid_block () =
  let bad = attachment_json ~id:"a-what" ~kind:"hologram"
      ~url:"https://example.com/h" ()
  in
  let post = make_post ~id:"p-render-6" ~meta_json:(meta_with_raw [ bad ]) () in
  let doc = Board_render.document_of_post post in
  match doc.blocks with
  | [ Header _; Body _; Attachment (Invalid_attachment { detail }) ] ->
    check bool "detail names the bad kind" true
      (String_util.contains_substring detail "hologram")
  | blocks ->
    failf "expected explicit invalid block for unknown kind, got %s"
      (Board_render.show_document { doc with blocks })

(* --- plain_text --- *)

let test_plain_text_full_projection () =
  let open BAM in
  let attachments =
    [ sample_attachment ~id:"a-img" ~kind:Image ~url:"https://cdn.example.com/a.png" ~name:"a.png" ()
    ; sample_attachment ~id:"a-yt" ~kind:Youtube
        ~url:"https://youtu.be/abc123def45" ~name:"" ()
    ]
  in
  let post =
    make_post ~id:"p-render-7" ~hearth:(Some "dev")
      ~meta_json:(meta_with attachments) ()
  in
  let doc = Board_render.document_of_post post in
  let expected =
    "Deploy retro\n\
     by render-test-author in dev\n\
     shipped the thing\n\
     [image] a.png (https://cdn.example.com/a.png)\n\
     [youtube] https://youtu.be/abc123def45"
  in
  check string "plain text fallback" expected (Board_render.plain_text doc)

let test_plain_text_names_invalid_attachment () =
  let bad = `Assoc [ "id", `String "a-bad"; "kind", `String "image" ] in
  let post = make_post ~id:"p-render-8" ~meta_json:(meta_with_raw [ bad ]) () in
  let doc = Board_render.document_of_post post in
  let text = Board_render.plain_text doc in
  check bool "invalid attachment is named in fallback" true
    (String_util.contains_substring text "[invalid attachment]")

let () =
  run "Board_render"
    [ ( "document_of_post"
      , [ test_case "no meta -> header+body" `Quick
            test_post_without_meta_renders_header_and_body
        ; test_case "blank body omitted" `Quick test_blank_body_is_omitted
        ; test_case "4 attachment kinds in order" `Quick
            test_all_four_attachment_kinds_render_in_order
        ; test_case "malformed entry -> explicit invalid" `Quick
            test_malformed_attachment_becomes_explicit_invalid_block
        ; test_case "non-list carrier -> explicit invalid" `Quick
            test_non_list_attachments_key_becomes_explicit_invalid_block
        ; test_case "unknown kind -> explicit invalid" `Quick
            test_unknown_kind_becomes_explicit_invalid_block
        ] )
    ; ( "plain_text"
      , [ test_case "full projection" `Quick test_plain_text_full_projection
        ; test_case "invalid attachment named" `Quick
            test_plain_text_names_invalid_attachment
        ] )
    ]

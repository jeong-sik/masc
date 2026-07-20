(** Unit tests for Board_render_discord — the Discord send-side adapter
    converting {!Board_render} documents into [Discord_rest_client] payload
    pieces. Pure: payloads are compared structurally, nothing is sent. *)

open Alcotest
open Masc

let embed_testable =
  testable
    (fun fmt (e : Discord_rest_client.embed) ->
      Format.pp_print_string fmt
        (Yojson.Safe.pretty_to_string (Discord_rest_client.embed_to_json e)))
    (fun a b ->
      Yojson.Safe.equal
        (Discord_rest_client.embed_to_json a)
        (Discord_rest_client.embed_to_json b))

let header ?(title = "Deploy retro") ?(author = "alice") ?(hearth = Some "dev") () :
    Board_render.block =
  Header { title; author; hearth }

let doc ?(post_id = "p-dc-1") blocks : Board_render.document =
  { post_id; blocks }

let image ?(name = "a.png") url =
  Board_render.Attachment
    (Image { url; name; width = Some 640; height = Some 480 })

let test_header_body_only_document () =
  let d = doc [ header (); Body "shipped the thing" ] in
  let payload = Board_render_discord.payload_of_document d in
  check string "content is header+body fallback"
    "Deploy retro\nby alice in dev\nshipped the thing" payload.content;
  check (list embed_testable) "no embeds" [] payload.embeds

let test_attachments_become_embeds_not_text () =
  let d =
    doc
      [ header ()
      ; Body "shipped the thing"
      ; image "https://cdn.example.com/a.png"
      ; Attachment
          (Video
             { url = "https://cdn.example.com/b.mp4"; name = "b.mp4"
             ; mime_type = "video/mp4" })
      ; Attachment
          (Youtube
             { url = "https://youtu.be/abc123def45"; name = "demo" })
      ; Attachment
          (External_link { url = "https://example.com/spec"; name = "spec" })
      ]
  in
  let payload = Board_render_discord.payload_of_document d in
  check string "content keeps header+body only"
    "Deploy retro\nby alice in dev\nshipped the thing" payload.content;
  let expected =
    [ Discord_rest_client.image_embed ~url:"https://cdn.example.com/a.png"
        ~caption:(Some "a.png")
    ; Discord_rest_client.link_embed ~url:"https://cdn.example.com/b.mp4"
        ~title:"b.mp4" ~description:None ~image:None
    ; Discord_rest_client.link_embed ~url:"https://youtu.be/abc123def45"
        ~title:"demo" ~description:None ~image:None
    ; Discord_rest_client.link_embed ~url:"https://example.com/spec"
        ~title:"spec" ~description:None ~image:None
    ]
  in
  check (list embed_testable) "4 attachment embeds" expected payload.embeds

let test_blank_name_falls_back_to_url_for_link_title () =
  let d =
    doc
      [ header ()
      ; Attachment
          (External_link { url = "https://example.com/spec"; name = "  " })
      ]
  in
  let payload = Board_render_discord.payload_of_document d in
  let expected =
    [ Discord_rest_client.link_embed ~url:"https://example.com/spec"
        ~title:"https://example.com/spec" ~description:None ~image:None
    ]
  in
  check (list embed_testable) "url stands in for blank title" expected
    payload.embeds

let test_invalid_attachment_stays_as_explicit_content_line () =
  let d =
    doc
      [ header ()
      ; Body "shipped the thing"
      ; Attachment
          (Invalid_attachment { detail = "Missing field: origin_url" })
      ]
  in
  let payload = Board_render_discord.payload_of_document d in
  check string "invalid attachment is named in content"
    "Deploy retro\nby alice in dev\nshipped the thing\n\
     [invalid attachment] Missing field: origin_url" payload.content;
  check (list embed_testable) "no embed for invalid attachment" []
    payload.embeds

let test_embed_overflow_falls_back_to_content_lines () =
  let images =
    List.init 11 (fun i ->
      image ~name:(Printf.sprintf "img-%02d.png" i)
        (Printf.sprintf "https://cdn.example.com/img-%02d.png" i))
  in
  let d = doc (header () :: images) in
  let payload = Board_render_discord.payload_of_document d in
  check int "embeds capped at the Discord limit"
    Board_render_discord.discord_embed_limit
    (List.length payload.embeds);
  check string "11th image stays visible as a text line"
    "Deploy retro\nby alice in dev\n\
     [image] img-10.png (https://cdn.example.com/img-10.png)" payload.content

let () =
  run "Board_render_discord"
    [ ( "payload_of_document"
      , [ test_case "header+body only" `Quick test_header_body_only_document
        ; test_case "attachments -> embeds" `Quick
            test_attachments_become_embeds_not_text
        ; test_case "blank name -> url title" `Quick
            test_blank_name_falls_back_to_url_for_link_title
        ; test_case "invalid attachment -> content line" `Quick
            test_invalid_attachment_stays_as_explicit_content_line
        ; test_case "embed overflow -> content lines" `Quick
            test_embed_overflow_falls_back_to_content_lines
        ] )
    ]

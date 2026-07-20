(** Unit tests for Board_render_slack — the Slack send-side adapter
    converting {!Board_render} documents into the (text, blocks) payload
    {!Keeper_chat_slack.send_message_with_blocks} accepts. Pure. *)

open Alcotest
open Masc

(* Order-insensitive structural JSON equality: Block Kit objects are maps,
   key order carries no meaning. *)
let rec normalize_json = function
  | `Assoc kvs ->
    `Assoc
      (List.sort (fun (a, _) (b, _) -> String.compare a b)
         (List.map (fun (k, v) -> k, normalize_json v) kvs))
  | `List xs -> `List (List.map normalize_json xs)
  | other -> other

let json_testable =
  testable
    (fun fmt j -> Format.pp_print_string fmt (Yojson.Safe.pretty_to_string j))
    (fun a b -> Yojson.Safe.equal (normalize_json a) (normalize_json b))

let mrkdwn_section text : Yojson.Safe.t =
  `Assoc
    [ "type", `String "section"
    ; "text", `Assoc [ "type", `String "mrkdwn"; "text", `String text ]
    ]

let image_block ~url ~alt : Yojson.Safe.t =
  `Assoc
    [ "type", `String "image"
    ; "image_url", `String url
    ; "alt_text", `String alt
    ]

let header ?(title = "Deploy retro") ?(author = "alice") ?(hearth = Some "dev") () :
    Board_render.block =
  Header { title; author; hearth }

let test_header_body_only_document () =
  let doc : Board_render.document =
    { post_id = "p-sl-1"; blocks = [ header (); Body "shipped the thing" ] }
  in
  let payload = Board_render_slack.payload_of_document doc in
  check string "text is the plain-text fallback"
    "Deploy retro\nby alice in dev\nshipped the thing" payload.content;
  check (list json_testable) "no blocks" [] payload.blocks

let test_all_attachment_kinds_become_blocks () =
  let doc : Board_render.document =
    { post_id = "p-sl-2"
    ; blocks =
        [ header ()
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
               { url = "https://youtu.be/abc123def45"; name = "demo" })
        ; Attachment
            (External_link { url = "https://example.com/spec"; name = "spec" })
        ]
    }
  in
  let payload = Board_render_slack.payload_of_document doc in
  check string "text fallback carries attachment lines too"
    "Deploy retro\nby alice in dev\nshipped the thing\n\
     [image] a.png (https://cdn.example.com/a.png)\n\
     [video] b.mp4 (https://cdn.example.com/b.mp4)\n\
     [youtube] demo (https://youtu.be/abc123def45)\n\
     [link] spec (https://example.com/spec)" payload.content;
  let expected =
    [ image_block ~url:"https://cdn.example.com/a.png" ~alt:"a.png"
    ; mrkdwn_section "*<https://cdn.example.com/b.mp4|b.mp4>*"
    ; mrkdwn_section "*<https://youtu.be/abc123def45|demo>*"
    ; mrkdwn_section "*<https://example.com/spec|spec>*"
    ]
  in
  check (list json_testable) "4 Block Kit blocks" expected payload.blocks

let test_blank_name_falls_back_to_url_for_link_title () =
  let doc : Board_render.document =
    { post_id = "p-sl-3"
    ; blocks =
        [ header ()
        ; Attachment
            (External_link { url = "https://example.com/spec"; name = "" })
        ]
    }
  in
  let payload = Board_render_slack.payload_of_document doc in
  let expected =
    [ mrkdwn_section "*<https://example.com/spec|https://example.com/spec>*" ]
  in
  check (list json_testable) "url stands in for blank title" expected
    payload.blocks

let test_invalid_attachment_becomes_explicit_notice_block () =
  let doc : Board_render.document =
    { post_id = "p-sl-4"
    ; blocks =
        [ header ()
        ; Attachment
            (Invalid_attachment { detail = "Missing field: origin_url" })
        ]
    }
  in
  let payload = Board_render_slack.payload_of_document doc in
  check bool "text fallback names the invalid attachment" true
    (String_util.contains_substring payload.content "[invalid attachment]");
  let expected =
    [ mrkdwn_section "⚠️ invalid attachment: Missing field: origin_url" ]
  in
  check (list json_testable) "explicit notice block" expected payload.blocks

let () =
  run "Board_render_slack"
    [ ( "payload_of_document"
      , [ test_case "header+body only" `Quick test_header_body_only_document
        ; test_case "all kinds -> blocks" `Quick
            test_all_attachment_kinds_become_blocks
        ; test_case "blank name -> url title" `Quick
            test_blank_name_falls_back_to_url_for_link_title
        ; test_case "invalid attachment -> notice block" `Quick
            test_invalid_attachment_becomes_explicit_notice_block
        ] )
    ]

open Alcotest

module Blocks = Masc.Keeper_chat_blocks
module Media = Masc_tui_chat_media
module Preview = Masc_tui_image_preview
module History = Masc_tui_keeper_chat_history

let image = Blocks.Image { src = "data:image/png;base64,aW1hZ2U="; cap = Some "result" }
let voice = Blocks.Voice {
  secs = Some 2.5; wave = None; via = None; size = None;
  transcript = Some "  음성\n\n본문  "; src = Some "/api/v1/audio/clip" }

let message ~role ~autonomous ~text blocks =
  `Assoc [ "id", `String "media-only"; "role", `String role;
           "content", `String text; "ts", `Float 1.;
           "autonomous_turn", (if autonomous then `Assoc [ "turn_id", `String "media#1" ] else `Null);
           "blocks", Blocks.blocks_to_yojson blocks ]

let read_message json =
  match History.rows_of_json (`List [ json ]) with
  | Ok { rows = [ row ]; dropped = 0 } -> row
  | Ok _ -> fail "media message was lost or duplicated"
  | Error detail -> fail detail

let test_media_only_autonomous () =
  let row = read_message (message ~role:"assistant" ~autonomous:true ~text:"" [ image; voice ]) in
  (match row.kind with History.Autonomous_reply -> () | _ -> fail "lost autonomous authorship");
  check string "visible media and exact transcript"
    "Image · result · inline payload\nVoice · 2.5s · /api/v1/audio/clip\n  음성\n\n본문  "
    (Media.append_text ~text:row.text row.media);
  match Media.newest_image row.media with
  | Some (Preview.Output_image { name = "result"; source = Preview.Inline_data src }) ->
    check string "payload decoded on opening" "image" (Result.get_ok (Preview.decode_payload src))
  | _ -> fail "voice displaced the image action"

let test_failure_retains_outputs () =
  let row = read_message (message ~role:"request_failure" ~autonomous:false
    ~text:"provider failed" [ image; voice ]) in
  (match row.kind with History.Delivery_failed _ -> () | _ -> fail "failure became Keeper speech");
  check int "both retained outputs" 2 (List.length row.media);
  check string "diagnostics precede media" "provider failed\nImage · result · inline payload\nVoice · 2.5s · /api/v1/audio/clip\n  음성\n\n본문  "
    (Media.append_text ~text:row.text row.media)

let test_prose_and_unknown_block () =
  let encoded = match Blocks.blocks_to_yojson [ image ] with
    | `List blocks -> `List (`Assoc [ "t", `String "unrecognized" ] :: blocks)
    | _ -> fail "canonical producer did not emit an array" in
  let media = Media.of_json encoded in
  check string "prose whitespace retained" "  caption\n\nImage · result · inline payload"
    (Media.append_text ~text:"  caption\n\n" media)

let test_sources () =
  List.iter (fun src -> match Preview.output_image ~name:"generated" ~src with
    | Preview.Unavailable_image _ -> ()
    | _ -> fail ("provider source became a local file: " ^ src))
    [ "file:///tmp/image.png"; "relative/image.png"; "//other-host/image.png" ];
  (match Preview.output_image ~name:"peer" ~src:"/api/v1/generated/image?token=x" with
   | Preview.Output_image { source = Preview.Server_path path; _ } ->
     check string "authenticated peer path" "/api/v1/generated/image?token=x" path
   | _ -> fail "peer image is unavailable");
  match Preview.output_image ~name:"remote" ~src:"https://example.com/image.png" with
  | Preview.Output_image { source = Preview.Remote_uri _; _ } -> ()
  | _ -> fail "HTTP source is unavailable"

let test_image_attachment_and_svg () =
  let attachment = Blocks.Attach { name = "output"; dims = None; src = Some "/image";
    svg = None; ph = None; via = None; size = None; data = None;
    mime_type = Some "image/png"; size_bytes = None; kind = None } in
  (match Media.newest_image (Media.of_json (Blocks.blocks_to_yojson [ attachment ])) with
   | Some (Preview.Output_image { source = Preview.Server_path "/image"; _ }) -> ()
   | _ -> fail "image attachment URL lost");
  let svg = "<svg xmlns=\"http://www.w3.org/2000/svg\"/>" in
  match Media.newest_image (Media.of_json (Blocks.blocks_to_yojson
    [ image; Blocks.Svg { svg; cap = Some "vector" } ])) with
  | Some (Preview.Output_image { name = "vector"; source = Preview.Inline_svg markup }) ->
    check string "newest SVG retained" svg markup
  | _ -> fail "SVG did not replace the older image"

let () = run "TUI retained output" [ "history", [
  test_case "media-only autonomous turn" `Quick test_media_only_autonomous;
  test_case "failure retains completed outputs" `Quick test_failure_retains_outputs;
  test_case "prose and unknown block" `Quick test_prose_and_unknown_block;
  test_case "source authority" `Quick test_sources;
  test_case "image attachment and SVG" `Quick test_image_attachment_and_svg ] ]

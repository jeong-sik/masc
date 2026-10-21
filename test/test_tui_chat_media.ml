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
    check string "payload decoded on opening" "image" (Result.get_ok (Masc_tui_image_payload.decode src))
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

let attach ?src ?data name : Blocks.attach_block =
  { name; dims = None; src; svg = None; ph = None; via = None; size = None
  ; data; mime_type = None; size_bytes = None; kind = None }

let attach_media ?src ?data name = Media.Attach (attach ?src ?data name)
let voice_media ?src () =
  Media.Voice { secs = None; wave = None; via = None; size = None
              ; transcript = None; src }

let playable_testable = Alcotest.testable
  (fun ppf (p : Media.playable) ->
     let kind = match p.kind with `Audio -> "audio" | `Midi -> "midi" in
     let source = match p.source with
       | `Data _ -> "data"
       | `Server_path path -> "server " ^ path
       | `Local_path path -> "local " ^ path
     in
     Format.fprintf ppf "%s %s (%s)" kind p.name source)
  ( = )

let check_playable label media expected =
  check (option playable_testable) label expected (Media.newest_playable media)

let test_newest_audio_wins () =
  check_playable "the last audio attach is the pick"
    [ attach_media "notes.txt"; attach_media ~src:"/api/v1/media/aaa" "take1.mid"
    ; attach_media ~src:"/api/v1/media/bbb" "riff.mp3" ]
    (Some { name = "riff.mp3"; kind = `Audio
          ; source = `Server_path "/api/v1/media/bbb" })

let test_midi_is_playable () =
  check_playable "a midi extension classifies as midi"
    [ attach_media ~src:"/api/v1/media/aaa" "take1.MID" ]
    (Some { name = "take1.MID"; kind = `Midi
          ; source = `Server_path "/api/v1/media/aaa" })

let test_unplayable_blocks_are_skipped () =
  check_playable "images and plain files are skipped, the older audio still plays"
    [ attach_media ~src:"/api/v1/media/aaa" "riff.mp3"
    ; attach_media "chart.png"; attach_media "setup.terminal" ]
    (Some { name = "riff.mp3"; kind = `Audio
          ; source = `Server_path "/api/v1/media/aaa" });
  check_playable "nothing playable gives none"
    [ attach_media "chart.png"; attach_media "notes.txt" ] None

let test_block_data_preferred_over_src () =
  check_playable "inline bytes beat a remote source"
    [ attach_media ~src:"/api/v1/media/aaa" ~data:"QUJD" "riff.mp3" ]
    (Some { name = "riff.mp3"; kind = `Audio; source = `Data "QUJD" })

let test_voice_is_audio_with_resolvable_src () =
  check_playable "a voice block on the server plays"
    [ voice_media ~src:"/api/v1/media/voice1" () ]
    (Some { name = "voice1"; kind = `Audio
          ; source = `Server_path "/api/v1/media/voice1" });
  check_playable "a voice block on a local path plays"
    [ voice_media ~src:"/tmp/voice/clip.mp3" () ]
    (Some { name = "clip.mp3"; kind = `Audio
          ; source = `Local_path "/tmp/voice/clip.mp3" });
  check_playable "a voice block without a source does not"
    [ voice_media () ] None

let test_remote_http_src_is_not_played () =
  check_playable "an external http source is out of scope for now"
    [ attach_media ~src:"https://example.com/x.mp3" "x.mp3" ] None

let test_canonical_mermaid_preview () =
  let source = "classDiagram\n  Keeper <|-- Librarian" in
  let row = read_message (message ~role:"assistant" ~autonomous:false ~text:""
    [ image; Blocks.Mermaid { source; caption = Some "Agents" } ]) in
  (match Media.newest_image row.media with
   | Some (Preview.Output_image { name = "Agents"; source = Preview.Inline_mermaid actual }) ->
       check string "canonical block retains exact source" source actual
   | _ -> fail "canonical diagram did not replace an older image");
  let visible = Media.append_text ~text:row.text row.media in
  check (list string) "canonical-only source is available even without Pele"
    [source] (Masc_tui_markdown.mermaid_sources visible);
  let prose = "Exact prose\n```mermaid\n" ^ source ^ "\n```\n" in
  check string "canonical source already in prose is not duplicated" prose
    (Media.append_text ~text:prose [Media.Mermaid { source; caption = None }]);
  check_playable "diagram is not audio" row.media None;
  match Media.newest_image (Media.of_json (Blocks.blocks_to_yojson
    [ Blocks.Mermaid { source; caption = None }; image ])) with
  | Some (Preview.Output_image { source = Preview.Inline_data _; _ }) -> ()
  | _ -> fail "diagram displaced a later image output"

let test_canonical_mermaid_fence_collision () =
  let source = "flowchart TD\n A[\"```\"] --> B" in
  let text = Media.append_text ~text:""
    [Media.Mermaid { source; caption = None }] in
  check (list string) "generated fence cannot close on a source line"
    [source] (Masc_tui_markdown.mermaid_sources text)

let test_all_producer_images () =
  let first = "flowchart TD\n A --> B" in
  let second = "sequenceDiagram\n A->>B: ready" in
  let media = [Media.Mermaid {source=first;caption=Some "first"};
    Media.Image {src="data:image/png;base64,aW1hZ2U=";cap=Some "result"};
    Media.Mermaid {source=second;caption=Some "second"};
    Media.Voice {secs=None;wave=None;via=None;size=None;transcript=None;src=None}] in
  match Media.images media with
  | [Preview.Output_image {name="first";source=Inline_mermaid one};
     Output_image {source=Inline_data _;_};
     Output_image {name="second";source=Inline_mermaid two}] ->
      check string "first source remains available" first one;
      check string "later source remains available" second two
  | _ -> fail "producer images were dropped or a voice became an image"

let test_drawn_diagram_coverage () =
  let first = "flowchart TD\n A[접수] --> B[검토]" in
  let second = "pie title 작업 비율\n \"완료\" : 3" in
  let canonical_only = Media.Mermaid {source="classDiagram\n A <|-- B";caption=None} in
  let one = Media.Mermaid {source=first;caption=Some "first"} in
  let two = Media.Mermaid {source=second;caption=None} in
  let other = [canonical_only; Media.Image {src="/api/v1/media/image";cap=None}] in
  let media = one :: two :: one :: other in
  let previews = Media.images media in
  let kept, images = Media.without_drawn_diagrams ~sources:[first;second] media previews in
  check bool "one owned fence covers one canonical occurrence" true (kept = one :: other);
  check bool "preview ownership follows the same occurrences" true (images = Media.images kept);
  let kept_again, images_again = Media.without_drawn_diagrams
      ~sources:[first;second;first] media previews in
  check bool "repeated owned fences retain canonical-only outputs" true (kept_again = other);
  check bool "uncovered image action survives" true (images_again = Media.images other);
  let untouched, untouched_images = Media.without_drawn_diagrams ~sources:[] media previews in
  check bool "no closed source claims no media" true (untouched=media && untouched_images=previews);
  check int "coverage does not mutate the original source list" 5 (List.length media)

let () = run "TUI retained output and playback" [ "history", [
  test_case "drawn diagram occurrence coverage" `Quick test_drawn_diagram_coverage;
  test_case "all producer visual sources are retained" `Quick test_all_producer_images;
  test_case "canonical diagram preserves producer order and source" `Quick test_canonical_mermaid_preview;
  test_case "canonical source fence collision" `Quick test_canonical_mermaid_fence_collision;
  test_case "media-only autonomous turn" `Quick test_media_only_autonomous;
  test_case "failure retains completed outputs" `Quick test_failure_retains_outputs;
  test_case "prose and unknown block" `Quick test_prose_and_unknown_block;
  test_case "source authority" `Quick test_sources;
  test_case "image attachment and SVG" `Quick test_image_attachment_and_svg ];
  "playable", [
  test_case "the newest audio wins" `Quick test_newest_audio_wins;
  test_case "midi is playable" `Quick test_midi_is_playable;
  test_case "unplayable blocks are skipped" `Quick test_unplayable_blocks_are_skipped;
  test_case "block data preferred over src" `Quick test_block_data_preferred_over_src;
  test_case "voice is audio with a resolvable src" `Quick
    test_voice_is_audio_with_resolvable_src;
  test_case "remote http src is not played" `Quick test_remote_http_src_is_not_played;
] ]

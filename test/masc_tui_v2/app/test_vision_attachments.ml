open Alcotest
open Masc_tui_core
open Masc_tui_keymap
open Masc_tui_protocol
open Masc_tui_store
open Masc_tui_term
open Masc_tui_ui
open Masc_tui_screens_core
open Masc_tui_screens_domain
open Masc_tui_screens_ops
open Masc_tui_app

let contains_sub ~needle ~haystack =
  let nl = String.length needle in
  let hl = String.length haystack in
  if nl = 0 then true
  else if nl > hl then false
  else
    let rec loop i =
      if i + nl > hl then false
      else if String.equal (String.sub haystack i nl) needle then true
      else loop (i + 1)
    in
    loop 0

let grid_all_text (grid : Cell_grid.t) =
  let buf = Buffer.create 1024 in
  for y = 0 to Cell_grid.rows grid - 1 do
    for x = 0 to Cell_grid.cols grid - 1 do
      match (Cell_grid.get grid ~x ~y).glyph with
      | Cell_grid.Ascii c -> Buffer.add_char buf c
      | Cell_grid.Utf8 s -> Buffer.add_string buf s
      | Cell_grid.Empty | Cell_grid.Continuation | Cell_grid.Braille _ ->
          Buffer.add_char buf ' '
    done;
    Buffer.add_char buf '\n'
  done;
  Buffer.contents buf

let make_test_png_2x2 () =
  (* Top row: red (255,0,0,255), green (0,255,0,255)
     Bottom row: blue (0,0,255,255), white (255,255,255,255) *)
  let rgba =
    "\255\000\000\255" ^ "\000\255\000\255"
    ^ "\000\000\255\255" ^ "\255\255\255\255"
  in
  match Rgb_png.encode_rgba ~width:2 ~height:2 ~rgba with
  | Ok png -> png
  | Error msg -> fail ("Rgb_png.encode_rgba failed: " ^ msg)

let with_temp_file ~suffix ~contents f =
  let path = Filename.temp_file "masc_tui_att_" suffix in
  Fun.protect
    ~finally:(fun () -> if Sys.file_exists path then Sys.remove path)
    (fun () ->
      let oc = open_out_bin path in
      Fun.protect ~finally:(fun () -> close_out oc) (fun () -> output_string oc contents);
      f path)

let sample_att_id = "att_" ^ String.make 64 'a'

let sample_attachment : Wire_attachment.t =
  {
    id = sample_att_id;
    attachment_id = sample_att_id;
    sha256 = Some (String.make 64 'a');
    url = "/api/v1/attachments/" ^ sample_att_id;
    mime_type = "image/png";
    kind = Wire_attachment.Kind_image;
    bytes = 4096;
    width = Some 1280;
    height = Some 720;
    filename = Some "screenshot.png";
    origin = Some "tui";
    retention = Some "session";
  }

let mk_key ?(ctrl = false) ?(alt = false) ?(shift = false) key =
  Keymap.Input.{ key; mods = { ctrl; alt; shift } }

let char_key ?ctrl ?alt ?shift s = mk_key ?ctrl ?alt ?shift (Keymap.Input.Char s)

let t0 = Clock.Mono.of_ns 1_000_000_000L

(* --- 1. Wire_attachment: MIME sniffing, path normalization, codecs --- *)

let test_wire_attachment_sniff_and_paths () =
  let png = make_test_png_2x2 () in
  check (option string) "sniff PNG magic" (Some "image/png")
    (Wire_attachment.sniff_mime png);
  check (option string) "sniff JPEG magic" (Some "image/jpeg")
    (Wire_attachment.sniff_mime "\255\216\255\224\000\016JFIF");
  check (option string) "sniff GIF magic" (Some "image/gif")
    (Wire_attachment.sniff_mime "GIF89a\001\000\001\000");
  check (option string) "sniff WebP magic" (Some "image/webp")
    (Wire_attachment.sniff_mime "RIFF\024\000\000\000WEBPVP8 ");
  check (option string) "sniff PDF magic" (Some "application/pdf")
    (Wire_attachment.sniff_mime "%PDF-1.7\n");
  check (option string) "reject SVG extension" None
    (Wire_attachment.sniff_mime ~filename:"evil.svg" "<svg></svg>");
  check (option string) "reject HTML extension" None
    (Wire_attachment.sniff_mime ~filename:"index.html" "<html></html>");
  check string "render path adds format and max_px"
    ("/api/v1/attachments/" ^ sample_att_id ^ "?format=png&max_px=160")
    (Wire_attachment.attachment_render_path ~format:"png" ~max_px:160
       sample_attachment.url);
  check string "render path adds download=1"
    ("/api/v1/attachments/" ^ sample_att_id ^ "?download=1")
    (Wire_attachment.attachment_render_path ~download:true sample_attachment.url);
  let legacy_media = "/api/v1/media/" ^ String.make 64 'b' in
  check bool "is_attachment_path accepts /api/v1/media/" true
    (Wire_attachment.is_attachment_path legacy_media);
  check string "render path rewrites /api/v1/media/ with ?format=png"
    (legacy_media ^ "?format=png")
    (Wire_attachment.attachment_render_path ~format:"png" legacy_media);
  let enc_kr =
    Wire_attachment.encode_filename_header "/tmp/스크린샷 100%.png"
  in
  check bool "X-Filename percent-encodes space, %, and UTF-8 bytes" true
    (contains_sub ~needle:"%20100%25.png" ~haystack:enc_kr
    && not (String.contains enc_kr ' ')
    && String.for_all (fun c -> Char.code c >= 0x21 && Char.code c <= 0x7E) enc_kr);
  let enc_crlf =
    Wire_attachment.encode_filename_header "bad\r\nX-Inject: 1.png"
  in
  check bool "X-Filename strips CR/LF control bytes" true
    ((not (contains_sub ~needle:"%0D" ~haystack:enc_crlf))
    && (not (contains_sub ~needle:"%0A" ~haystack:enc_crlf))
    && not (String.contains enc_crlf '\r')
    && not (String.contains enc_crlf '\n'));
  check (option string) "normalize Finder escaped path"
    (Some "/tmp/my photo.png")
    (Wire_attachment.normalize_pasted_path "  /tmp/my\\ photo.png \n");
  check (option string) "normalize single-quoted path"
    (Some "/tmp/shot 1.webp")
    (Wire_attachment.normalize_pasted_path "'/tmp/shot 1.webp'");
  check (option string) "normalize file:// URI"
    (Some "/tmp/my%20file.png" |> Option.map (fun _ -> "/tmp/my file.png"))
    (Wire_attachment.normalize_pasted_path "file:///tmp/my%20file.png");
  with_temp_file ~suffix:".png" ~contents:png (fun path ->
      let quoted = Printf.sprintf "'%s'" path in
      check (option string) "resolve_local_media_file detects quoted PNG"
        (Some path) (Wire_attachment.resolve_local_media_file quoted);
      check (option string) "plain non-file text is not a media file" None
        (Wire_attachment.resolve_local_media_file "hello world screenshot.png"));
  let upload_json =
    Yojson.Safe.from_string
      (Printf.sprintf
         {|{"ok":true,"data":{"id":"%s","attachment_id":"%s","sha256":"%s","url":"/api/v1/attachments/%s","mime_type":"image/png","kind":"image","bytes":2048,"width":640,"height":480,"filename":"cap.png"}}|}
         sample_att_id sample_att_id (String.make 64 'a') sample_att_id)
  in
  match Wire_attachment.decode_upload_response upload_json with
  | Error err -> fail ("decode_upload_response failed: " ^ err)
  | Ok att ->
      check string "decoded attachment_id" sample_att_id att.attachment_id;
      check (option int) "decoded width" (Some 640) att.width;
      check (option int) "decoded height" (Some 480) att.height;
      check string "format_chip includes name & dims"
        "[img: cap.png 640x480]" (Wire_attachment.format_chip att)

(* --- 2. Wire_fleet: user_blocks + attachment_id, SSE media, history --- *)

let test_wire_fleet_bidirectional_media () =
  let req : Wire_fleet.chat_submit_request =
    {
      keeper_name = "alpha";
      message = "Describe this screenshot";
      request_id = "tui-1";
      origin = Wire_fleet.Origin_bare;
      mode = Wire_fleet.Follow_up;
      turn_instructions = None;
      since_seq = None;
      attachments = [ sample_attachment ];
    }
  in
  let body = Wire_fleet.encode_chat_submit_request req in
  let body_str = Yojson.Safe.to_string body in
  check bool "no inline base64 data field in submit payload" false
    (contains_sub ~needle:"data:image" ~haystack:body_str);
  let open Yojson.Safe.Util in
  let user_blocks = body |> member "user_blocks" |> to_list in
  check int "2 user_blocks (text + attachment)" 2 (List.length user_blocks);
  check string "block 0 is text" "text"
    (List.nth user_blocks 0 |> member "type" |> to_string);
  check string "block 1 is attachment" "attachment"
    (List.nth user_blocks 1 |> member "type" |> to_string);
  check string "block 1 references attachment_id" sample_att_id
    (List.nth user_blocks 1 |> member "attachment_id" |> to_string);
  let atts = body |> member "attachments" |> to_list in
  check int "1 lightweight attachment ref" 1 (List.length atts);
  check string "attachment ref has url" sample_attachment.url
    (List.hd atts |> member "url" |> to_string);

  (* Attachment-only send omits empty text block *)
  let img_only =
    Wire_fleet.encode_chat_submit_request { req with message = "   " }
    |> member "user_blocks" |> to_list
  in
  check int "attachment-only send emits 1 block (no empty text)" 1
    (List.length img_only);
  check string "attachment-only block type" "attachment"
    (List.hd img_only |> member "type" |> to_string);

  (* Live SSE KEEPER_ATTACHMENT and KEEPER_MEDIA_DELTA never Chunk_ignored *)
  let att_sse =
    Yojson.Safe.from_string
      (Printf.sprintf
         {|{"type":"KEEPER_ATTACHMENT","attachment_id":"%s","url":"/api/v1/attachments/%s","mime_type":"image/webp","kind":"image","width":1024,"height":768,"bytes":9999,"filename":"gen.webp"}|}
         sample_att_id sample_att_id)
  in
  (match Wire_fleet.decode_chat_stream_chunk att_sse with
  | Ok (Wire_fleet.Chunk_attachment { attachment = att; _ }) ->
      check string "SSE KEEPER_ATTACHMENT id" sample_att_id att.attachment_id;
      check string "SSE KEEPER_ATTACHMENT mime" "image/webp" att.mime_type;
      check (option int) "SSE KEEPER_ATTACHMENT width" (Some 1024) att.width
  | Ok _ -> fail "expected Chunk_attachment"
  | Error err -> fail ("decode KEEPER_ATTACHMENT failed: " ^ err));

  (* Also test canonical AG-UI CUSTOM envelope for KEEPER_ATTACHMENT *)
  let custom_att_sse =
    Yojson.Safe.from_string
      (Printf.sprintf
         {|{"type":"CUSTOM","name":"KEEPER_ATTACHMENT","value":{"attachment_id":"%s","url":"/api/v1/attachments/%s","mime_type":"image/png","kind":"image","bytes":1024}}|}
         sample_att_id sample_att_id)
  in
  (match Wire_fleet.decode_chat_stream_chunk custom_att_sse with
  | Ok (Wire_fleet.Chunk_attachment { attachment = att; _ }) ->
      check string "AG-UI CUSTOM KEEPER_ATTACHMENT id" sample_att_id
        att.attachment_id
  | Ok _ -> fail "expected Chunk_attachment for CUSTOM envelope"
  | Error err -> fail ("decode CUSTOM KEEPER_ATTACHMENT failed: " ^ err));

  let media_delta_sse =
    Yojson.Safe.from_string
      (Printf.sprintf
         {|{"type":"KEEPER_MEDIA_DELTA","mime_type":"image/png","url":"/api/v1/attachments/%s","width":512,"height":512}|}
         sample_att_id)
  in
  (match Wire_fleet.decode_chat_stream_chunk media_delta_sse with
  | Ok (Wire_fleet.Chunk_media_delta { mime_type; url; _ }) ->
      check (option string) "SSE KEEPER_MEDIA_DELTA url"
        (Some ("/api/v1/attachments/" ^ sample_att_id)) url;
      check string "SSE KEEPER_MEDIA_DELTA mime" "image/png" mime_type
  | Ok _ -> fail "expected Chunk_media_delta"
  | Error err -> fail ("decode KEEPER_MEDIA_DELTA failed: " ^ err));

  (* Chat History: user, tool, and assistant rows all decode attachments & blocks *)
  let att_u = "att_" ^ String.make 64 '1' in
  let att_t = "att_" ^ String.make 64 '2' in
  let att_a = "att_" ^ String.make 64 '3' in
  let hist_json =
    Yojson.Safe.from_string
      (Printf.sprintf
         {|{
           "messages": [
             {
               "id": "m-user",
               "role": "user",
               "content": "Check this",
               "ts": 1795252000.0,
               "attachments": [
                 {"attachment_id": "%s", "url": "/api/v1/attachments/%s", "mime_type": "image/jpeg", "kind": "image", "bytes": 1200, "width": 800, "height": 600, "filename": "u.jpg"}
               ],
               "blocks": [
                 {"t": "text", "text": "Check this"},
                 {"t": "attachment", "attachment_id": "%s", "url": "/api/v1/attachments/%s", "mime_type": "image/jpeg"}
               ]
             },
             {
               "id": "m-tool",
               "role": "tool",
               "content": "Screenshot captured",
               "ts": 1795252005.0,
               "blocks": [
                 {"t": "attachment", "attachment_id": "%s", "url": "/api/v1/attachments/%s", "mime_type": "image/png", "filename": "tool.png"}
               ]
             },
             {
               "id": "m-assistant",
               "role": "assistant",
               "content": "Generated chart",
               "ts": 1795252010.0,
               "blocks": [
                 {"t": "image", "url": "/api/v1/attachments/%s", "mime_type": "image/webp", "caption": "Chart"}
               ]
             }
           ],
           "has_more": false,
           "next_cursor": null
         }|}
         att_u att_u att_u att_u att_t att_t att_a)
  in
  match Wire_fleet.decode_chat_history_page hist_json with
  | Error err -> fail ("decode_chat_history failed: " ^ err)
  | Ok page ->
      check int "3 history rows" 3 (List.length page.messages);
      let m_user = List.nth page.messages 0 in
      let m_tool = List.nth page.messages 1 in
      let m_asst = List.nth page.messages 2 in
      check int "user row deduplicates attachments[] + blocks[]" 1
        (List.length m_user.retained_images);
      check (option string) "user row mime is image/jpeg" (Some "image/jpeg")
        (List.hd m_user.retained_images).mime_type;
      check int "tool row keeps tool attachment" 1
        (List.length m_tool.retained_images);
      check string "tool row attachment path" ("/api/v1/attachments/" ^ att_t)
        (List.hd m_tool.retained_images).media_path;
      check int "assistant row keeps image block" 1
        (List.length m_asst.retained_images);
      check (option string) "assistant row caption" (Some "Chart")
        (List.hd m_asst.retained_images).caption

(* --- 3. Wire_chat_journal: preserves all 4 media event types --- *)

let test_wire_chat_journal_media_events () =
  let json =
    Yojson.Safe.from_string
      (Printf.sprintf
         {|{
           "schema": "masc.keeper_chat_events.v2",
           "operation_id": "op-1",
           "has_more": false,
           "next_since_seq": null,
           "next_since_offset": 4,
           "events": [
             {"seq": 1, "event": {"type": "attachment_emitted", "attachment_id": "%s", "url": "/api/v1/attachments/%s", "mime_type": "image/png", "kind": "image", "bytes": 500}},
             {"seq": 2, "event": {"type": "agent_core_media_delta", "mime_type": "image/jpeg", "url": "/api/v1/attachments/%s"}},
             {"seq": 3, "event": {"type": "image_block", "mime_type": "image/webp", "url": "/api/v1/attachments/%s", "caption": "gen"}},
             {"seq": 4, "event": {"type": "audio_block", "mime_type": "audio/mpeg", "url": "/api/v1/attachments/%s"}}
           ]
         }|}
         sample_att_id sample_att_id sample_att_id sample_att_id sample_att_id)
  in
  match Wire_chat_journal.decode_page ~operation_id:"op-1" json with
  | Error err -> fail ("decode_page failed: " ^ err)
  | Ok page ->
      check int "4 journal events" 4 (List.length page.events);
      (match List.nth page.events 0 with
      | Wire_chat_journal.Attachment_emitted att ->
          check string "attachment_emitted id" sample_att_id att.attachment_id
      | _ -> fail "expected Attachment_emitted");
      (match List.nth page.events 1 with
      | Wire_chat_journal.Media_delta { mime_type; _ } ->
          check (option string) "agent_core_media_delta mime"
            (Some "image/jpeg") mime_type
      | _ -> fail "expected Media_delta");
      (match List.nth page.events 2 with
      | Wire_chat_journal.Image_block { mime_type; caption; _ } ->
          check (option string) "image_block mime" (Some "image/webp")
            mime_type;
          check (option string) "image_block caption" (Some "gen") caption
      | _ -> fail "expected Image_block");
      (match List.nth page.events 3 with
      | Wire_chat_journal.Audio_block { mime_type; _ } ->
          check (option string) "audio_block mime" (Some "audio/mpeg")
            mime_type
      | _ -> fail "expected Audio_block")

(* --- 4. Wire_knowledge: Board attachments decode & create payload --- *)

let test_wire_knowledge_board_attachments () =
  let json =
    Yojson.Safe.from_string
      (Printf.sprintf
         {|{
           "id": "post-img",
           "title": "Design Review",
           "body": "Attached mockup",
           "author": "alice",
           "created_at": 1795252000.0,
           "votes": 3,
           "comment_count": 1,
           "attachments": [
             {"attachment_id": "%s", "url": "/api/v1/attachments/%s", "mime_type": "image/png", "kind": "image", "bytes": 4096, "width": 800, "height": 600, "filename": "mock.png"}
           ],
           "comments": [
             {
               "id": "c-1",
               "post_id": "post-img",
               "author": "bob",
               "body": "Updated crop",
               "created_at": 1795252100.0,
               "votes_up": 1,
               "votes_down": 0,
               "attachments": [
                 {"attachment_id": "%s", "url": "/api/v1/attachments/%s", "mime_type": "application/pdf", "kind": "document", "bytes": 8192, "filename": "spec.pdf"}
               ]
             }
           ]
         }|}
         sample_att_id sample_att_id sample_att_id sample_att_id)
  in
  (match Wire_knowledge.decode_board_thread ~observed_at:t0 json with
  | Error err -> fail ("decode_board_thread failed: " ^ err)
  | Ok (post, comments) ->
      check int "post has 1 attachment" 1 (List.length post.attachments);
      check string "post attachment mime" "image/png"
        (List.hd post.attachments).mime_type;
      check int "comment has 1 attachment" 1
        (List.length (List.hd comments).attachments);
      check string "comment attachment mime" "application/pdf"
        (List.hd (List.hd comments).attachments).mime_type);
  let create_json =
    Wire_knowledge.encode_board_create ~title:"T" ~body:"B"
      ~attachment_ids:[ sample_att_id ] ()
  in
  let open Yojson.Safe.Util in
  let ids = create_json |> member "attachment_ids" |> to_list |> List.map to_string in
  check (list string) "encode_board_create sends attachment_ids"
    [ sample_att_id ] ids

(* --- 5. Wire_runtime & Wire_config: media_failover purged, derived caps --- *)

let test_runtime_caps_and_media_failover_purge () =
  (match Wire_runtime.classify_routing_lane "media_failover" with
  | Wire_runtime.Route_named "media_failover" -> ()
  | _ -> fail "media_failover must no longer be classified as a special route");
  check bool "media_failover is no longer reserved" true
    (Wire_runtime.is_named_routing_lane "media_failover");
  let resolved_json =
    Yojson.Safe.from_string
      {|{
        "generated_at_iso": "2026-11-27T00:00:00Z",
        "source": "/api/v1/runtime/resolved",
        "config_path": ".masc/runtime.toml",
        "default_route": "primary",
        "lanes": [{"id": "primary", "declared": true, "runtime_ids": ["claude.sonnet", "gemini.img"]}],
        "runtimes": [
          {"id": "claude.sonnet", "provider_id": "anthropic", "provider": "anthropic", "model": "claude-sonnet-4-6", "is_default": true, "supports_image_input": true, "supports_image_output": false},
          {"id": "gemini.img", "provider_id": "gemini", "provider": "gemini", "model": "gemini-3-pro-image", "vision_input": true, "image_output": true}
        ],
        "media": {"vision_reader": "claude.sonnet", "image_generator": "gemini.img"}
      }|}
  in
  match Wire_runtime.decode_runtime_resolved resolved_json with
  | Error err -> fail ("decode_runtime_resolved failed: " ^ err)
  | Ok snap ->
      check int "2 runtimes decoded" 2 (List.length snap.runtimes);
      let r0 = List.nth snap.runtimes 0 in
      let r1 = List.nth snap.runtimes 1 in
      check (option bool) "r0 supports_image_input" (Some true)
        r0.supports_image_input;
      check (option bool) "r0 supports_image_output" (Some false)
        r0.supports_image_output;
      check (option bool) "r1 vision_input alias" (Some true)
        r1.supports_image_input;
      check (option bool) "r1 image_output alias" (Some true)
        r1.supports_image_output;
      (match snap.media with
      | Some m ->
          check (option string) "media.vision_reader" (Some "claude.sonnet")
            m.vision_reader;
          check (option string) "media.image_generator" (Some "gemini.img")
            m.image_generator
      | None -> fail "expected [runtime.media] overrides decoded")

(* --- 6. Png_decode & Halfblock renderer --- *)

let test_png_decode_and_halfblock () =
  let png = make_test_png_2x2 () in
  check (option (pair int int)) "PNG dimensions 2x2" (Some (2, 2))
    (Png_decode.image_dimensions png);
  (* GIF89a minimal header: 320x240 LE *)
  let gif_hdr = "GIF89a\064\001\240\000" in
  check (option (pair int int)) "GIF dimensions 320x240" (Some (320, 240))
    (Png_decode.image_dimensions gif_hdr);
  (* JPEG minimal SOF0: height=480 (0x01E0), width=640 (0x0280) *)
  let jpeg_hdr =
    "\255\216\255\192\000\011\008\001\224\002\128\001\001\017\000"
  in
  check (option (pair int int)) "JPEG SOF0 dimensions 640x480" (Some (640, 480))
    (Png_decode.image_dimensions jpeg_hdr);
  match Png_decode.decode_rgba png with
  | Error err -> fail ("Png_decode.decode_rgba failed: " ^ err)
  | Ok img ->
      check int "decoded width" 2 img.width;
      check int "decoded height" 2 img.height;
      check int "decoded rgba bytes" 16 (Bytes.length img.rgba);
      let grid = Cell_grid.create ~cols:4 ~rows:2 in
      Halfblock.draw_rgba grid ~rect:(Rect.make ~x:0 ~y:0 ~w:2 ~h:1)
        ~bg_rgb:0x000000 img;
      let c0 = Cell_grid.get grid ~x:0 ~y:0 in
      let c1 = Cell_grid.get grid ~x:1 ~y:0 in
      check bool "cell (0,0) uses upper half-block ▀" true
        (match c0.glyph with
        | Cell_grid.Utf8 s -> String.equal s Halfblock.upper_half_block
        | _ -> false);
      check bool "cell (0,0) fg is red (top-left pixel)" true
        (Color.equal c0.style.fg (Color.rgb ~r:255 ~g:0 ~b:0));
      check bool "cell (0,0) bg is blue (bottom-left pixel)" true
        (Color.equal c0.style.bg (Color.rgb ~r:0 ~g:0 ~b:255));
      check bool "cell (1,0) fg is green (top-right pixel)" true
        (Color.equal c1.style.fg (Color.rgb ~r:0 ~g:255 ~b:0));
      check bool "cell (1,0) bg is white (bottom-right pixel)" true
        (Color.equal c1.style.bg (Color.rgb ~r:255 ~g:255 ~b:255))

(* --- 7. Multi-protocol Document_graphics (Kitty / iTerm2 / Halfblock) --- *)

let test_document_graphics_all_protocols () =
  let png = make_test_png_2x2 () in
  let jpg_path = "/api/v1/attachments/" ^ sample_att_id in
  let make_grid () =
    let g = Cell_grid.create ~cols:20 ~rows:4 in
    let rows =
      {
        Cell_grid.source =
          Cell_grid.Retained_image
            { path = jpg_path; mime_type = Some "image/jpeg" };
        count = 2;
      }
    in
    for i = 0 to 1 do
      Cell_grid.register_document_image_part g
        ~rect:(Rect.make ~x:0 ~y:i ~w:20 ~h:1)
        { Cell_grid.rows; index = i; left_inset = 0 }
    done;
    g
  in
  let endpoint =
    Masc_tui_net.Http_client.make_endpoint ~host:"localhost" ~port:1 ()
  in
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  (* 7a. Kitty requests ?format=png for JPEG attachment and emits APC f=100 *)
  let kitty_doc = Document_graphics.create () in
  let kitty_paths = ref [] in
  let kitty_probe =
    { Probe.empty_observation with graphics = Some Probe.Graphics_supported }
  in
  let g_kitty = make_grid () in
  let ready_k, sig_k = Eio.Promise.create () in
  ignore
    (Document_graphics.prepare kitty_doc ~sw ~now:t0 ~base_path:"" ~endpoint
       ~fetch_retained:(fun _ ~path ~max_body_bytes:_ ->
         kitty_paths := path :: !kitty_paths;
         Ok png)
       ~on_ready:(fun () -> Eio.Promise.resolve sig_k ())
       ~probe:kitty_probe ~theme:Theme.default g_kitty);
  Eio.Time.with_timeout_exn env#clock 1.0 (fun () -> Eio.Promise.await ready_k);
  check (list string) "Kitty rewrites JPEG attachment to ?format=png"
    [ jpg_path ^ "?format=png" ] !kitty_paths;
  let kitty_pl =
    Document_graphics.prepare kitty_doc ~sw ~now:t0 ~base_path:"" ~endpoint
      ~fetch_retained:(fun _ ~path:_ ~max_body_bytes:_ -> Ok png)
      ~on_ready:(fun () -> ())
      ~probe:kitty_probe ~theme:Theme.default g_kitty
  in
  let kitty_out =
    Document_graphics.after_present kitty_doc ~in_tmux:false ~full_repaint:true
      kitty_pl
  in
  check bool "Kitty emits APC f=100 sequence" true
    (contains_sub ~needle:"\x1b_Gf=100" ~haystack:kitty_out);

  (* 7a-2. Kitty requests ?format=png when mime_type=None on both /attachments/ and /media/ *)
  let media_path = "/api/v1/media/" ^ String.make 64 'd' in
  let unknown_doc = Document_graphics.create () in
  let unknown_paths = ref [] in
  let g_unknown = Cell_grid.create ~cols:20 ~rows:4 in
  List.iteri
    (fun idx p ->
      let rows =
        {
          Cell_grid.source = Cell_grid.Retained_image { path = p; mime_type = None };
          count = 1;
        }
      in
      Cell_grid.register_document_image_part g_unknown
        ~rect:(Rect.make ~x:0 ~y:idx ~w:20 ~h:1)
        { Cell_grid.rows; index = 0; left_inset = 0 })
    [ jpg_path; media_path ];
  let await_unknown () =
    let ready_u, sig_u = Eio.Promise.create () in
    ignore
      (Document_graphics.prepare unknown_doc ~sw ~now:t0 ~base_path:"" ~endpoint
         ~fetch_retained:(fun _ ~path ~max_body_bytes:_ ->
           unknown_paths := path :: !unknown_paths;
           Ok png)
         ~on_ready:(fun () -> Eio.Promise.resolve sig_u ())
         ~probe:kitty_probe ~theme:Theme.default g_unknown);
    Eio.Time.with_timeout_exn env#clock 1.0 (fun () -> Eio.Promise.await ready_u)
  in
  await_unknown ();
  await_unknown ();
  check (list string)
    "Kitty rewrites mime_type=None to ?format=png for both /attachments/ and /media/"
    [ jpg_path ^ "?format=png"; media_path ^ "?format=png" ]
    (List.rev !unknown_paths);

  (* 7b. iTerm2 uses Graphics.iterm2_place with native bytes *)
  let it2_doc = Document_graphics.create () in
  let it2_paths = ref [] in
  let g_it2 = make_grid () in
  let ready_i, sig_i = Eio.Promise.create () in
  ignore
    (Document_graphics.prepare it2_doc ~sw ~now:t0 ~base_path:"" ~endpoint
       ~fetch_retained:(fun _ ~path ~max_body_bytes:_ ->
         it2_paths := path :: !it2_paths;
         Ok png)
       ~on_ready:(fun () -> Eio.Promise.resolve sig_i ())
       ~term_program:(Some "iTerm.app") ~in_tmux:false
       ~probe:Probe.empty_observation ~theme:Theme.default g_it2);
  Eio.Time.with_timeout_exn env#clock 1.0 (fun () -> Eio.Promise.await ready_i);
  check (list string) "iTerm2 fetches original attachment path" [ jpg_path ]
    !it2_paths;
  let it2_pl =
    Document_graphics.prepare it2_doc ~sw ~now:t0 ~base_path:"" ~endpoint
      ~fetch_retained:(fun _ ~path:_ ~max_body_bytes:_ -> Ok png)
      ~on_ready:(fun () -> ())
      ~term_program:(Some "iTerm.app") ~in_tmux:false
      ~probe:Probe.empty_observation ~theme:Theme.default g_it2
  in
  let it2_out =
    Document_graphics.after_present it2_doc ~in_tmux:false ~full_repaint:true
      it2_pl
  in
  check bool "iTerm2 emits OSC 1337 inline image" true
    (contains_sub ~needle:"\x1b]1337;File=inline=1;" ~haystack:it2_out);

  (* 7c. Standard/non-graphics terminal requests ?format=png&max_px=160 and paints half-blocks *)
  let hb_doc = Document_graphics.create () in
  let hb_paths = ref [] in
  let g_hb = make_grid () in
  let ready_h, sig_h = Eio.Promise.create () in
  ignore
    (Document_graphics.prepare hb_doc ~sw ~now:t0 ~base_path:"" ~endpoint
       ~fetch_retained:(fun _ ~path ~max_body_bytes:_ ->
         hb_paths := path :: !hb_paths;
         Ok png)
       ~on_ready:(fun () -> Eio.Promise.resolve sig_h ())
       ~term_program:None ~in_tmux:true ~probe:Probe.empty_observation
       ~theme:Theme.default g_hb);
  Eio.Time.with_timeout_exn env#clock 1.0 (fun () -> Eio.Promise.await ready_h);
  check (list string) "Halfblock requests ?format=png&max_px=160"
    [ jpg_path ^ "?format=png&max_px=160" ] !hb_paths;
  let hb_pl =
    Document_graphics.prepare hb_doc ~sw ~now:t0 ~base_path:"" ~endpoint
      ~fetch_retained:(fun _ ~path:_ ~max_body_bytes:_ -> Ok png)
      ~on_ready:(fun () -> ())
      ~term_program:None ~in_tmux:true ~probe:Probe.empty_observation
      ~theme:Theme.default g_hb
  in
  List.iter
    (Document_graphics.mask_fallback ~bg_rgb:0x000000 g_hb
       ~style:(Style.make ()))
    hb_pl;
  let saw_halfblock = ref false in
  for y = 0 to 1 do
    for x = 0 to 19 do
      match (Cell_grid.get g_hb ~x ~y).glyph with
      | Cell_grid.Utf8 s when String.equal s Halfblock.upper_half_block ->
          saw_halfblock := true
      | _ -> ()
    done
  done;
  check bool "Halfblock fallback painted ▀ pixels directly onto Cell_grid" true
    !saw_halfblock

(* --- 8. Bidirectional Compose, Paste, Ctrl+V, Live SSE & Image Inspector --- *)

let test_compose_paste_and_inspector_flow () =
  let png = make_test_png_2x2 () in
  let m0 =
    Model.initial ~auth_session:Rbac.single_user_local_admin ~lang:Say.Lang_en
      ~cols:120 ~rows:36 ()
  in
  let keeper = "alpha" in
  let m1 =
    {
      m0 with
      nav = { m0.nav with workspace = Nav.Keepers };
      drafts = Drafts.set_active_keeper keeper m0.drafts;
    }
  in
  (* 8a. Slash commands /attach, /detach, /paste-image *)
  check bool "Slash.parse /attach" true
    (Slash.parse "/attach /tmp/foo.png" = Ok (Slash.Attach "/tmp/foo.png"));
  check bool "Slash.parse /detach" true
    (Slash.parse "/detach" = Ok (Slash.Detach `Last));
  check bool "Slash.parse /detach all" true
    (Slash.parse "/detach all" = Ok (Slash.Detach `All));
  check bool "Slash.parse /paste-image" true
    (Slash.parse "/paste-image" = Ok Slash.Paste_image);
  check bool "Slash.parse /paste-img alias" true
    (Slash.parse "/paste-img" = Ok Slash.Paste_image);

  (* 8b. Smart apply_paste auto-attaches local PNG instead of inserting path text *)
  with_temp_file ~suffix:".png" ~contents:png (fun path ->
      let m_pasted, paste_cmds =
        Update.step ~now:t0 m1 (Msg.Paste_text ("'" ^ path ^ "'"))
      in
      check string "composer text stays empty on image path paste" ""
        (Drafts.current_draft m_pasted.drafts).text;
      check int "uploading_count incremented" 1
        (Drafts.current_draft m_pasted.drafts).uploading_count;
      check bool "emits Upload_attachment_file" true
        (List.exists
           (function
             | Cmd.Upload_attachment_file
                 { target = Cmd.Upload_for_keeper k; path = p; _ } ->
                 String.equal k keeper && String.equal p path
             | _ -> false)
           (Cmd.flatten paste_cmds));
      (* Complete upload -> chip appears *)
      let m_att, _ =
        Update.step ~now:t0 m_pasted
          (Msg.Attachment_uploaded
             {
               epoch = m_pasted.epoch;
               target = Cmd.Upload_for_keeper keeper;
               filename = Some "screenshot.png";
               result = Ok sample_attachment;
             })
      in
      check int "uploading_count returns to 0" 0
        (Drafts.current_draft m_att.drafts).uploading_count;
      check int "1 draft attachment chip ready" 1
        (List.length (Drafts.current_draft m_att.drafts).attachments);
      (* Attachment-only submit succeeds and sends attachment ref *)
      let m_sent, submit_cmds =
        Update.step ~now:t0 m_att (Msg.Key_event (mk_key Keymap.Input.Enter))
      in
      check int "draft attachments cleared on submit" 0
        (List.length (Drafts.current_draft m_sent.drafts).attachments);
      check bool "Http_post_stream carries attachment ref" true
        (List.exists
           (function
             | Cmd.Http_post_stream
                 {
                   req =
                     Cmd.Stream_keeper_chat
                       { request = { attachments = [ a ]; _ }; _ };
                   _;
                 } ->
                 String.equal a.attachment_id sample_att_id
             | _ -> false)
           (Cmd.flatten submit_cmds));
      (* Ctrl+V in focused composer emits Paste_clipboard_image *)
      let m_foc = { m1 with drafts = Drafts.set_focus true m1.drafts } in
      let _, cv_cmds =
        Update.step ~now:t0 m_foc (Msg.Key_event (char_key ~ctrl:true "v"))
      in
      check bool "Ctrl+V triggers Paste_clipboard_image" true
        (List.exists
           (function
             | Cmd.Paste_clipboard_image { target = Cmd.Upload_for_keeper k; _ } ->
                 String.equal k keeper
             | _ -> false)
           (Cmd.flatten cv_cmds));
      (* Backspace on empty text pops last attachment chip *)
      let m_pop, _ =
        Update.step ~now:t0
          { m_att with drafts = Drafts.set_focus true m_att.drafts }
          (Msg.Key_event (mk_key Keymap.Input.Backspace))
      in
      check int "Backspace on empty draft pops attachment" 0
        (List.length (Drafts.current_draft m_pop.drafts).attachments));

  (* 8c. Live SSE Chunk_attachment accumulates & Image Inspector opens via [M] *)
  let m_streaming =
    {
      m1 with
      fleet = Fleet_store.start_chat_stream ~keeper ~request_id:"req-1" m1.fleet;
    }
  in
  let m_sse, _ =
    Update.step ~now:t0 m_streaming
      (Msg.Chat_stream_chunk
         {
           epoch = m_streaming.epoch;
           keeper;
           request_id = "req-1";
           is_btw = false;
           seq = Some 1;
           chunk =
             Wire_fleet.Chunk_attachment
               {
                 operation_id = None;
                 attachment = sample_attachment;
                 block_index = Some 0;
                 tool_call_id = None;
                 role = Some "assistant";
               };
         })
  in
  let collected = Chat_transcript.collect_chat_images ~model:m_sse ~keeper in
  check int "collect_chat_images finds live streamed attachment" 1
    (List.length collected);
  let m_insp, insp_cmds =
    Update.step ~now:t0 m_sse (Msg.Key_event (char_key "M"))
  in
  check bool "[M] opens Nav.Media_viewer with image_inspector" true
    (Option.equal Nav.equal_overlay m_insp.nav.overlay
       (Some (Nav.System_gate Nav.Media_viewer))
    && Option.is_some m_insp.image_inspector);
  check bool "[M] triggers Fetch_inspector_image with format_png=true" true
    (List.exists
       (function
         | Cmd.Fetch_inspector_image { url; format_png = true; _ } ->
             String.equal url sample_attachment.url
         | _ -> false)
       (Cmd.flatten insp_cmds));
  (* Deliver PNG bytes -> zoom, pan, copy, export, render half-block, close *)
  let m_loaded, _ =
    Update.step ~now:t0 m_insp
      (Msg.Inspector_image_fetched
         {
           epoch = m_insp.epoch;
           url = sample_attachment.url;
           result = Ok (png, Some (2, 2), None);
         })
  in
  let m_zoomed, _ = Update.step ~now:t0 m_loaded (Msg.Key_event (char_key "+")) in
  let st_z = Option.get m_zoomed.image_inspector in
  check bool "[+] zooms in past 1.0" true (st_z.zoom > 1.0);
  let m_panned, _ = Update.step ~now:t0 m_zoomed (Msg.Key_event (char_key "l")) in
  let st_p = Option.get m_panned.image_inspector in
  check bool "[l] pans right" true (st_p.pan_x > 0.5);
  let _, copy_cmds = Update.step ~now:t0 m_panned (Msg.Key_event (char_key "y")) in
  check bool "[y] copies attachment_id" true
    (List.exists
       (function Cmd.Copy_clipboard s -> String.equal s sample_att_id | _ -> false)
       (Cmd.flatten copy_cmds));
  let _, exp_cmds = Update.step ~now:t0 m_panned (Msg.Key_event (char_key "e")) in
  check bool "[e] exports attachment (open_after=false)" true
    (List.exists
       (function
         | Cmd.Export_attachment { url; open_after = false; _ } ->
             String.equal url sample_attachment.url
         | _ -> false)
       (Cmd.flatten exp_cmds));
  let _, open_cmds = Update.step ~now:t0 m_panned (Msg.Key_event (char_key "o")) in
  check bool "[o] opens attachment externally (open_after=true)" true
    (List.exists
       (function
         | Cmd.Export_attachment { url; open_after = true; _ } ->
             String.equal url sample_attachment.url
         | _ -> false)
       (Cmd.flatten open_cmds));
  (* Render overlay onto Cell_grid and verify Inspector title + ▀ half-block *)
  let grid = Cell_grid.create ~cols:120 ~rows:36 in
  let cache = Card.Cache.create () in
  Overlays.render ~model:m_loaded ~cache ~rect:(Rect.make ~x:0 ~y:1 ~w:120 ~h:34)
    grid;
  let txt = grid_all_text grid in
  check bool "Inspector overlay renders title & zoom %" true
    (contains_sub ~needle:"Image Inspector" ~haystack:txt
    && contains_sub ~needle:"100%" ~haystack:txt);
  check bool "Inspector overlay renders half-block ▀ preview" true
    (contains_sub ~needle:Halfblock.upper_half_block ~haystack:txt);
  let m_closed, _ = Update.step ~now:t0 m_panned (Msg.Key_event (char_key "q")) in
  check bool "[q] closes inspector and clears image_inspector" true
    (Option.is_none m_closed.nav.overlay && Option.is_none m_closed.image_inspector)

(* --- 9. UI Rendering: [Vision]/[Image Gen] badges & Board attachments --- *)

let test_ui_capability_badges_and_board_attachments () =
  let m0 =
    Model.initial ~auth_session:Rbac.single_user_local_admin ~cols:140 ~rows:40
      ~lang:Say.Lang_en ()
  in
  let snap : Wire_runtime.runtime_resolved_snapshot =
    {
      generated_at_iso = "2026-11-27T00:00:00Z";
      config_path = Some ".masc/runtime.toml";
      default_route = Some "primary";
      lanes =
        [
          {
            id = "primary";
            declared = true;
            runtime_ids = [ "claude.sonnet"; "gemini.img" ];
          };
        ];
      runtimes =
        [
          {
            id = "claude.sonnet";
            provider_id = "anthropic";
            provider = "anthropic";
            model = Some "claude-sonnet-4-6";
            declared_reasoning_effort = None;
            transport = Some "http";
            is_default = true;
            supports_image_input = Some true;
            supports_image_output = Some false;
          };
          {
            id = "gemini.img";
            provider_id = "gemini";
            provider = "gemini";
            model = Some "gemini-3-pro-image";
            declared_reasoning_effort = None;
            transport = Some "http";
            is_default = false;
            supports_image_input = Some true;
            supports_image_output = Some true;
          };
        ];
      usage_windows = None;
      media =
        Some
          {
            vision_reader = Some "claude.sonnet";
            image_generator = Some "gemini.img";
          };
    }
  in
  let m_rt =
    {
      m0 with
      nav = { m0.nav with workspace = Nav.Runtime };
      runtime =
        m0.runtime
        |> Runtime_store.set_tab Nav.Runtime_failover_lanes
        |> Runtime_store.apply_runtime_resolved ~observed_at:t0 snap;
    }
  in
  let grid_rt = Cell_grid.create ~cols:140 ~rows:36 in
  Screen_runtime.render ~model:m_rt ~cache:(Card.Cache.create ())
    ~rect:(Rect.make ~x:0 ~y:0 ~w:140 ~h:36) grid_rt;
  let rt_txt = grid_all_text grid_rt in
  check bool "Runtime lanes render [Vision] badge" true
    (contains_sub ~needle:"[Vision]" ~haystack:rt_txt);
  check bool "Runtime lanes render [Image Gen] badge" true
    (contains_sub ~needle:"[Image Gen]" ~haystack:rt_txt);
  check bool "Runtime lanes render [runtime.media] override pill" true
    (contains_sub ~needle:"Vision:claude.sonnet" ~haystack:rt_txt);

  (* Board preview renders raster attachment image placement & Inspect hint *)
  let post : Wire_knowledge.board_post =
    {
      id = "p-att";
      title = "Visual Report";
      body = "See screenshot below.";
      author = "alpha";
      hearth = Some "design";
      created_at_unix = 1795252000.0;
      updated_at_unix = None;
      score = 5;
      comment_count = 0;
      author_karma = Observed.value ~observed_at:t0 10;
      visibility = None;
      post_kind = None;
      succession_chain_root_id = None;
      chain_depth = None;
      is_signal = true;
      pinned = false;
      attachments = [ sample_attachment ];
    }
  in
  let m_board =
    {
      m0 with
      nav = { m0.nav with workspace = Nav.Knowledge };
      knowledge =
        m0.knowledge
        |> Knowledge_store.set_tab Nav.Knowledge_board
        |> Knowledge_store.apply_board ~observed_at:t0
             {
               Wire_knowledge.posts = [ post ];
               count = 1;
               sort_by = "recent";
               signal_only = false;
             };
    }
  in
  let grid_b = Cell_grid.create ~cols:140 ~rows:36 in
  Screen_knowledge.render ~model:m_board ~cache:(Card.Cache.create ())
    ~rect:(Rect.make ~x:0 ~y:0 ~w:140 ~h:36) grid_b;
  let placements = Cell_grid.document_placements grid_b in
  check int "Board preview registers 1 inline Retained_image placement" 1
    (List.length placements);
  let b_txt = grid_all_text grid_b in
  check bool "Board preview renders [M] Inspect caption" true
    (contains_sub ~needle:"[M] Inspect" ~haystack:b_txt)

(* --- 10. P1: Slash commands & @mention preserve/route draft attachments --- *)

let make_att suffix name : Wire_attachment.t =
  let id = "att_" ^ String.make 64 suffix in
  {
    sample_attachment with
    id;
    attachment_id = id;
    sha256 = Some (String.make 64 suffix);
    url = "/api/v1/attachments/" ^ id;
    filename = Some name;
  }

let fleet_with_alpha_and_beta () =
  let mk_keeper name =
    Printf.sprintf
      {|{"name": "%s", "health": "healthy", "paused": false, "keepalive_running": true, "activation_mode": "autonomous", "runtime_id": "claude.sonnet"}|}
      name
  in
  let json =
    Yojson.Safe.from_string
      (Printf.sprintf {|{"keepers": [%s, %s]}|} (mk_keeper "alpha")
         (mk_keeper "beta"))
  in
  match Wire_fleet.decode_keepers_roster ~observed_at:t0 json with
  | Error err -> fail ("decode_keepers_roster failed: " ^ err)
  | Ok roster -> Fleet_store.apply_keepers ~observed_at:t0 roster.keepers Fleet_store.empty

let type_and_enter (m : Model.t) text =
  let m0 = { m with drafts = Drafts.set_focus true m.drafts } in
  let m_typed, _ = Update.step ~now:t0 m0 (Msg.Paste_text text) in
  Update.step ~now:t0 m_typed (Msg.Key_event (mk_key Keymap.Input.Enter))

let test_slash_and_mention_preserve_attachments () =
  let att1 = make_att '1' "first.png" in
  let att2 = make_att '2' "second.png" in
  let att_beta = make_att 'b' "beta-wip.png" in
  let m0 =
    let base =
      Model.initial ~auth_session:Rbac.single_user_local_admin ~lang:Say.Lang_en
        ~cols:120 ~rows:36 ()
    in
    {
      base with
      nav = { base.nav with workspace = Nav.Keepers };
      fleet = fleet_with_alpha_and_beta ();
      drafts = Drafts.set_active_keeper "alpha" base.drafts;
    }
  in
  (* (a) /attach a.png -> upload -> /attach b.png -> upload keeps BOTH *)
  let m_u1, cmds_u1 = type_and_enter m0 "/attach /tmp/first.png" in
  check bool "/attach a.png emits Upload_attachment_file" true
    (List.exists
       (function
         | Cmd.Upload_attachment_file
             { target = Cmd.Upload_for_keeper "alpha"; path = "/tmp/first.png"; _ }
           -> true
         | _ -> false)
       (Cmd.flatten cmds_u1));
  let m_a1, _ =
    Update.step ~now:t0 m_u1
      (Msg.Attachment_uploaded
         {
           epoch = m_u1.epoch;
           target = Cmd.Upload_for_keeper "alpha";
           filename = Some "first.png";
           result = Ok att1;
         })
  in
  let m_u2, _ = type_and_enter m_a1 "/attach /tmp/second.png" in
  check int "/attach b.png preserves att1 before upload finishes" 1
    (List.length (Drafts.current_draft m_u2.drafts).attachments);
  let m_both, _ =
    Update.step ~now:t0 m_u2
      (Msg.Attachment_uploaded
         {
           epoch = m_u2.epoch;
           target = Cmd.Upload_for_keeper "alpha";
           filename = Some "second.png";
           result = Ok att2;
         })
  in
  check (list string) "both att1 and att2 present after sequential /attach"
    [ att1.attachment_id; att2.attachment_id ]
    (List.map
       (fun (a : Wire_attachment.t) -> a.attachment_id)
       (Drafts.current_draft m_both.drafts).attachments);

  (* (b) /help preserves draft attachments *)
  let m_help, _ = type_and_enter m_both "/help" in
  check bool "/help opens Help overlay" true
    (Option.equal Nav.equal_overlay m_help.nav.overlay (Some Nav.Help));
  check (list string) "/help preserves both draft attachments"
    [ att1.attachment_id; att2.attachment_id ]
    (List.map
       (fun (a : Wire_attachment.t) -> a.attachment_id)
       (Drafts.draft_for ~keeper:"alpha" m_help.drafts).attachments);
  let m_after_help, _ =
    Update.step ~now:t0 m_help (Msg.Key_event (mk_key Keymap.Input.Escape))
  in

  (* (c) Esc on bare '/' preserves draft attachments *)
  let m_slash_peek, _ =
    Update.step ~now:t0
      { m_after_help with drafts = Drafts.set_focus true m_after_help.drafts }
      (Msg.Key_event (char_key "/"))
  in
  let m_esc_slash, _ =
    Update.step ~now:t0 m_slash_peek (Msg.Key_event (mk_key Keymap.Input.Escape))
  in
  check string "Esc on bare '/' clears slash text" ""
    (Drafts.current_draft m_esc_slash.drafts).text;
  check int "Esc on bare '/' preserves both attachments" 2
    (List.length (Drafts.current_draft m_esc_slash.drafts).attachments);

  (* (d) /detach 2 removes ONLY second image, leaving image 1 *)
  let m_det2, _ = type_and_enter m_esc_slash "/detach 2" in
  check (list string) "/detach 2 leaves att1 intact" [ att1.attachment_id ]
    (List.map
       (fun (a : Wire_attachment.t) -> a.attachment_id)
       (Drafts.current_draft m_det2.drafts).attachments);

  (* (e) Bare @beta switch and mention popup completion preserve alpha's attachments *)
  let m_bare_switch, _ = type_and_enter m_det2 "@beta" in
  check (option string) "bare @beta switches active keeper" (Some "beta")
    m_bare_switch.drafts.active_keeper;
  check (list string) "bare @beta preserves alpha's att1" [ att1.attachment_id ]
    (List.map
       (fun (a : Wire_attachment.t) -> a.attachment_id)
       (Drafts.draft_for ~keeper:"alpha" m_bare_switch.drafts).attachments);
  let m_pop_src =
    {
      m_det2 with
      drafts =
        m_det2.drafts
        |> Drafts.set_focus true
        |> Drafts.set_current_text "@be";
    }
  in
  let m_pop_done, _ =
    Update.step ~now:t0 m_pop_src (Msg.Key_event (mk_key Keymap.Input.Tab))
  in
  check (option string) "mention popup Tab completion switches active keeper"
    (Some "beta") m_pop_done.drafts.active_keeper;
  check (list string) "mention popup Tab completion preserves alpha's att1"
    [ att1.attachment_id ]
    (List.map
       (fun (a : Wire_attachment.t) -> a.attachment_id)
       (Drafts.draft_for ~keeper:"alpha" m_pop_done.drafts).attachments);

  (* (f) @beta look sends alpha's att1 to beta AND preserves beta's existing unsent draft *)
  let m_with_beta_wip =
    let d_beta =
      m_det2.drafts
      |> Drafts.set_keeper_draft_slot ~keeper:"beta" ~text:"beta wip" ~cursor:8
           ~attachments:[ att_beta ] ~uploading_count:0
    in
    { m_det2 with drafts = d_beta }
  in
  let m_mention_sent, mention_cmds = type_and_enter m_with_beta_wip "@beta look" in
  check bool "@beta look sends alpha's att1 to beta (not beta's att_beta)" true
    (List.exists
       (function
         | Cmd.Http_post_stream
             {
               req =
                 Cmd.Stream_keeper_chat
                   {
                     request =
                       {
                         keeper_name = "beta";
                         message = "look";
                         attachments = [ a ];
                         _;
                       };
                     _;
                   };
               _;
             } ->
             String.equal a.attachment_id att1.attachment_id
         | _ -> false)
       (Cmd.flatten mention_cmds));
  check int "alpha's attachments cleared after @beta look send" 0
    (List.length (Drafts.draft_for ~keeper:"alpha" m_mention_sent.drafts).attachments);
  let beta_after = Drafts.draft_for ~keeper:"beta" m_mention_sent.drafts in
  check string "beta's prior unsent draft text restored" "beta wip" beta_after.text;
  check (list string) "beta's prior unsent draft attachment restored"
    [ att_beta.attachment_id ]
    (List.map (fun (a : Wire_attachment.t) -> a.attachment_id) beta_after.attachments);

  (* (g) /clear clears both text and attachments *)
  let m_cleared, _ = type_and_enter m_det2 "/clear" in
  check int "/clear removes draft attachments" 0
    (List.length (Drafts.current_draft m_cleared.drafts).attachments)

(* --- 11. P2-1 & P2-2: Block submit while uploading + preserve board attachments on failure --- *)

let test_upload_in_flight_blocks_send_and_board_retry () =
  let png = make_test_png_2x2 () in
  let m0 =
    let base =
      Model.initial ~auth_session:Rbac.single_user_local_admin ~lang:Say.Lang_en
        ~cols:120 ~rows:36 ()
    in
    {
      base with
      nav = { base.nav with workspace = Nav.Keepers };
      fleet = fleet_with_alpha_and_beta ();
      drafts = Drafts.set_active_keeper "alpha" base.drafts;
    }
  in
  (* Keeper chat: in-flight upload blocks both enqueue_submission and Enter *)
  let d_up =
    m0.drafts
    |> Drafts.inc_uploading ~keeper:"alpha"
    |> Drafts.set_current_text "hello"
  in
  check bool "Drafts.enqueue_submission returns None while uploading_count > 0"
    true
    (Option.is_none
       (Drafts.enqueue_submission ~now:t0 ~keeper:"alpha"
          ~mode:Drafts.Mode_follow_up d_up));
  let m_up = { m0 with drafts = Drafts.set_focus true d_up } in
  let m_blocked, blocked_cmds =
    Update.step ~now:t0 m_up (Msg.Key_event (mk_key Keymap.Input.Enter))
  in
  check int "chat submit blocked while uploading emits 0 cmds" 0
    (List.length (Cmd.flatten blocked_cmds));
  check string "chat draft text preserved when blocked" "hello"
    (Drafts.current_draft m_blocked.drafts).text;
  check bool "chat block displays waiting toast" true
    (match m_blocked.toast with
    | Some { message; _ } ->
        contains_sub ~needle:"Waiting for attachment upload"
          ~haystack:(Say.resolve Say.Lang_en message)
    | None -> false);
  (* Also block @mention send while source keeper is uploading *)
  let m_up_mention =
    {
      m0 with
      drafts =
        m0.drafts
        |> Drafts.inc_uploading ~keeper:"alpha"
        |> Drafts.set_current_text "@beta look"
        |> Drafts.set_focus true;
    }
  in
  let _, mention_blocked_cmds =
    Update.step ~now:t0 m_up_mention (Msg.Key_event (mk_key Keymap.Input.Enter))
  in
  check int "@mention submit blocked while uploading emits 0 cmds" 0
    (List.length (Cmd.flatten mention_blocked_cmds));

  (* Board_new_post: block submit while board_uploading_count > 0, keep attachments on failure, clear on Ok ack *)
  let m_modal0, _ = Update_nav.open_inline_modal m0 Nav.Board_new_post in
  let m_filled =
    match m_modal0.inline_modal with
    | None -> fail "Board_new_post modal did not open"
    | Some modal ->
        let fields =
          List.map
            (fun (f : Model.modal_form_field) ->
              if String.equal f.key "title" then
                { f with Model.value = "My Post" }
              else if String.equal f.key "body" then
                { f with Model.value = "Post body" }
              else f)
            modal.fields
        in
        { m_modal0 with inline_modal = Some { modal with fields } }
  in
  with_temp_file ~suffix:".png" ~contents:png (fun path ->
      let m_b_up, _ = Update.step ~now:t0 m_filled (Msg.Paste_text path) in
      check int "board_uploading_count incremented on paste" 1
        m_b_up.drafts.board_uploading_count;
      let m_b_blocked, b_blocked_cmds =
        Update_nav.submit_inline_modal ~now:t0 m_b_up
      in
      check int "Board_new_post blocked while board_uploading_count > 0" 0
        (List.length (Cmd.flatten b_blocked_cmds));
      check bool "Board_new_post keeps modal open with error notice" true
        (match m_b_blocked.inline_modal with
        | Some { submitting = false; error = Some err; _ } ->
            contains_sub ~needle:"Waiting for attachment upload" ~haystack:err
        | _ -> false);
      (* Complete board upload *)
      let m_b_ready, _ =
        Update.step ~now:t0 m_b_up
          (Msg.Attachment_uploaded
             {
               epoch = m_b_up.epoch;
               target = Cmd.Upload_for_board;
               filename = Some "shot.png";
               result = Ok sample_attachment;
             })
      in
      check int "board_uploading_count returns to 0" 0
        m_b_ready.drafts.board_uploading_count;
      check int "board_attachments has 1 chip" 1
        (List.length m_b_ready.drafts.board_attachments);
      (* Submit -> emits Post_board_create AND preserves board_attachments until ack *)
      let m_b_sub, b_sub_cmds =
        Update_nav.submit_inline_modal ~now:t0 m_b_ready
      in
      check bool "Board_new_post submits attachment_ids" true
        (List.exists
           (function
             | Cmd.Http_post
                 {
                   req =
                     Cmd.Post_board_create
                       { attachment_ids = [ id ]; title = "My Post"; _ };
                   _;
                 } ->
                 String.equal id sample_att_id
             | _ -> false)
           (Cmd.flatten b_sub_cmds));
      check int "board_attachments preserved while awaiting server ack" 1
        (List.length m_b_sub.drafts.board_attachments);
      (* Simulated server error -> modal stays open AND board_attachments preserved for retry *)
      let m_b_fail, _ =
        Update.step ~now:t0 m_b_sub
          (Msg.Http_reply
             {
               epoch = m_b_sub.epoch;
               reply =
                 Msg.Reply_action_ack
                   {
                     label = Say.make ~ko:"게시글 작성 완료" ~en:"Board post created";
                     ack_scope = Msg.Ack_close_modal_and_refresh;
                     for_modal = Some Nav.Board_new_post;
                     result =
                       Error
                         (Msg.Http_error
                            {
                              status = 500;
                              body = "internal error";
                              api_error = None;
                            });
                   };
             })
      in
      check bool "failed board submit keeps modal open for retry" true
        (match m_b_fail.inline_modal with
        | Some { kind = Nav.Board_new_post; submitting = false; _ } -> true
        | _ -> false);
      check (list string) "failed board submit preserves board_attachments"
        [ sample_att_id ]
        (List.map
           (fun (a : Wire_attachment.t) -> a.attachment_id)
           m_b_fail.drafts.board_attachments);
      (* Retry succeeds -> modal closes AND board_attachments cleared *)
      let m_b_retry, retry_cmds =
        Update_nav.submit_inline_modal ~now:t0 m_b_fail
      in
      check bool "retry emits Post_board_create with preserved attachment_ids"
        true
        (List.exists
           (function
             | Cmd.Http_post
                 { req = Cmd.Post_board_create { attachment_ids = [ id ]; _ }; _ }
               -> String.equal id sample_att_id
             | _ -> false)
           (Cmd.flatten retry_cmds));
      let m_b_ok, _ =
        Update.step ~now:t0 m_b_retry
          (Msg.Http_reply
             {
               epoch = m_b_retry.epoch;
               reply =
                 Msg.Reply_action_ack
                   {
                     label = Say.make ~ko:"게시글 작성 완료" ~en:"Board post created";
                     ack_scope = Msg.Ack_close_modal_and_refresh;
                     for_modal = Some Nav.Board_new_post;
                     result = Ok ();
                   };
             })
      in
      check bool "successful ack closes Board_new_post modal" true
        (Option.is_none m_b_ok.inline_modal);
      check int "successful ack clears board_attachments" 0
        (List.length m_b_ok.drafts.board_attachments))

(* --- 12. P2-3: Cached inspector RGBA decode & halfblock max_px=1280 fetch --- *)

let test_inspector_cached_decode_and_halfblock_max_px () =
  let url = sample_attachment.url in
  let kitty_probe =
    { Probe.empty_observation with graphics = Some Probe.Graphics_supported }
  in
  check string "Halfblock terminal requests ?format=png&max_px=1280"
    (url ^ "?format=png&max_px=1280")
    (Cmd_executor.inspector_fetch_path ~probe:Probe.empty_observation
       ~term_program:None ~in_tmux:false ~format_png:true url);
  check string "tmux without Kitty requests ?format=png&max_px=1280"
    (url ^ "?format=png&max_px=1280")
    (Cmd_executor.inspector_fetch_path ~probe:Probe.empty_observation
       ~term_program:(Some "iTerm.app") ~in_tmux:true ~format_png:true url);
  check string "Kitty terminal requests full-res ?format=png"
    (url ^ "?format=png")
    (Cmd_executor.inspector_fetch_path ~probe:kitty_probe
       ~term_program:None ~in_tmux:false ~format_png:true url);
  check string "iTerm2 direct requests full-res ?format=png"
    (url ^ "?format=png")
    (Cmd_executor.inspector_fetch_path ~probe:Probe.empty_observation
       ~term_program:(Some "iTerm.app") ~in_tmux:false ~format_png:true url);

  (* Prove Overlays.render uses cached decoded_rgba and never re-decodes png_bytes *)
  let cached_rgba : Png_decode.rgba_image =
    {
      width = 2;
      height = 2;
      rgba =
        Bytes.of_string
          ("\255\000\000\255" ^ "\000\255\000\255"
          ^ "\000\000\255\255" ^ "\255\255\255\255");
    }
  in
  let m0 =
    Model.initial ~auth_session:Rbac.single_user_local_admin ~lang:Say.Lang_en
      ~cols:120 ~rows:36 ()
  in
  let img = Wire_fleet.retained_image_of_attachment sample_attachment in
  let m1 = Model.open_image_inspector ~now:t0 ~images:[ img ] m0 in
  let m2, _ =
    Update_nav.open_overlay m1 (Nav.System_gate Nav.Media_viewer)
  in
  let m_cached, _ =
    Update.step ~now:t0 m2
      (Msg.Inspector_image_fetched
         {
           epoch = m2.epoch;
           url = img.media_path;
           result =
             Ok
               ( "corrupt-bytes-proving-render-never-calls-decode_rgba"
               , Some (2, 2)
               , Some (Ok cached_rgba) );
         })
  in
  let render_and_check label model =
    let grid = Cell_grid.create ~cols:120 ~rows:36 in
    Overlays.render ~model ~cache:(Card.Cache.create ())
      ~rect:(Rect.make ~x:0 ~y:1 ~w:120 ~h:34) grid;
    let txt = grid_all_text grid in
    check bool label true
      (contains_sub ~needle:Halfblock.upper_half_block ~haystack:txt)
  in
  render_and_check "100% frame renders from cached decoded_rgba" m_cached;
  let m_zoom, _ = Update.step ~now:t0 m_cached (Msg.Key_event (char_key "+")) in
  render_and_check "zoomed frame renders from cached decoded_rgba" m_zoom;
  let m_pan, _ = Update.step ~now:t0 m_zoom (Msg.Key_event (char_key "l")) in
  render_and_check "panned frame renders from cached decoded_rgba" m_pan

(* --- 13. P3: Early abort on inflate cap + 1/2/4-bit grayscale & indexed PNG --- *)

let png_crc32 s =
  let crc = ref 0xFFFFFFFFl in
  for i = 0 to String.length s - 1 do
    crc := Int32.logxor !crc (Int32.of_int (Char.code s.[i]));
    for _ = 0 to 7 do
      if Int32.logand !crc 1l <> 0l then
        crc := Int32.logxor (Int32.shift_right_logical !crc 1) 0xEDB88320l
      else crc := Int32.shift_right_logical !crc 1
    done
  done;
  Int32.logxor !crc 0xFFFFFFFFl

let add_be32 buf v =
  Buffer.add_char buf (Char.chr (Int32.to_int (Int32.logand (Int32.shift_right_logical v 24) 0xFFl)));
  Buffer.add_char buf (Char.chr (Int32.to_int (Int32.logand (Int32.shift_right_logical v 16) 0xFFl)));
  Buffer.add_char buf (Char.chr (Int32.to_int (Int32.logand (Int32.shift_right_logical v 8) 0xFFl)));
  Buffer.add_char buf (Char.chr (Int32.to_int (Int32.logand v 0xFFl)))

let make_png_chunk kind data =
  let buf = Buffer.create (12 + String.length data) in
  add_be32 buf (Int32.of_int (String.length data));
  Buffer.add_string buf kind;
  Buffer.add_string buf data;
  add_be32 buf (png_crc32 (kind ^ data));
  Buffer.contents buf

let zlib_stored_blocks raw =
  let len = String.length raw in
  let buf = Buffer.create (len + 64) in
  (* Zlib header: CMF=0x78 (deflate, 32K window), FLG=0x01 (check bits) *)
  Buffer.add_char buf '\x78';
  Buffer.add_char buf '\x01';
  let rec write_blocks off =
    let rem = len - off in
    let chunk = Int.min rem 65535 in
    let is_final = off + chunk >= len in
    Buffer.add_char buf (if is_final then '\x01' else '\x00');
    Buffer.add_char buf (Char.chr (chunk land 0xFF));
    Buffer.add_char buf (Char.chr ((chunk lsr 8) land 0xFF));
    let nlen = chunk lxor 0xFFFF in
    Buffer.add_char buf (Char.chr (nlen land 0xFF));
    Buffer.add_char buf (Char.chr ((nlen lsr 8) land 0xFF));
    Buffer.add_substring buf raw off chunk;
    if not is_final then write_blocks (off + chunk)
  in
  write_blocks 0;
  (* Adler-32 checksum *)
  let s1 = ref 1 in
  let s2 = ref 0 in
  for i = 0 to len - 1 do
    s1 := (!s1 + Char.code raw.[i]) mod 65521;
    s2 := (!s2 + !s1) mod 65521
  done;
  let adler = Int32.logor (Int32.shift_left (Int32.of_int !s2) 16) (Int32.of_int !s1) in
  add_be32 buf adler;
  Buffer.contents buf

let build_raw_png ~width ~height ~bit_depth ~color_type ?plte ?trns scanlines_raw =
  let ihdr = Buffer.create 13 in
  add_be32 ihdr (Int32.of_int width);
  add_be32 ihdr (Int32.of_int height);
  Buffer.add_char ihdr (Char.chr bit_depth);
  Buffer.add_char ihdr (Char.chr color_type);
  Buffer.add_char ihdr '\000';
  Buffer.add_char ihdr '\000';
  Buffer.add_char ihdr '\000';
  let out = Buffer.create 256 in
  Buffer.add_string out Rgb_png.signature;
  Buffer.add_string out (make_png_chunk "IHDR" (Buffer.contents ihdr));
  Option.iter (fun p -> Buffer.add_string out (make_png_chunk "PLTE" p)) plte;
  Option.iter (fun t -> Buffer.add_string out (make_png_chunk "tRNS" t)) trns;
  Buffer.add_string out (make_png_chunk "IDAT" (zlib_stored_blocks scanlines_raw));
  Buffer.add_string out (make_png_chunk "IEND" "");
  Buffer.contents out

let px_at (img : Png_decode.rgba_image) ~x ~y =
  let o = ((y * img.width) + x) * 4 in
  ( Char.code (Bytes.get img.rgba o)
  , Char.code (Bytes.get img.rgba (o + 1))
  , Char.code (Bytes.get img.rgba (o + 2))
  , Char.code (Bytes.get img.rgba (o + 3)) )

let test_png_decode_sub_byte_and_inflate_cap () =
  let rgba_t = testable (fun fmt (r, g, b, a) -> Format.fprintf fmt "(%d,%d,%d,%d)" r g b a) ( = ) in
  (* 13a. Oversized IDAT aborts immediately at inflate cap *)
  let oversized_png =
    build_raw_png ~width:1 ~height:1 ~bit_depth:8 ~color_type:6
      (String.make (256 * 1024) '\000')
  in
  (match Png_decode.decode_rgba oversized_png with
  | Error msg ->
      check bool "inflate cap rejects oversized IDAT" true
        (contains_sub ~needle:"exceeds expected decompressed size" ~haystack:msg)
  | Ok _ -> fail "expected oversized IDAT to fail at inflate cap");

  (* 13b. 1-bit grayscale 3x2 (odd width -> 5 trailing padding bits per row) *)
  (* Row 0: bits 1,0,1 -> 0b101_00000 = 0xA0; Row 1: bits 0,1,0 -> 0b010_00000 = 0x40 *)
  let gray1 =
    build_raw_png ~width:3 ~height:2 ~bit_depth:1 ~color_type:0
      "\x00\xA0\x00\x40"
  in
  (match Png_decode.decode_rgba gray1 with
  | Error err -> fail ("1-bit grayscale decode failed: " ^ err)
  | Ok img ->
      check rgba_t "gray1 (0,0)" (255, 255, 255, 255) (px_at img ~x:0 ~y:0);
      check rgba_t "gray1 (1,0)" (0, 0, 0, 255) (px_at img ~x:1 ~y:0);
      check rgba_t "gray1 (2,0)" (255, 255, 255, 255) (px_at img ~x:2 ~y:0);
      check rgba_t "gray1 (0,1)" (0, 0, 0, 255) (px_at img ~x:0 ~y:1);
      check rgba_t "gray1 (1,1)" (255, 255, 255, 255) (px_at img ~x:1 ~y:1);
      check rgba_t "gray1 (2,1)" (0, 0, 0, 255) (px_at img ~x:2 ~y:1));

  (* 13c. 2-bit grayscale 3x2: [0,1,2] = 0b00_01_10_00 = 0x18; [3,2,1] = 0b11_10_01_00 = 0xE4 *)
  let gray2 =
    build_raw_png ~width:3 ~height:2 ~bit_depth:2 ~color_type:0
      "\x00\x18\x00\xE4"
  in
  (match Png_decode.decode_rgba gray2 with
  | Error err -> fail ("2-bit grayscale decode failed: " ^ err)
  | Ok img ->
      check rgba_t "gray2 (0,0)" (0, 0, 0, 255) (px_at img ~x:0 ~y:0);
      check rgba_t "gray2 (1,0)" (85, 85, 85, 255) (px_at img ~x:1 ~y:0);
      check rgba_t "gray2 (2,0)" (170, 170, 170, 255) (px_at img ~x:2 ~y:0);
      check rgba_t "gray2 (0,1)" (255, 255, 255, 255) (px_at img ~x:0 ~y:1);
      check rgba_t "gray2 (1,1)" (170, 170, 170, 255) (px_at img ~x:1 ~y:1);
      check rgba_t "gray2 (2,1)" (85, 85, 85, 255) (px_at img ~x:2 ~y:1));

  (* 13d. 4-bit grayscale 3x1 + tRNS(15): nibbles [0,8,15] -> bytes 0x08, 0xF0 *)
  let gray4 =
    build_raw_png ~width:3 ~height:1 ~bit_depth:4 ~color_type:0
      ~trns:"\x00\x0F" "\x00\x08\xF0"
  in
  (match Png_decode.decode_rgba gray4 with
  | Error err -> fail ("4-bit grayscale decode failed: " ^ err)
  | Ok img ->
      check rgba_t "gray4 (0,0)" (0, 0, 0, 255) (px_at img ~x:0 ~y:0);
      check rgba_t "gray4 (1,0)" (136, 136, 136, 255) (px_at img ~x:1 ~y:0);
      check rgba_t "gray4 (2,0) tRNS transparent" (255, 255, 255, 0) (px_at img ~x:2 ~y:0));

  (* 13e. 1-bit indexed 3x2 + PLTE + tRNS *)
  let plte2 = "\xFF\x00\x00" ^ "\x00\x00\xFF" in
  let idx1 =
    build_raw_png ~width:3 ~height:2 ~bit_depth:1 ~color_type:3
      ~plte:plte2 ~trns:"\xFF\x80" "\x00\xA0\x00\x40"
  in
  (match Png_decode.decode_rgba idx1 with
  | Error err -> fail ("1-bit indexed decode failed: " ^ err)
  | Ok img ->
      check rgba_t "idx1 (0,0) blue alpha=128" (0, 0, 255, 128) (px_at img ~x:0 ~y:0);
      check rgba_t "idx1 (1,0) red alpha=255" (255, 0, 0, 255) (px_at img ~x:1 ~y:0);
      check rgba_t "idx1 (2,0) blue alpha=128" (0, 0, 255, 128) (px_at img ~x:2 ~y:0);
      check rgba_t "idx1 (1,1) blue alpha=128" (0, 0, 255, 128) (px_at img ~x:1 ~y:1));

  (* 13f. 2-bit indexed 3x1 + PLTE *)
  let plte4 =
    "\xFF\x00\x00" ^ "\x00\xFF\x00" ^ "\x00\x00\xFF" ^ "\xFF\xFF\x00"
  in
  let idx2 =
    build_raw_png ~width:3 ~height:1 ~bit_depth:2 ~color_type:3 ~plte:plte4
      "\x00\x6C" (* 0b01_10_11_00 -> indices 1, 2, 3 *)
  in
  (match Png_decode.decode_rgba idx2 with
  | Error err -> fail ("2-bit indexed decode failed: " ^ err)
  | Ok img ->
      check rgba_t "idx2 (0,0) green" (0, 255, 0, 255) (px_at img ~x:0 ~y:0);
      check rgba_t "idx2 (1,0) blue" (0, 0, 255, 255) (px_at img ~x:1 ~y:0);
      check rgba_t "idx2 (2,0) yellow" (255, 255, 0, 255) (px_at img ~x:2 ~y:0));

  (* 13g. 4-bit indexed 3x2 + PLTE + tRNS (odd width -> 2 bytes/row) *)
  let idx4 =
    build_raw_png ~width:3 ~height:2 ~bit_depth:4 ~color_type:3
      ~plte:plte4 ~trns:"\xFF\xFF\x40\xFF"
      "\x00\x01\x20\x00\x32\x10"
  in
  match Png_decode.decode_rgba idx4 with
  | Error err -> fail ("4-bit indexed decode failed: " ^ err)
  | Ok img ->
      check rgba_t "idx4 (0,0) red" (255, 0, 0, 255) (px_at img ~x:0 ~y:0);
      check rgba_t "idx4 (1,0) green" (0, 255, 0, 255) (px_at img ~x:1 ~y:0);
      check rgba_t "idx4 (2,0) blue alpha=64" (0, 0, 255, 64) (px_at img ~x:2 ~y:0);
      check rgba_t "idx4 (0,1) yellow" (255, 255, 0, 255) (px_at img ~x:0 ~y:1);
      check rgba_t "idx4 (1,1) blue alpha=64" (0, 0, 255, 64) (px_at img ~x:1 ~y:1);
      check rgba_t "idx4 (2,1) green" (0, 255, 0, 255) (px_at img ~x:2 ~y:1)

let () =
  run "masc_tui_v2_vision_attachments"
    [
      ( "vision_and_attachments",
        [
          test_case "Wire_attachment MIME sniff, paths, upload decode" `Quick
            test_wire_attachment_sniff_and_paths;
          test_case "Wire_fleet user_blocks, live SSE media, user/tool/asst history" `Quick
            test_wire_fleet_bidirectional_media;
          test_case "Wire_chat_journal preserves all 4 media events" `Quick
            test_wire_chat_journal_media_events;
          test_case "Wire_knowledge board post & comment attachments" `Quick
            test_wire_knowledge_board_attachments;
          test_case "Wire_runtime derived caps & media_failover purge" `Quick
            test_runtime_caps_and_media_failover_purge;
          test_case "Png_decode multi-format headers & Halfblock 24-bit RGB" `Quick
            test_png_decode_and_halfblock;
          test_case "Document_graphics Kitty ?format=png, iTerm2, Halfblock" `Quick
            test_document_graphics_all_protocols;
          test_case "Compose /attach, apply_paste, Ctrl+V, SSE, Image Inspector" `Quick
            test_compose_paste_and_inspector_flow;
          test_case "Runtime [Vision]/[Image Gen] badges & Board inline image" `Quick
            test_ui_capability_badges_and_board_attachments;
          test_case "P1: Slash commands & @mention preserve/route attachments" `Quick
            test_slash_and_mention_preserve_attachments;
          test_case "P2-1/P2-2: Upload blocks submit & board attachments survive failure" `Quick
            test_upload_in_flight_blocks_send_and_board_retry;
          test_case "P2-3: Inspector caches decoded RGBA & halfblock max_px=1280" `Quick
            test_inspector_cached_decode_and_halfblock_max_px;
          test_case "P3: Png_decode early inflate cap abort & 1/2/4-bit PNGs" `Quick
            test_png_decode_sub_byte_and_inflate_cap;
        ] );
    ]

open Alcotest

module S = Masc.Keeper_chat_slack.For_testing

let json_string json = Yojson.Safe.to_string json

let contains haystack needle =
  let hlen = String.length haystack in
  let nlen = String.length needle in
  let rec scan i =
    if i + nlen > hlen then false
    else if String.sub haystack i nlen = needle then true
    else scan (i + 1)
  in
  scan 0

let test_public_voice_audio_url_uses_base_url () =
  let url = S.public_voice_audio_url ~base_url:"https://chat.example.com" "tok123" in
  check string "audio URL"
    "https://chat.example.com/api/v1/voice/audio/tok123" url

let test_public_voice_audio_url_strips_trailing_slash () =
  let url =
    S.public_voice_audio_url ~base_url:"https://chat.example.com/" "tok123"
  in
  check string "audio URL"
    "https://chat.example.com/api/v1/voice/audio/tok123" url

(* No [Unix.unsetenv] exists in the stdlib, so a variable this helper found
   absent is restored to "" -- which [Env_config_core.trim_opt] reads as
   absent, the state the rest of the file expects. *)
let with_base_url value f =
  let key = "MASC_HTTP_BASE_URL" in
  let previous = Sys.getenv_opt key in
  Unix.putenv key value;
  Fun.protect
    ~finally:(fun () -> Unix.putenv key (Option.value previous ~default:""))
    f

(* The argument and the env fallback name the same server, so the link must
   not depend on which branch resolved it. Before #30476 this file folded the
   argument and took the env value verbatim. *)
let test_public_voice_audio_url_agrees_with_the_env_fallback () =
  let base = "http://0.0.0.0:8935" in
  let from_argument = S.public_voice_audio_url ~base_url:base "tok" in
  let from_env =
    with_base_url base (fun () -> S.public_voice_audio_url "tok")
  in
  check string "a wildcard is not a link anyone can open"
    "http://127.0.0.1:8935/api/v1/voice/audio/tok" from_argument;
  check string "both branches build the same link" from_argument from_env

let test_link_block_renders_section () =
  let json =
    S.link_block_json ~url:"https://example.com"
      ~title:"Example" ~description:(Some "A description")
  in
  let s = json_string json in
  check bool "type section" true (contains s "\"type\":\"section\"");
  check bool "mrkdwn text" true (contains s "\"type\":\"mrkdwn\"");
  check bool "link syntax" true (contains s "*<https://example.com|Example>*");
  check bool "description" true (contains s "A description")

let test_escape_mrkdwn_control_chars () =
  check string "control chars escaped"
    "&lt;@U123&gt; &amp; &lt;b&gt;"
    (S.escape_mrkdwn_text "<@U123> & <b>")

let test_link_block_escapes_mrkdwn_fields () =
  let json =
    S.link_block_json ~url:"https://example.com/?a=1&b=2"
      ~title:"<@U123> & title" ~description:(Some "a > b")
  in
  let s = json_string json in
  check bool "raw mention removed" false (contains s "<@U123>");
  check bool "title escaped" true (contains s "&lt;@U123&gt; &amp; title");
  check bool "url escaped" true
    (contains s "<https://example.com/?a=1&amp;b=2|");
  check bool "description escaped" true (contains s "a &gt; b")

let test_image_block_renders_image () =
  let json =
    S.image_block_json ~url:"https://example.com/img.png"
      ~caption:(Some "caption text")
  in
  let s = json_string json in
  check bool "type image" true (contains s "\"type\":\"image\"");
  check bool "image_url" true (contains s "\"image_url\":\"https://example.com/img.png\"");
  check bool "alt_text" true (contains s "\"alt_text\":\"caption text\"")

let test_audio_block_renders_voice_link () =
  let json =
    S.audio_block_json ~base_url:(Some "https://chat.example.com") ~token:"tok456"
      ~message_text:"hello"
  in
  let s = json_string json in
  check bool "type section" true (contains s "\"type\":\"section\"");
  check bool "voice link" true
    (contains s "<https://chat.example.com/api/v1/voice/audio/tok456|Voice message>");
  check bool "message text" true (contains s "hello")

let test_audio_block_escapes_message_text () =
  let json =
    S.audio_block_json ~base_url:(Some "https://chat.example.com") ~token:"tok456"
      ~message_text:"<@U123> & done"
  in
  let s = json_string json in
  check bool "raw mention removed" false (contains s "<@U123>");
  check bool "message escaped" true (contains s "&lt;@U123&gt; &amp; done")

let test_truncate_to_limit_keeps_utf8_boundary () =
  let s = String.concat "" (List.init 10 (fun _ -> "가")) in
  let truncated = S.truncate_to_limit s 4 in
  check bool "valid utf8" true (String.is_valid_utf_8 truncated);
  check string "first four codepoints" "가가가가" truncated

let test_limit_blocks_adds_visible_omission_notice () =
  let mk_block n =
    S.link_block_json ~url:(Printf.sprintf "https://example.com/%d" n)
      ~title:(Printf.sprintf "item %d" n) ~description:None
  in
  let blocks = List.init 55 mk_block |> S.limit_blocks_for_slack in
  check int "max 50 blocks" 50 (List.length blocks);
  let last = List.nth blocks 49 |> json_string in
  check bool "visible omission notice" true
    (contains last "6 Slack block(s) omitted")

(* ── content_blocks_of_text ─────────────────────────────────────── *)

let test_content_blocks_use_native_markdown_for_plain_text () =
  let blocks = S.content_blocks_of_text "> quoted\n\n**just plain text**\n<@U123> <!channel>" in
  check int "one markdown block" 1 (List.length blocks);
  let s = json_string (List.hd blocks) in
  check bool "native markdown block" true (contains s "\"type\":\"markdown\"");
  check bool "standard markdown stays intact" true
    (contains s "**just plain text**");
  check bool "blockquote marker stays intact" true (contains s "> quoted");
  check bool "raw user mention is suppressed" false (contains s "<@U123>");
  check bool "raw broadcast mention is suppressed" false (contains s "<!channel>");
  check bool "user mention is escaped" true (contains s "&lt;@U123>");
  check bool "broadcast mention is escaped" true (contains s "&lt;!channel>")

let test_content_blocks_detects_markdown_image () =
  let blocks =
    S.content_blocks_of_text "Hello ![alt text](https://example.com/img.png) world"
  in
  check int "markdown plus image block" 2 (List.length blocks);
  let s = json_string (List.nth blocks 1) in
  check bool "type image" true (contains s "\"type\":\"image\"");
  check bool "image_url" true
    (contains s "\"image_url\":\"https://example.com/img.png\"");
  check bool "alt_text" true (contains s "\"alt_text\":\"alt text\"")

let test_content_blocks_detects_bare_image_url () =
  let blocks = S.content_blocks_of_text "https://example.com/photo.jpg" in
  check int "markdown plus image block" 2 (List.length blocks);
  let s = json_string (List.nth blocks 1) in
  check bool "type image" true (contains s "\"type\":\"image\"");
  check bool "image_url" true
    (contains s "\"image_url\":\"https://example.com/photo.jpg\"")

let test_content_blocks_detects_link () =
  let blocks = S.content_blocks_of_text "https://example.com/page" in
  check int "one block" 1 (List.length blocks);
  let s = json_string (List.hd blocks) in
  check bool "type markdown" true (contains s "\"type\":\"markdown\"");
  check bool "link retained for Slack translation" true
    (contains s "https://example.com/page")

let test_content_blocks_detects_code () =
  let blocks = S.content_blocks_of_text "```ocaml\nlet x = 1 + 2\n```" in
  check int "one code block" 1 (List.length blocks);
  let s = json_string (List.hd blocks) in
  check bool "code block text" true (contains s "```ocaml")

let test_content_blocks_detects_mermaid () =
  let blocks = S.content_blocks_of_text "```mermaid\nflowchart TD\nA-->B\n```" in
  check int "one mermaid block" 1 (List.length blocks);
  let s = json_string (List.hd blocks) in
  check bool "mermaid block text" true (contains s "```mermaid")

let test_content_blocks_mixed_content () =
  let blocks =
    S.content_blocks_of_text
      "Check this out\nhttps://example.com/page\n![diagram](https://example.com/diagram.png)\nignore me"
  in
  check int "two blocks" 2 (List.length blocks)

let test_content_blocks_redacts_text_derived_image_secrets () =
  let secret = "sk-proj-abcdefghijklmnopqrstuvwxyz" in
  let blocks =
    S.content_blocks_of_text
      (Printf.sprintf "![%s](https://example.com/diagram.png?token=%s)"
         secret secret)
  in
  check int "markdown plus image block" 2 (List.length blocks);
  let s = json_string (List.nth blocks 1) in
  check bool "raw secret removed" false (contains s secret);
  check bool "redaction marker present" true (contains s "[REDACTED]")

let test_content_blocks_keeps_standard_markdown_contract_for_credential_url () =
  let blocks =
    S.content_blocks_of_text "https://user:pass@example.com/diagram.png"
  in
  check int "no image block for credential URL" 1 (List.length blocks);
  check bool "remaining block is markdown" true
    (contains (json_string (List.hd blocks)) "\"type\":\"markdown\"")

let test_final_message_blocks_merges_text_and_event_blocks () =
  let event_block =
    S.link_block_json ~url:"https://event.example.com"
      ~title:"event" ~description:None
  in
  let blocks =
    S.final_message_blocks
      ~content:"https://example.com/photo.jpg"
      ~event_blocks:[ event_block ]
  in
  check int "markdown, image, and event block" 3 (List.length blocks);
  let first = json_string (List.hd blocks) in
  check bool "native markdown first" true
    (contains first "\"type\":\"markdown\"");
  let second = json_string (List.nth blocks 2) in
  check bool "event block preserved" true
    (contains second "https://event.example.com")

let test_message_blocks_render_visible_stable_mentions () =
  let blocks =
    S.message_blocks_of_text ~mention_user_ids:[ "U060QL6SV1V" ]
      "**PR report** raw <@U_UNTRUSTED>"
  in
  check int "mention plus markdown" 2 (List.length blocks);
  let mention = json_string (List.hd blocks) in
  check bool "Slack wire mention remains visible" true
    (contains mention "<@U060QL6SV1V>");
  let markdown = json_string (List.nth blocks 1) in
  check bool "report uses native markdown" true
    (contains markdown "**PR report**");
  check bool "raw mention syntax is escaped" false
    (contains markdown "<@U_UNTRUSTED>")

let run_adapter ?post_stream ?edit_stream ?edit_blocks ?delete_stream ?now ?sleep
    ?set_activity_status events ~send_plain ~send_blocks =
  Eio_main.run @@ fun _env ->
  let stream = Masc.Keeper_chat_events.create () in
  List.iter (Masc.Keeper_chat_events.publish stream) events;
  let outcomes = ref [] in
  S.adapter_loop ~events:stream ~send_plain ~send_blocks
    ?post_stream ?edit_stream ?edit_blocks ?delete_stream ?now ?sleep
    ?set_activity_status
    ~on_send_result:(fun result -> outcomes := result :: !outcomes)
    ();
  List.rev !outcomes

let test_adapter_streams_one_edited_reply () =
  let posts = ref [] in
  let stream_edits = ref [] in
  let final_edits = ref [] in
  let clock = ref 0.0 in
  let now () =
    let current = !clock in
    clock := current +. 4.0;
    current
  in
  let outcomes =
    run_adapter
      ~now
      ~post_stream:(fun ~content ->
        posts := content :: !posts;
        Ok "slack-message-1")
      ~edit_stream:(fun ~message_id ~content ->
        check string "stream message identity" "slack-message-1" message_id;
        stream_edits := content :: !stream_edits;
        Ok ())
      ~edit_blocks:(fun ~message_id ~content ~blocks ->
        check string "final message identity" "slack-message-1" message_id;
        final_edits := (content, blocks) :: !final_edits;
        Ok ())
      ~delete_stream:(fun ~message_id:_ ->
        fail "successful streaming reply must not be deleted")
      [ Masc.Keeper_chat_events.Run_started
          { run_id = "run-stream"; thread_id = "thread-stream" }
      ; Masc.Keeper_chat_events.Text_delta "hello "
      ; Masc.Keeper_chat_events.Text_delta "world "
      ; Masc.Keeper_chat_events.Text_message_end
      ; Masc.Keeper_chat_events.Run_finished { run_id = "run-stream" }
      ]
      ~send_plain:(fun ~content:_ -> fail "streaming success needs no side message")
      ~send_blocks:(fun ~content:_ ~blocks:_ ->
        fail "streaming success must finalize the accepted message")
  in
  check bool "terminal callback succeeds" true (outcomes = [ Ok () ]);
  check (list string) "one initial Slack post" [ "hello " ] (List.rev !posts);
  check (list string)
    "rate-limited incremental edit"
    [ "hello world " ]
    (List.rev !stream_edits);
  (match List.rev !final_edits with
   | [ (content, [ block ]) ] ->
     check string "final rich edit keeps complete text" "hello world " content;
     check bool "final rich edit adds native markdown" true
       (contains (json_string block) "\"type\":\"markdown\"")
   | _ -> fail "streamed reply must receive one terminal rich edit")
;;

let test_adapter_stream_error_edits_accepted_reply () =
  let error_edits = ref [] in
  let outcomes =
    run_adapter
      ~post_stream:(fun ~content:_ -> Ok "slack-message-error")
      ~edit_stream:(fun ~message_id ~content ->
        error_edits := (message_id, content) :: !error_edits;
        Ok ())
      ~edit_blocks:(fun ~message_id:_ ~content:_ ~blocks:_ ->
        fail "failed run must not use the success finalizer")
      ~delete_stream:(fun ~message_id:_ ->
        fail "failed run must not delete its error reply")
      [ Masc.Keeper_chat_events.Run_started
          { run_id = "run-error"; thread_id = "thread-error" }
      ; Masc.Keeper_chat_events.Text_delta "partial "
      ; Masc.Keeper_chat_events.Event_error { message = "tool failed" }
      ]
      ~send_plain:(fun ~content:_ ->
        fail "streaming error must replace the accepted reply")
      ~send_blocks:(fun ~content:_ ~blocks:_ ->
        fail "streaming error must not create a second reply")
  in
  check bool "error callback succeeds" true (outcomes = [ Ok () ]);
  check (list (pair string string)) "same reply becomes terminal error"
    [ "slack-message-error", "Keeper error: tool failed" ]
    (List.rev !error_edits)
;;

let test_adapter_terminal_success_once () =
  let sends = ref [] in
  let outcomes =
    run_adapter
      [ Masc.Keeper_chat_events.Run_started
          { run_id = "run-1"; thread_id = "thread-1" }
      ; Masc.Keeper_chat_events.Text_delta "done"
      ; Masc.Keeper_chat_events.Run_finished { run_id = "run-1" }
      ]
      ~send_plain:(fun ~content ->
        sends := ("plain", content) :: !sends;
        Ok ())
      ~send_blocks:(fun ~content ~blocks:_ ->
        sends := ("blocks", content) :: !sends;
        Ok ())
  in
  check int "one terminal callback" 1 (List.length outcomes);
  check bool "terminal callback succeeds" true (outcomes = [ Ok () ]);
  check (list (pair string string)) "one final blocks send"
    [ "blocks", "done" ] (List.rev !sends)

let test_runtime_attempt_discards_unfinished_text_and_keeps_tool_trail () =
  let sends = ref [] in
  let outcomes =
    run_adapter
      [ Masc.Keeper_chat_events.Run_started
          { run_id = "run-retry"; thread_id = "thread-retry" }
      ; Masc.Keeper_chat_events.Text_delta "stale"
      ; Masc.Keeper_chat_events.Tool_call_start
          { occurrence =
              { stream_scope = 0; provider_message_id = None; block_index = 0 }
          ; tool_call_id = Some "call-retry"
          ; tool_call_name = "Read"
          }
      ; Masc.Keeper_chat_events.Agent_core_runtime_attempt_started
      ; Masc.Keeper_chat_events.Text_delta "fresh"
      ; Masc.Keeper_chat_events.Run_finished { run_id = "run-retry" }
      ]
      ~send_plain:(fun ~content:_ -> fail "terminal reply uses block delivery")
      ~send_blocks:(fun ~content ~blocks:_ ->
        sends := content :: !sends;
        Ok ())
  in
  check bool "runtime attempt settles successfully" true (outcomes = [ Ok () ]);
  match List.rev !sends with
  | [ content ] ->
      check bool "prior attempt text is discarded" false (contains content "stale");
      check bool "fresh attempt text is delivered" true (contains content "fresh");
      check bool "prior tool evidence is retained" true (contains content "Read")
  | sent -> failf "expected one final Slack send, got %d" (List.length sent)

let test_protocol_diagnostic_cannot_mask_final_failure () =
  let protocol_error : Masc.Keeper_chat_events.stream_protocol_error =
    { kind = Masc.Keeper_chat_events.Sse_error
    ; quarantined_occurrence = None
    ; index = None
    ; tool_call_id = None
    ; event_type = Some "error"
    ; reason = Some "upstream warning"
    ; raw_bytes = None
    }
  in
  let outcomes =
    run_adapter
      [ Masc.Keeper_chat_events.Agent_core_stream_protocol_error protocol_error
      ; Masc.Keeper_chat_events.Text_delta "final"
      ; Masc.Keeper_chat_events.Run_finished { run_id = "run-2" }
      ]
      ~send_plain:(fun ~content:_ -> Ok ())
      ~send_blocks:(fun ~content:_ ~blocks:_ ->
        Error (Masc.Keeper_chat_slack.Other "final send failed"))
  in
  match outcomes with
  | [ Error (Masc.Keeper_chat_slack.Other message) ] ->
    check string "final error wins" "final send failed" message
  | _ -> fail "only the terminal final-send failure settles the callback"

let test_adapter_empty_terminal_is_error () =
  let sends = ref 0 in
  let outcomes =
    run_adapter
      [ Masc.Keeper_chat_events.Run_finished { run_id = "run-empty" } ]
      ~send_plain:(fun ~content:_ ->
        incr sends;
        Ok ())
      ~send_blocks:(fun ~content:_ ~blocks:_ ->
        incr sends;
        Ok ())
  in
  check int "empty terminal makes no Slack call" 0 !sends;
  match outcomes with
  | [ Error (Masc.Keeper_chat_slack.Other message) ] ->
    check bool "empty terminal failure is explicit" true
      (contains message "no text or blocks")
  | _ -> fail "empty terminal must settle exactly once with an error"

let test_completed_external_effect_settles_without_duplicate_send () =
  let sends = ref 0 in
  let outcomes =
    run_adapter
      [ Masc.Keeper_chat_events.External_effect_completed
          { target =
              Masc.Keeper_surface_post.Delivered_to_slack
                { channel_id = "C-effect"; thread_ts = None }
          }
      ; Masc.Keeper_chat_events.Run_finished { run_id = "run-effect" }
      ]
      ~send_plain:(fun ~content:_ ->
        incr sends;
        Ok ())
      ~send_blocks:(fun ~content:_ ~blocks:_ ->
        incr sends;
        Ok ())
  in
  check int "completed effect makes no Slack call" 0 !sends;
  check bool "completed effect settles the receipt" true
    (outcomes = [ Ok () ])

let test_completed_external_effect_deletes_streamed_draft () =
  let deleted = ref [] in
  let outcomes =
    run_adapter
      ~post_stream:(fun ~content:_ -> Ok "slack-draft")
      ~edit_stream:(fun ~message_id:_ ~content:_ -> Ok ())
      ~edit_blocks:(fun ~message_id:_ ~content:_ ~blocks:_ ->
        fail "external effect must not finalize the streamed draft")
      ~delete_stream:(fun ~message_id ->
        deleted := message_id :: !deleted;
        Ok ())
      [ Masc.Keeper_chat_events.Text_delta "partial "
      ; Masc.Keeper_chat_events.External_effect_completed
          { target =
              Masc.Keeper_surface_post.Delivered_to_slack
                { channel_id = "C-effect"; thread_ts = None }
          }
      ; Masc.Keeper_chat_events.Run_finished { run_id = "run-effect-draft" }
      ]
      ~send_plain:(fun ~content:_ -> fail "external effect needs no side message")
      ~send_blocks:(fun ~content:_ ~blocks:_ ->
        fail "external effect needs no final message")
  in
  check (list string) "streamed draft deleted once" [ "slack-draft" ]
    (List.rev !deleted);
  check bool "draft cleanup settles the receipt" true (outcomes = [ Ok () ])

let test_terminal_edit_waits_for_slack_interval () =
  let clock = ref 0.0 in
  let sleeps = ref [] in
  let edits = ref [] in
  let final_edits = ref [] in
  let outcomes =
    run_adapter
      ~now:(fun () -> !clock)
      ~sleep:(fun seconds ->
        sleeps := seconds :: !sleeps;
        clock := !clock +. seconds)
      ~post_stream:(fun ~content:_ -> Ok "slack-paced")
      ~edit_stream:(fun ~message_id ~content ->
        edits := (message_id, content) :: !edits;
        Ok ())
      ~edit_blocks:(fun ~message_id ~content ~blocks ->
        final_edits := (message_id, content, blocks) :: !final_edits;
        Ok ())
      ~delete_stream:(fun ~message_id:_ ->
        fail "successful streaming reply must not be deleted")
      [ Masc.Keeper_chat_events.Text_delta "hello "
      ; Masc.Keeper_chat_events.Text_delta "world"
      ; Masc.Keeper_chat_events.Text_message_end
      ; Masc.Keeper_chat_events.Run_finished { run_id = "run-paced" }
      ]
      ~send_plain:(fun ~content:_ -> fail "streaming success needs no side message")
      ~send_blocks:(fun ~content:_ ~blocks:_ ->
        fail "streaming success must not create a second message")
  in
  check (list (float 0.0001)) "terminal edit sleeps for remaining interval"
    [ 3.0; 3.0 ] (List.rev !sleeps);
  check (list (pair string string)) "terminal edit uses accepted message"
    [ "slack-paced", "hello world" ] (List.rev !edits);
  (match List.rev !final_edits with
   | [ (message_id, content, [ block ]) ] ->
     check string "rich edit keeps accepted message" "slack-paced" message_id;
     check string "rich edit keeps complete content" "hello world" content;
     check bool "rich edit carries markdown block" true
       (contains (json_string block) "\"type\":\"markdown\"")
   | _ -> fail "terminal delivery must add one rich edit");
  check bool "paced delivery settles successfully" true (outcomes = [ Ok () ])

let test_adapter_external_effect_status_is_terminal_success () =
  let sends = ref [] in
  let outcomes =
    run_adapter
      [ Masc.Keeper_chat_events.Run_started
          { run_id = "run-status"; thread_id = "thread-status" }
      ; Masc.Keeper_chat_events.Text_delta "assistant preface that must not survive"
      ; Masc.Keeper_chat_events.Status_block
          { kind = Masc.Keeper_chat_blocks.Awaiting_gate_approval }
      ; Masc.Keeper_chat_events.Run_finished { run_id = "run-status" }
      ]
      ~send_plain:(fun ~content:_ -> fail "status uses Slack blocks")
      ~send_blocks:(fun ~content ~blocks ->
        sends := (content, blocks) :: !sends;
        Ok ())
  in
  check bool "typed status settles the terminal receipt" true
    (outcomes = [ Ok () ]);
  match List.rev !sends with
  | [ (content, [ block ]) ] ->
    check string "assistant preface cleared" "" content;
    check bool "status is visible" true
      (contains (json_string block) "승인 대기")
  | _ -> fail "status must produce exactly one Slack block send"

let test_message_body_preserves_reply_thread () =
  let body =
    Masc.Keeper_chat_slack.For_testing.build_message_body
      ~channel:"C-thread" ~content:"deferred reply" ~blocks:[]
      ~thread_ts:"1710000000.123456" ()
    |> Yojson.Safe.from_string
  in
  let open Yojson.Safe.Util in
  check string "channel retained" "C-thread" (body |> member "channel" |> to_string);
  check string "reply thread retained" "1710000000.123456"
    (body |> member "thread_ts" |> to_string)

let test_thread_status_body_uses_assistant_contract () =
  let body =
    S.build_thread_status_body ~channel:"C-status"
      ~thread_ts:"1710000000.654321" ~status:"답변을 준비하고 있어요…"
    |> Yojson.Safe.from_string
  in
  let open Yojson.Safe.Util in
  check string "channel_id" "C-status"
    (body |> member "channel_id" |> to_string);
  check string "thread_ts" "1710000000.654321"
    (body |> member "thread_ts" |> to_string);
  check string "status" "답변을 준비하고 있어요…"
    (body |> member "status" |> to_string)

let test_native_activity_failure_does_not_affect_delivery () =
  let statuses = ref [] in
  let sends = ref [] in
  let outcomes =
    run_adapter
      ~set_activity_status:(fun ~status ->
        statuses := status :: !statuses;
        Error (Masc.Keeper_chat_slack.Slack_api { error = "missing_scope" }))
      [ Masc.Keeper_chat_events.Run_started
          { run_id = "run-activity"; thread_id = "thread-activity" }
      ; Masc.Keeper_chat_events.Tool_call_start
          { occurrence =
              { stream_scope = 0; provider_message_id = None; block_index = 0 }
          ; tool_call_id = Some "call-activity"
          ; tool_call_name = "keeper_surface_post"
          }
      ; Masc.Keeper_chat_events.Tool_context_block
          { tool_call_id = "call-activity"
          ; name = "keeper_surface_post"
          ; args_summary = "private args"
          ; result_summary = Some "private result"
          }
      ; Masc.Keeper_chat_events.Tool_call_end
          { occurrence =
              { stream_scope = 0; provider_message_id = None; block_index = 0 }
          ; tool_call_id = Some "call-activity"
          }
      ; Masc.Keeper_chat_events.Text_delta "final"
      ; Masc.Keeper_chat_events.Run_finished { run_id = "run-activity" }
      ]
      ~send_plain:(fun ~content:_ -> fail "final reply uses blocks sender")
      ~send_blocks:(fun ~content ~blocks:_ ->
        sends := content :: !sends;
        Ok ())
  in
  check (list string) "typed activity lifecycle"
    [ "답변을 준비하고 있어요…"; "🔧 keeper_surface_post 사용 중…"; "" ]
    (List.rev !statuses);
  (* The trail names the call the turn made. Tool_context_block's summaries are
     a different thing and stay off the channel -- that is the property this
     case exists to hold, so it is now checked for itself rather than implied
     by the reply being bare. *)
  check (list string) "the reply carries the call's name"
    [ "final\n```\n\xe2\x94\x94 keeper_surface_post\n```" ]
    (List.rev !sends);
  check bool "private tool context never reaches the channel" false
    (List.exists
       (fun sent -> contains sent "private args" || contains sent "private result")
       !sends);
  check bool "delivery still succeeds" true (outcomes = [ Ok () ])

let disposition_testable =
  testable
    (fun fmt disposition ->
      Format.pp_print_string fmt
        (Tool_result.failure_effect_disposition_to_string disposition))
    ( = )

(* Slack answers logical refusals with HTTP 200 and [{ok:false,error}]
   (Slack_rest_client, RFC-0317), so a refused post never happened.
   Keeper_tools_agent_core_handler skips mark_terminal_effect_failed on
   Proven_pre_effect, so this mapping is what keeps an invalid_blocks refusal
   correctable inside the provider turn instead of ending it. *)
let test_slack_api_refusal_is_proven_pre_effect () =
  check disposition_testable "invalid_blocks"
    Tool_result.Proven_pre_effect
    (Masc.Keeper_chat_slack.effect_disposition
       (Masc.Keeper_chat_slack.Slack_api { error = "invalid_blocks" }))

let test_unproven_slack_failures_stay_unknown () =
  let unknown = Tool_result.Effect_outcome_unknown in
  check disposition_testable "network"
    unknown
    (Masc.Keeper_chat_slack.effect_disposition
       (Masc.Keeper_chat_slack.Network "connection reset"));
  check disposition_testable "http status"
    unknown
    (Masc.Keeper_chat_slack.effect_disposition
       (Masc.Keeper_chat_slack.Http_status { code = 503; body = "" }));
  check disposition_testable "other"
    unknown
    (Masc.Keeper_chat_slack.effect_disposition
       (Masc.Keeper_chat_slack.Other "ok=true but missing 'ts'"))

(* A failed streaming edit consumed Slack's rate budget just like a
   successful one. Leaving last_edit_time stale let the very next token retry
   immediately, so a 429 window attracted one edit attempt per token. The
   failure must re-arm the throttle. *)
let test_failed_stream_edit_rearms_the_throttle () =
  let times = ref [ 10.0; 13.2; 13.3; 13.4; 16.5; 16.6; 16.7 ] in
  let now () =
    match !times with
    | t :: rest ->
        times := rest;
        t
    | [] -> 16.7
  in
  let edits = ref [] in
  let outcomes =
    run_adapter ~now ~sleep:(fun _ -> ())
      ~post_stream:(fun ~content:_ -> Ok "slack-message-1")
      ~edit_stream:(fun ~message_id:_ ~content ->
        edits := content :: !edits;
        Error (Masc.Keeper_chat_slack.Network "rate limited"))
      ~edit_blocks:(fun ~message_id:_ ~content:_ ~blocks:_ ->
        Error (Masc.Keeper_chat_slack.Network "rate limited"))
      ~delete_stream:(fun ~message_id:_ ->
        fail "a rate-limited reply must not be deleted")
      [ Masc.Keeper_chat_events.Run_started
          { run_id = "run-throttle"; thread_id = "thread-throttle" }
      ; Masc.Keeper_chat_events.Text_delta "a "
      ; Masc.Keeper_chat_events.Text_delta "b "
      ; Masc.Keeper_chat_events.Text_delta "c "
      ; Masc.Keeper_chat_events.Text_delta "d "
      ; Masc.Keeper_chat_events.Run_finished { run_id = "run-throttle" }
      ]
      ~send_plain:(fun ~content:_ ->
        fail "a streaming failure needs no side message")
      ~send_blocks:(fun ~content:_ ~blocks:_ ->
        fail "the accepted streaming message is edited, not replaced")
  in
  check bool "terminal callback reports the failure" true
    (outcomes = [ Error (Masc.Keeper_chat_slack.Network "rate limited") ]);
  check (list string)
    "a failed edit re-arms the throttle: one retry per interval"
    [ "a b "; "a b c d " ]
    (List.rev !edits)

(* A mid-turn checkpoint status is a block alongside the reply, not a
   replacement for it: wiping acc_text made the already-posted channel
   message visibly shrink at the next edit. *)
let test_checkpoint_status_keeps_the_accumulated_stream_text () =
  let final_edits = ref [] in
  let outcomes =
    run_adapter
      ~post_stream:(fun ~content:_ -> Ok "slack-message-ckpt")
      ~edit_stream:(fun ~message_id:_ ~content:_ -> Ok ())
      ~edit_blocks:(fun ~message_id:_ ~content ~blocks ->
        final_edits := (content, blocks) :: !final_edits;
        Ok ())
      ~delete_stream:(fun ~message_id:_ ->
        fail "a checkpointed reply must not be deleted")
      [ Masc.Keeper_chat_events.Run_started
          { run_id = "run-ckpt"; thread_id = "thread-ckpt" }
      ; Masc.Keeper_chat_events.Text_delta "hello "
      ; Masc.Keeper_chat_events.Status_block
          { kind = Masc.Keeper_chat_blocks.Continuation_checkpoint }
      ; Masc.Keeper_chat_events.Text_delta "world "
      ; Masc.Keeper_chat_events.Run_finished { run_id = "run-ckpt" }
      ]
      ~send_plain:(fun ~content:_ ->
        fail "a checkpoint status needs no side message")
      ~send_blocks:(fun ~content:_ ~blocks:_ ->
        fail "the accepted streaming message is edited, not replaced")
  in
  check bool "terminal callback succeeds" true (outcomes = [ Ok () ]);
  match List.rev !final_edits with
  | [ (content, blocks) ] ->
      check bool "pre-checkpoint text survives" true (contains content "hello");
      check bool "post-checkpoint text is delivered" true
        (contains content "world");
      check bool "the checkpoint status block is still delivered" true
        (List.exists
           (fun block -> contains (json_string block) "체크포인트")
           blocks)
  | _ -> fail "a checkpointed reply must receive one terminal rich edit"

(* A failed placeholder POST may still have landed server-side; Slack has no
   idempotency key for chat.postMessage. One bounded retry, then the turn
   degrades to a single final message instead of risking a duplicate. *)
let test_unknown_outcome_post_retries_once_then_degrades () =
  let posts = ref [] in
  let finals = ref [] in
  let outcomes =
    run_adapter
      ~post_stream:(fun ~content ->
        posts := content :: !posts;
        Error (Masc.Keeper_chat_slack.Network "connection reset after send"))
      ~edit_stream:(fun ~message_id:_ ~content:_ ->
        fail "without a message id there is nothing to edit")
      ~edit_blocks:(fun ~message_id:_ ~content:_ ~blocks:_ ->
        fail "without a message id there is nothing to finalize")
      ~delete_stream:(fun ~message_id:_ ->
        fail "without a message id there is nothing to delete")
      [ Masc.Keeper_chat_events.Run_started
          { run_id = "run-post"; thread_id = "thread-post" }
      ; Masc.Keeper_chat_events.Text_delta "a "
      ; Masc.Keeper_chat_events.Text_delta "b "
      ; Masc.Keeper_chat_events.Text_delta "c "
      ; Masc.Keeper_chat_events.Run_finished { run_id = "run-post" }
      ]
      ~send_plain:(fun ~content:_ ->
        fail "the final reply uses block delivery")
      ~send_blocks:(fun ~content ~blocks:_ ->
        finals := content :: !finals;
        Ok ())
  in
  check bool "terminal callback succeeds" true (outcomes = [ Ok () ]);
  check (list string) "the placeholder POST is retried at most once"
    [ "a "; "a b " ] (List.rev !posts);
  check (list string) "the reply still arrives as one final message"
    [ "a b c " ] (List.rev !finals)

let () =
  run "keeper_chat_slack"
    [
      ( "effect-disposition"
      , [ test_case "Slack refusal proves no post" `Quick
            test_slack_api_refusal_is_proven_pre_effect
        ; test_case "unproven failures stay unknown" `Quick
            test_unproven_slack_failures_stay_unknown
        ] )
    ; ( "audio-url"
      , [ test_case "uses base URL" `Quick test_public_voice_audio_url_uses_base_url
        ; test_case "strips trailing slash" `Quick
            test_public_voice_audio_url_strips_trailing_slash
        ; test_case "argument and env fallback agree" `Quick
            test_public_voice_audio_url_agrees_with_the_env_fallback
        ] )
    ; ( "block-rendering"
      , [ test_case "link block renders section" `Quick test_link_block_renders_section
        ; test_case "escapes mrkdwn control chars" `Quick
            test_escape_mrkdwn_control_chars
        ; test_case "link block escapes mrkdwn fields" `Quick
            test_link_block_escapes_mrkdwn_fields
        ; test_case "image block renders image" `Quick test_image_block_renders_image
        ; test_case "audio block renders voice link" `Quick
            test_audio_block_renders_voice_link
        ; test_case "audio block escapes message text" `Quick
            test_audio_block_escapes_message_text
        ; test_case "truncate keeps utf8 boundary" `Quick
            test_truncate_to_limit_keeps_utf8_boundary
        ; test_case "block limit adds visible omission notice" `Quick
            test_limit_blocks_adds_visible_omission_notice
        ] )
    ; ( "content-blocks"
      , [ test_case "plain text uses native markdown" `Quick
            test_content_blocks_use_native_markdown_for_plain_text
        ; test_case "detects markdown image" `Quick
            test_content_blocks_detects_markdown_image
        ; test_case "detects code fences" `Quick
            test_content_blocks_detects_code
        ; test_case "detects mermaid blocks" `Quick
            test_content_blocks_detects_mermaid
        ; test_case "detects bare image URL" `Quick
            test_content_blocks_detects_bare_image_url
        ; test_case "detects link" `Quick test_content_blocks_detects_link
        ; test_case "mixed content" `Quick test_content_blocks_mixed_content
        ; test_case "redacts text-derived image secrets" `Quick
            test_content_blocks_redacts_text_derived_image_secrets
        ; test_case "credential URL gets no image block" `Quick
            test_content_blocks_keeps_standard_markdown_contract_for_credential_url
        ; test_case "final delivery merges text and event blocks" `Quick
            test_final_message_blocks_merges_text_and_event_blocks
        ; test_case "stable mentions are visible" `Quick
            test_message_blocks_render_visible_stable_mentions
        ] )
    ; ( "terminal-receipt"
      , [ test_case "terminal success settles once" `Quick
            test_adapter_terminal_success_once
        ; test_case "runtime retry drops stale text and keeps tool evidence" `Quick
            test_runtime_attempt_discards_unfinished_text_and_keeps_tool_trail
        ; test_case "streams one edited reply" `Quick
            test_adapter_streams_one_edited_reply
        ; test_case "stream error edits accepted reply" `Quick
            test_adapter_stream_error_edits_accepted_reply
        ; test_case "protocol diagnostic cannot mask final failure" `Quick
            test_protocol_diagnostic_cannot_mask_final_failure
        ; test_case "empty terminal is explicit failure" `Quick
            test_adapter_empty_terminal_is_error
        ; test_case "completed effect sends no duplicate reply" `Quick
            test_completed_external_effect_settles_without_duplicate_send
        ; test_case "completed effect deletes streamed draft" `Quick
            test_completed_external_effect_deletes_streamed_draft
        ; test_case "terminal edit observes Slack interval" `Quick
            test_terminal_edit_waits_for_slack_interval
        ; test_case "typed external-effect status settles successfully" `Quick
            test_adapter_external_effect_status_is_terminal_success
        ; test_case "failed stream edit re-arms the throttle" `Quick
            test_failed_stream_edit_rearms_the_throttle
        ; test_case "checkpoint status keeps accumulated text" `Quick
            test_checkpoint_status_keeps_the_accumulated_stream_text
        ; test_case "unknown-outcome POST retries once then degrades" `Quick
            test_unknown_outcome_post_retries_once_then_degrades
        ; test_case "native activity failure is isolated" `Quick
            test_native_activity_failure_does_not_affect_delivery
        ] )
    ; ( "thread-routing"
      , [ test_case "deferred reply keeps thread_ts" `Quick
            test_message_body_preserves_reply_thread
        ; test_case "assistant status body uses thread contract" `Quick
            test_thread_status_body_uses_assistant_contract
        ] )
    ]

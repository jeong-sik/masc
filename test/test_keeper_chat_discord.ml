open Alcotest

module D = Masc.Keeper_chat_discord.For_testing

let contains haystack needle =
  String_util.contains_substring haystack needle

let run_adapter ?show_activity ?now events ~post_message ~edit_message
    ~send_message =
  Eio_main.run
  @@ fun _env ->
  let stream = Masc.Keeper_chat_events.create () in
  List.iter (Masc.Keeper_chat_events.publish stream) events;
  let outcomes = ref [] in
  D.adapter_loop ~token:"test-token" ~channel_id:"test-channel"
    ~events:stream ~post_message ~edit_message ~send_message
    ?show_activity ?now
    ~on_send_result:(fun result -> outcomes := result :: !outcomes) ();
  List.rev !outcomes

let check_single_ok label = function
  | [ Ok () ] -> ()
  | outcomes ->
      failf "%s: expected one Ok callback, got %d callback(s)" label
        (List.length outcomes)

let check_single_network_error label expected = function
  | [ Error (Discord_rest_client.Network actual) ] ->
      check string label expected actual
  | outcomes ->
      failf "%s: expected one Network error callback, got %d callback(s)"
        label (List.length outcomes)

let test_streaming_holds_back_trailing_token () =
  let content =
    D.streaming_patch_content "prefix sk-proj-abcdefghijklmnop"
  in
  check string "only stable prefix is published" "prefix " content;
  check bool "raw token prefix withheld" false (contains content "sk-proj")

let test_streaming_redacts_delimited_secret () =
  let secret = "sk-proj-abcdefghijklmnopqrstuvwxyz" in
  let content =
    D.streaming_patch_content ("prefix " ^ secret ^ " done ")
  in
  check bool "redaction marker present" true
    (contains content "[REDACTED]");
  check bool "raw secret removed" false (contains content secret)

let test_streaming_single_word_waits_for_final_send () =
  let content = D.streaming_patch_content "hello" in
  check string "no stable segment yet" "" content

let test_final_split_preserves_overflow () =
  let input = String.concat "" (List.init 420 (fun _ -> "word ")) in
  let head, overflow = D.final_head_and_overflow input in
  check int "head capped at Discord limit" 2000 (String.length head);
  match overflow with
  | None -> fail "expected overflow"
  | Some overflow ->
      check int "overflow preserves tail"
        (String.length input - 2000)
        (String.length overflow);
      check string "reconstructed final text" input (head ^ overflow)

let test_final_split_redacts_before_chunking () =
  let secret = "sk-proj-abcdefghijklmnopqrstuvwxyz" in
  let head, overflow =
    D.final_head_and_overflow ("prefix " ^ secret ^ " suffix")
  in
  let full =
    match overflow with
    | None -> head
    | Some overflow -> head ^ overflow
  in
  check bool "redaction marker present" true
    (contains full "[REDACTED]");
  check bool "raw secret removed" false (contains full secret)

let test_public_voice_audio_url_uses_base_url () =
  let url =
    D.public_voice_audio_url ~base_url:"https://chat.example.com" "tok123"
  in
  check string "audio URL"
    "https://chat.example.com/api/v1/voice/audio/tok123" url

let test_public_voice_audio_url_strips_trailing_slash () =
  let url =
    D.public_voice_audio_url ~base_url:"https://chat.example.com/" "tok123"
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
  let from_argument = D.public_voice_audio_url ~base_url:base "tok" in
  let from_env =
    with_base_url base (fun () -> D.public_voice_audio_url "tok")
  in
  check string "a wildcard is not a link anyone can open"
    "http://127.0.0.1:8935/api/v1/voice/audio/tok" from_argument;
  check string "both branches build the same link" from_argument from_env

let test_rich_embeds_of_text_projects_links_and_images () =
  let embeds =
    D.rich_embeds_of_text
      "https://example.com/page\n![diagram](https://example.com/diagram.png)\nplain text"
  in
  check int "two embeds" 2 (List.length embeds);
  let link_json =
    Discord_rest_client.embed_to_json (List.hd embeds) |> Yojson.Safe.to_string
  in
  check bool "link title" true (contains link_json "\"title\":\"example.com\"");
  check bool "link url" true
    (contains link_json "\"url\":\"https://example.com/page\"");
  let image_json =
    Discord_rest_client.embed_to_json (List.nth embeds 1)
    |> Yojson.Safe.to_string
  in
  check bool "image url" true
    (contains image_json "\"url\":\"https://example.com/diagram.png\"");
  check bool "image caption" true
    (contains image_json "\"description\":\"diagram\"")

let test_rich_embeds_redacts_text_derived_image_secrets () =
  let secret = "sk-proj-abcdefghijklmnopqrstuvwxyz" in
  let embeds =
    D.rich_embeds_of_text
      (Printf.sprintf "![%s](https://example.com/diagram.png?token=%s)"
         secret secret)
  in
  check int "one image embed" 1 (List.length embeds);
  let image_json =
    Discord_rest_client.embed_to_json (List.hd embeds) |> Yojson.Safe.to_string
  in
  check bool "raw secret removed" false (contains image_json secret);
  check bool "redaction marker present" true
    (contains image_json "[REDACTED]")

let test_rich_embeds_suppresses_credential_url () =
  let embeds =
    D.rich_embeds_of_text "https://user:pass@example.com/diagram.png"
  in
  check int "credential URL does not become embed" 0 (List.length embeds)

let test_rich_embeds_includes_code_and_mermaid () =
  let embeds =
    D.rich_embeds_of_text
      "```ocaml\nlet x = 1 + 2\n```\n```mermaid\nflowchart TD\nA-->B\n```"
  in
  check int "code and mermaid embeds" 2 (List.length embeds);
  let code_json = List.hd embeds |> Discord_rest_client.embed_to_json |> Yojson.Safe.to_string in
  check bool "code title" true (contains code_json "Code (ocaml)");
  check bool "code body" true
    (contains code_json "```ocaml\\nlet x = 1 + 2\\n```");
  let mermaid_json =
    List.nth embeds 1 |> Discord_rest_client.embed_to_json |> Yojson.Safe.to_string
  in
  check bool "mermaid title" true (contains mermaid_json "Mermaid Diagram");
  check bool "mermaid body" true
    (contains mermaid_json "```mermaid\\nflowchart TD\\nA-->B\\n```")

let test_terminal_callback_once_for_fallback_post () =
  let final_posts = ref [] in
  let outcomes =
    run_adapter
      [ Masc.Keeper_chat_events.Run_started
          { run_id = "run-fallback"; thread_id = "thread-fallback" }
      ; Masc.Keeper_chat_events.Text_delta "hello"
      ; Masc.Keeper_chat_events.Text_message_end
      ; Masc.Keeper_chat_events.Run_finished { run_id = "run-fallback" }
      ]
      ~post_message:(fun ~content:_ -> fail "stable prefix should not POST")
      ~edit_message:(fun ~message_id:_ ~content:_ ->
        fail "fallback delivery should not PATCH")
      ~send_message:(fun ~content ->
        final_posts := content :: !final_posts;
        Ok ())
  in
  check_single_ok "fallback terminal result" outcomes;
  check (list string) "one final POST" [ "hello" ] (List.rev !final_posts)

let test_runtime_attempt_discards_unfinished_text_and_keeps_tool_trail () =
  let final_posts = ref [] in
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
      ~post_message:(fun ~content:_ -> fail "single words stay buffered")
      ~edit_message:(fun ~message_id:_ ~content:_ ->
        fail "retry fixture never opens a streaming message")
      ~send_message:(fun ~content ->
        final_posts := content :: !final_posts;
        Ok ())
  in
  check_single_ok "runtime attempt terminal result" outcomes;
  match List.rev !final_posts with
  | [ content ] ->
      check bool "prior attempt text is discarded" false (contains content "stale");
      check bool "fresh attempt text is delivered" true (contains content "fresh");
      check bool "prior tool evidence is retained" true (contains content "Read")
  | posts -> failf "expected one final POST, got %d" (List.length posts)

let test_adapter_empty_terminal_is_local_error () =
  let sends = ref 0 in
  let outcomes =
    run_adapter
      [ Masc.Keeper_chat_events.Run_finished { run_id = "run-empty" } ]
      ~post_message:(fun ~content:_ ->
        incr sends;
        Ok "unexpected-stream-message")
      ~edit_message:(fun ~message_id:_ ~content:_ ->
        incr sends;
        Ok ())
      ~send_message:(fun ~content:_ ->
        incr sends;
        Ok ())
  in
  check int "empty terminal makes no Discord call" 0 !sends;
  match outcomes with
  | [ Error (Discord_rest_client.Other { reason; _ }) ] ->
    check bool "empty terminal failure is explicit" true
      (contains reason "contained no text")
  | _ -> fail "empty terminal settles once with a local delivery error"

let test_completed_external_effect_settles_without_duplicate_send () =
  let sends = ref 0 in
  let outcomes =
    run_adapter
      [ Masc.Keeper_chat_events.External_effect_completed
          { target =
              Masc.Keeper_surface_post.Delivered_to_discord
                { channel_id = "channel-effect" }
          }
      ; Masc.Keeper_chat_events.Run_finished { run_id = "run-effect" }
      ]
      ~post_message:(fun ~content:_ ->
        incr sends;
        Ok "unexpected-stream-message")
      ~edit_message:(fun ~message_id:_ ~content:_ ->
        incr sends;
        Ok ())
      ~send_message:(fun ~content:_ ->
        incr sends;
        Ok ())
  in
  check int "completed effect makes no Discord call" 0 !sends;
  check_single_ok "completed effect settles the receipt" outcomes

let test_terminal_callback_reports_final_patch_failure () =
  let patch_calls = ref 0 in
  let outcomes =
    run_adapter
      [ Masc.Keeper_chat_events.Run_started
          { run_id = "run-patch"; thread_id = "thread-patch" }
      ; Masc.Keeper_chat_events.Text_delta "hello "
      ; Masc.Keeper_chat_events.Text_message_end
      ; Masc.Keeper_chat_events.Run_finished { run_id = "run-patch" }
      ]
      ~post_message:(fun ~content ->
        check string "streaming POST content" "hello " content;
        Ok "discord-message-1")
      ~edit_message:(fun ~message_id ~content ->
        incr patch_calls;
        check string "final PATCH message" "discord-message-1" message_id;
        check string "final PATCH content" "hello " content;
        Error (Discord_rest_client.Network "final patch failed"))
      ~send_message:(fun ~content:_ -> fail "no overflow expected")
  in
  check int "one final PATCH" 1 !patch_calls;
  check_single_network_error "final PATCH failure" "final patch failed" outcomes

let test_terminal_callback_reports_overflow_failure () =
  let content = String.make 2100 'x' ^ " " in
  let overflow_posts = ref 0 in
  let outcomes =
    run_adapter
      [ Masc.Keeper_chat_events.Run_started
          { run_id = "run-overflow"; thread_id = "thread-overflow" }
      ; Masc.Keeper_chat_events.Text_delta content
      ; Masc.Keeper_chat_events.Text_message_end
      ; Masc.Keeper_chat_events.Run_finished { run_id = "run-overflow" }
      ]
      ~post_message:(fun ~content ->
        check int "streaming head length" 2000 (String.length content);
        Ok "discord-message-2")
      ~edit_message:(fun ~message_id:_ ~content ->
        check int "final head length" 2000 (String.length content);
        Ok ())
      ~send_message:(fun ~content ->
        incr overflow_posts;
        check int "overflow length" 101 (String.length content);
        Error (Discord_rest_client.Network "overflow failed"))
  in
  check int "one overflow POST" 1 !overflow_posts;
  check_single_network_error "overflow failure" "overflow failed" outcomes

let test_error_reply_callback_once () =
  let sends = ref 0 in
  let outcomes =
    run_adapter
      [ Masc.Keeper_chat_events.Run_started
          { run_id = "run-error"; thread_id = "thread-error" }
      ; Masc.Keeper_chat_events.Event_error { message = "provider failed" }
      ]
      ~post_message:(fun ~content:_ -> fail "error reply should use final sender")
      ~edit_message:(fun ~message_id:_ ~content:_ ->
        fail "error reply should not PATCH")
      ~send_message:(fun ~content ->
        incr sends;
        check string "error reply" "Keeper error: provider failed" content;
        Error (Discord_rest_client.Network "error post failed"))
  in
  check int "one error POST" 1 !sends;
  check_single_network_error "error POST failure" "error post failed" outcomes

let test_external_effect_status_replaces_assistant_preface () =
  let posts = ref [] in
  let edits = ref [] in
  let outcomes =
    run_adapter
      [ Masc.Keeper_chat_events.Run_started
          { run_id = "run-status"; thread_id = "thread-status" }
      ; Masc.Keeper_chat_events.Text_delta "assistant preface that must not survive"
      ; Masc.Keeper_chat_events.Status_block
          { kind = Masc.Keeper_chat_blocks.Awaiting_gate_approval }
      ; Masc.Keeper_chat_events.Run_finished { run_id = "run-status" }
      ]
      ~post_message:(fun ~content ->
        posts := content :: !posts;
        Ok "status-message")
      ~edit_message:(fun ~message_id ~content ->
        check string "typed status edits the streaming message"
          "status-message" message_id;
        edits := content :: !edits;
        Ok ())
      ~send_message:(fun ~content:_ ->
        fail "typed status must replace the existing streaming message")
  in
  check_single_ok "typed status terminal result" outcomes;
  check int "streaming preface is posted once" 1 (List.length !posts);
  check (list string) "typed status is the terminal message"
    [ "승인 대기: 외부 작업을 실행하기 전에 확인이 필요합니다." ]
    (List.rev !edits)

let test_tool_activity_uses_native_surface_without_messages () =
  let activity_refreshes = ref 0 in
  let final_sends = ref [] in
  let outcomes =
    run_adapter
      ~show_activity:(fun () ->
        incr activity_refreshes;
        Error (Discord_rest_client.Network "typing unavailable"))
      [ Masc.Keeper_chat_events.Run_started
          { run_id = "run-tool"; thread_id = "thread-tool" }
      ; Masc.Keeper_chat_events.Tool_call_start
          { occurrence =
              { stream_scope = 0; provider_message_id = None; block_index = 0 }
          ; tool_call_id = Some "call-1"
          ; tool_call_name = "keeper_surface_read"
          }
      ; Masc.Keeper_chat_events.Tool_context_block
          { tool_call_id = "call-1"
          ; name = "keeper_surface_read"
          ; args_summary = "surface=discord"
          ; result_summary = Some "private tool result"
          }
      ; Masc.Keeper_chat_events.Tool_call_end
          { occurrence =
              { stream_scope = 0; provider_message_id = None; block_index = 0 }
          ; tool_call_id = Some "call-1"
          }
      ; Masc.Keeper_chat_events.Text_delta "done"
      ; Masc.Keeper_chat_events.Run_finished { run_id = "run-tool" }
      ]
      ~post_message:(fun ~content:_ ->
        fail "tool activity and one-word final reply must not stream POST")
      ~edit_message:(fun ~message_id:_ ~content:_ ->
        fail "tool activity must not create a message to edit")
      ~send_message:(fun ~content ->
        final_sends := content :: !final_sends;
        Ok ())
  in
  check int "run start and tool start refresh native activity" 2
    !activity_refreshes;
  (* The tool trail rides on that one reply. Tool activity still creates no
     message of its own -- post_message and edit_message fail the test above if
     it does -- which is the property this case exists to hold. *)
  check (list string) "only the final reply is sent, carrying the turn's trail"
    [ "done\n```\n\xe2\x94\x94 keeper_surface_read\n```" ]
    (List.rev !final_sends);
  check bool "private tool context never reaches the channel" false
    (List.exists (fun sent -> contains sent "private tool result") !final_sends);
  check_single_ok "activity failure does not affect delivery" outcomes

(* A failed streaming edit consumed Discord's rate budget just like a
   successful one. Leaving last_edit_time stale let the very next token retry
   immediately, so a 429 window attracted one edit attempt per token. The
   failure must re-arm the throttle. *)
let test_failed_stream_edit_rearms_the_throttle () =
  let times = ref [ 10.0; 11.2; 11.3; 11.4; 12.5; 12.6 ] in
  let now () =
    match !times with
    | t :: rest ->
        times := rest;
        t
    | [] -> 12.6
  in
  let edits = ref [] in
  let outcomes =
    run_adapter ~now
      ~post_message:(fun ~content:_ -> Ok "discord-message-1")
      ~edit_message:(fun ~message_id:_ ~content ->
        edits := content :: !edits;
        Error (Discord_rest_client.Network "rate limited"))
      ~send_message:(fun ~content:_ ->
        fail "the accepted streaming message is edited, not replaced")
      [ Masc.Keeper_chat_events.Run_started
          { run_id = "run-throttle"; thread_id = "thread-throttle" }
      ; Masc.Keeper_chat_events.Text_delta "a "
      ; Masc.Keeper_chat_events.Text_delta "b "
      ; Masc.Keeper_chat_events.Text_delta "c "
      ; Masc.Keeper_chat_events.Text_delta "d "
      ; Masc.Keeper_chat_events.Run_finished { run_id = "run-throttle" }
      ]
  in
  check_single_network_error "terminal callback reports the failure"
    "rate limited" outcomes;
  check (list string)
    "a failed edit re-arms the throttle: one retry per interval"
    [ "a b "; "a b c d "; "a b c d " ]
    (List.rev !edits)

(* A mid-turn checkpoint status is a block alongside the reply, not a
   replacement for it: replacing acc_text made the already-posted channel
   message visibly shrink at the next edit. *)
let test_checkpoint_status_keeps_the_accumulated_stream_text () =
  let edits = ref [] in
  let outcomes =
    run_adapter
      ~post_message:(fun ~content:_ -> Ok "discord-message-ckpt")
      ~edit_message:(fun ~message_id:_ ~content ->
        edits := content :: !edits;
        Ok ())
      ~send_message:(fun ~content:_ ->
        fail "the accepted streaming message is edited, not replaced")
      [ Masc.Keeper_chat_events.Run_started
          { run_id = "run-ckpt"; thread_id = "thread-ckpt" }
      ; Masc.Keeper_chat_events.Text_delta "hello "
      ; Masc.Keeper_chat_events.Status_block
          { kind = Masc.Keeper_chat_blocks.Continuation_checkpoint }
      ; Masc.Keeper_chat_events.Text_delta "world "
      ; Masc.Keeper_chat_events.Run_finished { run_id = "run-ckpt" }
      ]
  in
  check_single_ok "checkpointed reply settles" outcomes;
  match List.rev !edits with
  | [ content ] ->
      check bool "pre-checkpoint text survives" true (contains content "hello");
      check bool "post-checkpoint text is delivered" true
        (contains content "world")
  | _ -> fail "a checkpointed reply must receive one terminal edit"

(* A failed placeholder POST may still have landed server-side; Discord has no
   idempotency key for message creation. One bounded retry, then the turn
   degrades to a single final message instead of risking a duplicate. *)
let test_unknown_outcome_post_retries_once_then_degrades () =
  let posts = ref [] in
  let finals = ref [] in
  let outcomes =
    run_adapter
      ~post_message:(fun ~content ->
        posts := content :: !posts;
        Error (Discord_rest_client.Network "connection reset after send"))
      ~edit_message:(fun ~message_id:_ ~content:_ ->
        fail "without a message id there is nothing to edit")
      ~send_message:(fun ~content ->
        finals := content :: !finals;
        Ok ())
      [ Masc.Keeper_chat_events.Run_started
          { run_id = "run-post"; thread_id = "thread-post" }
      ; Masc.Keeper_chat_events.Text_delta "a "
      ; Masc.Keeper_chat_events.Text_delta "b "
      ; Masc.Keeper_chat_events.Text_delta "c "
      ; Masc.Keeper_chat_events.Run_finished { run_id = "run-post" }
      ]
  in
  check_single_ok "the degraded turn still settles" outcomes;
  check (list string) "the placeholder POST is retried at most once"
    [ "a "; "a b " ] (List.rev !posts);
  check (list string) "the reply still arrives as one final message"
    [ "a b c " ] (List.rev !finals)

let () =
  run "keeper_chat_discord"
    [ ( "streaming-redaction"
      , [ test_case "holds back trailing token" `Quick
            test_streaming_holds_back_trailing_token
        ; test_case "redacts delimited secret" `Quick
            test_streaming_redacts_delimited_secret
        ; test_case "single word waits for final send" `Quick
            test_streaming_single_word_waits_for_final_send
        ] )
    ; ( "final-delivery"
      , [ test_case "preserves overflow" `Quick
            test_final_split_preserves_overflow
        ; test_case "redacts before chunking" `Quick
            test_final_split_redacts_before_chunking
        ; test_case "callback once for fallback POST" `Quick
            test_terminal_callback_once_for_fallback_post
        ; test_case "runtime retry drops stale text and keeps tool evidence" `Quick
            test_runtime_attempt_discards_unfinished_text_and_keeps_tool_trail
        ; test_case "empty terminal is local-only" `Quick
            test_adapter_empty_terminal_is_local_error
        ; test_case "completed effect sends no duplicate reply" `Quick
            test_completed_external_effect_settles_without_duplicate_send
        ; test_case "callback reports final PATCH failure" `Quick
            test_terminal_callback_reports_final_patch_failure
        ; test_case "callback reports overflow failure" `Quick
            test_terminal_callback_reports_overflow_failure
        ; test_case "error reply callback exactly once" `Quick
            test_error_reply_callback_once
        ; test_case "typed status replaces assistant preface" `Quick
            test_external_effect_status_replaces_assistant_preface
        ; test_case "tool activity uses native surface" `Quick
            test_tool_activity_uses_native_surface_without_messages
        ; test_case "failed stream edit re-arms the throttle" `Quick
            test_failed_stream_edit_rearms_the_throttle
        ; test_case "checkpoint status keeps accumulated text" `Quick
            test_checkpoint_status_keeps_the_accumulated_stream_text
        ; test_case "unknown-outcome POST retries once then degrades" `Quick
            test_unknown_outcome_post_retries_once_then_degrades
        ] )
    ; ( "rich-blocks"
      , [ test_case "audio URL uses base URL" `Quick
            test_public_voice_audio_url_uses_base_url
        ; test_case "audio URL strips trailing slash" `Quick
            test_public_voice_audio_url_strips_trailing_slash
        ; test_case "argument and env fallback agree" `Quick
            test_public_voice_audio_url_agrees_with_the_env_fallback
        ; test_case "projects text links and images to embeds" `Quick
            test_rich_embeds_of_text_projects_links_and_images
        ; test_case "supports code and mermaid as embeds" `Quick
            test_rich_embeds_includes_code_and_mermaid
        ; test_case "redacts text-derived image secrets" `Quick
            test_rich_embeds_redacts_text_derived_image_secrets
        ; test_case "suppresses credential URL embeds" `Quick
            test_rich_embeds_suppresses_credential_url
        ] )
    ]

(* Keeper_surface_post target resolution + assistant-only
   store append.

   resolve_target is pure (surface label + channel arg + bindings in,
   target or error out). The Discord transport path needs a live REST
   client and stays operational; the dashboard persistence path is
   covered against a temp store here. *)

open Alcotest

module Store = Masc.Keeper_chat_store
module SP = Masc.Keeper_surface_post

(* A 2x1 PNG header and a MIDI header: the store sniffs both by magic bytes. *)
let tiny_png =
  String.concat ""
    [ "\x89PNG\r\n\x1a\n"; "\x00\x00\x00\x0d"; "IHDR"; "\x00\x00\x00\x02"
    ; "\x00\x00\x00\x01"; "\x08\x06\x00\x00\x00"; "\x72\xb6\x0d\x24"
    ]

let tiny_midi = "MThd\x00\x00\x00\x06\x00\x00\x00\x01\x00\x60"

(* A RIFF/WAVE header, which is what the attachment store sniffs as WAV. *)
let tiny_wav = "RIFF\x24\x00\x00\x00WAVEfmt "

let target_pp fmt = function
  | SP.To_native route -> Format.fprintf fmt "To_native{%s}" (Yojson.Safe.to_string (Masc.Keeper_native_origin_reply.to_yojson route))
  | SP.To_dashboard -> Format.fprintf fmt "To_dashboard"
  | SP.To_discord { channel_id } ->
      Format.fprintf fmt "To_discord{%s}" channel_id
  | SP.To_slack { channel_id; thread_ts; blocks } ->
      let blocks_label =
        match blocks with None -> "no-blocks" | Some [] -> "empty" | Some _ -> "blocks"
      in
      let thread_label =
        match thread_ts with None -> "root" | Some ts -> "thread:" ^ ts
      in
      Format.fprintf fmt "To_slack{%s,%s,%s}" channel_id thread_label blocks_label

let target : SP.post_target testable = testable target_pp ( = )

let resolve = SP.resolve_target

(* ── resolve_target ─────────────────────────────────────────────── *)

let test_dashboard_always_resolves () =
  check (result target string) "no bindings needed" (Ok SP.To_dashboard)
    (resolve ~surface:"dashboard" ~channel_id:None ~bound_discord_channels:[] ())

let test_discord_unbound_is_error () =
  match resolve ~surface:"discord" ~channel_id:None ~bound_discord_channels:[] () with
  | Error message ->
      check bool "names the unbound condition" true
        (Astring.String.is_infix ~affix:"no Discord channel binding" message)
  | Ok _ -> fail "unbound discord must not resolve"

let test_discord_single_binding_resolves_implicitly () =
  check (result target string) "single binding"
    (Ok (SP.To_discord { channel_id = "98791450001" }))
    (resolve ~surface:"discord" ~channel_id:None
       ~bound_discord_channels:[ "98791450001" ] ())

let test_discord_multiple_bindings_require_channel_id () =
  (match
     resolve ~surface:"discord" ~channel_id:None
       ~bound_discord_channels:[ "111"; "222" ] ()
   with
  | Error message ->
      check bool "lists bound channels" true
        (Astring.String.is_infix ~affix:"111, 222" message)
  | Ok _ -> fail "ambiguous binding must not resolve");
  check (result target string) "explicit channel_id picks one"
    (Ok (SP.To_discord { channel_id = "222" }))
    (resolve ~surface:"discord" ~channel_id:(Some "222")
       ~bound_discord_channels:[ "111"; "222" ] ())

let test_discord_continuation_selects_exact_bound_channel () =
  let continuation_channel =
    match
      Keeper_continuation_channel.discord
        ~guild_id:(Some "guild")
        ~channel_id:"222"
        ~parent_channel_id:None
        ~thread_id:None
        ~user_id:"user"
        ()
    with
    | Ok channel -> channel
    | Error message -> fail message
  in
  check (result target string) "typed continuation channel"
    (Ok (SP.To_discord { channel_id = "222" }))
    (resolve ~surface:"discord" ~channel_id:None ~continuation_channel
       ~bound_discord_channels:[ "111"; "222" ] ())

let test_discord_thread_continuation_stays_in_thread () =
  let continuation_channel =
    match
      Keeper_continuation_channel.discord
        ~guild_id:(Some "guild")
        ~channel_id:"thread-1"
        ~parent_channel_id:(Some "parent-1")
        ~thread_id:(Some "thread-1")
        ~user_id:"user"
        ()
    with
    | Ok channel -> channel
    | Error message -> fail message
  in
  check (result target string) "thread continuation selects thread channel"
    (Ok (SP.To_discord { channel_id = "thread-1" }))
    (resolve ~surface:"discord" ~channel_id:None ~continuation_channel
       ~bound_discord_channels:[ "parent-1" ] ());
  check (result target string) "explicit thread channel remains in thread"
    (Ok (SP.To_discord { channel_id = "thread-1" }))
    (resolve ~surface:"discord" ~channel_id:(Some "thread-1")
       ~continuation_channel ~bound_discord_channels:[ "parent-1" ] ())

let test_discord_thread_foreign_explicit_channel_is_error () =
  let continuation_channel =
    match
      Keeper_continuation_channel.discord
        ~guild_id:(Some "guild")
        ~channel_id:"thread-1"
        ~parent_channel_id:(Some "parent-1")
        ~thread_id:(Some "thread-1")
        ~user_id:"user"
        ()
    with
    | Ok channel -> channel
    | Error message -> fail message
  in
  match
    resolve ~surface:"discord" ~channel_id:(Some "thread-2")
      ~continuation_channel ~bound_discord_channels:[ "parent-1" ] ()
  with
  | Error message ->
      check bool "names the rejected channel" true
        (Astring.String.is_infix ~affix:"thread-2" message)
  | Ok _ -> fail "foreign explicit thread must not resolve"

let test_mismatched_continuation_does_not_select_channel () =
  let continuation_channel =
    match
      Keeper_continuation_channel.slack
        ~team_id:(Some "team")
        ~channel_id:"222"
        ~thread_ts:None
        ~user_id:"user"
    with
    | Ok channel -> channel
    | Error message -> fail message
  in
  match
    resolve ~surface:"discord" ~channel_id:None ~continuation_channel
      ~bound_discord_channels:[ "111"; "222" ] ()
  with
  | Error _ -> ()
  | Ok _ -> fail "a Slack continuation selected a Discord channel"

let test_discord_foreign_channel_id_is_error () =
  match
    resolve ~surface:"discord" ~channel_id:(Some "999")
      ~bound_discord_channels:[ "111" ] ()
  with
  | Error message ->
      check bool "names the rejected id" true
        (Astring.String.is_infix ~affix:"999" message)
  | Ok _ -> fail "foreign channel_id must not resolve"

let test_slack_unbound_is_error () =
  match
    resolve ~surface:"slack" ~channel_id:None
      ~bound_discord_channels:[] ~bound_slack_channels:[] ()
  with
  | Error message ->
      check bool "names the unbound condition" true
        (Astring.String.is_infix ~affix:"no Slack channel binding" message)
  | Ok _ -> fail "unbound slack must not resolve"

let test_slack_single_binding_resolves_implicitly () =
  check (result target string) "single slack binding"
    (Ok (SP.To_slack { channel_id = "C123456"; thread_ts = None; blocks = None }))
    (resolve ~surface:"slack" ~channel_id:None
       ~bound_discord_channels:[] ~bound_slack_channels:[ "C123456" ] ())

let test_slack_multiple_bindings_require_channel_id () =
  (match
     resolve ~surface:"slack" ~channel_id:None
       ~bound_discord_channels:[] ~bound_slack_channels:[ "AAA"; "BBB" ] ()
   with
  | Error message ->
      check bool "lists bound slack channels" true
        (Astring.String.is_infix ~affix:"AAA, BBB" message)
  | Ok _ -> fail "ambiguous slack binding must not resolve");
  check (result target string) "explicit channel_id picks one"
    (Ok (SP.To_slack { channel_id = "BBB"; thread_ts = None; blocks = None }))
    (resolve ~surface:"slack" ~channel_id:(Some "BBB")
       ~bound_discord_channels:[] ~bound_slack_channels:[ "AAA"; "BBB" ] ())

let test_slack_continuation_selects_exact_bound_channel () =
  let continuation_channel =
    match
      Keeper_continuation_channel.slack
        ~team_id:(Some "team")
        ~channel_id:"BBB"
        ~thread_ts:(Some "thread")
        ~user_id:"user"
    with
    | Ok channel -> channel
    | Error message -> fail message
  in
  check (result target string) "typed Slack continuation channel keeps its thread"
    (Ok
       (SP.To_slack
          { channel_id = "BBB"; thread_ts = Some "thread"; blocks = None }))
    (resolve ~surface:"slack" ~channel_id:None ~continuation_channel
       ~bound_discord_channels:[] ~bound_slack_channels:[ "AAA"; "BBB" ] ());
  check (result target string)
    "explicit continuation channel also keeps its thread"
    (Ok
       (SP.To_slack
          { channel_id = "BBB"; thread_ts = Some "thread"; blocks = None }))
    (resolve ~surface:"slack" ~channel_id:(Some "BBB") ~continuation_channel
       ~bound_discord_channels:[] ~bound_slack_channels:[ "AAA"; "BBB" ] ());
  check (result target string)
    "explicit different channel posts to its root, not a foreign thread"
    (Ok (SP.To_slack { channel_id = "AAA"; thread_ts = None; blocks = None }))
    (resolve ~surface:"slack" ~channel_id:(Some "AAA") ~continuation_channel
       ~bound_discord_channels:[] ~bound_slack_channels:[ "AAA"; "BBB" ] ())

let test_slack_foreign_channel_id_is_error () =
  match
    resolve ~surface:"slack" ~channel_id:(Some "ZZZ")
      ~bound_discord_channels:[] ~bound_slack_channels:[ "AAA" ] ()
  with
  | Error message ->
      check bool "names the rejected slack id" true
        (Astring.String.is_infix ~affix:"ZZZ" message)
  | Ok _ -> fail "foreign slack channel_id must not resolve"

let test_missing_native_origin_and_unknown_surface_are_errors () =
  List.iter
    (fun surface ->
      check bool (surface ^ " has no authorized destination") true
        (Result.is_error (resolve ~surface ~channel_id:None ~bound_discord_channels:[] ())))
    [ "telegram"; "imessage"; "openclaw" ]

(* ── set_blocks ─────────────────────────────────────────────────── *)

let test_set_blocks_attaches_to_slack () =
  let block = `Assoc [ ("type", `String "section") ] in
  let resolved =
    SP.set_blocks
      (SP.To_slack { channel_id = "C1"; thread_ts = None; blocks = None })
      (Some [ block ])
  in
  check (result target string) "blocks attached"
    (Ok
       (SP.To_slack
          { channel_id = "C1"; thread_ts = None; blocks = Some [ block ] }))
    (Ok resolved)

let test_set_blocks_ignores_other_targets () =
  let block = `Assoc [ ("type", `String "section") ] in
  check target "dashboard unchanged" SP.To_dashboard
    (SP.set_blocks SP.To_dashboard (Some [ block ]));
  check target "discord unchanged"
    (SP.To_discord { channel_id = "D1" })
    (SP.set_blocks (SP.To_discord { channel_id = "D1" }) (Some [ block ]))

(* ── delivery_target codec ──────────────────────────────────────── *)

let delivery_target_pp fmt = function
  | SP.Delivered_to_native route -> Format.fprintf fmt "native{%s}" (Yojson.Safe.to_string (Masc.Keeper_native_origin_reply.to_yojson route))
  | SP.Delivered_to_dashboard -> Format.fprintf fmt "dashboard"
  | SP.Delivered_to_discord { channel_id } ->
      Format.fprintf fmt "discord{%s}" channel_id
  | SP.Delivered_to_slack { channel_id; thread_ts } ->
      Format.fprintf fmt "slack{%s,%s}" channel_id
        (Option.value thread_ts ~default:"root")

let delivery_target : SP.delivery_target testable =
  testable delivery_target_pp ( = )

let test_delivery_target_json_round_trip () =
  List.iter
    (fun target ->
      match SP.delivery_target_of_yojson (SP.delivery_target_to_yojson target) with
      | Ok decoded -> check delivery_target "round trip" target decoded
      | Error message -> fail message)
    [ SP.Delivered_to_dashboard
    ; SP.Delivered_to_discord { channel_id = "D1" }
    ; SP.Delivered_to_slack { channel_id = "C1"; thread_ts = None }
    ; SP.Delivered_to_slack
        { channel_id = "C1"; thread_ts = Some "1700000000.000100" }
    ]

let test_delivery_target_decode_rejects_widened_input () =
  List.iter
    (fun json ->
      match SP.delivery_target_of_yojson json with
      | Error _ -> ()
      | Ok _ -> fail "widened delivery target must not decode")
    [ `Assoc [ ("kind", `String "telegram") ]
    ; `Assoc [ ("kind", `String "slack") ]
    ; `Assoc [ ("kind", `String "slack"); ("channel_id", `String " ") ]
    ; `Assoc
        [ ("kind", `String "slack")
        ; ("channel_id", `String "C1")
        ; ("thread_ts", `Int 1700000000)
        ]
    ; `Assoc [ ("channel_id", `String "C1") ]
    ; `String "dashboard"
    ]

let test_delivery_target_of_post_target_drops_payload_only () =
  check delivery_target "dashboard maps" SP.Delivered_to_dashboard
    (SP.delivery_target_of_post_target SP.To_dashboard);
  check delivery_target "slack keeps destination coordinates"
    (SP.Delivered_to_slack
       { channel_id = "C1"; thread_ts = Some "1700000000.000100" })
    (SP.delivery_target_of_post_target
       (SP.To_slack
          { channel_id = "C1"
          ; thread_ts = Some "1700000000.000100"
          ; blocks = Some [ `Assoc [ ("type", `String "section") ] ]
          }))

(* ── append_assistant_message ───────────────────────────────────── *)

let with_temp_base_dir f =
  let dir =
    Filename.concat (Filename.get_temp_dir_name ())
      (Printf.sprintf "surface-post-%d" (Unix.getpid ()))
  in
  let masc = Filename.concat dir ".masc" in
  let keeper_chat = Filename.concat masc "keeper_chat" in
  List.iter
    (fun d -> if not (Sys.file_exists d) then Unix.mkdir d 0o755)
    [ dir; masc; keeper_chat ];
  Fun.protect
    ~finally:(fun () ->
      Array.iter
        (fun f -> try Sys.remove (Filename.concat keeper_chat f) with _ -> ())
        (try Sys.readdir keeper_chat with Sys_error _ -> [||]))
    (fun () -> f dir)

let test_assistant_message_persists_with_typed_surface () =
  with_temp_base_dir (fun base_dir ->
      Store.append_assistant_message ~base_dir ~keeper_name:"post-keeper"
        ~content:"keeper-initiated hello"
        ~surface:
          (Masc.Surface_ref.Discord
             {
               guild_id = None;
               channel_id = "chan-1";
               channel_name = None;
               parent_channel_id = None;
               thread_id = None;
             })
        ();
      let messages = Store.load ~base_dir ~keeper_name:"post-keeper" in
      check int "one line" 1 (List.length messages);
      let m = List.hd messages in
      check string "role" "assistant" (Store.Role.to_label m.Store.role);
      check string "content" "keeper-initiated hello" m.Store.content;
      check (option string)
        "surface-derived label"
        (Some "discord")
        (Option.map Masc.Surface_ref.lane_label m.Store.surface);
      check bool "no speaker on keeper output" true (m.Store.speaker = None))

let test_replay_connector_post_preserves_discord_and_slack_coordinates () =
  let base_path = Filename.temp_dir "surface-post-replay-coords-" "" in
  (* The cleanup calls [Channel_gate_discord_state.unregister_thread], which
     takes an [Eio.Mutex] (`use_rw`), so it must run while the Eio loop below is
     still alive. A [Fun.protect] outside [Eio_main.run] runs its [finally] once
     the loop has ended, and then the mutex raises
     `Fun.Finally_raised: Stdlib.Effect.Unhandled(Eio__core__Cancel.Get_context)`
     instead of the test's own result. *)
  Masc_test_deps.with_process_env Env_config_core.base_path_env_key (Some base_path)
  @@ fun () ->
  Eio_main.run @@ fun env ->
  Fun.protect
    ~finally:(fun () ->
      Channel_gate_discord_state.unregister_thread ~thread_id:"discord-thread-9";
      Channel_gate_slack_state.clear_workspace_id ();
      Fs_compat.remove_tree base_path)
    (fun () ->
       if not (Fs_compat.has_fs ()) then Fs_compat.set_fs (Eio.Stdenv.fs env);
       let config = Masc.Workspace.default_config base_path in
       ignore (Masc.Workspace.init config ~agent_name:(Some "replay-coords-test"));
       let meta =
         match
           Masc_test_deps.meta_of_json_fixture
             (`Assoc
                [ "name", `String "replay-keeper"
                ; "always_allow", `Bool true
                ])
         with
         | Ok meta -> meta
         | Error detail -> fail detail
       in
       let discord_cont =
         Keeper_continuation_channel.discord
           ~guild_id:(Some "guild-42")
           ~channel_id:"discord-thread-9"
           ~parent_channel_id:(Some "discord-parent-3")
           ~thread_id:(Some "discord-thread-9")
           ~user_id:"100001"
           ()
         |> Result.get_ok
       in
       let discord_replay =
         Masc.Keeper_tool_in_process_runtime.Replay_discord_post
           { input =
               `Assoc
                 [ "connector", `String "discord"
                 ; "channel_id", `String "discord-thread-9"
                 ; "content", `String "reply in discord thread"
                 ; "mention_user_ids", `List []
                 ]
           ; channel_id = "discord-thread-9"
           ; content = "reply in discord thread"
           ; mention_user_ids = []
           ; files = SP.Text_only
           }
       in
       let discord_result =
         Masc.Keeper_tool_in_process_runtime.For_testing.replay_connector_post_with_senders
           ~config
           ~meta
           ~continuation_channel:discord_cont
           ~discord_send:(fun ~channel_id:_ ~content:_ ~mention_user_ids:_ ~attachments ->
             check bool "text-only post sends no files" true (Option.is_none attachments);
             Ok "discord-msg-1")
           discord_replay
       in
       check bool "Discord replay completed" true
         (discord_result.disposition = Tool_result.Completed ());
       (* A post naming stored files sends their bytes under their stored
          names, in order; a post naming a missing file sends nothing. *)
       let store = Attachment_store.create ~base_path in
       let stored ~filename ~declared_mime bytes =
         match
           Attachment_store.put ~declared_mime ~filename
             ~origin:Attachment_store.Model_generated ~created_by:"replay-keeper"
             ~retention:Attachment_store.Durable store ~bytes
         with
         | Ok (meta : Attachment_store.meta) -> meta.id
         | Error error -> fail (Attachment_store.put_error_to_string error)
       in
       let png_id = stored ~filename:"cat.png" ~declared_mime:"image/png" tiny_png in
       let midi_id =
         stored ~filename:"riff.mid" ~declared_mime:"audio/midi" tiny_midi
       in
       let file_replay files =
         Masc.Keeper_tool_in_process_runtime.Replay_discord_post
           { input =
               Masc.Keeper_connector_post_replay.connector_post_gate_input
                 ~connector:"discord" ~channel_id:"discord-thread-9"
                 ~content:"악보와 그림이에요" ~mention_user_ids:[]
                 ~discord_files:files ()
           ; channel_id = "discord-thread-9"
           ; content = "악보와 그림이에요"
           ; mention_user_ids = []
           ; files
           }
       in
       let sent_names = ref None in
       let file_result =
         Masc.Keeper_tool_in_process_runtime.For_testing.replay_connector_post_with_senders
           ~config ~meta ~continuation_channel:discord_cont
           ~discord_send:(fun ~channel_id:_ ~content:_ ~mention_user_ids:_ ~attachments ->
             (match attachments with
              | Some (Channel_gate_discord_state.Uploads (first, rest)) ->
                sent_names :=
                  Some (List.map Discord_rest_client.upload_filename (first :: rest))
              | Some (Channel_gate_discord_state.Voice _) ->
                fail "a file post was sent as a voice message"
              | None -> fail "a file post was sent without its files");
             Ok "discord-msg-2")
           (file_replay (SP.Files (png_id, [ midi_id ])))
       in
       check bool "file post completed" true
         (file_result.disposition = Tool_result.Completed ());
       check (option (list string)) "stored files sent by name, in order"
         (Some [ "cat.png"; "riff.mid" ]) !sent_names;
       (* A voice message that fails after its text: the text is in the
          channel, so the Keeper is told its id and the conversation records
          it. The seam stands in for Discord once the clip is made, and making
          a clip needs ffmpeg, which the runner lacks; the answer to this
          error does not depend on which attachments the seam is handed. *)
       let half_sent =
         Masc.Keeper_tool_in_process_runtime.For_testing.replay_connector_post_with_senders
           ~config ~meta ~continuation_channel:discord_cont
           ~discord_send:(fun ~channel_id:_ ~content:_ ~mention_user_ids:_ ~attachments:_ ->
             Error
               (Channel_gate_discord_state.Voice_failed_after_text
                  { text_message_id = "discord-text-7"
                  ; error =
                      Channel_gate_discord_state.Rest_error
                        (Discord_rest_client.Other
                           { request_id = ""; reason = "voice refused"; body_bytes = 0 })
                  }))
           (file_replay (SP.Files (png_id, [])))
       in
       (match half_sent.disposition, half_sent.failure_effect_disposition with
        | Tool_result.Failed _, Tool_result.Proven_post_effect -> ()
        | (Tool_result.Completed () | Tool_result.Deferred () | Tool_result.Failed _), _ ->
          fail "a voice message that failed after its text is not a failure after the effect");
       check bool "the Keeper is told the text's id" true
         (Astring.String.is_infix ~affix:"discord-text-7" half_sent.raw_output);
       let missing_id = "att_" ^ String.make 64 'a' in
       let missing_result =
         Masc.Keeper_tool_in_process_runtime.For_testing.replay_connector_post_with_senders
           ~config ~meta ~continuation_channel:discord_cont
           ~discord_send:(fun ~channel_id:_ ~content:_ ~mention_user_ids:_ ~attachments:_ ->
             fail "a post naming a missing file reached Discord")
           (file_replay (SP.Files (png_id, [ missing_id ])))
       in
       let failed_before_effect (result : Masc.Keeper_tool_execution.t) =
         match result.disposition with
         | Tool_result.Failed _ ->
           result.failure_effect_disposition = Tool_result.Proven_pre_effect
         | Tool_result.Completed () | Tool_result.Deferred () -> false
       in
       check bool "missing file fails before any effect" true
         (failed_before_effect missing_result);
       (* MIDI is notes, not sound: a voice message naming it stops before
          ffmpeg runs or anything is sent. *)
       let midi_voice_result =
         Masc.Keeper_tool_in_process_runtime.For_testing.replay_connector_post_with_senders
           ~config ~meta ~continuation_channel:discord_cont
           ~discord_send:(fun ~channel_id:_ ~content:_ ~mention_user_ids:_ ~attachments:_ ->
             fail "a MIDI voice message reached Discord")
           (file_replay (SP.Voice_message midi_id))
       in
       check bool "MIDI voice message fails before any effect" true
         (failed_before_effect midi_voice_result);
       Channel_gate_slack_state.record_workspace_id "T-SLACK-99";
       let slack_cont =
         Keeper_continuation_channel.slack
           ~team_id:(Some "T-SLACK-77")
           ~channel_id:"C-SLACK-1"
           ~thread_ts:(Some "1700000000.000100")
           ~user_id:"U123ABC"
         |> Result.get_ok
       in
       let slack_replay =
         Masc.Keeper_tool_in_process_runtime.Replay_slack_post
           { input =
               `Assoc
                 [ "connector", `String "slack"
                 ; "channel_id", `String "C-SLACK-1"
                 ; "thread_ts", `String "1700000000.000100"
                 ; "content", `String "reply in slack thread"
                 ; "blocks", `List []
                 ; "mention_user_ids", `List []
                 ]
           ; channel_id = "C-SLACK-1"
           ; thread_ts = Some "1700000000.000100"
           ; content = "reply in slack thread"
           ; blocks = []
           ; mention_user_ids = []
           }
       in
       let slack_result =
         Masc.Keeper_tool_in_process_runtime.For_testing.replay_connector_post_with_senders
           ~config
           ~meta
           ~continuation_channel:slack_cont
           ~slack_send:
             (fun ~thread_ts:_ ~channel:_ ~content:_ ~blocks:_ ~mention_user_ids:_ ->
               Ok ())
           slack_replay
       in
       check bool "Slack replay completed" true
         (slack_result.disposition = Tool_result.Completed ());
       match Store.load ~base_dir:base_path ~keeper_name:meta.name with
       (* The text post, the file post, the text of the half-sent voice post
          and the Slack post each persist a row; the refused posts persist
          none. *)
       | [ discord_row; file_row; half_sent_row; slack_row ] ->
         check string "the file post's row carries its text" "악보와 그림이에요"
           file_row.content;
         check string "the half-sent post's row carries the text in the channel"
           "악보와 그림이에요" half_sent_row.content;
         check (option string) "the half-sent post stays in the Discord conversation"
           (Some "discord:guild-42:channel:discord-thread-9")
           half_sent_row.conversation_id;
         check (option string) "the file post stays in the Discord conversation"
           (Some "discord:guild-42:channel:discord-thread-9")
           file_row.conversation_id;
         check (option string) "Discord conversation_id preserved"
           (Some "discord:guild-42:channel:discord-thread-9")
           discord_row.conversation_id;
         (match discord_row.surface with
          | Some
              (Masc.Surface_ref.Discord
                 { guild_id
                 ; channel_id
                 ; channel_name = _
                 ; parent_channel_id
                 ; thread_id
                 }) ->
            check (option string) "Discord guild_id" (Some "guild-42") guild_id;
            check string "Discord channel_id" "discord-thread-9" channel_id;
            check (option string) "Discord parent_channel_id"
              (Some "discord-parent-3") parent_channel_id;
            check (option string) "Discord thread_id"
              (Some "discord-thread-9") thread_id
          | _ -> fail "expected Discord surface on persisted row");
         check (option string) "Slack conversation_id preserved"
           (Some "slack:channel:C-SLACK-1")
           slack_row.conversation_id;
         (match slack_row.surface with
          | Some
              (Masc.Surface_ref.Slack
                 { team_id; channel_id; channel_name = _; thread_ts }) ->
            check (option string) "Slack team_id" (Some "T-SLACK-77") team_id;
            check string "Slack channel_id" "C-SLACK-1" channel_id;
            check (option string) "Slack thread_ts"
              (Some "1700000000.000100") thread_ts
          | _ -> fail "expected Slack surface on persisted row")
       | rows ->
         failf "expected 4 persisted assistant rows, got %d" (List.length rows))

let test_slack_mentions_require_stable_ids () =
  let args =
    `Assoc
      [ "mention_user_ids"
      , `List [ `String "U060QL6SV1V"; `String "W123ABC"; `String "U060QL6SV1V" ]
      ]
  in
  check (result (list string) string) "deduplicated stable ids"
    (Ok [ "U060QL6SV1V"; "W123ABC" ])
    (SP.user_mentions_of_args ~surface:"slack" args);
  match
    SP.user_mentions_of_args ~surface:"slack"
      (`Assoc [ "mention_user_ids", `List [ `String "Vincent" ] ])
  with
  | Error message ->
    check bool "error points to participant ids" true
      (Astring.String.is_infix ~affix:"participant roster" message)
  | Ok _ -> fail "Slack display name became a mention id"

let test_discord_mentions_reject_broad_or_named_targets () =
  check (result (list string) string) "decimal snowflakes"
    (Ok [ "1234567890" ])
    (SP.user_mentions_of_args ~surface:"discord"
       (`Assoc [ "mention_user_ids", `List [ `String "1234567890" ] ]));
  List.iter
    (fun value ->
       match
         SP.user_mentions_of_args ~surface:"discord"
           (`Assoc [ "mention_user_ids", `List [ `String value ] ])
       with
       | Error _ -> ()
       | Ok _ -> failf "Discord accepted unsafe mention target %S" value)
    [ "@everyone"; "Vincent"; "<@123>" ]

let test_dashboard_rejects_nonempty_mentions () =
  match
    SP.user_mentions_of_args ~surface:"dashboard"
      (`Assoc [ "mention_user_ids", `List [ `String "U123" ] ])
  with
  | Error _ -> ()
  | Ok _ -> fail "dashboard accepted connector mention ids"

let roster_message ~surface ~speaker_id : Store.chat_message =
  { id = "roster-message"
  ; role = Store.Role.User
  ; content = "hello"
  ; ts = 1.0
  ; attachments = None
  ; tool_call_id = None
  ; execution_id = None
  ; tool_call_name = None
  ; surface = Some surface
  ; conversation_id = None
  ; external_message_id = None
  ; workspace_id = None
  ; speaker =
      Some
        { Store.speaker_id = Some speaker_id
        ; speaker_name = None
        ; speaker_authority = Store.External
        }
  ; audio = None
  ; blocks = None
  ; mentions = []
  ; turn_ref = None
  ; failure_kind = None
  ; stream_lifecycle = None
  ; approval_lifecycle = None
  ; delivery_provenance = None
  }

let test_mentions_require_exact_resolved_target_roster () =
  let messages =
    [ roster_message
        ~surface:
          (Masc.Surface_ref.Discord
             { guild_id = None
             ; channel_id = "D-current"
             ; channel_name = None
             ; parent_channel_id = None
             ; thread_id = None
             })
        ~speaker_id:"1234567890"
    ; roster_message
        ~surface:
          (Masc.Surface_ref.Discord
             { guild_id = None
             ; channel_id = "D-other"
             ; channel_name = None
             ; parent_channel_id = None
             ; thread_id = None
             })
        ~speaker_id:"9999999999"
    ; roster_message
        ~surface:
          (Masc.Surface_ref.Slack
             { team_id = None
             ; channel_id = "C-current"
             ; channel_name = None; thread_ts = Some "thread-other"
             })
        ~speaker_id:"UOTHER"
    ]
  in
  check (result unit string) "current Discord participant is allowed" (Ok ())
    (SP.validate_user_mentions_against_roster
       ~target:(SP.To_discord { channel_id = "D-current" })
       ~messages
       [ "1234567890" ]);
  (match
     SP.validate_user_mentions_against_roster
       ~target:(SP.To_discord { channel_id = "D-current" })
       ~messages
       [ "9999999999" ]
   with
   | Error message ->
     check bool "cross-channel id is named" true
       (Astring.String.is_infix ~affix:"9999999999" message)
   | Ok () -> fail "cross-channel Discord participant was mentionable");
  match
    SP.validate_user_mentions_against_roster
      ~target:
        (SP.To_slack
           { channel_id = "C-current"
           ; thread_ts = Some "thread-current"
           ; blocks = None
           })
      ~messages
      [ "UOTHER" ]
  with
  | Error _ -> ()
  | Ok () -> fail "participant from another Slack thread was mentionable"

(* ── thread_ts / blocks tool args ───────────────────────────────── *)

let block ?(block_type = "section") () =
  `Assoc [ ("type", `String block_type); ("text", `String "t") ]

let test_thread_ts_args_decode () =
  check (result (option string) string) "absent decodes to None" (Ok None)
    (SP.thread_ts_of_args ~surface:"slack" (`Assoc []));
  check (result (option string) string) "value decodes trimmed"
    (Ok (Some "1755134336.123456"))
    (SP.thread_ts_of_args ~surface:"slack"
       (`Assoc [ ("thread_ts", `String " 1755134336.123456 ") ]));
  (match
     SP.thread_ts_of_args ~surface:"slack"
       (`Assoc [ ("thread_ts", `String "  ") ])
   with
   | Error _ -> ()
   | Ok _ -> fail "blank thread_ts was accepted");
  (match
     SP.thread_ts_of_args ~surface:"discord"
       (`Assoc [ ("thread_ts", `String "1755134336.123456") ])
   with
   | Error _ -> ()
   | Ok _ -> fail "thread_ts on a non-Slack surface was accepted");
  match
    SP.thread_ts_of_args ~surface:"slack" (`Assoc [ ("thread_ts", `Int 3) ])
  with
  | Error _ -> ()
  | Ok _ -> fail "non-string thread_ts was accepted"

let test_discord_files_args_decode () =
  let id c = "att_" ^ String.make 64 c in
  let decode ?(surface = "discord") fields = SP.discord_files_of_args ~surface (`Assoc fields) in
  let ids values = ("attachment_ids", `List (List.map (fun v -> `String v) values)) in
  check bool "absent decodes to text only" true (decode [] = Ok SP.Text_only);
  check bool "ids keep their order" true
    (decode [ ids [ id 'b'; id 'a' ] ] = Ok (SP.Files (id 'b', [ id 'a' ])));
  check bool "as_voice_message false is files" true
    (decode [ ids [ id 'a' ]; ("as_voice_message", `Bool false) ]
     = Ok (SP.Files (id 'a', [])));
  check bool "one id as a voice message" true
    (decode [ ids [ id 'a' ]; ("as_voice_message", `Bool true) ]
     = Ok (SP.Voice_message (id 'a')));
  let refused label = function
    | Error (_ : string) -> ()
    | Ok _ -> fail (label ^ " was accepted")
  in
  refused "files on Slack" (decode ~surface:"slack" [ ids [ id 'a' ] ]);
  refused "files on the dashboard" (decode ~surface:"dashboard" [ ids [ id 'a' ] ]);
  refused "a voice flag on Slack" (decode ~surface:"slack" [ ("as_voice_message", `Bool false) ]);
  refused "empty array" (decode [ ("attachment_ids", `List []) ]);
  refused "repeated id" (decode [ ids [ id 'a'; id 'a' ] ]);
  refused "malformed id" (decode [ ids [ "att_xyz" ] ]);
  refused "non-string id" (decode [ ("attachment_ids", `List [ `Int 1 ]) ]);
  refused "non-array" (decode [ ("attachment_ids", `String (id 'a')) ]);
  refused "repeated attachment_ids" (decode [ ids [ id 'a' ]; ids [ id 'b' ] ]);
  refused "a voice message without a file" (decode [ ("as_voice_message", `Bool true) ]);
  refused "a voice message with two files"
    (decode [ ids [ id 'a'; id 'b' ]; ("as_voice_message", `Bool true) ]);
  refused "a non-boolean voice flag"
    (decode [ ids [ id 'a' ]; ("as_voice_message", `String "true") ]);
  let distinct n = ids (List.init n (fun i -> "att_" ^ Printf.sprintf "%064x" i)) in
  check bool "ten files fit one Discord message" true
    (match decode [ distinct 10 ] with
     | Ok (SP.Files (_, rest)) -> List.length rest = 9
     | Ok (SP.Text_only | SP.Voice_message _) | Error _ -> false);
  refused "an eleventh file" (decode [ distinct 11 ])

(* Before approval a post may name only files its Keeper may read, and a voice
   message only sound. A post that passes makes its files durable, so the
   Keeper's later ephemeral files cannot evict them while the post waits for
   an operator; a refused post leaves them ephemeral. *)
let test_discord_attachments_held_before_approval () =
  let base_path = Filename.temp_dir "surface-post-held-" "" in
  Eio_main.run @@ fun env ->
  Fun.protect
    ~finally:(fun () -> Fs_compat.remove_tree base_path)
    (fun () ->
       if not (Fs_compat.has_fs ()) then Fs_compat.set_fs (Eio.Stdenv.fs env);
       let store = Attachment_store.create ~base_path in
       let alice_file ~mime ~filename bytes =
         match
           Attachment_store.put ~declared_mime:mime ~filename
             ~origin:Attachment_store.Model_generated ~created_by:"alice"
             ~retention:(Attachment_store.Ephemeral { keeper = "alice" })
             store ~bytes
         with
         | Ok (meta : Attachment_store.meta) -> meta.id
         | Error error -> fail (Attachment_store.put_error_to_string error)
       in
       let ephemeral_id = alice_file ~mime:"image/png" ~filename:"cat.png" tiny_png in
       let held keeper ids =
         let files =
           match ids with
           | first :: rest -> SP.Files (first, rest)
           | [] -> SP.Text_only
         in
         Masc.Keeper_tool_in_process_runtime.For_testing.discord_files_held
           ~base_path ~keeper files
       in
       let retention_of id =
         match Attachment_store.get_meta store ~id with
         | Ok (Some (meta : Attachment_store.meta)) -> meta.retention
         | Ok None -> fail "the attachment vanished"
         | Error error -> fail (Attachment_store.get_error_to_string error)
       in
       let retention () = retention_of ephemeral_id in
       let ephemeral = Attachment_store.Ephemeral { keeper = "alice" } in
       check bool "another keeper's ephemeral file is refused" true
         (Result.is_error (held "bob" [ ephemeral_id ]));
       check bool "a refused check leaves the file ephemeral" true
         (retention () = Attachment_store.Ephemeral { keeper = "alice" });
       check bool "an absent file is refused" true
         (Result.is_error (held "alice" [ "att_" ^ String.make 64 'f' ]));
       check bool "a post with one absent file is refused" true
         (Result.is_error (held "alice" [ ephemeral_id; "att_" ^ String.make 64 'f' ]));
       check bool "its readable file stays ephemeral" true (retention () = ephemeral);
       (match held "alice" [ ephemeral_id ] with
        | Ok () -> ()
        | Error detail -> fail detail);
       check bool "the owner's file is now durable" true
         (retention () = Attachment_store.Durable);
       (* A voice message must be sound MASC can transcode. *)
       let voice id =
         Masc.Keeper_tool_in_process_runtime.For_testing.discord_files_held
           ~base_path ~keeper:"alice" (SP.Voice_message id)
       in
       let midi_id = alice_file ~mime:"audio/midi" ~filename:"riff.mid" tiny_midi in
       check bool "a MIDI voice message is refused" true (Result.is_error (voice midi_id));
       check bool "the refused MIDI file stays ephemeral" true
         (retention_of midi_id = ephemeral);
       let png_id = alice_file ~mime:"image/png" ~filename:"dog.png" (tiny_png ^ "dog") in
       check bool "an image voice message is refused" true (Result.is_error (voice png_id));
       check bool "the refused image stays ephemeral" true (retention_of png_id = ephemeral);
       let wav_id = alice_file ~mime:"audio/wav" ~filename:"hello.wav" tiny_wav in
       (match voice wav_id with
        | Ok () -> ()
        | Error detail -> fail detail);
       check bool "the voice message's sound is now durable" true
         (retention_of wav_id = Attachment_store.Durable))

(* keeper_voice_speak's clip becomes the Keeper's ephemeral attachment, and a
   voice post naming that id passes the check before approval. A clip that
   cannot be read is reported in the result, not raised. *)
let test_spoken_clip_is_a_voice_message_file () =
  let base_path = Filename.temp_dir "surface-post-spoken-" "" in
  Eio_main.run @@ fun env ->
  Fun.protect
    ~finally:(fun () -> Fs_compat.remove_tree base_path)
    (fun () ->
       if not (Fs_compat.has_fs ()) then Fs_compat.set_fs (Eio.Stdenv.fs env);
       let spoken audio_file =
         Masc.Keeper_tool_voice_runtime.For_testing.with_clip_attachment
           ~base_dir:base_path ~keeper:"alice" ~audio_file
           [ ("status", `String "spoken") ]
       in
       let clip = Filename.concat base_path "reply.wav" in
       Fs_compat.save_file clip tiny_wav;
       let open Yojson.Safe.Util in
       let result = spoken clip in
       check string "the speak result is kept" "spoken"
         (result |> member "status" |> to_string);
       let id = result |> member "attachment_id" |> to_string in
       let store = Attachment_store.create ~base_path in
       (match Attachment_store.get_meta store ~id with
        | Ok (Some (meta : Attachment_store.meta)) ->
          check string "stored as WAV, read from the bytes" "audio/wav" meta.mime_type;
          check bool "the Keeper's ephemeral file" true
            (meta.retention = Attachment_store.Ephemeral { keeper = "alice" })
        | Ok None -> fail "the clip is not in the attachment store"
        | Error error -> fail (Attachment_store.get_error_to_string error));
       (match
          Masc.Keeper_tool_in_process_runtime.For_testing.discord_files_held
            ~base_path ~keeper:"alice" (SP.Voice_message id)
        with
        | Ok () -> ()
        | Error detail -> fail detail);
       let unread = spoken (Filename.concat base_path "gone.wav") in
       check bool "an unreadable clip has no attachment_id" true
         (unread |> member "attachment_id" = `Null);
       check bool "and says why" true
         (match unread |> member "attachment_error" with
          | `String detail -> String.length detail > 0
          | _ -> false))

(* The approved input is what the replay sends after approval: the files a
   post names survive it in order, a voice message stays a voice message, and
   a text-only post's input has no file keys at all. *)
let test_approved_discord_input_carries_files () =
  let id c = "att_" ^ String.make 64 c in
  let input files =
    Masc.Keeper_connector_post_replay.connector_post_gate_input
      ~connector:"discord" ~channel_id:"123" ~content:"그림이에요"
      ~mention_user_ids:[] ~discord_files:files ()
  in
  let round_trip files =
    match
      Masc.Keeper_connector_post_replay.connector_post_replay_of_gate_input
        (input files)
    with
    | Ok (Masc.Keeper_connector_post_replay.Replay_discord_post { files; _ }) -> files
    | Ok _ -> fail "a Discord post decoded as another connector"
    | Error detail -> fail detail
  in
  check bool "approved files keep their order" true
    (round_trip (SP.Files (id 'b', [ id 'a' ])) = SP.Files (id 'b', [ id 'a' ]));
  check bool "an approved voice message stays one" true
    (round_trip (SP.Voice_message (id 'c')) = SP.Voice_message (id 'c'));
  (match input SP.Text_only with
   | `Assoc fields ->
     check bool "text-only input names no files" false
       (List.mem_assoc "attachment_ids" fields || List.mem_assoc "as_voice_message" fields)
   | _ -> fail "approved input is not an object");
  match
    Masc.Keeper_connector_post_replay.connector_post_replay_of_gate_input
      (`Assoc
         [ "connector", `String "discord"; "channel_id", `String "123"
         ; "content", `String "x"; "mention_user_ids", `List []
         ; "attachment_ids", `List [ `String "att_xyz" ]
         ])
  with
  | Error _ -> ()
  | Ok _ -> fail "an approved input with a malformed id decoded"

let test_blocks_args_decode () =
  check bool "absent decodes to None" true
    (SP.blocks_of_args ~surface:"slack" (`Assoc []) = Ok None);
  (match
     SP.blocks_of_args ~surface:"slack"
       (`Assoc [ ("blocks", `List [ block () ]) ])
   with
   | Ok (Some [ _ ]) -> ()
   | Ok _ | Error _ -> fail "one valid block was rejected");
  (match
     SP.blocks_of_args ~surface:"discord"
       (`Assoc [ ("blocks", `List [ block () ]) ])
   with
   | Error _ -> ()
   | Ok _ -> fail "blocks on a non-Slack surface were accepted");
  (match
     SP.blocks_of_args ~surface:"slack" (`Assoc [ ("blocks", `List []) ])
   with
   | Error _ -> ()
   | Ok _ -> fail "empty blocks array was accepted");
  (match
     SP.blocks_of_args ~surface:"slack"
       (`Assoc [ ("blocks", `List [ `String "not-a-block" ]) ])
   with
   | Error _ -> ()
   | Ok _ -> fail "non-object block was accepted");
  (match
     SP.blocks_of_args ~surface:"slack"
       (`Assoc [ ("blocks", `List [ `Assoc [ ("text", `String "x") ] ]) ])
   with
   | Error _ -> ()
   | Ok _ -> fail "block without a type member was accepted");
  let too_many =
    List.init (SP.max_rich_blocks + 1) (fun _ -> block ())
  in
  match
    SP.blocks_of_args ~surface:"slack" (`Assoc [ ("blocks", `List too_many) ])
  with
  | Error _ -> ()
  | Ok _ -> fail "more than max_rich_blocks blocks were accepted"

let test_resolve_explicit_thread_ts_wins_over_continuation () =
  let continuation_channel =
    match
      Keeper_continuation_channel.slack
        ~team_id:(Some "team")
        ~channel_id:"BBB"
        ~thread_ts:(Some "continuation-thread")
        ~user_id:"user"
    with
    | Ok channel -> channel
    | Error message -> fail message
  in
  check (result target string) "explicit thread_ts wins"
    (Ok
       (SP.To_slack
          { channel_id = "BBB"
          ; thread_ts = Some "explicit-thread"
          ; blocks = None
          }))
    (resolve ~surface:"slack" ~channel_id:None ~continuation_channel
       ~requested_thread_ts:"explicit-thread"
       ~bound_discord_channels:[] ~bound_slack_channels:[ "BBB" ] ())

let test_resolve_explicit_thread_ts_without_continuation () =
  check (result target string) "explicit thread_ts travels alone"
    (Ok
       (SP.To_slack
          { channel_id = "AAA"
          ; thread_ts = Some "explicit-thread"
          ; blocks = None
          }))
    (resolve ~surface:"slack" ~channel_id:None
       ~requested_thread_ts:"explicit-thread"
       ~bound_discord_channels:[] ~bound_slack_channels:[ "AAA" ] ())


(* ── resolve_bound_channel_reference ─────────────────────────────── *)

let ref names bound requested =
  SP.resolve_bound_channel_reference ~names ~bound requested
;;

let test_channel_reference_resolution () =
  let names = [ ("C1", "dev-team"); ("C2", "release-deployment") ] in
  let bound = [ "C1"; "C2" ] in
  check (option string) "plain id passes through"
    (Some "C1") (ref names bound "C1");
  check (option string) "whitespace is trimmed around an id"
    (Some "C1") (ref names bound " C1 ");
  check (option string) "bare name resolves to the bound id"
    (Some "C2") (ref names bound "release-deployment");
  check (option string) "hash-prefixed name resolves to the bound id"
    (Some "C1") (ref names bound "#dev-team");
  check (option string) "name case must match exactly"
    None (ref names bound "#Dev-Team");
  check (option string) "unknown name does not resolve"
    None (ref names bound "#unknown");
  (* A name matching an id of a channel that is NOT bound must not resolve:
     the binding contract, not the store, decides where a post may land. *)
  let wider_names = names @ [ ("C3", "ops") ] in
  check (option string) "unbound channel's name never resolves"
    None (ref wider_names bound "ops");
  check (option string) "unbound channel's id returns None (caller passes it through)"
    None (ref wider_names bound "C3");
  (* Ambiguity resolves to nothing: two bound channels sharing a name must
     not pick one silently. *)
  let ambiguous_names = names @ [ ("C2", "dev-team") ] in
  check (option string) "a name held by two bound channels resolves to none"
    None (ref ambiguous_names bound "#dev-team");
  check (option string) "space after the hash is trimmed away"
    (Some "C1") (ref names bound "# dev-team")
;;

let () =
  run "keeper_surface_post"
    [
      ( "resolve_target",
        [
          test_case "channel reference resolution" `Quick
            test_channel_reference_resolution;
          test_case "dashboard always resolves" `Quick
            test_dashboard_always_resolves;
          test_case "discord unbound is an error" `Quick
            test_discord_unbound_is_error;
          test_case "single binding resolves implicitly" `Quick
            test_discord_single_binding_resolves_implicitly;
          test_case "multiple bindings require channel_id" `Quick
            test_discord_multiple_bindings_require_channel_id;
          test_case "Discord continuation selects exact bound channel" `Quick
            test_discord_continuation_selects_exact_bound_channel;
          test_case "Discord thread continuation stays in thread" `Quick
            test_discord_thread_continuation_stays_in_thread;
          test_case "foreign explicit thread is an error" `Quick
            test_discord_thread_foreign_explicit_channel_is_error;
          test_case "mismatched continuation stays ambiguous" `Quick
            test_mismatched_continuation_does_not_select_channel;
          test_case "foreign channel_id is an error" `Quick
            test_discord_foreign_channel_id_is_error;
          test_case "slack unbound is an error" `Quick
            test_slack_unbound_is_error;
          test_case "slack single binding resolves implicitly" `Quick
            test_slack_single_binding_resolves_implicitly;
          test_case "slack multiple bindings require channel_id" `Quick
            test_slack_multiple_bindings_require_channel_id;
          test_case "Slack continuation selects exact bound channel" `Quick
            test_slack_continuation_selects_exact_bound_channel;
          test_case "slack foreign channel_id is an error" `Quick
            test_slack_foreign_channel_id_is_error;
          test_case "missing native origin and unknown surface are errors" `Quick
            test_missing_native_origin_and_unknown_surface_are_errors;
        ] );
      ( "set_blocks",
        [
          test_case "attaches blocks to slack target" `Quick
            test_set_blocks_attaches_to_slack;
          test_case "ignores non-slack targets" `Quick
            test_set_blocks_ignores_other_targets;
        ] );
      ( "mentions",
        [ test_case "Slack uses stable ids" `Quick
            test_slack_mentions_require_stable_ids
        ; test_case "Discord rejects named or broad targets" `Quick
            test_discord_mentions_reject_broad_or_named_targets
        ; test_case "dashboard rejects connector mentions" `Quick
            test_dashboard_rejects_nonempty_mentions
        ; test_case "requires exact resolved target roster" `Quick
            test_mentions_require_exact_resolved_target_roster
        ] );
      ( "thread and blocks args",
        [
          test_case "thread_ts decode closes its domain" `Quick
            test_thread_ts_args_decode;
          test_case "blocks decode closes its domain" `Quick
            test_blocks_args_decode;
          test_case "attachment_ids and as_voice_message decode closes its domain" `Quick
            test_discord_files_args_decode;
          test_case "approved Discord input carries files and voice" `Quick
            test_approved_discord_input_carries_files;
          test_case "attachments are held before approval" `Quick
            test_discord_attachments_held_before_approval;
          test_case "a spoken clip is a voice message file" `Quick
            test_spoken_clip_is_a_voice_message_file;
          test_case "explicit thread_ts wins over continuation" `Quick
            test_resolve_explicit_thread_ts_wins_over_continuation;
          test_case "explicit thread_ts travels without continuation" `Quick
            test_resolve_explicit_thread_ts_without_continuation;
        ] );
      ( "delivery target",
        [
          test_case "json round trip" `Quick
            test_delivery_target_json_round_trip;
          test_case "decode rejects widened input" `Quick
            test_delivery_target_decode_rejects_widened_input;
          test_case "post target maps to destination coordinates" `Quick
            test_delivery_target_of_post_target_drops_payload_only;
        ] );
      ( "assistant append",
        [
          test_case "persists assistant line with typed surface" `Quick
            test_assistant_message_persists_with_typed_surface;
          test_case "replay preserves Discord/Slack surface and conversation metadata" `Quick
            test_replay_connector_post_preserves_discord_and_slack_coordinates;
        ] );
    ]

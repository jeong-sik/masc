(* RFC-0223 P4 — Keeper_surface_post target resolution + assistant-only
   store append.

   resolve_target is pure (surface label + channel arg + bindings in,
   target or error out). The Discord transport path needs a live REST
   client and stays operational; the dashboard persistence path is
   covered against a temp store here. *)

open Alcotest

module Store = Masc.Keeper_chat_store
module SP = Masc.Keeper_surface_post

let target_pp fmt = function
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

let test_unsupported_surface_is_error () =
  List.iter
    (fun surface ->
      match resolve ~surface ~channel_id:None ~bound_discord_channels:[] () with
      | Error message ->
          check bool (surface ^ " unsupported") true
            (Astring.String.is_infix ~affix:"not supported" message)
      | Ok _ -> fail (surface ^ " must not resolve in P4"))
    [ "telegram"; "openclaw" ]

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

let test_terminal_receipt_requires_exact_supported_route () =
  let discord ?reply_to_message_id channel_id =
    match
      Keeper_continuation_channel.discord
        ~guild_id:(Some "guild")
        ~channel_id
        ~parent_channel_id:None
        ~thread_id:None
        ?reply_to_message_id
        ~user_id:"user"
        ()
    with
    | Ok channel -> channel
    | Error message -> fail message
  in
  check bool "same direct Discord channel" true
    (SP.matches_continuation_route
       (SP.To_discord { channel_id = "D1" })
       (discord "D1"));
  check bool "different Discord channel" false
    (SP.matches_continuation_route
       (SP.To_discord { channel_id = "D2" })
       (discord "D1"));
  (* PR #28225 review (comment 3761300281): Discord channel_id is the innermost
     conversation locus, so a same-channel post delivers a reply-scoped
     continuation. reply_to_message_id names the trigger, not a destination. *)
  check bool "Discord post to the channel delivers a reply-scoped continuation"
    true
    (SP.matches_continuation_route
       (SP.To_discord { channel_id = "D1" })
       (discord ~reply_to_message_id:"message-1" "D1"));
  let slack ?thread_ts channel_id =
    match
      Keeper_continuation_channel.slack
        ~team_id:(Some "team")
        ~channel_id
        ~thread_ts
        ~user_id:"user"
    with
    | Ok channel -> channel
    | Error message -> fail message
  in
  check bool "Slack post to the channel delivers an unthreaded continuation" true
    (SP.matches_continuation_route
       (SP.To_slack { channel_id = "C1"; thread_ts = None; blocks = None })
       (slack "C1"));
  (* Slack thread_ts is a destination distinct from the channel root, so a
     root post does not prove delivery of a threaded Slack continuation;
     recovery settles it. *)
  check bool "Slack channel post does not satisfy a threaded continuation" false
    (SP.matches_continuation_route
       (SP.To_slack { channel_id = "C1"; thread_ts = None; blocks = None })
       (slack ~thread_ts:"1700000000.000100" "C1"));
  check bool "Slack thread post delivers the same threaded continuation" true
    (SP.matches_continuation_route
       (SP.To_slack
          { channel_id = "C1"
          ; thread_ts = Some "1700000000.000100"
          ; blocks = None
          })
       (slack ~thread_ts:"1700000000.000100" "C1"));
  check bool "Slack thread post does not satisfy a different thread" false
    (SP.matches_continuation_route
       (SP.To_slack
          { channel_id = "C1"
          ; thread_ts = Some "1700000000.000100"
          ; blocks = None
          })
       (slack ~thread_ts:"1700000000.000200" "C1"));
  check bool "Slack thread post does not satisfy an unthreaded continuation"
    false
    (SP.matches_continuation_route
       (SP.To_slack
          { channel_id = "C1"
          ; thread_ts = Some "1700000000.000100"
          ; blocks = None
          })
       (slack "C1"));
  check bool "keeper-global dashboard post has no exact thread receipt" false
    (SP.matches_continuation_route
       SP.To_dashboard
       (match Keeper_continuation_channel.dashboard ~thread_id:"thread-1" with
        | Ok channel -> channel
        | Error message -> fail message))

(* ── delivery_target codec ──────────────────────────────────────── *)

let delivery_target_pp fmt = function
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
  ; kind = Store.Row_kind.Utterance
  ; turn_ref = None
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
  check (option string) "unbound channel's id passes through unresolved"
    (Some "C3") (ref wider_names bound "C3")
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
          test_case "unsupported surfaces are errors" `Quick
            test_unsupported_surface_is_error;
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
          test_case "explicit thread_ts wins over continuation" `Quick
            test_resolve_explicit_thread_ts_wins_over_continuation;
          test_case "explicit thread_ts travels without continuation" `Quick
            test_resolve_explicit_thread_ts_without_continuation;
        ] );
      ( "terminal receipt",
        [
          test_case "requires exact supported route" `Quick
            test_terminal_receipt_requires_exact_supported_route;
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
        ] );
    ]

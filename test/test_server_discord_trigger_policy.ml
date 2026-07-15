(* F941 — the server's resolved-config trigger-policy parser must
   delegate to the single canonical grammar in [Discord_gateway_state]
   so production config and the (separately test-covered) grammar can
   never drift apart. Before this, a permissive duplicate parser lived
   in [Server_discord_in_process_gateway]; adding a new policy variant
   to the strict grammar would have left prod silently coercing it.

   These assertions pin the wrapper's contract: an empty value is unset
   (=> default), the four valid forms parse through to the same variant
   the strict grammar yields, and an unparseable value falls back to the
   default rather than producing a half-formed policy. *)

open Alcotest
module G = Server_discord_in_process_gateway
module State = Channel_gate_discord_state

external unsetenv : string -> unit = "masc_test_unsetenv"

let with_env key value f =
  let previous = Sys.getenv_opt key in
  Fun.protect
    ~finally:(fun () ->
      match previous with
      | Some previous -> Unix.putenv key previous
      | None -> unsetenv key)
    (fun () ->
      Unix.putenv key value;
      f ())
;;

let rec rm_rf path =
  if Sys.file_exists path then
    if Sys.is_directory path then begin
      Sys.readdir path
      |> Array.iter (fun name -> rm_rf (Filename.concat path name));
      Unix.rmdir path
    end
    else Sys.remove path
;;

let with_temp_dir f =
  let dir =
    Filename.concat
      (Filename.get_temp_dir_name ())
      (Printf.sprintf "masc-discord-preworker-%d-%d" (Unix.getpid ())
         (Random.bits ()))
  in
  Unix.mkdir dir 0o700;
  Fun.protect ~finally:(fun () -> rm_rf dir) (fun () -> f dir)
;;

let ps p = Discord_gateway_state.trigger_policy_to_string p
let default_str = ps G.default_trigger_policy

let test_empty_is_default () =
  check string "empty => default" default_str (ps (G.parse_trigger_policy ""))

let test_whitespace_is_default () =
  check string "whitespace => default" default_str
    (ps (G.parse_trigger_policy "   "))

let test_valid_values_parse_through () =
  (* Each valid form yields exactly what the strict grammar yields,
     proving the wrapper delegates rather than re-implementing. *)
  List.iter
    (fun raw ->
      let expected =
        match Discord_gateway_state.parse_trigger_policy raw with
        | Ok p -> ps p
        | Error msg -> failf "strict grammar rejected %S: %s" raw msg
      in
      check string (Printf.sprintf "%S parses through" raw) expected
        (ps (G.parse_trigger_policy raw)))
    [ "mention_only"; "mention_or_thread"; "all"; "user_only:VINCENT" ]

let test_unknown_falls_back_to_default () =
  (* A typo must not produce a policy the operator did not write. The
     wrapper logs (via Log.Server) and returns the default. *)
  check string "typo => default" default_str
    (ps (G.parse_trigger_policy "mention_ony"))

let test_user_only_empty_id_falls_back () =
  (* The strict grammar rejects an empty id; the wrapper falls back to
     the default instead of constructing User_only "". *)
  check string "user_only: empty id => default" default_str
    (ps (G.parse_trigger_policy "user_only:"))

let discord_message ~message_id =
  Discord_gateway_client.Message_create
    { channel_id = "C123"
    ; guild_id = Some "G123"
    ; message_id
    ; author_id = "U123"
    ; author_name = Some "operator"
    ; content = "wake the keeper"
    ; raw_content = "wake the keeper"
    ; resolved_mentions = []
    ; mention_user_ids = []
    ; mentions_bot = true
    ; explicit_mentions_bot = true
    ; author_is_bot = false
    ; message_reference_channel_id = None
    ; message_reference_message_id = None
    ; referenced_message_author_id = None
    }
;;

let test_durable_accept_precedes_delivery_handoff () =
  with_temp_dir @@ fun base_dir ->
  with_env "MASC_DISCORD_BINDING_STORE_PATH"
    (Filename.concat base_dir "bindings.json")
  @@ fun () ->
  with_env "MASC_DISCORD_BINDING_AUDIT_PATH"
    (Filename.concat base_dir "audit.jsonl")
  @@ fun () ->
  with_env "MASC_DISCORD_NAMES_PATH" (Filename.concat base_dir "names.json")
  @@ fun () ->
  (match State.bind ~channel_id:"C123" ~keeper_name:"luna" ~actor_name:"test" with
   | Error detail -> fail detail
   | Ok _ -> ());
  Eio_main.run @@ fun _env ->
  Eio.Switch.run @@ fun sw ->
  let observed, resolve_observed = Eio.Promise.create () in
  let ingress =
    Connector_ingress_lane.create ~sw
      ~on_failure:(fun failure -> Eio.Promise.resolve resolve_observed failure)
      ()
  in
  let accepted_before_delivery = ref false in
  let observed_delivery = ref None in
  let dispatch ~channel:_ ~channel_user_id:_ ~channel_user_name:_
      ~channel_workspace_id:_ ~keeper_name:_ ~idempotency_key:_ ~metadata:_
      ~content:_ =
    accepted_before_delivery := true;
    Gate_protocol.Reply
      { content = "queued"
      ; structured = None
      ; stats = None
      ; message_request = None
      }
  in
  let dispatch_for_delivery delivery =
    observed_delivery := Some delivery;
    dispatch
  in
  G.For_testing.submit_triggered_event
    ~deliver:(fun () ->
      if not !accepted_before_delivery then
        failwith "delivery ran before durable accept";
      failwith "observe Discord ingress identity")
    ingress ~dispatch_for_delivery ~base_dir
    (discord_message ~message_id:"discord-exact-123");
  check bool "accept completed before handoff" true !accepted_before_delivery;
  (match !observed_delivery with
   | Some
       { Gate_keeper_backend.source =
           Keeper_chat_queue.Discord { channel_id; user_id }
       ; surface =
           Surface_ref.Discord
             { guild_id; channel_id = surface_channel_id; parent_channel_id
             ; thread_id }
       ; conversation_id
       ; external_message_id
       } ->
     check string "Discord delivery channel" "C123" channel_id;
     check string "Discord delivery actor" "U123" user_id;
     check string "Discord surface channel" "C123" surface_channel_id;
     check (option string) "Discord surface guild" (Some "G123") guild_id;
     check (option string) "Discord surface parent" None parent_channel_id;
     check (option string) "Discord surface thread" None thread_id;
     check (option string) "Discord conversation identity"
       (Some "discord:G123:channel:C123") conversation_id;
     check (option string) "Discord external event identity"
       (Some "discord-exact-123") external_message_id
   | Some _ -> fail "Discord leaf emitted another connector projection"
   | None -> fail "Discord leaf did not emit a delivery projection");
  let failure = Eio.Promise.await observed in
  check string "exact Discord message id" "discord-exact-123"
    failure.Connector_ingress_lane.event_id.opaque_id;
  check string "connector source" State.channel failure.event_id.source;
  check bool "triggered route" true
    (failure.event_id.route = Connector_ingress_lane.Triggered);
  check bool "delivery phase" true
    (failure.event_id.phase = Connector_ingress_lane.Delivery);
  match failure.lane with
  | Connector_ingress_lane.Keeper_lane keeper_name ->
    check string "resolved Keeper lane" "luna" keeper_name
  | Connector_ingress_lane.Connector_lane connector_id ->
    failf "expected Keeper lane, got connector:%s" connector_id
;;

let test_accept_failure_does_not_kill_discord_ingress () =
  with_temp_dir @@ fun base_dir ->
  with_env "MASC_DISCORD_BINDING_STORE_PATH"
    (Filename.concat base_dir "bindings.json")
  @@ fun () ->
  with_env "MASC_DISCORD_BINDING_AUDIT_PATH"
    (Filename.concat base_dir "audit.jsonl")
  @@ fun () ->
  with_env "MASC_DISCORD_NAMES_PATH" (Filename.concat base_dir "names.json")
  @@ fun () ->
  (match State.bind ~channel_id:"C123" ~keeper_name:"luna" ~actor_name:"test" with
   | Error detail -> fail detail
   | Ok _ -> ());
  Eio_main.run @@ fun _env ->
  Eio.Switch.run @@ fun sw ->
  let observed_failure = ref None in
  let ingress =
    Connector_ingress_lane.create
      ~sw
      ~on_failure:(fun failure -> observed_failure := Some failure)
      ()
  in
  let accept_count = ref 0 in
  let dispatch ~channel:_ ~channel_user_id:_ ~channel_user_name:_
      ~channel_workspace_id:_ ~keeper_name:_ ~idempotency_key:_ ~metadata:_
      ~content:_ =
    incr accept_count;
    if !accept_count = 1
    then failwith "first Discord accept crashed"
    else
      Gate_protocol.Reply
        { content = "queued"; structured = None; stats = None; message_request = None }
  in
  let dispatch_for_delivery _delivery = dispatch in
  G.For_testing.submit_triggered_event
    ~deliver:(fun () -> ())
    ingress ~dispatch_for_delivery ~base_dir
    (discord_message ~message_id:"discord-accept-failed");
  G.For_testing.submit_triggered_event
    ~deliver:(fun () -> ())
    ingress ~dispatch_for_delivery ~base_dir
    (discord_message ~message_id:"discord-accept-next");
  check int "next event was accepted" 2 !accept_count;
  match !observed_failure with
  | None -> fail "Discord accept failure was not observed"
  | Some failure ->
    check string "failed source event" "discord-accept-failed"
      failure.Connector_ingress_lane.event_id.opaque_id;
    check string "connector source" State.channel failure.event_id.source;
    check bool "triggered route" true
      (failure.event_id.route = Connector_ingress_lane.Triggered);
    check bool "acceptance phase" true
      (failure.event_id.phase = Connector_ingress_lane.Acceptance);
    (match failure.lane with
     | Connector_ingress_lane.Keeper_lane keeper_name ->
       check string "failed Keeper lane" "luna" keeper_name
     | Connector_ingress_lane.Connector_lane connector_id ->
       failf "expected Keeper lane, got connector:%s" connector_id)
;;

let () =
  run "server_discord_trigger_policy"
    [ ( "parse_trigger_policy"
      , [ test_case "empty => default" `Quick test_empty_is_default
        ; test_case "whitespace => default" `Quick test_whitespace_is_default
        ; test_case "valid values parse through strict grammar" `Quick
            test_valid_values_parse_through
        ; test_case "unknown => default (no silent coercion)" `Quick
            test_unknown_falls_back_to_default
        ; test_case "user_only empty id => default" `Quick
            test_user_only_empty_id_falls_back
        ] )
    ; ( "ingress handoff"
      , [ test_case "durable accept precedes Discord delivery" `Quick
            test_durable_accept_precedes_delivery_handoff
        ; test_case "accept failure preserves next Discord event" `Quick
            test_accept_failure_does_not_kill_discord_ingress
        ] )
    ]

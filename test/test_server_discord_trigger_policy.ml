(* F941 / masc#25123 — the server's trigger-policy loading is typed and
   fail-closed, mirroring the Slack sibling: a missing runtime.toml or a
   missing key is "unset" (default applies); unreadable/malformed TOML, a
   wrong field type, an invalid policy value, or an invalid
   MASC_DISCORD_TRIGGER_POLICY env value is an explicit load error — the
   gateway must not boot on a policy the operator did not write. Env wins
   over TOML, matching the precedence config/runtime.toml documents for this
   key. *)

open Alcotest
open Masc
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

let write_file path content =
  Out_channel.with_open_bin path (fun oc -> output_string oc content)
;;

(* -- load_trigger_policy_from_toml: the TOML plane in isolation -- *)

let test_toml_missing_file_is_unset () =
  with_temp_dir @@ fun dir ->
  match
    G.load_trigger_policy_from_toml
      ~path:(Filename.concat dir "runtime.toml")
  with
  | Ok G.Runtime_toml_missing -> ()
  | Ok _ -> fail "expected Runtime_toml_missing"
  | Error e -> failf "expected missing, got error: %s"
                 (G.trigger_policy_load_error_to_string e)

let test_toml_missing_key_is_unset () =
  with_temp_dir @@ fun dir ->
  let path = Filename.concat dir "runtime.toml" in
  write_file path "[discord]\nother = \"x\"\n";
  match G.load_trigger_policy_from_toml ~path with
  | Ok G.Trigger_policy_missing -> ()
  | Ok _ -> fail "expected Trigger_policy_missing"
  | Error e -> failf "expected missing key, got error: %s"
                 (G.trigger_policy_load_error_to_string e)

let test_toml_empty_value_is_unset () =
  with_temp_dir @@ fun dir ->
  let path = Filename.concat dir "runtime.toml" in
  write_file path "[discord]\ntrigger_policy = \"  \"\n";
  match G.load_trigger_policy_from_toml ~path with
  | Ok G.Trigger_policy_missing -> ()
  | Ok _ -> fail "expected Trigger_policy_missing for blank value"
  | Error e -> failf "expected unset, got error: %s"
                 (G.trigger_policy_load_error_to_string e)

let test_toml_valid_value_loads () =
  with_temp_dir @@ fun dir ->
  let path = Filename.concat dir "runtime.toml" in
  write_file path "[discord]\ntrigger_policy = \"mention_only\"\n";
  match G.load_trigger_policy_from_toml ~path with
  | Ok (G.Trigger_policy_loaded p) ->
    check string "loaded policy" "mention_only" (ps p)
  | Ok _ -> fail "expected loaded policy"
  | Error e -> failf "expected policy, got error: %s"
                 (G.trigger_policy_load_error_to_string e)

let test_toml_malformed_is_load_error () =
  with_temp_dir @@ fun dir ->
  let path = Filename.concat dir "runtime.toml" in
  write_file path "[discord\ntrigger_policy = \"mention_only\"\n";
  match G.load_trigger_policy_from_toml ~path with
  | Error (G.Runtime_toml_invalid _) -> ()
  | Error e -> failf "expected Runtime_toml_invalid, got: %s"
                 (G.trigger_policy_load_error_to_string e)
  | Ok _ -> fail "malformed TOML must not load"

let test_toml_wrong_type_is_load_error () =
  with_temp_dir @@ fun dir ->
  let path = Filename.concat dir "runtime.toml" in
  write_file path "[discord]\ntrigger_policy = 7\n";
  match G.load_trigger_policy_from_toml ~path with
  | Error (G.Trigger_policy_invalid _) -> ()
  | Error e -> failf "expected Trigger_policy_invalid, got: %s"
                 (G.trigger_policy_load_error_to_string e)
  | Ok _ -> fail "a non-string trigger_policy must not load"

let test_toml_invalid_policy_is_load_error () =
  with_temp_dir @@ fun dir ->
  let path = Filename.concat dir "runtime.toml" in
  write_file path "[discord]\ntrigger_policy = \"mention_ony\"\n";
  match G.load_trigger_policy_from_toml ~path with
  | Error (G.Trigger_policy_invalid _) -> ()
  | Error e -> failf "expected Trigger_policy_invalid, got: %s"
                 (G.trigger_policy_load_error_to_string e)
  | Ok _ -> fail "a typo policy must not load"

(* -- resolved_trigger_policy: env > TOML > default -- *)

(* Point the config resolver at a temp config root so the TOML plane is
   under test control. MASC_CONFIG_DIR is the documented override the
   sandbox suites already use. *)
let with_config_root dir f =
  with_env "MASC_CONFIG_DIR" dir @@ fun () ->
  with_env "MASC_TEST_ALLOW_CONFIG_PATH_OVERRIDE" "1" @@ fun () ->
  Config_dir_resolver.reset ();
  Fun.protect ~finally:Config_dir_resolver.reset f

let test_env_valid_wins_over_toml () =
  with_temp_dir @@ fun dir ->
  write_file (Filename.concat dir "runtime.toml")
    "[discord]\ntrigger_policy = \"all\"\n";
  with_config_root dir @@ fun () ->
  with_env "MASC_DISCORD_TRIGGER_POLICY" "mention_only" @@ fun () ->
  match G.resolved_trigger_policy () with
  | Ok p -> check string "env wins over TOML" "mention_only" (ps p)
  | Error e -> failf "expected env policy, got error: %s"
                 (G.trigger_policy_load_error_to_string e)

let test_env_invalid_is_load_error () =
  with_temp_dir @@ fun dir ->
  with_config_root dir @@ fun () ->
  with_env "MASC_DISCORD_TRIGGER_POLICY" "mention_ony" @@ fun () ->
  match G.resolved_trigger_policy () with
  | Error (G.Trigger_policy_env_invalid _) -> ()
  | Error e -> failf "expected env_invalid, got: %s"
                 (G.trigger_policy_load_error_to_string e)
  | Ok p -> failf "invalid env must not resolve, got %s" (ps p)

let test_env_unset_falls_to_toml () =
  with_temp_dir @@ fun dir ->
  write_file (Filename.concat dir "runtime.toml")
    "[discord]\ntrigger_policy = \"all\"\n";
  with_config_root dir @@ fun () ->
  with_env "MASC_DISCORD_TRIGGER_POLICY" "" @@ fun () ->
  match G.resolved_trigger_policy () with
  | Ok p -> check string "TOML applies when env unset" "all" (ps p)
  | Error e -> failf "expected TOML policy, got error: %s"
                 (G.trigger_policy_load_error_to_string e)

let test_all_unset_is_default () =
  with_temp_dir @@ fun dir ->
  with_config_root dir @@ fun () ->
  with_env "MASC_DISCORD_TRIGGER_POLICY" "" @@ fun () ->
  match G.resolved_trigger_policy () with
  | Ok p -> check string "default when nothing configured" default_str (ps p)
  | Error e -> failf "expected default, got error: %s"
                 (G.trigger_policy_load_error_to_string e)

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
  with_env Env_config_core.base_path_env_key base_dir @@ fun () ->
  with_env Env_config_core.base_path_input_env_key base_dir @@ fun () ->
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
       { source =
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
  check string "typed source" "discord_triggered" failure.event_id.source;
  match failure.lane with
  | Connector_ingress_lane.Keeper_lane keeper_name ->
    check string "resolved Keeper lane" "luna" keeper_name
  | Connector_ingress_lane.Connector_lane connector_id ->
    failf "expected Keeper lane, got connector:%s" connector_id
;;

let () =
  run "server_discord_trigger_policy"
    [ ( "toml_loader"
      , [ test_case "missing file => unset" `Quick test_toml_missing_file_is_unset
        ; test_case "missing key => unset" `Quick test_toml_missing_key_is_unset
        ; test_case "blank value => unset" `Quick test_toml_empty_value_is_unset
        ; test_case "valid value loads" `Quick test_toml_valid_value_loads
        ; test_case "malformed TOML => load error" `Quick
            test_toml_malformed_is_load_error
        ; test_case "wrong type => load error" `Quick
            test_toml_wrong_type_is_load_error
        ; test_case "invalid policy => load error" `Quick
            test_toml_invalid_policy_is_load_error
        ] )
    ; ( "resolved_precedence"
      , [ test_case "valid env wins over TOML" `Quick test_env_valid_wins_over_toml
        ; test_case "invalid env => load error (no silent default)" `Quick
            test_env_invalid_is_load_error
        ; test_case "unset env falls to TOML" `Quick test_env_unset_falls_to_toml
        ; test_case "all unset => default" `Quick test_all_unset_is_default
        ] )
    ; ( "ingress handoff"
      , [ test_case "durable accept precedes Discord delivery" `Quick
            test_durable_accept_precedes_delivery_handoff
        ] )
    ]

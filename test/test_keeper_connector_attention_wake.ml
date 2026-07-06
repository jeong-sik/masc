(* test_keeper_connector_attention_wake.ml —
   RFC-connector-ambient-attention-wake P1.

   Pins the wake decision plumbing: a Connector_attention_stimulus event-queue
   trigger yields a Run { Connector_attention_pending } reactive decision, the
   same path Mention_pending / Bootstrap_stimulus take. The Discord ambient
   producer is pinned below through Server_discord_in_process_gateway.For_testing,
   so this file covers both the producer and the decision-layer intake. *)

open Alcotest
module WO = Masc.Keeper_world_observation
module A = Masc.Keeper_external_attention
module Q = Keeper_event_queue
module Gateway = Server_discord_in_process_gateway
module Discord_state = Channel_gate_discord_state

let contains ~needle haystack =
  let nl = String.length needle in
  let hl = String.length haystack in
  let rec loop i =
    i + nl <= hl
    && (String.equal (String.sub haystack i nl) needle || loop (i + 1))
  in
  nl = 0 || loop 0

(* keeper_cycle_decision resolves a runtime id unconditionally (RFC-0206 §2.1),
   so a minimal default runtime must exist — same setup the other cycle-decision
   unit tests use. *)
let runtime_toml =
  {|
[runtime]
default = "test_provider.test_model"

[providers.test_provider]
display-name = "Test Provider"
protocol = "openai-compatible-http"
endpoint = "http://127.0.0.1:1"

[models.test_model]
api-name = "test-model"
max-context = 8192
tools-support = true
streaming = true

[test_provider.test_model]
is-default = true
max-concurrent = 1
|}

let init_runtime_default_for_tests () =
  let path = Filename.temp_file "connector_attention_runtime_" ".toml" in
  let oc = open_out path in
  Fun.protect
    ~finally:(fun () -> close_out_noerr oc)
    (fun () -> output_string oc runtime_toml);
  match Runtime.init_default ~config_path:path with
  | Ok () -> ()
  | Error e -> Alcotest.failf "Runtime.init_default failed: %s" e

let with_env name value f =
  let previous = Sys.getenv_opt name in
  (match value with
   | Some v -> Unix.putenv name v
   | None -> Unix.putenv name "");
  Fun.protect
    ~finally:(fun () ->
      match previous with
      | Some v -> Unix.putenv name v
      | None -> Unix.putenv name "")
    f

let rm_rf path =
  let rec loop path =
    if Sys.file_exists path then
      if Sys.is_directory path then begin
        Sys.readdir path
        |> Array.iter (fun name -> loop (Filename.concat path name));
        Unix.rmdir path
      end
      else Sys.remove path
  in
  loop path

let with_temp_dir prefix f =
  let path = Filename.temp_file prefix "" in
  Sys.remove path;
  Unix.mkdir path 0o755;
  Fun.protect ~finally:(fun () -> rm_rf path) (fun () -> f path)

let with_discord_paths dir f =
  with_env "MASC_DISCORD_STATUS_PATH" (Some (Filename.concat dir "status.json"))
  @@ fun () ->
  with_env "MASC_DISCORD_BINDING_STORE_PATH"
    (Some (Filename.concat dir "bindings.json"))
  @@ fun () ->
  with_env "MASC_DISCORD_BINDING_AUDIT_PATH"
    (Some (Filename.concat dir "audit.jsonl"))
  @@ fun () ->
  with_env "MASC_DISCORD_NAMES_PATH" (Some (Filename.concat dir "names.json")) f

let with_boot_override name value f =
  let saved = Config_boot_overrides.get_opt name in
  Config_boot_overrides.set name value;
  Fun.protect
    ~finally:(fun () ->
      match saved with
      | Some prior -> Config_boot_overrides.set name prior
      | None -> Config_boot_overrides.clear name)
    f

let make_meta name =
  let json =
    `Assoc
      [ ("name", `String name)
      ; ("agent_name", `String ("agent-" ^ name))
      ; ("trace_id", `String ("trace-conn-" ^ name))
      ; ("goal", `String "connector attention wake test")
      ]
  in
  match Masc_test_deps.meta_of_json_fixture json with
  | Ok meta -> meta
  | Error err -> Alcotest.fail ("make_meta failed: " ^ err)

let discord_surface =
  A.Discord
    {
      guild_id = Some "guild-1";
      channel_id = "chan-1";
      parent_channel_id = None;
      thread_id = None;
    }

let external_attention_item ?(urgency = A.Ambient) ?(preview = "ambient TOKEN-123")
    () : A.item =
  let dedupe_key = "discord:discord:guild-1:channel:chan-1:msg-1" in
  {
    A.event_id = A.event_id_of_dedupe_key dedupe_key;
    dedupe_key;
    keeper_name = "conn-keeper";
    conversation =
      {
        conversation_id = "discord:guild-1:channel:chan-1";
        surface = discord_surface;
      };
    external_message =
      Some
        {
          surface = discord_surface;
          message_id = "msg-1";
          reply_to_message_id = None;
        };
    source_label = "discord";
    actor =
      {
        actor_id = Some "user-1";
        display_name = Some "Alex";
        authority = Masc.Keeper_chat_store.External;
      };
    urgency;
    content_preview = preview;
    content_ref = None;
    received_at = 123.0;
    metadata = [ ("route", "ambient") ];
  }

(* Quiet observation: no mention / board / scope trigger and no task backlog, so
   the ONLY reactive trigger is the injected event-queue one. *)
let quiet_obs : WO.world_observation =
  { pending_mentions = []
  ; pending_board_events = []
  ; pending_scope_messages = []
  ; idle_seconds = 0
  ; active_goals = []
  ; continuity_summary = ""
  ; context_ratio = lazy 0.0
  ; unclaimed_task_count = 0
  ; claimable_task_count = 0
  ; provider_capacity_blocked_task_count = 0
  ; failed_task_count = 0
  ; pending_verification_count = 0
  ; scheduled_automation = WO.empty_scheduled_automation_observation
  ; backlog_updated_since_last_scheduled_autonomous = false
  ; running_keeper_fiber_count = 1
  ; connected_surfaces = []
  }

let no_provider_cooldown ~keeper_name:_ ~runtime_id:_ = None

let reasons_of_verdict = function
  | WO.Run { reasons = first, rest } -> first :: rest
  | WO.Skip _ -> []

let decide ?(event_queue_triggers = []) () =
  WO.keeper_cycle_decision
    ~provider_cooldown_remaining_sec:no_provider_cooldown
    ~event_queue_triggers
    ~meta:(make_meta "conn-keeper")
    quiet_obs

let test_connector_attention_stimulus_drives_run () =
  let d = decide ~event_queue_triggers:[ WO.Connector_attention_stimulus ] () in
  check bool "connector attention stimulus drives a turn" true d.should_run;
  check bool "channel is Reactive" true (d.channel = WO.Reactive);
  check bool "verdict carries Connector_attention_pending" true
    (List.mem WO.Connector_attention_pending (reasons_of_verdict d.verdict))

(* Dormancy guard: with no stimulus and a quiet observation, the keeper does NOT
   reactively run on connector attention — the trigger is the only thing that
   introduces it. *)
let test_no_stimulus_no_connector_reason () =
  let d = decide () in
  check bool "no Connector_attention_pending without the stimulus" false
    (List.mem WO.Connector_attention_pending (reasons_of_verdict d.verdict))

(* The Connector_attention payload persists to / replays from the per-keeper
   event-queue snapshot, so its JSON codec must round-trip the event_id pointer. *)
let test_connector_attention_codec_roundtrips () =
  let s =
    { Q.post_id = "evt-77"
    ; urgency = Q.Normal
    ; arrived_at = 1.0
    ; payload = Q.Connector_attention { event_id = "evt-77" }
    }
  in
  match Q.stimulus_of_yojson (Q.stimulus_to_yojson s) with
  | Ok s' -> (
    match s'.Q.payload with
    | Q.Connector_attention { event_id } ->
      check string "event_id survives the JSON round-trip" "evt-77" event_id
    | _ -> check bool "round-trip payload stays Connector_attention" true false)
  | Error e -> check bool ("round-trip decode failed: " ^ e) true false

let test_discord_ambient_producer_enqueues_connector_attention () =
  Eio_main.run @@ fun _env ->
  with_temp_dir "connector-attention-producer" @@ fun dir ->
  with_discord_paths dir @@ fun () ->
  with_env "MASC_CONNECTOR_AMBIENT_WAKE_ENABLED" (Some "true") @@ fun () ->
  with_boot_override "MASC_CONNECTOR_AMBIENT_WAKE_ENABLED" "true" @@ fun () ->
  let base_path = Filename.concat dir "base" in
  Unix.mkdir base_path 0o755;
  let keeper_name = "conn-keeper" in
  let meta = make_meta keeper_name in
  Masc.Keeper_registry.clear ();
  Fun.protect
    ~finally:(fun () -> Masc.Keeper_registry.clear ())
    (fun () ->
      let entry = Masc.Keeper_registry.register ~base_path keeper_name meta in
      (match
         Discord_state.bind ~channel_id:"chan-1" ~keeper_name
           ~actor_name:"test"
       with
       | Ok _ -> ()
       | Error msg -> fail ("discord bind failed: " ^ msg));
      Gateway.For_testing.handle_ambient
        ~base_dir:base_path
        ~channel_id:"chan-1"
        ~guild_id:(Some "guild-1")
        ~message_id:"msg-ambient-1"
        ~author_id:"user-1"
        ~author_name:(Some "Alex")
        ~content:"ambient TOKEN-456";
      check bool "ambient wake flips keeper wake hint" true
        (Atomic.get entry.fiber_wakeup);
      let queue =
        Masc.Keeper_registry_event_queue.snapshot ~base_path keeper_name
        |> Q.to_list
      in
      check int "one connector attention stimulus enqueued" 1
        (List.length queue);
      match queue with
      | [ { Q.payload = Q.Connector_attention { event_id }; post_id; urgency; _ } ] ->
        check string "post id carries event id" event_id post_id;
        check bool "ambient urgency is low" true (urgency = Q.Low)
      | _ -> fail "expected a single Connector_attention stimulus")

let test_external_attention_projects_to_prompt_event () =
  let meta = make_meta "conn-keeper" in
  let item = external_attention_item () in
  let ev = WO.pending_board_event_of_external_attention ~meta item in
  check string "post id carries event id"
    ("connector-attention:" ^ item.A.event_id)
    ev.WO.post_id;
  check bool "title carries typed surface" true
    (contains ~needle:"External discord attention" ev.WO.title);
  check bool "preview carries connector message" true
    (contains ~needle:"TOKEN-123" ev.WO.preview);
  check bool "ambient is not an explicit mention" false ev.WO.explicit_mention;
  check bool "ambient stays observational" true
    (match ev.WO.provenance with
     | WO.Unknown -> true
     | _ -> false)

let () =
  init_runtime_default_for_tests ();
  run "connector_attention_wake"
    [ ( "decision",
        [ test_case "stimulus drives Run { Connector_attention_pending }" `Quick
            test_connector_attention_stimulus_drives_run
        ; test_case "dormant without the stimulus" `Quick
            test_no_stimulus_no_connector_reason
        ] )
    ; ( "codec",
        [ test_case "Connector_attention payload JSON round-trips" `Quick
            test_connector_attention_codec_roundtrips
        ] )
    ; ( "producer",
        [ test_case "Discord ambient message enqueues Connector_attention" `Quick
            test_discord_ambient_producer_enqueues_connector_attention
        ] )
    ; ( "projection",
        [ test_case "external attention becomes prompt event" `Quick
            test_external_attention_projects_to_prompt_event
        ] )
    ]

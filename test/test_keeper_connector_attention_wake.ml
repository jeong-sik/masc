(* test_keeper_connector_attention_wake.ml —
   RFC-connector-ambient-attention-wake P1.

   Pins the wake decision plumbing: a Connector_attention_stimulus event-queue
   trigger yields a Run { Connector_attention_pending } reactive decision, the
   same path Mention_pending / Bootstrap_stimulus take. Dormant in production —
   nothing enqueues this stimulus yet (P3 wires handle_ambient) — so this is a
   pure decision-layer test with no I/O. *)

open Alcotest
module WO = Masc.Keeper_world_observation
module A = Masc.Keeper_external_attention

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
  let module Q = Keeper_event_queue in
  let s =
    { Q.post_id = "evt-77"
    ; urgency = Q.Normal
    ; arrived_at = 1.0
    ; payload =
        Q.Connector_attention
          { event_id = "evt-77"
          ; channel =
              Keeper_continuation_channel.Discord
                { channel_id = "chan-77"; user_id = "user-77" }
          }
    }
  in
  match Q.stimulus_of_yojson (Q.stimulus_to_yojson s) with
  | Ok s' -> (
    match s'.Q.payload with
    | Q.Connector_attention { event_id } ->
      check string "event_id survives the JSON round-trip" "evt-77" event_id
    | _ -> check bool "round-trip payload stays Connector_attention" true false)
  | Error e -> check bool ("round-trip decode failed: " ^ e) true false

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
    ; ( "projection",
        [ test_case "external attention becomes prompt event" `Quick
            test_external_attention_projects_to_prompt_event
        ] )
    ]

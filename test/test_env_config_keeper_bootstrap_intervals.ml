(** Pin the {!Env_config_keeper.KeeperBootstrap} polling/settle
    interval contract. Three values were extracted from inline
    literals at [server_bootstrap_loops.ml]:

    - line 157  0.25  → lazy_startup_poll_interval_sec
    - line 240  0.25  → keeper_listener_retry_interval_sec
    - line 482  5.0   → post_startup_settle_sec

    The two [0.25] values shared a literal but encode *different*
    intents (lazy-startup polling vs. listener-retry backoff). The
    SSOT keeps them as separate knobs so future operator overrides
    can tune one without affecting the other.

    Properties pinned:

    1. Defaults preserve the pre-extraction literals (regression
       guard against silent shifts that would change autoboot wall-
       clock or burn CPU on busy-poll).
    2. Polling intervals have a >= 0.05s floor (50ms) so an operator
       typo doesn't accidentally turn the loop into a CPU sink.
    3. [post_startup_settle_sec] allows 0 (no settle) but caps at
       no upper bound — operators on slow machines may raise. *)

open Alcotest

module KB = Env_config_keeper.KeeperBootstrap
module Boot = Server_bootstrap_loops.For_testing
module Chat_queue = Masc.Keeper_chat_queue
module Workspace = Masc.Workspace
module Surface_ref = Masc.Surface_ref
module Keeper_chat_store = Masc.Keeper_chat_store

let approx = float 0.001

let contains_substring text fragment =
  let text_len = String.length text in
  let fragment_len = String.length fragment in
  let rec loop index =
    if fragment_len = 0
    then true
    else if index + fragment_len > text_len
    then false
    else if String.sub text index fragment_len = fragment
    then true
    else loop (index + 1)
  in
  loop 0

let substring_index text fragment =
  let text_len = String.length text in
  let fragment_len = String.length fragment in
  let rec loop index =
    if fragment_len = 0
    then Some 0
    else if index + fragment_len > text_len
    then None
    else if String.sub text index fragment_len = fragment
    then Some index
    else loop (index + 1)
  in
  loop 0

let required_index ~label text fragment =
  match substring_index text fragment with
  | Some index -> index
  | None -> failf "%s: expected source marker %S" label fragment

let load_source relative_path =
  let source_root =
    match Sys.getenv_opt "DUNE_SOURCEROOT" with
    | Some root when String.trim root <> "" -> root
    | Some _ | None -> Sys.getcwd ()
  in
  let path = Filename.concat source_root relative_path in
  In_channel.with_open_bin path In_channel.input_all

let workspace_config ~cluster_name base_path =
  let config : Workspace.config = Workspace.default_config base_path in
  let backend_config =
    { config.backend_config with Backend_types.cluster_name = cluster_name }
  in
  { config with backend_config }

let rec remove_tree path =
  if Sys.file_exists path then
    if Sys.is_directory path then begin
      Sys.readdir path
      |> Array.iter (fun name -> remove_tree (Filename.concat path name));
      Unix.rmdir path
    end
    else Sys.remove path

let test_default_lazy_startup_poll () =
  check approx
    "lazy_startup_poll_interval_sec default (was inline 0.25)"
    0.25 KB.lazy_startup_poll_interval_sec

let test_default_listener_retry () =
  check approx
    "keeper_listener_retry_interval_sec default (was inline 0.25)"
    0.25 KB.keeper_listener_retry_interval_sec

let test_default_post_startup_settle () =
  check approx
    "post_startup_settle_sec default (was inline 5.0)"
    5.0 KB.post_startup_settle_sec

let test_polling_floor () =
  check bool
    "lazy_startup_poll_interval_sec must satisfy the documented \
     >= 0.05s floor (else the loop becomes a CPU sink)"
    true
    (KB.lazy_startup_poll_interval_sec >= 0.05);
  check bool
    "keeper_listener_retry_interval_sec must satisfy the documented \
     >= 0.05s floor"
    true
    (KB.keeper_listener_retry_interval_sec >= 0.05)

let test_smoke_call_sites_compile () =
  let _ = KB.lazy_startup_poll_interval_sec in
  let _ = KB.keeper_listener_retry_interval_sec in
  let _ = KB.post_startup_settle_sec in
  check bool "all three accessors are reachable" true true

let test_autoboot_warmup_jitter_is_bounded_not_linear () =
  let names =
    [
      "analyst";
      "executor";
      "issue_king";
      "janitor";
      "masc-improver";
      "nick0cave";
      "qa-king";
      "ramarama";
      "sangsu";
      "scholar";
      "taskmaster";
      "tech_glutton";
      "velvet-hammer";
      "verifier";
    ]
  in
  let warmups =
    List.map
      (fun keeper_name ->
        Boot.autoboot_proactive_warmup_sec ~base_warmup:60
          ~stagger_window_sec:15 ~keeper_name)
      names
  in
  check bool "every warmup stays inside the 60..75s jitter window" true
    (List.for_all (fun value -> value >= 60 && value <= 75) warmups);
  check bool "last keeper is not delayed by list position" true
    (List.nth warmups 13 <= 75)

(* §L (tracker #13155): pin exact warmup outputs for fixed keeper
   names so any silent regression to native-int [acc lsl 5] (which
   wraps differently on 31-bit vs 63-bit OCaml) breaks at least one
   assertion on at least one architecture.

   Expected values come from the Int32 djb2 spec:
     [acc := Int32.logand (Int32.add (Int32.add (acc lsl 5) acc) ch)
            0x3FFF_FFFFl]

   With [base_warmup = 0, stagger_window_sec = 99] the formula
   reduces to [hash mod 100] which is itself stable across platforms
   under the Int32 implementation. *)
let test_warmup_hash_pinned_cross_platform () =
  let warmup name =
    Boot.autoboot_proactive_warmup_sec ~base_warmup:0
      ~stagger_window_sec:99 ~keeper_name:name
  in
  check int "verifier hash mod 100 (Int32 djb2)" 25 (warmup "verifier");
  check int "designer hash mod 100 (Int32 djb2)" 74 (warmup "designer");
  check int "developer hash mod 100 (Int32 djb2)" 15 (warmup "developer");
  check int "analyst hash mod 100 (Int32 djb2)" 73 (warmup "analyst");
  check int "janitor hash mod 100 (Int32 djb2)" 4 (warmup "janitor")

let test_autoboot_warmup_is_order_independent () =
  let warmup name =
    Boot.autoboot_proactive_warmup_sec ~base_warmup:60 ~stagger_window_sec:15
      ~keeper_name:name
  in
  (* PR #13119 review: previously this test called [warmup "verifier"]
     twice with identical inputs, which would still pass even if the
     implementation depended on list position.  The actual invariant
     is "permuting the keeper boot list does not change any individual
     keeper's warmup".  Compute warmups for an ordered name list and
     for its reverse, then assert per-name equality. *)
  let names = [
    "verifier"; "designer"; "developer"; "operator"; "supervisor";
    "tester"; "auditor"; "researcher"; "writer"; "scheduler";
  ] in
  let warmups_forward = List.map (fun n -> (n, warmup n)) names in
  let warmups_reverse = List.map (fun n -> (n, warmup n)) (List.rev names) in
  List.iter
    (fun (name, w_fwd) ->
      let w_rev = List.assoc name warmups_reverse in
      check int
        (Printf.sprintf "%s gets identical warmup regardless of list position"
           name)
        w_fwd w_rev)
    warmups_forward;
  check int "same keeper gets same warmup independent of boot order"
    (warmup "verifier") (warmup "verifier");
  check int "zero jitter keeps exact base warmup" 60
    (Boot.autoboot_proactive_warmup_sec ~base_warmup:60
       ~stagger_window_sec:0 ~keeper_name:"verifier");
  (* Coverage smoke: the test assumes the hash actually distributes
     names across the stagger window — if every name collapsed to
     a single offset the previous "no list-position dependency"
     check would degenerate to a tautology.  Assert ≥3 distinct
     warmup values across the 10-name list (with stagger=15 the
     hash buckets collide naturally; ≥3 still proves the hash is
     producing a non-trivial distribution). *)
  let distinct =
    warmups_forward
    |> List.map snd
    |> List.sort_uniq compare
    |> List.length
  in
  check bool "stagger produces ≥3 distinct warmups across 10 names" true
    (distinct >= 3)

let test_discord_queue_projection_matches_gateway_context () =
  let queued : Chat_queue.queued_message =
    {
      content = "hello";
      user_blocks = [];
      attachments = [];
      timestamp = 0.0;
      source =
        Chat_queue.Discord
          { channel_id = "discord-channel-1"; user_id = "discord-user-9" };
      transcript_context =
        Some
          { surface =
              Surface_ref.Discord
                { guild_id = None
                ; channel_id = "discord-channel-1"
                ; parent_channel_id = None
                ; thread_id = None
                }
          ; conversation_id = None
          ; external_message_id = None
          ; speaker =
              { Keeper_chat_store.speaker_id = Some "discord-user-9"
              ; speaker_name = Some "Discord User"
              ; speaker_authority = Keeper_chat_store.External
              }
          ; extra_mentions = []
          };
    }
  in
  let projection = Boot.queued_chat_projection queued in
  check string "connector label" "discord" projection.payload_channel;
  check string "actor id" "discord-user-9" projection.payload_channel_user_id;
  check string "workspace id uses Discord channel id" "discord-channel-1"
    projection.payload_channel_workspace_id;
  check string "agent identity matches gate channel actor"
    "gate:discord:discord-channel-1:discord-user-9"
    projection.agent_name

let test_slack_queue_projection_matches_gateway_context () =
  let queued : Chat_queue.queued_message =
    { content = "hello"
    ; user_blocks = []
    ; attachments = []
    ; timestamp = 0.0
    ; source =
        Chat_queue.Slack
          { channel_id = "C-SLACK"
          ; user_id = "U-SLACK"
          ; user_name = "Slack User"
          ; team_id = Some "T-SLACK"
          ; thread_ts = Some "171.001"
          }
    ; transcript_context =
        Some
          { surface =
              Surface_ref.Slack
                { team_id = Some "T-SLACK"
                ; channel_id = "C-SLACK"
                ; thread_ts = Some "171.001"
                }
          ; conversation_id = None
          ; external_message_id = None
          ; speaker =
              { Keeper_chat_store.speaker_id = Some "U-SLACK"
              ; speaker_name = Some "Slack User"
              ; speaker_authority = Keeper_chat_store.External
              }
          ; extra_mentions = []
          }
    }
  in
  let projection = Boot.queued_chat_projection queued in
  check string "connector label" "slack" projection.payload_channel;
  check string "actor id" "U-SLACK" projection.payload_channel_user_id;
  check string "actor name" "Slack User" projection.payload_channel_user_name;
  check string "workspace id uses Slack channel id" "C-SLACK"
    projection.payload_channel_workspace_id;
  check string "agent identity matches gate channel actor"
    "gate:slack:C-SLACK:U-SLACK" projection.agent_name;
  match Chat_queue.continuation_channel_of_message_source queued.source with
  | Keeper_continuation_channel.Slack { team_id; channel_id; thread_ts; user_id } ->
    check (option string) "team retained" (Some "T-SLACK") team_id;
    check string "channel retained" "C-SLACK" channel_id;
    check (option string) "thread retained" (Some "171.001") thread_ts;
    check string "user retained" "U-SLACK" user_id
  | _ -> fail "Slack source must project to a Slack continuation"

let test_queue_bootstrap_precedes_state_publish_and_is_autoboot_independent () =
  let runtime_source =
    load_source "lib/server/server_runtime_bootstrap.ml"
  in
  let queue_start =
    required_index ~label:"queue startup" runtime_source
      "Server_bootstrap_loops.start_keeper_chat_queue"
  in
  let state_publish =
    required_index ~label:"state publication" runtime_source
      "server_state := Some state;"
  in
  let state_ready =
    required_index ~label:"readiness" runtime_source
      "Server_startup_state.mark_state_ready"
  in
  let discord_ingress =
    required_index ~label:"Discord ingress" runtime_source
      "Server_discord_in_process_gateway.start"
  in
  let slack_ingress =
    required_index ~label:"Slack ingress" runtime_source
      "Server_slack_in_process_gateway.start"
  in
  check bool "queue starts before state publication" true
    (queue_start < state_publish);
  check bool "queue starts before readiness" true (queue_start < state_ready);
  check bool "queue starts before Discord ingress" true
    (queue_start < discord_ingress);
  check bool "queue starts before Slack ingress" true
    (queue_start < slack_ingress);
  let loops_source = load_source "lib/server/server_bootstrap_loops.ml" in
  let queue_helper_start =
    required_index ~label:"queue helper" loops_source
      "let start_keeper_chat_queue"
  in
  let keeper_loops_start =
    required_index ~label:"keeper loops" loops_source
      "let start_keeper_loops"
  in
  let queue_helper_source =
    String.sub loops_source queue_helper_start
      (keeper_loops_start - queue_helper_start)
  in
  let keeper_loops_source =
    String.sub loops_source keeper_loops_start
      (String.length loops_source - keeper_loops_start)
  in
  check bool "queue helper configures the immutable bootstrap snapshot" true
    (contains_substring queue_helper_source
       "configure_persistence ~config:workspace_config");
  check bool "consumer uses the same snapshot base_path" true
    (contains_substring queue_helper_source
       "let base_path = workspace_config.base_path");
  check bool "queue ownership is not nested under Keeper autoboot" false
    (contains_substring keeper_loops_source
       "Keeper_chat_queue.configure_persistence");
  check bool "queue consumer is not nested under Keeper autoboot" false
    (contains_substring keeper_loops_source "Keeper_chat_consumer.start");
  check bool "Keeper autoboot can still be disabled independently" true
    (contains_substring keeper_loops_source
       "MASC_KEEPER_BOOTSTRAP_ENABLED=false")

let test_queue_bootstrap_ownership_rejects_live_config_drift () =
  Eio_main.run @@ fun _environment ->
  let base_path = Filename.temp_file "keeper-chat-bootstrap" "" in
  Sys.remove base_path;
  Unix.mkdir base_path 0o755;
  let configured = workspace_config ~cluster_name:"configured" base_path in
  let drifted = workspace_config ~cluster_name:"drifted" base_path in
  Fun.protect
    ~finally:(fun () ->
      Chat_queue.For_testing.reset ();
      remove_tree base_path)
    (fun () ->
      Chat_queue.For_testing.reset ();
      ignore
        (Chat_queue.configure_persistence ~config:configured
          : Chat_queue.configure_report);
      check bool "configured snapshot remains accepted" true
        (Chat_queue.persistence_matches_config ~config:configured);
      check bool "live cluster/root drift is rejected" false
        (Chat_queue.persistence_matches_config ~config:drifted))

let () =
  run "env_config_keeper_bootstrap_intervals"
    [
      ( "defaults preserve pre-extraction literals",
        [
          test_case "lazy_startup_poll = 0.25" `Quick
            test_default_lazy_startup_poll;
          test_case "listener_retry = 0.25" `Quick
            test_default_listener_retry;
          test_case "post_startup_settle = 5.0" `Quick
            test_default_post_startup_settle;
        ] );
      ( "polling floors",
        [
          test_case ">= 0.05s floor on both polling intervals" `Quick
            test_polling_floor;
        ] );
      ( "API surface",
        [
          test_case "all three accessors reachable" `Quick
            test_smoke_call_sites_compile;
        ] );
      ( "autoboot warmup fairness",
        [
          test_case "jitter bounded, not linear by boot order" `Quick
            test_autoboot_warmup_jitter_is_bounded_not_linear;
          test_case "warmup deterministic per keeper" `Quick
            test_autoboot_warmup_is_order_independent;
          test_case "Int32 hash pinned cross-platform (#13155 §L)" `Quick
            test_warmup_hash_pinned_cross_platform;
        ] );
      ( "queued chat projection",
        [
          test_case "Discord queue source keeps connector context" `Quick
            test_discord_queue_projection_matches_gateway_context;
          test_case "Slack queue source keeps connector context" `Quick
            test_slack_queue_projection_matches_gateway_context;
        ] );
      ( "queue bootstrap ownership",
        [
          test_case
            "queue starts before readiness even when Keeper autoboot is disabled"
            `Quick
            test_queue_bootstrap_precedes_state_publish_and_is_autoboot_independent;
          test_case "live workspace config drift is rejected" `Quick
            test_queue_bootstrap_ownership_rejects_live_config_drift;
        ] );
    ]

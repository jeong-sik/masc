open Alcotest

module Observer = Masc_tui_observer
module Acting = Masc_tui_acting

let agent_core ?(kind = Observer.Tool_called) ?tool ?task ?turn ?tool_use_id ?batch
    ?(at = 100.) agent : Observer.event =
  Observer.Agent_core
    { Observer.kind
    ; agent = Some agent
    ; tool
    ; task
    ; turn
    ; tool_use_id
    ; batch
    ; at
    ; correlation = None
    ; parent = None
    ; event_id = None
    ; run_id = None
    ; caused_by = None
    ; execution_id = None
    }

let heartbeat keeper : Observer.event =
  Observer.Keeper_heartbeat
    { Observer.hb_keeper = keeper
    ; hb_phase = Some "turn_running"
    ; hb_in_turn = Some true
    ; hb_in_flight_ms = Some 2_189_925.4
    ; hb_at = 100.
    }

let settled keeper : Observer.event =
  Observer.Keeper_turn_complete
    { Observer.tc_keeper = keeper
    ; tc_turn = Some 2086
    ; tc_model = None
    ; tc_input_tokens = Some 73877
    ; tc_output_tokens = Some 358
    ; tc_cost_usd = Some 0.02581816
    ; tc_tool_calls = Some 0
    ; tc_at = 100.
    }

(* The hook's per-call report: provider call [session] ran while [completed]
   keeper turns were done, so it belongs to keeper turn [completed + 1]. *)
let observation ~keeper ~session ~completed : Observer.event =
  Observer.Keeper_turn_observation
    { Observer.to_keeper = keeper
    ; to_session_turn = Some session
    ; to_total_turns = Some completed
    ; to_at = 100.
    }

let text row =
  Printf.sprintf "%s %s %s | %s" (Acting.glyph_text row.Acting.glyph)
    row.Acting.keeper row.Acting.label row.Acting.detail

let entries_of events =
  (* Newest first, as the screen holds them; arrival follows list order. *)
  List.rev
    (List.mapi
       (fun index event ->
         { Acting.ae_at = 100. +. float_of_int index; ae_event = event })
       events)

let test_filter_explanations_name_scope_and_quiet_rows () =
  check string "turns explains internal agents"
    "scope turns · one row per Keeper turn · agent start/done = internal run"
    (Acting.filter_explanation Acting.Turns);
  check string "actions says state is hidden"
    "scope actions · flat calls/returns/turn/chat · state pushes hidden"
    (Acting.filter_explanation Acting.Actions);
  (* The dot this line used to name is not drawn on any row: #33691 gave a
     quiet row a blank mark cell, and this legend's own separator is a dot. *)
  check string "everything names the only cue a quiet row carries"
    "scope everything · gray = state/telemetry · composite = Keeper snapshot changed"
    (Acting.filter_explanation Acting.Everything)
;;

let ledger_tool ?duration_ms ?turn ~keeper tool : Observer.event =
  Observer.Keeper_tool_call
    { Observer.kt_keeper = keeper
    ; kt_turn = turn
    ; kt_tool = tool
    ; kt_duration_ms = duration_ms
    ; kt_disposition = Some (Ok Masc.Tui_decode.Keeper_call_completed)
    ; kt_at = 100.
      ; kt_tool_use_id = None
      ; kt_schedule = None
      ; kt_tool_args = None
      ; kt_tool_result = None
      ; kt_tool_args_preview = None
      ; kt_tool_output_preview = None
    }

let turn_settled ~keeper ~turn ~input ~output ~cost : Observer.event =
  Observer.Keeper_turn_complete
    { Observer.tc_keeper = keeper
    ; tc_turn = Some turn
    ; tc_model = None
    ; tc_input_tokens = Some input
    ; tc_output_tokens = Some output
    ; tc_cost_usd = Some cost
    ; tc_tool_calls = Some 1
    ; tc_at = 100.
    }

(* How the two planes interleave on the feed. The observation, the ledger's
   tool row and the settle are broadcast as they happen; the agent-core wire
   reaches the feed through a polling relay, so a turn's wire frames (end /
   call / returned) replay after its settle, while the next call's turn
   markers, published before that call, land ahead of its observation.
   Seventeen entries: fourteen rows on the flat actions view, which hides
   the three observations, and seventeen under [Everything]; the fold owes
   three rows.
   The session ordinals (149-151) differ from the keeper turns (49-51), so a
   row that printed the ordinal as its turn would not pass. *)
let test_turns_fold_the_two_planes_into_one_row_per_turn () =
  let k = "kpr-07" in
  let events_oldest_first =
    [ observation ~keeper:k ~session:149 ~completed:48
    ; ledger_tool ~duration_ms:63. ~keeper:k "masc_schedule_list"
    ; turn_settled ~keeper:k ~turn:49 ~input:39050 ~output:70 ~cost:0.0100
    ; agent_core ~kind:Observer.Turn_completed ~turn:149 k
    ; agent_core ~kind:Observer.Tool_called ~tool:"masc_schedule_list"
        ~turn:149 ~tool_use_id:"c49" k
    ; agent_core ~kind:Observer.Tool_completed ~tool:"masc_schedule_list"
        ~turn:149 ~tool_use_id:"c49" k
    ; agent_core ~kind:Observer.Turn_started ~turn:150 k
    ; agent_core ~kind:Observer.Turn_ready ~turn:150 k
    ; observation ~keeper:k ~session:150 ~completed:49
    ; ledger_tool ~duration_ms:6. ~keeper:k "keeper_artifact_read"
    ; turn_settled ~keeper:k ~turn:50 ~input:39237 ~output:76 ~cost:0.0102
    ; agent_core ~kind:Observer.Turn_completed ~turn:150 k
    ; agent_core ~kind:Observer.Tool_called ~tool:"keeper_artifact_read"
        ~turn:150 ~tool_use_id:"c50" k
    ; agent_core ~kind:Observer.Tool_completed ~tool:"keeper_artifact_read"
        ~turn:150 ~tool_use_id:"c50" k
    ; agent_core ~kind:Observer.Turn_started ~turn:151 k
    ; agent_core ~kind:Observer.Turn_ready ~turn:151 k
    ; observation ~keeper:k ~session:151 ~completed:50
    ]
  in
  let rows = Acting.chunk_rows ~traces:[] (entries_of events_oldest_first) in
  check int "seventeen entries fold to three turns" 3 (List.length rows);
  check (list string)
    "newest first: 51 running, 50 and 49 settled with ledger durations"
    [ "\xe2\x96\xb6 kpr-07 turn 51 | running"
    ; "\xe2\x96\xa0 kpr-07 turn 50 | keeper_artifact_read 6ms \xc2\xb7 in \
       39237 out 76 \xc2\xb7 $0.0102"
    ; "\xe2\x96\xa0 kpr-07 turn 49 | masc_schedule_list 63ms \xc2\xb7 in \
       39050 out 70 \xc2\xb7 $0.0100"
    ]
    (List.map text rows)

(* The wire numbers a call from the agent session; the settle numbers the
   turn from the keeper's lifetime. With no observation to translate the
   one into the other, the settle joins the newest open chunk -- a keeper
   runs one turn at a time -- and stamps it with the keeper's number. *)
let test_a_settle_joins_the_open_turn_it_ends_despite_the_number () =
  let k = "kpr-08" in
  let events_oldest_first =
    [ agent_core ~kind:Observer.Turn_started ~turn:500 k
    ; agent_core ~kind:Observer.Tool_called ~tool:"Read" ~turn:500
        ~tool_use_id:"c500" k
    ; ledger_tool ~duration_ms:12. ~keeper:k "Read"
    ; turn_settled ~keeper:k ~turn:3084 ~input:2000 ~output:40 ~cost:0.0040
    ]
  in
  let rows = Acting.chunk_rows ~traces:[] (entries_of events_oldest_first) in
  check int "one turn, not two" 1 (List.length rows);
  check (list string)
    "the keeper's number, settled, with the ledger call on the same row"
    [ "\xe2\x96\xa0 kpr-08 turn 3084 | Read 12ms \xc2\xb7 in 2000 out 40 \xc2\xb7 $0.0040" ]
    (List.map text rows)

(* What is not turn lifecycle stays its own row, in feed position. *)
let test_turns_pass_non_lifecycle_rows_through () =
  let events_oldest_first =
    [ agent_core ~kind:Observer.Turn_ready ~turn:7 "analyst"
    ; observation ~keeper:"analyst" ~session:7 ~completed:6
    ; Observer.Keeper_chat_appended
        { keeper = "analyst"; connector = Some "discord"; at = 100. }
    ; Observer.Other "operator_digest"
    ]
  in
  let rows = Acting.chunk_rows ~traces:[] (entries_of events_oldest_first) in
  check (list string) "chunk plus the chat and server rows"
    [ "? server operator_digest | "
    ; "\xe2\x97\x8f analyst chat | discord"
    ; "\xe2\x96\xb6 analyst turn 7 | running"
    ]
    (List.map text rows)

(* What [visible Turns] hides must not come back through the fold as
   pass-through rows. The live screen this pins showed 128 rows under
   "scope turns" dominated by composite pushes and heartbeats
   (2026-09-01). *)
let test_turns_do_not_readmit_what_the_scope_hides () =
  let events_oldest_first =
    [ agent_core ~kind:Observer.Turn_ready ~turn:7 "analyst"
    ; observation ~keeper:"analyst" ~session:7 ~completed:6
    ; Observer.Keeper_composite_changed { keeper = "analyst"; at = 100. }
    ; heartbeat "analyst"
    ; Observer.Keeper_chat_stream_frame
        { keeper = "analyst"; operation_id = "op"; seq = None
        ; frame = Some "text_delta"; at = 100. }
    ; Observer.Keeper_waiting_inventory_changed
        { keeper = "analyst"; queue_kind = Some "event_queue"; at = 100. }
    ; Observer.Snapshot "keepers"
    ; Observer.Other "operator_digest"
    ]
  in
  let rows = Acting.chunk_rows ~traces:[] (entries_of events_oldest_first) in
  check (list string) "only the turn and the untaught server row remain"
    [ "? server operator_digest | "
    ; "\xe2\x96\xb6 analyst turn 7 | running"
    ]
    (List.map text rows)

(* Telemetry is a quiet member: it may refresh a chunk that exists, but a
   keeper the feed knows nothing else about must not gain a ghost
   [turn | running] row from it (#32208, live capture 2026-09-01). *)
let test_telemetry_alone_conjures_no_turn () =
  let events_oldest_first =
    [ agent_core ~kind:Observer.Telemetry "analyst" ]
  in
  check (list string) "no rows from telemetry alone" []
    (List.map text
       (Acting.chunk_rows ~traces:[] (entries_of events_oldest_first)))

let test_telemetry_refreshes_but_never_duplicates_a_turn () =
  let events_oldest_first =
    [ agent_core ~kind:Observer.Turn_ready ~turn:7 "analyst"
    ; observation ~keeper:"analyst" ~session:7 ~completed:6
    ; agent_core ~kind:Observer.Telemetry "analyst"
    ]
  in
  check (list string) "still exactly the one turn row"
    [ "\xe2\x96\xb6 analyst turn 7 | running" ]
    (List.map text
       (Acting.chunk_rows ~traces:[] (entries_of events_oldest_first)))

(* A running turn names what it is doing right now: the call alone puts the
   tool on screen, before any return or ledger row exists. *)
let test_a_running_turn_names_its_in_flight_call () =
  let events_oldest_first =
    [ agent_core ~kind:Observer.Turn_ready ~turn:7 "alpha"
    ; observation ~keeper:"alpha" ~session:7 ~completed:6
    ; agent_core ~kind:Observer.Tool_called ~tool:"read_file" ~turn:7
        ~tool_use_id:"w1" "alpha"
    ]
  in
  match Acting.chunk_rows ~traces:[] (entries_of events_oldest_first) with
  | [ row ] ->
      check string "the in-flight tool is on the row"
        "\xe2\x96\xb6 alpha turn 7 | read_file" (text row)
  | rows -> failf "expected one chunk row, got %d" (List.length rows)

(* A runtime whose ledger plane is silent still names its tools: the wire
   pair supplies the name and the call-to-return gap supplies the duration. *)
let test_turns_fall_back_to_the_wire_when_the_ledger_is_silent () =
  let events_oldest_first =
    [ agent_core ~kind:Observer.Turn_ready ~turn:3 "edgar"
    ; observation ~keeper:"edgar" ~session:3 ~completed:2
    ; agent_core ~kind:Observer.Tool_called ~tool:"read_file" ~turn:3
        ~tool_use_id:"w1" "edgar"
    ; agent_core ~kind:Observer.Tool_completed ~tool:"read_file" ~turn:3
        ~tool_use_id:"w1" "edgar"
    ]
  in
  let rows = Acting.chunk_rows ~traces:[] (entries_of events_oldest_first) in
  match rows with
  | [ row ] ->
      check string "wire duration is the call-to-return gap"
        "\xe2\x96\xb6 edgar turn 3 | read_file 1.0s" (text row)
  | rows -> failf "expected one chunk row, got %d" (List.length rows)

let test_actions_hide_what_says_nothing_a_row_can_act_on () =
  let events =
    [ agent_core ~tool:"read_file" "analyst"
    ; agent_core ~kind:Observer.Telemetry "analyst"
    ; heartbeat "bandleader"
    ; Observer.Keeper_composite_changed { keeper = "largo"; at = 100. }
    ; Observer.Snapshot "execution_snapshot"
    ; settled "largo"
    ; Observer.Keeper_chat_appended { keeper = "lane-smith"; connector = Some "agent"; at = 100. }
    ; Observer.Other "brand_new_push"
    ; Observer.Internal_agent_runs_changed
    ; Observer.Keeper_chat_stream_frame
        { keeper = "test-keeper"; operation_id = "op"; seq = None
        ; frame = Some "TEXT_MESSAGE_CONTENT"; at = 100. }
    ; Observer.Keeper_waiting_inventory_changed
        { keeper = "lane-smith"; queue_kind = Some "board"; at = 100. }
    ; Observer.Fusion_run_status
        { keeper = "polisher"; run_id = "kmsg-f04701e2"; status = "running" }
    ]
  in
  let under filter =
    List.filter (Acting.visible filter) events |> List.length
  in
  check int "actions keeps the call, the settlement, the chat, and the unknown" 4
    (under Acting.Actions);
  check int "everything keeps all twelve" 12 (under Acting.Everything);
  check bool "an event this build was not taught always draws" true
    (Acting.visible Acting.Actions (Observer.Other "brand_new"))

(* The run registries broadcast a change on every run they add or settle, and
   it arrived as a type this build did not know -- which every scope draws,
   with the mark that asks the reader to look. On the live fleet it was two of
   the five rows under "turns", beside a scope line promising one row per
   Keeper turn. It is a server push: the everything scope shows it, the two
   that show what a keeper did do not. *)
let test_the_internal_runs_push_is_not_a_keepers_act () =
  let push = Observer.Internal_agent_runs_changed in
  check bool "turns does not draw it" false (Acting.visible Acting.Turns push);
  check bool "actions does not draw it" false (Acting.visible Acting.Actions push);
  check bool "everything does" true (Acting.visible Acting.Everything push);
  let row = Acting.row_of_event ~at:100. ~duration_ms:None push in
  check bool "it is drawn quiet, not with the look-here mark" true
    (row.Acting.glyph = Acting.Quiet);
  check string "and it says what changed" "a run registry changed"
    row.Acting.detail

module Lane_events = Masc.Lane_addon_resource_events

let lane_resource ?detail lifecycle =
  Observer.Lane_resource
    { Observer.lr_lifecycle = lifecycle
    ; lr_package = "masc-dos"
    ; lr_instance = "inst-7"
    ; lr_detail = detail
    ; lr_at = 100.
    }

(* A container that would not start, or whose removal nobody can show, is a
   failure the operator acts on, so the scopes that show what happened draw
   it -- with the failure mark, the package, and the reason in the server's
   own words. A container that started or was removed is the lane runtime
   doing its job: state, shown under everything. *)
let test_a_lane_container_failure_is_drawn_with_its_reason () =
  let failed = lane_resource ~detail:"image not found" Lane_events.Acquire_failed in
  check bool "turns draws a failed start" true (Acting.visible Acting.Turns failed);
  let row = Acting.row_of_event ~at:100. ~duration_ms:None failed in
  check bool "with the failure mark" true (row.Acting.glyph = Acting.Failure);
  check string "naming the package and the reason"
    "masc-dos \xc2\xb7 image not found" row.Acting.detail;
  List.iter
    (fun (name, lifecycle, shown) ->
      check bool (name ^ " under turns") shown
        (Acting.visible Acting.Turns (lane_resource lifecycle));
      check bool (name ^ " under everything") true
        (Acting.visible Acting.Everything (lane_resource lifecycle)))
    [ ("a started container", Lane_events.Acquired, false)
    ; ("a failed start", Lane_events.Acquire_failed, true)
    ; ("a removed container", Lane_events.Release_confirmed, false)
    ; ("an unproven removal", Lane_events.Release_incomplete, true)
    ]

(* A lane container that keeps failing the same way fails once every few
   seconds: on the live fleet two packages missing their image failed 7,196
   times in one day. Under turns, the scope that folds a keeper's lifecycle
   rows into one row per turn, each package failing for one reason is one row
   carrying how many times the screen holds it, at its newest occurrence --
   and a different reason is a different row. *)
let test_a_repeating_container_failure_is_one_row_under_turns () =
  let no_image = "No such image" in
  let events_oldest_first =
    [ lane_resource ~detail:no_image Lane_events.Acquire_failed
    ; Observer.Lane_resource
        { Observer.lr_lifecycle = Lane_events.Acquire_failed
        ; lr_package = "output-statistics"
        ; lr_instance = "inst-8"
        ; lr_detail = Some no_image
        ; lr_at = 100.
        }
    ; lane_resource ~detail:no_image Lane_events.Acquire_failed
    ; lane_resource ~detail:no_image Lane_events.Acquire_failed
    ; lane_resource ~detail:"daemon not running" Lane_events.Acquire_failed
    ]
  in
  let rows = Acting.chunk_rows ~traces:[] (entries_of events_oldest_first) in
  let details = List.map (fun row -> row.Acting.detail) rows in
  check (list string) "one row per package and reason, newest first"
    [ "masc-dos \xc2\xb7 daemon not running"
    ; "\xc3\x973 masc-dos \xc2\xb7 No such image"
    ; "output-statistics \xc2\xb7 No such image"
    ]
    details;
  check int "actions still lists every failure" 5
    (List.length (List.filter (Acting.visible Acting.Actions) events_oldest_first))

(* A reply sends one stream frame per token, so a single keeper answering fills
   the retained ring on its own. Before these frames were decoded they arrived
   as Other, which the actions filter admits, and a screen asked for actions
   showed hundreds of rows with no time, no keeper and no detail -- two real
   actions among them. Counted here rather than described. *)
let test_one_reply_does_not_bury_the_actions_it_sits_between () =
  let frames =
    List.init 400 (fun index ->
        Observer.Keeper_chat_stream_frame
          { keeper = "test-keeper"
          ; operation_id = "op"
          ; seq = Some index
          ; frame = Some "TEXT_MESSAGE_CONTENT"
          ; at = 100. +. float_of_int index
          })
  in
  let events = (settled "largo" :: frames) @ [ agent_core ~tool:"read_file" "analyst" ] in
  check int "actions are the two the keeper took" 2
    (List.filter (Acting.visible Acting.Actions) events |> List.length);
  check int "everything still holds every frame" 402
    (List.filter (Acting.visible Acting.Everything) events |> List.length)

(* The row a stream frame draws: a real keeper and what the frame was, not the
   "server" placeholder with an empty detail that Other falls back to. The
   clock is the feed's, not the frame's -- the decoder still keeps the frame's
   own timestamp, and test_tui_observer pins that; it is the row that follows
   the order the screen scrolls through. *)
let test_a_stream_frame_draws_its_keeper_and_what_it_was () =
  let row =
    Acting.row_of_event ~at:100. ~duration_ms:None
      (Observer.Keeper_chat_stream_frame
         { keeper = "test-keeper"; operation_id = "op"; seq = None
         ; frame = Some "CUSTOM KEEPER_TOOL_RESULT_READY"; at = 1787507570.5 })
  in
  check string "keeper" "test-keeper" row.Acting.keeper;
  check bool "the row wears the feed's clock, not the frame's" true
    (Float.equal row.Acting.at 100.);
  check string "detail names the frame" "CUSTOM KEEPER_TOOL_RESULT_READY"
    row.Acting.detail

(* The Fusion surface reloads on this event; the row is only the Everything
   trace that a deliberation moved. It answers the owning keeper -- not the
   "server" placeholder -- and the run id keeps its kmsg- prefix, which is
   what a Ctrl-] jump would look for. *)
let test_a_fusion_status_row_names_the_owning_keeper () =
  let row =
    Acting.row_of_event ~at:100. ~duration_ms:None
      (Observer.Fusion_run_status
         { keeper = "polisher"; run_id = "kmsg-f04701e2"; status = "completed" })
  in
  check string "keeper" "polisher" row.Acting.keeper;
  check string "label" "fusion" row.Acting.label;
  check string "detail carries status and run id"
    "completed \xc2\xb7 kmsg-f04701e2" row.Acting.detail

(* A type this build was not taught puts its name in the Event column and its
   tool in Detail. [masc:audit_event] carries no tool, and the cell drew the
   [?] the default stood for -- which in a column of tool names reads as a
   failure marker and says nothing. Read on screen as:

     -                ? masc:audit_event ?

   The name is what the row has; an absent tool adds nothing to it. *)
let test_an_untaught_event_without_a_tool_says_only_its_name () =
  let row =
    Acting.row_of_event ~at:100. ~duration_ms:None
      (agent_core ~kind:(Observer.Agent_core_other "masc:audit_event") "-")
  in
  check string "the name is the label" "masc:audit_event" row.Acting.label;
  check string "and nothing stands in for the tool it has none of" ""
    row.Acting.detail

let test_an_untaught_event_with_a_tool_still_names_it () =
  let row =
    Acting.row_of_event ~at:100. ~duration_ms:None
      (agent_core ~kind:(Observer.Agent_core_other "masc:something")
         ~tool:"read_file" "analyst")
  in
  check string "a tool it does have is still the detail" "read_file"
    row.Acting.detail

(* The screen that prompted this: 927 rows held, two of them actions, and the
   whole page inside one second. A reply sends one frame per token, so 1,200
   frames arriving after two real events used to push both out of a ring
   trimmed by arrival. Budgeting per class keeps them. *)
let test_a_long_reply_does_not_evict_the_log_it_streams_into () =
  let stream index =
    Observer.Keeper_chat_stream_frame
      { keeper = "test-keeper"
      ; operation_id = "op"
      ; seq = Some index
      ; frame = Some "TEXT_MESSAGE_CONTENT"
      ; at = 200. +. float_of_int index
      }
  in
  (* Newest first, the order the ring holds. *)
  let ring = List.init 1_200 stream @ [ settled "largo"; agent_core ~tool:"read_file" "analyst" ] in
  let kept, dropped =
    Acting.retain ~actions:1_000 ~quiet:200 ~event_of:Fun.id ring
  in
  check int "both actions survive a reply twelve hundred frames long" 2
    (List.filter (Acting.visible Acting.Actions) kept |> List.length);
  check int "the quiet budget is spent, not the whole ring" 200
    (List.filter (fun e -> not (Acting.visible Acting.Actions e)) kept |> List.length);
  check int "everything dropped is counted" 1_000 dropped;
  check int "nothing is invented" (List.length kept + dropped) (List.length ring)

(* Trimming by arrival is what the budgets replace. Pinned so that a single
   shared budget cannot come back without this failing. *)
let test_the_old_arrival_trim_would_have_lost_them () =
  let stream index =
    Observer.Keeper_chat_stream_frame
      { keeper = "test-keeper"; operation_id = "op"; seq = Some index
      ; frame = Some "TEXT_MESSAGE_CONTENT"; at = float_of_int index }
  in
  let ring = List.init 1_200 stream @ [ settled "largo" ] in
  let by_arrival = List.filteri (fun index _ -> index < 1_000) ring in
  check int "arrival order keeps no action at all" 0
    (List.filter (Acting.visible Acting.Actions) by_arrival |> List.length);
  let kept, _ = Acting.retain ~actions:1_000 ~quiet:200 ~event_of:Fun.id ring in
  check int "the class budget keeps it" 1
    (List.filter (Acting.visible Acting.Actions) kept |> List.length)

(* A turn observation draws under no scope but [Everything], yet the Turns
   fold reads it to number the calls. Counted with the quiet class, a reply
   long enough to spend the quiet budget trimmed the observation before the
   call it numbers, and the call fell back to a turn with no number. *)
let test_a_reply_does_not_trim_the_observation_a_call_needs () =
  let stream index =
    Observer.Keeper_chat_stream_frame
      { keeper = "alpha"; operation_id = "op"; seq = Some index
      ; frame = Some "TEXT_MESSAGE_CONTENT"; at = 200. +. float_of_int index }
  in
  (* Newest first, the order the ring holds: the reply streamed after the
     call and the observation that numbers it. *)
  let ring =
    List.init 1_200 stream
    @ [ agent_core ~kind:Observer.Tool_called ~tool:"Read" ~turn:149
          ~tool_use_id:"w1" "alpha"
      ; observation ~keeper:"alpha" ~session:149 ~completed:48
      ]
  in
  let kept, dropped = Acting.retain ~actions:1_000 ~quiet:200 ~event_of:Fun.id ring in
  check int "only the stream past the quiet budget is dropped" 1_000 dropped;
  match Acting.chunks ~traces:[] (entries_of (List.rev kept)) with
  | [ chunk ] ->
      check (option int) "the call keeps its keeper turn" (Some 49) chunk.Acting.ck_turn
  | chunks -> failf "expected one chunk, got %d" (List.length chunks)

(* An observation spends an action slot: it competes with the calls it
   numbers for the same newest-first window, and never spills into the quiet
   slots, so the ring stays within [actions] + [quiet]. *)
let test_an_observation_spends_an_action_slot () =
  let kept, dropped =
    Acting.retain ~actions:1 ~quiet:0 ~event_of:Fun.id
      [ observation ~keeper:"a" ~session:2 ~completed:1; settled "b" ]
  in
  (match kept with
   | [ Observer.Keeper_turn_observation _ ] -> ()
   | _ -> failf "expected the newer observation alone, kept %d" (List.length kept));
  check int "the older action is counted" 1 dropped;
  let kept, dropped =
    Acting.retain ~actions:1 ~quiet:5 ~event_of:Fun.id
      [ observation ~keeper:"a" ~session:2 ~completed:1
      ; observation ~keeper:"a" ~session:1 ~completed:1
      ]
  in
  check int "a second observation finds no action slot" 1 (List.length kept);
  check int "and is not kept in a quiet one" 1 dropped

(* A session created without a checkpoint numbers its calls from zero again.
   An observation held past the calls it numbered would still answer for its
   ordinal when the new session reaches it, and file the new call in flight
   under a keeper turn that settled long ago. Trimmed in arrival order with
   its calls, it leaves the ring with them. *)
let test_an_observation_leaves_the_ring_with_its_calls () =
  let beta_call index =
    let turn = 1_000 + index in
    let id = Printf.sprintf "b%d" index in
    [ agent_core ~kind:Observer.Turn_started ~turn "beta"
    ; agent_core ~kind:Observer.Turn_ready ~turn "beta"
    ; observation ~keeper:"beta" ~session:turn ~completed:500
    ; agent_core ~kind:Observer.Tool_called ~tool:"Read" ~turn ~tool_use_id:id "beta"
    ; agent_core ~kind:Observer.Tool_completed ~tool:"Read" ~turn ~tool_use_id:id "beta"
    ; agent_core ~kind:Observer.Turn_completed ~turn "beta"
    ]
  in
  let oldest_first =
    [ agent_core ~kind:Observer.Turn_started ~turn:1 "alpha"
    ; observation ~keeper:"alpha" ~session:1 ~completed:11
    ; agent_core ~kind:Observer.Tool_called ~tool:"Read" ~turn:1 ~tool_use_id:"a1" "alpha"
    ; agent_core ~kind:Observer.Tool_completed ~tool:"Read" ~turn:1 ~tool_use_id:"a1" "alpha"
    ; turn_settled ~keeper:"alpha" ~turn:12 ~input:10 ~output:2 ~cost:0.001
    ]
    @ List.concat (List.init 220 beta_call)
    @ [ agent_core ~kind:Observer.Turn_started ~turn:0 "alpha"
      ; observation ~keeper:"alpha" ~session:0 ~completed:12
      ; agent_core ~kind:Observer.Tool_called ~tool:"Grep" ~turn:0 ~tool_use_id:"a2" "alpha"
      ; agent_core ~kind:Observer.Tool_completed ~tool:"Grep" ~turn:0 ~tool_use_id:"a2" "alpha"
      ; agent_core ~kind:Observer.Turn_started ~turn:1 "alpha"
      ; agent_core ~kind:Observer.Turn_ready ~turn:1 "alpha"
      ]
  in
  let kept, _ =
    Acting.retain ~actions:1_000 ~quiet:200
      ~event_of:(fun entry -> entry.Acting.ae_event)
      (entries_of oldest_first)
  in
  match
    Acting.chunks ~traces:[] kept
    |> List.filter (fun chunk -> String.equal chunk.Acting.ck_keeper "alpha")
  with
  | [ chunk ] ->
      check (option int) "the call in flight joins the open keeper turn" (Some 13)
        chunk.Acting.ck_turn;
      check bool "which is still running" false chunk.Acting.ck_settled
  | chunks ->
      failf "alpha drew %d turns: %s" (List.length chunks)
        (String.concat ", "
           (List.map (fun chunk -> Acting.turn_label chunk.Acting.ck_turn) chunks))

(* [turn] on an agent-core frame or a ledger call is the agent session's
   ordinal for the provider call, and [turn N] on this surface names a keeper
   turn. The flat turn boundary rows carry no number, and the evidence names
   the ordinal for what it is. *)
let test_the_session_ordinal_is_named_only_in_the_evidence () =
  List.iter
    (fun (kind, label) ->
      let row =
        Acting.row_of_event ~at:100. ~duration_ms:None
          (agent_core ~kind ~turn:2086 "analyst")
      in
      check string "the boundary label" label row.Acting.label;
      check string (label ^ " carries no ordinal") "" row.Acting.detail)
    [ (Observer.Turn_started, "turn start")
    ; (Observer.Turn_ready, "turn ready")
    ; (Observer.Turn_completed, "turn end")
    ];
  let evidence event = Acting.evidence_fields { Acting.ae_at = 100.; ae_event = event } in
  List.iter
    (fun (what, event) ->
      let fields = evidence event in
      check (option (option string)) (what ^ " names the ordinal")
        (Some (Some "2086"))
        (List.assoc_opt "Agent session turn" fields);
      check bool (what ^ " does not call it a turn") false (List.mem_assoc "Turn" fields))
    [ ("a wire call", agent_core ~kind:Observer.Tool_called ~tool:"Read" ~turn:2086 "analyst")
    ; ("a ledger call", ledger_tool ~turn:2086 ~keeper:"analyst" "Read")
    ]

(* Order is what the screen scrolls through, so trimming must not reorder. *)
let test_trimming_keeps_the_order_it_was_given () =
  let ring = [ settled "a"; heartbeat "b"; settled "c"; heartbeat "d"; settled "e" ] in
  let kept, dropped = Acting.retain ~actions:2 ~quiet:1 ~event_of:Fun.id ring in
  check (list string) "newest of each class, in arrival order"
    [ "a"; "b"; "c" ]
    (List.map (fun e -> (Acting.row_of_event ~at:100. ~duration_ms:None e).Acting.keeper) kept);
  check int "the rest is counted" 2 dropped

(* The screen is a feed: rows are held and drawn in the order they arrived,
   so the clock the caller hands in is that arrival. Reading each event's own
   timestamp put two clocks on one screen, and the two kinds that carry none
   drew --:--:-- -- on 925 of the 927 rows that prompted this, which is the
   column an operator would have read to check the order. *)
let test_every_row_wears_the_clock_the_feed_ordered_it_by () =
  let received = 1787507570.5 in
  let at_of event = (Acting.row_of_event ~at:received ~duration_ms:None event).Acting.at in
  List.iter
    (fun (name, event) ->
       check bool (name ^ " wears the arrival clock") true
         (Float.equal (at_of event) received))
    [ ("an unknown type", Observer.Other "brand_new_push")
    ; ("the internal runs push", Observer.Internal_agent_runs_changed)
    ; ("a snapshot", Observer.Snapshot "execution_snapshot")
      (* These two carried a clock of their own before, and it is no longer
         what the row shows -- the row shows the order it sits in. *)
    ; ("a settlement", settled "largo")
    ; ("a heartbeat", heartbeat "bandleader")
    ]

let test_a_call_and_its_return_read_as_one_pair () =
  let started =
    agent_core ~tool:"read_file" ~task:"task-494" ~turn:2086 ~tool_use_id:"tu-1"
      ~batch:(0, 2) ~at:100. "analyst"
  in
  let completed =
    { Observer.kind = Observer.Tool_completed
    ; agent = Some "analyst"
    ; tool = Some "read_file"
    ; task = Some "task-494"
    ; turn = Some 2086
    ; tool_use_id = Some "tu-1"
    ; batch = Some (0, 2)
    ; at = 100.032
    ; correlation = None
    ; parent = None
    ; event_id = None
    ; run_id = None
    ; caused_by = None
    ; execution_id = None
    }
  in
  (* [turn] on the wire is the agent session's ordinal for the provider
     call; [turn N] on this surface is a keeper turn, so the row leaves the
     ordinal to the event evidence. *)
  check string "the call names its tool, batch slot, and task"
    "\xe2\x96\xb6 analyst call | read_file [1/2] \xc2\xb7 task-494"
    (text (Acting.row_of_event ~at:100. ~duration_ms:None started));
  let duration =
    Acting.duration_of_completion ~before:[ heartbeat "x"; started ] completed
  in
  check (option (float 0.5)) "the return is paired with its start by tool-use id"
    (Some 32.) duration;
  check string "and the row carries the pairing"
    "\xe2\x9c\x93 analyst returned | read_file \xc2\xb7 32ms [1/2] \xc2\xb7 task-494"
    (text (Acting.row_of_event ~at:100. ~duration_ms:duration (Observer.Agent_core completed)))

let test_a_return_with_no_start_held_has_no_duration () =
  let completed =
    { Observer.kind = Observer.Tool_completed
    ; agent = Some "analyst"
    ; tool = Some "read_file"
    ; task = None
    ; turn = None
    ; tool_use_id = Some "tu-9"
    ; batch = None
    ; at = 100.
    ; correlation = None
    ; parent = None
    ; event_id = None
    ; run_id = None
    ; caused_by = None
    ; execution_id = None
    }
  in
  check (option (float 0.)) "another keeper's start with the same id does not pair"
    None
    (Acting.duration_of_completion
       ~before:[ agent_core ~tool_use_id:"tu-9" "someone-else" ]
       completed);
  check string "the row then shows the tool alone"
    "\xe2\x9c\x93 analyst returned | read_file"
    (text (Acting.row_of_event ~at:100. ~duration_ms:None (Observer.Agent_core completed)))

let test_keeper_rows_say_what_the_keeper_did () =
  check string "a settlement carries tokens, cost, and calls"
    "\xe2\x96\xa0 largo turn done | turn 2086 \xc2\xb7 in 73877 out 358 \xc2\xb7 $0.0258 \xc2\xb7 0 calls"
    (text (Acting.row_of_event ~at:100. ~duration_ms:None (settled "largo")));
  (* A settle that carried no number drops the turn from the detail rather
     than drawing [turn ?] there. Each part carries no separator of its own,
     so the figures do not open with one when the turn is the missing part. *)
  check string "an unnumbered settlement opens on its figures"
    "\xe2\x96\xa0 largo turn done | in 73877 out 358 \xc2\xb7 $0.0258 \xc2\xb7 0 calls"
    (text
       (Acting.row_of_event ~at:100. ~duration_ms:None
          (match settled "largo" with
           | Observer.Keeper_turn_complete t ->
               Observer.Keeper_turn_complete { t with Observer.tc_turn = None }
           | other -> other)));
  check string "a heartbeat in a turn says how long it has been in it"
    "  bandleader heartbeat | turn_running \xc2\xb7 in turn for 36m29s"
    (text (Acting.row_of_event ~at:100. ~duration_ms:None (heartbeat "bandleader")))

(* The four lifecycle kinds carry the run's own wire id as [task_id] -- an
   [evt-] id on every one of the live fleet's agent_started rows, keepers and
   internal runs alike. It is not a task, so the row does not print it; it
   says how the run went instead. *)
let test_agent_terminal_rows_keep_success_and_failure_distinct () =
  let run_id = "evt-9565f12c61e9c2d7" in
  let started = agent_core ~kind:Observer.Agent_started ~task:run_id "analyst" in
  let completed =
    agent_core ~kind:(Observer.Agent_completed { elapsed_s = 1.5 }) ~task:run_id
      "analyst"
  in
  let failed =
    agent_core
      ~kind:
        (Observer.Agent_failed
           { elapsed_s = 0.5; error_code = "provider_error"; error = "rate limited" })
      ~task:run_id "analyst"
  in
  check string "a started run says nothing it does not know yet"
    "\xe2\x97\x8f analyst agent start | "
    (text (Acting.row_of_event ~at:100. ~duration_ms:None started));
  check string "a successful run says how long it ran"
    "\xe2\x96\xa0 analyst agent done | 1.5s"
    (text (Acting.row_of_event ~at:100. ~duration_ms:None completed));
  check string "a failed run says how long and why"
    "\xe2\x9c\x97 analyst agent failed | 500ms \xc2\xb7 provider_error \xc2\xb7 rate limited"
    (text (Acting.row_of_event ~at:100. ~duration_ms:None failed))

let test_a_lane_named_event_is_attributed_by_its_trace () =
  let on_lane =
    Observer.Agent_core
      { Observer.kind = Observer.Tool_called
      ; agent = Some "agent_core-glm-coding.glm-5-turbo"
      ; tool = Some "Grep"
      ; task = None
      ; turn = Some 2135
      ; tool_use_id = None
      ; batch = None
      ; at = 100.
      ; correlation = Some "trace-1787333554989-0001e"
      ; parent = None
    ; event_id = None
    ; run_id = None
    ; caused_by = None
    ; execution_id = None
      }
  in
  let traces =
    [ ("polisher", "trace-1787333554796-0001d"); ("largo", "trace-1787333554989-0001e") ]
  in
  check string "the keeper whose trace the event carries" "largo"
    (Acting.keeper_of_event ~traces on_lane);
  check string "an unmatched trace keeps the lane name"
    "agent_core-glm-coding.glm-5-turbo"
    (Acting.keeper_of_event ~traces:[] on_lane);
  check string "a keeper-named event keeps its keeper" "bandleader"
    (Acting.keeper_of_event ~traces (heartbeat "bandleader"))

let test_elapsed_text_picks_a_unit () =
  check (list string) "ms, seconds, minutes"
    [ "32ms"; "1.2s"; "2m05s" ]
    (List.map Acting.elapsed_text [ 32.; 1200.; 125_000. ])

(* The feed used to render keeper_skill and keeper_compose_* as anonymous
   "call"/"returned" rows, so skill use was invisible in the chat-side surfaces
   and only the Tools screen knew. The label now says it is a skill. *)
let test_skill_tools_wear_a_skill_label () =
  let row event =
    Acting.row_of_entry ~duration_ms:None { Acting.ae_at = 100.; ae_event = event }
  in
  check string "skill body read is named" "skill call"
    (row (agent_core ~tool:"keeper_skill" "alpha")).Acting.label;
  check string "composition run is named" "skill call"
    (row (agent_core ~tool:"keeper_compose_work-intake" "alpha")).Acting.label;
  check string "a plain tool stays a call" "call"
    (row (agent_core ~tool:"masc_board_stats" "alpha")).Acting.label;
  check string "completion keeps the tag" "skill returned"
    (row (agent_core ~kind:Observer.Tool_completed ~tool:"keeper_skill" "alpha"))
      .Acting.label;
  let keeper_tool_call ?disposition tool : Observer.event =
    Observer.Keeper_tool_call
      { Observer.kt_keeper = "alpha"
      ; kt_turn = None
      ; kt_tool = tool
      ; kt_duration_ms = None
      ; kt_disposition = disposition
      ; kt_at = 100.
      ; kt_tool_use_id = None
      ; kt_schedule = None
      ; kt_tool_args = None
      ; kt_tool_result = None
      ; kt_tool_args_preview = None
      ; kt_tool_output_preview = None
      }
  in
  check string "keeper skill call is named" "skill call"
    (row (keeper_tool_call "keeper_skill")).Acting.label;
  check string "a disposition keeps the tag beside it" "skill \xc2\xb7 deferred"
    (row
       (keeper_tool_call
          ~disposition:(Ok Masc.Tui_decode.Keeper_call_deferred)
          "keeper_compose_work-intake"))
      .Acting.label;
  check string "a word outside the vocabulary is said to be one"
    "unknown disposition"
    (row (keeper_tool_call ~disposition:(Error "keeper call has unknown disposition delivered")
            "masc_board_stats"))
      .Acting.label;
  check string "a plain keeper tool stays a tool call" "tool call"
    (row (keeper_tool_call "masc_board_stats")).Acting.label
;;

(* A ledger row states the call it ran in, and the fold files it under that
   call's keeper turn. A row for the earlier turn that is reported only
   after the next turn has opened lands on its own turn, not the newest. *)
let test_late_ledger_row_stays_on_its_own_turn () =
  let events =
    [ agent_core ~kind:Observer.Turn_started ~turn:7 ~at:100. "alpha"
    ; observation ~keeper:"alpha" ~session:7 ~completed:41
    ; ledger_tool ~turn:7 ~keeper:"alpha" "Read"
    ; agent_core ~kind:Observer.Turn_started ~turn:8 ~at:102. "alpha"
    ; observation ~keeper:"alpha" ~session:8 ~completed:42
    ; ledger_tool ~turn:8 ~keeper:"alpha" "Grep"
      (* Turn 42's second call is reported only now, after turn 43 opened. *)
    ; ledger_tool ~turn:7 ~keeper:"alpha" "Write"
    ]
  in
  let chunks = Acting.chunks ~traces:[] (entries_of events) in
  let tools_of turn =
    List.find_opt (fun c -> c.Acting.ck_turn = Some turn) chunks
    |> Option.map (fun c ->
           List.map (fun t -> t.Acting.ct_tool) (Acting.chunk_tools c))
  in
  check
    (option (list string))
    "the late row went to keeper turn 42"
    (Some [ "Read"; "Write" ])
    (tools_of 42);
  check
    (option (list string))
    "keeper turn 43 kept only its own call"
    (Some [ "Grep" ])
    (tools_of 43)
;;

(* The same feed without observations: the ordinal a row states still keeps
   it with the rows that stated the same ordinal, and no row claims a keeper
   number it was never given. *)
let test_late_ledger_row_stays_with_its_session_without_an_observation () =
  let events =
    [ agent_core ~kind:Observer.Turn_started ~turn:7 ~at:100. "alpha"
    ; ledger_tool ~turn:7 ~keeper:"alpha" "Read"
    ; agent_core ~kind:Observer.Turn_started ~turn:8 ~at:102. "alpha"
    ; ledger_tool ~turn:8 ~keeper:"alpha" "Grep"
    ; ledger_tool ~turn:7 ~keeper:"alpha" "Write"
    ]
  in
  let chunks = Acting.chunks ~traces:[] (entries_of events) in
  let tools_of ordinal =
    List.find_opt (fun c -> List.mem ordinal c.Acting.ck_session_turns) chunks
    |> Option.map (fun c ->
           List.map (fun t -> t.Acting.ct_tool) (Acting.chunk_tools c))
  in
  check
    (option (list string))
    "the late row went to its own ordinal"
    (Some [ "Read"; "Write" ])
    (tools_of 7);
  check
    (option (list string))
    "the other ordinal kept only its own call"
    (Some [ "Grep" ])
    (tools_of 8);
  check bool "neither row claims a keeper number" true
    (List.for_all (fun c -> c.Acting.ck_turn = None) chunks)
;;

(* A settle numbers the turn from the keeper's lifetime while a ledger row
   states the session's ordinal. A row arriving after the settle, with no
   observation to translate it, still finds its turn by the ordinal the
   turn's earlier rows stated instead of opening a second row. *)
let test_ledger_row_after_a_settle_finds_its_turn () =
  let settle_other_plane =
    Observer.Keeper_turn_complete
      { Observer.tc_keeper = "alpha"
      ; tc_turn = Some 3084
      ; tc_model = None
      ; tc_input_tokens = Some 10
      ; tc_output_tokens = Some 2
      ; tc_cost_usd = None
      ; tc_tool_calls = Some 2
      ; tc_at = 100.
      }
  in
  let events =
    [ agent_core ~kind:Observer.Turn_started ~turn:7 ~at:100. "alpha"
    ; ledger_tool ~turn:7 ~keeper:"alpha" "Read"
    ; settle_other_plane
    ; ledger_tool ~turn:7 ~keeper:"alpha" "Write"
    ]
  in
  let chunks =
    Acting.chunks ~traces:[] (entries_of events)
    |> List.filter (fun c -> String.equal c.Acting.ck_keeper "alpha")
  in
  check int "one turn drew one chunk" 1 (List.length chunks);
  let chunk = List.hd chunks in
  check
    (list string)
    "both calls landed on it"
    [ "Read"; "Write" ]
    (List.map (fun t -> t.Acting.ct_tool) (Acting.chunk_tools chunk))
;;


(* One keeper turn is several provider calls. The wire numbers each call
   from the agent session, the settle numbers the turn from the keeper's
   lifetime, and the hook's observation names both for every call. Three
   calls and their settle are one row, under the keeper's number. *)
let test_one_keeper_turn_of_three_calls_is_one_row () =
  let k = "alpha" in
  let calls =
    [ agent_core ~kind:Observer.Turn_started ~turn:100 k
    ; observation ~keeper:k ~session:100 ~completed:6
    ; agent_core ~kind:Observer.Tool_called ~tool:"Read" ~turn:100
        ~tool_use_id:"w1" k
    ; agent_core ~kind:Observer.Tool_completed ~tool:"Read" ~turn:100
        ~tool_use_id:"w1" k
    ; agent_core ~kind:Observer.Turn_started ~turn:101 k
    ; observation ~keeper:k ~session:101 ~completed:6
    ; agent_core ~kind:Observer.Tool_called ~tool:"Grep" ~turn:101
        ~tool_use_id:"w2" k
    ; agent_core ~kind:Observer.Tool_completed ~tool:"Grep" ~turn:101
        ~tool_use_id:"w2" k
    ; agent_core ~kind:Observer.Turn_started ~turn:102 k
    ; observation ~keeper:k ~session:102 ~completed:6
    ]
  in
  let tools chunk =
    List.map (fun t -> t.Acting.ct_tool) (Acting.chunk_tools chunk)
  in
  (match Acting.chunks ~traces:[] (entries_of calls) with
   | [ chunk ] ->
       check (option int) "the keeper's number, from the observations" (Some 7)
         chunk.Acting.ck_turn;
       check bool "still running" false chunk.Acting.ck_settled;
       check (list string) "both calls on the one row" [ "Read"; "Grep" ]
         (tools chunk)
   | chunks -> failf "three calls drew %d rows before the settle" (List.length chunks));
  let settled =
    calls @ [ turn_settled ~keeper:k ~turn:7 ~input:10 ~output:2 ~cost:0.001 ]
  in
  match Acting.chunks ~traces:[] (entries_of settled) with
  | [ chunk ] ->
      check (option int) "the settle agrees with the observations" (Some 7)
        chunk.Acting.ck_turn;
      check bool "and settles the row" true chunk.Acting.ck_settled;
      check (list string) "with both calls still on it" [ "Read"; "Grep" ]
        (tools chunk)
  | chunks -> failf "three calls and a settle drew %d rows" (List.length chunks)

(* The hook sends a call's observation when the call's response is
   collected. A call the agent-core loop makes runs its tools after that, so
   its tool frames follow the observation. A CLI lane runs a whole keeper
   turn as one call with its tools inside it, so the turn's frames arrive
   first and the observation comes at the end. The fold reads every
   observation in the ring first, so frames that arrived unnumbered are
   filed once the observation lands. *)
let test_an_observation_after_its_frames_still_files_them () =
  let events_oldest_first =
    [ agent_core ~kind:Observer.Turn_started ~turn:5 "alpha"
    ; agent_core ~kind:Observer.Tool_called ~tool:"Read" ~turn:5
        ~tool_use_id:"w1" "alpha"
    ; observation ~keeper:"alpha" ~session:5 ~completed:11
    ]
  in
  match Acting.chunks ~traces:[] (entries_of events_oldest_first) with
  | [ chunk ] ->
      check (option int) "filed under keeper turn 12" (Some 12) chunk.Acting.ck_turn
  | chunks -> failf "expected one chunk, got %d" (List.length chunks)

(* The shape a live claude_code keeper's turns took (critic, 2026-09-15):
   every ledger call of the turn arrived first, then the observation, then
   the settle. No observation names a lane turn while it runs, so its row
   has no number until the end; the turn settled before it keeps its own
   call. *)
let test_a_cli_lane_turn_is_numbered_when_its_observation_lands () =
  let k = "critic" in
  let before =
    [ ledger_tool ~duration_ms:75. ~turn:6 ~keeper:k "masc_board_comment"
    ; observation ~keeper:k ~session:6 ~completed:2273
    ; turn_settled ~keeper:k ~turn:2274 ~input:853484 ~output:1662 ~cost:0.0100
    ]
  in
  let running =
    before
    @ [ ledger_tool ~duration_ms:1. ~turn:7 ~keeper:k "masc_board_list"
      ; ledger_tool ~duration_ms:1. ~turn:7 ~keeper:k "masc_ask_status"
      ]
  in
  let tools chunk =
    List.map (fun t -> t.Acting.ct_tool) (Acting.chunk_tools chunk)
  in
  (match Acting.chunks ~traces:[] (entries_of running) with
   | [ current; previous ] ->
       check (option int) "the running lane turn has no number yet" None
         current.Acting.ck_turn;
       check bool "and is not settled" false current.Acting.ck_settled;
       check (list string) "its calls so far" [ "masc_board_list"; "masc_ask_status" ]
         (tools current);
       check (option int) "the turn before keeps its number" (Some 2274)
         previous.Acting.ck_turn;
       check (list string) "and its own call" [ "masc_board_comment" ] (tools previous)
   | chunks -> failf "a running lane turn drew %d rows" (List.length chunks));
  let ended =
    running
    @ [ ledger_tool ~duration_ms:1. ~turn:7 ~keeper:k "masc_board_post_get"
      ; observation ~keeper:k ~session:7 ~completed:2274
      ; turn_settled ~keeper:k ~turn:2275 ~input:1288966 ~output:1779 ~cost:0.0100
      ]
  in
  match Acting.chunks ~traces:[] (entries_of ended) with
  | [ current; previous ] ->
      check (option int) "the observation and the settle number the turn" (Some 2275)
        current.Acting.ck_turn;
      check bool "and close it" true current.Acting.ck_settled;
      check (list string) "with every call of the turn"
        [ "masc_board_list"; "masc_ask_status"; "masc_board_post_get" ]
        (tools current);
      check (list string) "the turn before is unchanged" [ "masc_board_comment" ]
        (tools previous)
  | chunks -> failf "an ended lane turn drew %d rows" (List.length chunks)

(* The call in flight has no observation yet -- its response has not come
   back -- but a keeper runs one turn at a time, so its frames join the
   keeper's open turn rather than opening a second row. *)
let test_a_call_in_flight_joins_the_open_keeper_turn () =
  let events_oldest_first =
    [ observation ~keeper:"alpha" ~session:20 ~completed:6
    ; agent_core ~kind:Observer.Tool_called ~tool:"Read" ~turn:20
        ~tool_use_id:"w1" "alpha"
    ; agent_core ~kind:Observer.Tool_completed ~tool:"Read" ~turn:20
        ~tool_use_id:"w1" "alpha"
    ; agent_core ~kind:Observer.Turn_started ~turn:21 "alpha"
    ]
  in
  check (list string) "one row, the keeper's turn, still running"
    [ "\xe2\x96\xb6 alpha turn 7 | Read 1.0s" ]
    (List.map text
       (Acting.chunk_rows ~traces:[] (entries_of events_oldest_first)))

(* After a settle the next call opens the next keeper turn even before its
   observation names the number: the settled row is closed. *)
let test_a_new_keeper_turn_after_a_settle_opens_its_own_row () =
  let events_oldest_first =
    [ observation ~keeper:"alpha" ~session:20 ~completed:6
    ; agent_core ~kind:Observer.Turn_started ~turn:20 "alpha"
    ; turn_settled ~keeper:"alpha" ~turn:7 ~input:10 ~output:2 ~cost:0.001
    ; agent_core ~kind:Observer.Turn_started ~turn:21 "alpha"
    ]
  in
  check (list string)
    "the new turn has no number yet; the settled one keeps its own"
    [ "\xe2\x96\xb6 alpha turn | running"
    ; "\xe2\x96\xa0 alpha turn 7 | 1 call \xc2\xb7 in 10 out 2 \xc2\xb7 $0.0010"
    ]
    (List.map text
       (Acting.chunk_rows ~traces:[] (entries_of events_oldest_first)))

(* An agent session created without a checkpoint numbers its calls from zero
   again, so the ring can hold ordinal 5 from the old session and from the
   new one. Each call is filed under the keeper turn observed nearest to it,
   so the old turn keeps its call and the new turn gets only its own. *)
let test_a_restarted_session_keeps_each_call_on_its_own_keeper_turn () =
  let events_oldest_first =
    [ observation ~keeper:"alpha" ~session:5 ~completed:6
    ; agent_core ~kind:Observer.Tool_called ~tool:"Read" ~turn:5
        ~tool_use_id:"old" "alpha"
    ; turn_settled ~keeper:"alpha" ~turn:7 ~input:10 ~output:2 ~cost:0.001
    ; observation ~keeper:"alpha" ~session:5 ~completed:7
    ; agent_core ~kind:Observer.Tool_called ~tool:"Grep" ~turn:5
        ~tool_use_id:"new" "alpha"
    ]
  in
  check (list string) "turn 8 holds the new call, turn 7 keeps the old one"
    [ "\xe2\x96\xb6 alpha turn 8 | Grep"
    ; "\xe2\x96\xa0 alpha turn 7 | Read \xc2\xb7 in 10 out 2 \xc2\xb7 $0.0010"
    ]
    (List.map text
       (Acting.chunk_rows ~traces:[] (entries_of events_oldest_first)))

(* With no observation at all -- a feed that opened on a call in flight --
   the row names the event without a number rather than borrowing the
   session's. It used to draw [turn ?]: on a live-only feed the settle that
   carries the number is usually outside the held window, so that question
   was the common reading, not the odd one, and no answer to it was ever
   coming from this row. *)
let test_without_an_observation_a_running_turn_has_no_number () =
  check (list string) "the row names the turn without inventing a number"
    [ "\xe2\x96\xb6 analyst turn | running" ]
    (List.map text
       (Acting.chunk_rows ~traces:[]
          (entries_of [ agent_core ~kind:Observer.Turn_ready ~turn:7 "analyst" ])))

let test_chunk_projection_tracks_ordered_trace_identity () =
  let event = match agent_core ~tool:"Read" ~turn:5 "runtime-lane" with
    | Observer.Agent_core event ->
      Observer.Agent_core { event with correlation = Some "shared-trace" }
    | _ -> fail "expected agent-core fixture" in
  let source = entries_of [event] in
  let traces = [ "keeper-a", "shared-trace"; "keeper-b", "shared-trace" ] in
  let first = Acting.refresh_projection ~previous:None ~traces source in
  let owner projection = match Acting.projection_chunks projection with
    | [chunk] -> chunk.Acting.ck_keeper
    | _ -> fail "expected one attributed chunk" in
  check string "first duplicate trace owner wins" "keeper-a" (owner first);
  let equal_traces = List.map Fun.id traces in
  check bool "fixture mapping list was reallocated" false (traces == equal_traces);
  let reused = Acting.refresh_projection ~previous:(Some first) ~traces:equal_traces source in
  check bool "equal ordered mapping reuses derived chunks" true (first == reused);
  let reversed = Acting.refresh_projection ~previous:(Some reused) ~traces:(List.rev traces) source in
  check string "mapping reorder changes first-match attribution" "keeper-b" (owner reversed);
  let reassigned = Acting.refresh_projection ~previous:(Some reversed)
    ~traces:[ "keeper-c", "shared-trace" ] source in
  check string "unchanged events follow trace reassignment" "keeper-c" (owner reassigned);
  check string "previous immutable projection retains its owner" "keeper-a" (owner first)

let test_chunk_projection_rebuilds_after_append_and_trim () =
  let source = entries_of [agent_core ~tool:"Read" ~turn:5 "keeper-a"] in
  let first = Acting.refresh_projection ~previous:None ~traces:[] source in
  let only projection = match Acting.projection_chunks projection with
    | [chunk] -> chunk
    | _ -> fail "expected one chunk" in
  check bool "initial observed call has no settlement" false (only first).Acting.ck_settled;
  let appended = { Acting.ae_at = 101.; ae_event = settled "keeper-a" } :: source in
  let next = Acting.refresh_projection ~previous:(Some first) ~traces:[] appended in
  check bool "appended settle rebuilds projection" false (first == next);
  check bool "settlement becomes observable" true (only next).Acting.ck_settled;
  check int "existing wire call remains in settled chunk" 1
    (List.length (only next).Acting.ck_wire_tools);
  let trimmed = [List.hd appended] in
  let after_trim = Acting.refresh_projection ~previous:(Some next) ~traces:[] trimmed in
  check bool "trimmed source rebuilds projection" false (next == after_trim);
  check int "trimmed wire call is no longer retained in chunk" 0
    (List.length (only after_trim).Acting.ck_wire_tools);
  let replaced = Acting.refresh_projection ~previous:(Some after_trim) ~traces:[]
    (List.map Fun.id trimmed) in
  check bool "equal-content replacement is a new event source" false (after_trim == replaced);
  let empty = Acting.refresh_projection ~previous:(Some replaced) ~traces:[] [] in
  check int "empty retained feed clears chunks" 0 (List.length (Acting.projection_chunks empty));
  check bool "previous projection remains unclosed" false (only first).Acting.ck_settled

(* The fold carries what the ledger row said past the name and the
   duration: the schedule, the disposition and the two previews reach the
   folded call as they were, and the receipt clock of the row is the
   call's. A wire-plane call stands in with none of them. *)
let test_a_folded_ledger_call_keeps_the_rows_facts () =
  let schedule : Agent_core.Tool_contract.schedule =
    { Agent_core.Tool_contract.planned_index = 1
    ; batch_index = 1
    ; batch_size = 3
    ; execution_mode = Agent_core.Tool_contract.Concurrent
    }
  in
  let row : Observer.event =
    Observer.Keeper_tool_call
      { Observer.kt_keeper = "alpha"
      ; kt_turn = Some 7
      ; kt_tool = "masc_delegate"
      ; kt_duration_ms = Some 50.
      ; kt_disposition = Some (Ok Masc.Tui_decode.Keeper_call_deferred)
      ; kt_at = 5.
      ; kt_tool_use_id = Some "call-2"
      ; kt_schedule = Some (Ok schedule)
      ; kt_tool_args = None
      ; kt_tool_result = None
      ; kt_tool_args_preview = Some "{\"to\":\"probe\"}"
      ; kt_tool_output_preview = Some "queued"
      }
  in
  let chunk =
    match
      Acting.chunks ~traces:[]
        (entries_of [ agent_core ~kind:Observer.Turn_started ~turn:7 ~at:100. "alpha"; row ])
      |> List.filter (fun c -> String.equal c.Acting.ck_keeper "alpha")
    with
    | [ chunk ] -> chunk
    | _ -> fail "one turn, one chunk"
  in
  match Acting.chunk_tools chunk with
  | [ call ] ->
      check string "the tool" "masc_delegate" call.Acting.ct_tool;
      check (option string) "the provider's call id" (Some "call-2") call.Acting.ct_tool_use_id;
      check bool "the disposition as the ledger typed it" true
        (call.Acting.ct_disposition = Some (Ok Masc.Tui_decode.Keeper_call_deferred));
      check bool "the schedule whole" true (call.Acting.ct_schedule = Some (Ok schedule));
      check (option string) "the input preview" (Some "{\"to\":\"probe\"}") call.Acting.ct_input;
      check (option string) "the output preview" (Some "queued") call.Acting.ct_output;
      (* [entries_of] gives the second event receipt clock 101, not the
         row's own [kt_at] of 5: the fold keeps the feed's clock, the one the
         pane ages every other row by. *)
      check (float 0.) "the receipt clock, not the producer's" 101. call.Acting.ct_at
  | calls -> failf "one call expected, %d folded" (List.length calls)

let test_call_key_prefers_the_provider_id () =
  let call ?id ~at tool : Acting.chunk_tool =
    { Acting.ct_tool = tool
    ; ct_duration_ms = None
    ; ct_at = at
    ; ct_tool_use_id = id
    ; ct_session_turn = None
    ; ct_disposition = None
    ; ct_schedule = None
    ; ct_input = None
    ; ct_output = None
    }
  in
  let equal = Acting.call_key_equal in
  check bool "an id names the call" true
    (equal (Acting.call_key (call ~id:"x" ~at:1. "Read")) (Acting.Call_by_id "x"));
  check bool "without one the receipt clock and the tool do" true
    (equal
       (Acting.call_key (call ~at:2. "Read"))
       (Acting.Call_by_receipt { at = 2.; tool = "Read" }));
  check bool "the same clock under another tool is another call" false
    (equal
       (Acting.call_key (call ~at:2. "Read"))
       (Acting.call_key (call ~at:2. "Grep")));
  check bool "an id and a receipt never name the same call" false
    (equal (Acting.Call_by_id "2") (Acting.Call_by_receipt { at = 2.; tool = "2" }));
  (* The wire plane's stand-in carries the wire's call id, so a press on a
     wire call is keyed the way a press on its ledger row would be. *)
  let chunk =
    match
      Acting.chunks ~traces:[]
        (entries_of
           [ agent_core ~kind:Observer.Turn_started ~turn:3 ~at:100. "alpha"
           ; agent_core ~tool:"Read" ~turn:3 ~tool_use_id:"wire-1" ~at:101. "alpha"
           ])
      |> List.filter (fun c -> String.equal c.Acting.ck_keeper "alpha")
    with
    | [ chunk ] -> chunk
    | _ -> fail "one turn, one chunk"
  in
  match Acting.chunk_tools chunk with
  | [ call ] ->
      check bool "keyed by the wire id" true
        (equal (Acting.call_key call) (Acting.Call_by_id "wire-1"))
  | calls -> failf "one call expected, %d folded" (List.length calls)

(* The Activity table's two named columns were literals of 16 cells. The
   agent_core family names its runtime lane as the agent, so those rows drew
   [agent_core-olla...] at every width -- including the ones where the detail
   column beside them was empty. *)
let table_row ?(keeper = "keeper") ?(label = "turn") ?(detail = "") () =
  { Acting.at = 100.; keeper; glyph = Acting.Turn_boundary; label; detail }

let test_a_long_keeper_widens_its_column () =
  let name = "agent_core-glm-coding.glm-5-turbo" in
  let columns =
    Acting.columns ~inner_width:160 [ table_row ~keeper:name () ]
  in
  check int "the column holds the name whole" (String.length name)
    columns.Acting.keeper_cells

(* A roster of short names has no use for a wider column: those cells belong
   to the detail beside them. *)
let test_short_rows_leave_the_columns_where_they_were () =
  let columns =
    Acting.columns ~inner_width:160
      [ table_row ~keeper:"vesta" ~label:"turn" () ]
  in
  check int "the keeper column is what it drew before" 16
    columns.Acting.keeper_cells;
  check int "and so is the event column" 16 columns.Acting.label_cells

(* Neither column goes under what it drew before, whatever the frame is, so a
   narrow terminal draws the table it drew yesterday. *)
let test_no_column_goes_under_what_it_drew_before () =
  for inner_width = 0 to 200 do
    let columns =
      Acting.columns ~inner_width [ table_row ~keeper:"a-very-long-agent-name-indeed" () ]
    in
    check bool
      (Printf.sprintf "inner %d keeps the keeper column" inner_width)
      true
      (columns.Acting.keeper_cells >= 16);
    check bool
      (Printf.sprintf "inner %d keeps the event column" inner_width)
      true
      (columns.Acting.label_cells >= 16)
  done

(* And the detail column keeps half the row: it is the one that carries
   sentences. *)
let test_the_named_columns_leave_detail_its_half () =
  let long = String.make 80 'x' in
  for inner_width = 80 to 200 do
    let columns =
      Acting.columns ~inner_width [ table_row ~keeper:long ~label:long () ]
    in
    let taken = columns.Acting.keeper_cells + columns.Acting.label_cells in
    let half = max 32 ((inner_width - 15) / 2) in
    check bool
      (Printf.sprintf "inner %d leaves detail its half (took %d)" inner_width
         taken)
      true (taken <= half)
  done

let () =
  run "tui acting"
    [ ( "rows"
      , [ test_case "a repeating container failure is one row under turns" `Quick
            test_a_repeating_container_failure_is_one_row_under_turns
        ; test_case "a lane container failure is drawn with its reason" `Quick
            test_a_lane_container_failure_is_drawn_with_its_reason
        ; test_case "the internal runs push is not a keeper's act" `Quick
            test_the_internal_runs_push_is_not_a_keepers_act
        ; test_case "actions hide what says nothing a row can act on" `Quick
            test_actions_hide_what_says_nothing_a_row_can_act_on
        ; test_case "filter explanations name scope and quiet rows" `Quick
            test_filter_explanations_name_scope_and_quiet_rows
        ; test_case "one reply does not bury the actions it sits between" `Quick
            test_one_reply_does_not_bury_the_actions_it_sits_between
        ; test_case "a stream frame draws its keeper and what it was" `Quick
            test_a_stream_frame_draws_its_keeper_and_what_it_was
        ; test_case "a fusion status row names the owning keeper" `Quick
            test_a_fusion_status_row_names_the_owning_keeper
        ; test_case "an untaught event without a tool says only its name" `Quick
            test_an_untaught_event_without_a_tool_says_only_its_name
        ; test_case "an untaught event with a tool still names it" `Quick
            test_an_untaught_event_with_a_tool_still_names_it
        ; test_case "a long reply does not evict the log it streams into" `Quick
            test_a_long_reply_does_not_evict_the_log_it_streams_into
        ; test_case "the old arrival trim would have lost them" `Quick
            test_the_old_arrival_trim_would_have_lost_them
        ; test_case "a reply does not trim the observation a call needs" `Quick
            test_a_reply_does_not_trim_the_observation_a_call_needs
        ; test_case "an observation spends an action slot" `Quick
            test_an_observation_spends_an_action_slot
        ; test_case "an observation leaves the ring with its calls" `Quick
            test_an_observation_leaves_the_ring_with_its_calls
        ; test_case "the session ordinal is named only in the evidence" `Quick
            test_the_session_ordinal_is_named_only_in_the_evidence
        ; test_case "trimming keeps the order it was given" `Quick
            test_trimming_keeps_the_order_it_was_given
        ; test_case "every row wears the clock the feed ordered it by" `Quick
            test_every_row_wears_the_clock_the_feed_ordered_it_by
        ; test_case "a call and its return read as one pair" `Quick
            test_a_call_and_its_return_read_as_one_pair
        ; test_case "a return with no start held has no duration" `Quick
            test_a_return_with_no_start_held_has_no_duration
        ; test_case "keeper rows say what the keeper did" `Quick
            test_keeper_rows_say_what_the_keeper_did
        ; test_case "agent terminal rows keep success and failure distinct" `Quick
            test_agent_terminal_rows_keep_success_and_failure_distinct
        ; test_case "a lane-named event is attributed by its trace" `Quick
            test_a_lane_named_event_is_attributed_by_its_trace
        ; test_case "elapsed text picks a unit" `Quick test_elapsed_text_picks_a_unit
        ; test_case "skill tools wear a skill label in the feed" `Quick
            test_skill_tools_wear_a_skill_label
        ; test_case "turns fold the two planes into one row per turn" `Quick
            test_turns_fold_the_two_planes_into_one_row_per_turn
        ; test_case "a settle joins the open turn it ends despite the number" `Quick
            test_a_settle_joins_the_open_turn_it_ends_despite_the_number
        ; test_case "a running turn names its in-flight call" `Quick
            test_a_running_turn_names_its_in_flight_call
        ; test_case "turns pass non-lifecycle rows through" `Quick
            test_turns_pass_non_lifecycle_rows_through
        ; test_case "turns do not readmit what the scope hides" `Quick
            test_turns_do_not_readmit_what_the_scope_hides
        ; test_case "telemetry alone conjures no turn" `Quick
            test_telemetry_alone_conjures_no_turn
        ; test_case "telemetry refreshes but never duplicates a turn" `Quick
            test_telemetry_refreshes_but_never_duplicates_a_turn
        ; test_case "turns fall back to the wire when the ledger is silent"
            `Quick test_turns_fall_back_to_the_wire_when_the_ledger_is_silent
        ; test_case "a late ledger row stays on its own turn" `Quick
            test_late_ledger_row_stays_on_its_own_turn
        ; test_case "a ledger row after a settle finds its turn" `Quick
            test_ledger_row_after_a_settle_finds_its_turn
        ; test_case "a late ledger row stays with its session without an observation"
            `Quick test_late_ledger_row_stays_with_its_session_without_an_observation
        ; test_case "one keeper turn of three calls is one row" `Quick
            test_one_keeper_turn_of_three_calls_is_one_row
        ; test_case "an observation after its frames still files them" `Quick
            test_an_observation_after_its_frames_still_files_them
        ; test_case "a cli lane turn is numbered when its observation lands" `Quick
            test_a_cli_lane_turn_is_numbered_when_its_observation_lands
        ; test_case "a call in flight joins the open keeper turn" `Quick
            test_a_call_in_flight_joins_the_open_keeper_turn
        ; test_case "a new keeper turn after a settle opens its own row" `Quick
            test_a_new_keeper_turn_after_a_settle_opens_its_own_row
        ; test_case "a restarted session keeps each call on its own keeper turn"
            `Quick test_a_restarted_session_keeps_each_call_on_its_own_keeper_turn
        ; test_case "without an observation a running turn has no number" `Quick
            test_without_an_observation_a_running_turn_has_no_number
        ; test_case "chunk projection follows ordered trace identity" `Quick
            test_chunk_projection_tracks_ordered_trace_identity
        ; test_case "chunk projection rebuilds after append and trim" `Quick
            test_chunk_projection_rebuilds_after_append_and_trim
        ; test_case "a folded ledger call keeps the row's facts" `Quick
            test_a_folded_ledger_call_keeps_the_rows_facts
        ; test_case "a call key prefers the provider's id" `Quick
            test_call_key_prefers_the_provider_id
        ; test_case "a long keeper widens its column" `Quick
            test_a_long_keeper_widens_its_column
        ; test_case "short rows leave the columns where they were" `Quick
            test_short_rows_leave_the_columns_where_they_were
        ; test_case "no column goes under what it drew before" `Quick
            test_no_column_goes_under_what_it_drew_before
        ; test_case "the named columns leave detail its half" `Quick
            test_the_named_columns_leave_detail_its_half
        ] )
    ]

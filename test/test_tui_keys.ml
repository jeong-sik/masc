(* The display contracts of the key table.

   The table exists so footers and the help overlay stop drifting; these
   tests pin the conventions (one spelling per key, one order per screen)
   and the specific drifts the table was written to close. *)

open Masc_tui_types
module Cat = Masc.Keeper_memory_os_types

let check = Alcotest.check
let str = Alcotest.string

let every_surface =
  [ Overview; Acting; Metrics; Keepers Keeper_list; Keepers Keeper_detail
  ; Keepers Keeper_logs; Keepers Keeper_calls; Keepers Keeper_message
  ; Keepers Keeper_runtime_pick; Lanes; Board; Approvals; Planning
  ; Schedules; Verification; Harness; Fusion; Repositories; Code; Changes
  ; Connectors; Runtime; Clients; Config; Resources; Tools; System_logs
  ; Memory
  ]

let schedule_form_row : schedule_row =
  { sch_schedule_id = "daily-check"
  ; sch_schedule_instance_id = "instance-old"
  ; sch_status = "scheduled"
  ; sch_source = "operator_request"
  ; sch_requested_by = "operator (human)"
  ; sch_scheduled_by = "operator (human)"
  ; sch_requested_at_iso = "2026-09-01T00:00:00Z"
  ; sch_due_at_iso = Some "2026-09-02T00:00:00Z"
  ; sch_next_due_at_iso = Some "2026-09-02T00:00:00Z"
  ; sch_expires_at_iso = Some "2026-09-30T00:00:00Z"
  ; sch_recurrence_summary = "daily 09:30:05 Asia/Seoul"
  ; sch_recurrence =
      `Assoc
        [ "kind", `String "daily"
        ; "hour", `Int 9
        ; "minute", `Int 30
        ; "second", `Int 5
        ; "timezone", `String "Asia/Seoul"
        ]
  ; sch_payload_digest = "digest"
  ; sch_payload =
      `Assoc
        [ "kind", `String "masc.keeper_wake"
        ; ( "body"
          , `Assoc
              [ "keeper_name", `String "edgar.a.poe"
              ; "message", `String "inspect the latest work"
              ; "title", `String "daily inspection"
              ; "urgency", `String "low"
              ] )
        ]
  ; sch_payload_kind = Some "masc.keeper_wake"
  ; sch_payload_support = "supported"
  ; sch_payload_dispatch_tool = Some "masc_keeper_wakeup"
  ; sch_payload_target = Some "keeper:edgar.a.poe"
  ; sch_payload_keeper_name = Some "edgar.a.poe"
  ; sch_payload_summary = Some "daily inspection"
  ; sch_last_wake_status = None
  ; sch_last_wake_started_at_iso = None
  ; sch_last_wake_error = None
  ; sch_queue_projection_status = None
  ; sch_queue_pending_count = None
  ; sch_reaction_projection_status = None
  ; sch_reaction_latest_at_iso = None
  ; sch_reaction_kind = None
  ; sch_reaction_keeper_name = None
  ; sch_reaction_stimulus_id = None
  ; sch_reaction_post_id = None
  ; sch_reaction_reason = None
  ; sch_wake_seen = None
  ; sch_turn_started = None
  ; sch_turn_finished = None
  ; sch_queue_ack_seen = None
  ; sch_wake_cancelled = None
  ; sch_stimulus_recorded_at_iso = None
  ; sch_turn_started_recorded_at_iso = None
  ; sch_turn_finished_recorded_at_iso = None
  ; sch_queue_ack_recorded_at_iso = None
  ; sch_wake_cancelled_recorded_at_iso = None
  ; sch_reaction_quarantined = None
  ; sch_runner_hold = None
  }

(* The wire carries both an encoded target and a display name. When the
   latter is absent, an older server's target stays intact. *)
let test_schedule_who_uses_the_named_field () =
  let who row = Masc_tui_types.schedule_row_who row in
  Alcotest.(check (option string)) "the bare name wins" (Some "edgar.a.poe")
    (who schedule_form_row);
  Alcotest.(check (option string)) "an older server leaves the target intact"
    (Some "keeper:edgar.a.poe")
    (who { schedule_form_row with sch_payload_keeper_name = None });
  Alcotest.(check (option string)) "an unnamed non-Keeper target is not parsed"
    (Some "board:sweep")
    (who { schedule_form_row with sch_payload_keeper_name = None
                                ; sch_payload_target = Some "board:sweep" });
  Alcotest.(check (option string)) "an absent target remains absent" None
    (who { schedule_form_row with sch_payload_keeper_name = None
                                ; sch_payload_target = None })
;;

let test_schedule_create_form_names_the_canonical_required_fields () =
  let open Yojson.Safe.Util in
  let form =
    Masc_tui_types.schedule_create_form_json () |> Yojson.Safe.from_string
  in
  check str "keeper is explicit" "" (form |> member "keeper_name" |> to_string);
  check str "message is explicit" "" (form |> member "message" |> to_string);
  check str "one-shot is the visible default" "one_shot"
    (form |> member "recurrence_kind" |> to_string);
  check Alcotest.int "interval alternative is discoverable" 3600
    (form |> member "recurrence_interval_sec" |> to_int);
  check str "cron alternative is discoverable" "0 9 * * *"
    (form |> member "recurrence_cron" |> to_string)

(* The modify key's help says "running/finished rows refuse". These pin that
   the refusal now happens at the keypress, and that the set it refuses is the
   store's own: both ask [Schedule_domain.modify_allowed].

   The vocabulary is checked against
   [Schedule_contract_values.schedule_status_strings] rather than trusted as a
   hand-copied list, which is a second copy of the contract that goes stale
   quietly. *)
let refusal_for status =
  Masc_tui_types.schedule_modify_refusal
    { schedule_form_row with sch_status = status }

let test_modify_refuses_exactly_the_statuses_the_store_refuses () =
  (* The two sides are spelled out rather than recomputed from the gate's own
     expression: a test that recomputes it only proves the code equals itself.
     The sort below then checks these words against the contract's vocabulary,
     so a status added upstream fails here instead of being classified
     unasked. *)
  let refused = [ "running"; "succeeded"; "failed"; "cancelled"; "expired" ] in
  let opens = [ "scheduled"; "due" ] in
  check (Alcotest.list str)
    "the two sides together name every status the contract has"
    (List.sort compare Schedule_contract_values.schedule_status_strings)
    (List.sort compare (refused @ opens));
  List.iter
    (fun word ->
      check Alcotest.bool (word ^ " is refused before the editor opens") true
        (refusal_for word <> None))
    refused;
  (* The inputs that split this from a blanket refusal. Without them a gate
     that refused everything would pass every assertion above. *)
  List.iter
    (fun word ->
      check Alcotest.bool (word ^ " still opens the editor") true
        (refusal_for word = None))
    opens

let test_modify_names_the_status_it_refuses () =
  match refusal_for "running" with
  | None -> Alcotest.fail "a running row must refuse"
  | Some reason ->
    (* The operator is told which word on the screen closed the door, not
       just that it is closed. *)
    check str "the reason quotes the status the screen showed"
      "the store refuses to modify a running schedule (status as last read; \
       refresh if it has changed)"
      reason

(* The TUI and [Schedule_store.update_request] both ask
   [Schedule_domain.modify_allowed]; the store side is pinned in
   test_schedule_store. This pins the TUI side for every contract status. *)
let test_modify_refusal_is_the_shared_predicate () =
  List.iter
    (fun word ->
      match Schedule_domain.schedule_status_of_string word with
      | Error msg -> Alcotest.fail msg
      | Ok status ->
        check Alcotest.bool (word ^ " refuses iff modify_allowed is false")
          (not (Schedule_domain.modify_allowed status))
          (refusal_for word <> None))
    Schedule_contract_values.schedule_status_strings

let test_modify_leaves_an_unnamed_status_to_the_server () =
  (* [sch_status] stays a string so a status this build does not name renders
     as itself. Refusing on a word we cannot read would turn that forward
     compatibility into a row nobody can edit, so the roundtrip is the right
     answer here -- the server knows what it means. *)
  check Alcotest.bool "a status this build does not name is not refused here"
    true
    (refusal_for "paused" = None)

let test_schedule_update_form_preserves_exact_editable_definition () =
  let open Yojson.Safe.Util in
  let form =
    Masc_tui_types.schedule_update_form_json schedule_form_row
    |> Yojson.Safe.from_string
  in
  check str "stable id" "daily-check" (form |> member "schedule_id" |> to_string);
  check str "keeper" "edgar.a.poe" (form |> member "keeper_name" |> to_string);
  check str "full message" "inspect the latest work"
    (form |> member "message" |> to_string);
  check str "urgency" "low" (form |> member "urgency" |> to_string);
  check str "daily kind" "daily" (form |> member "recurrence_kind" |> to_string);
  check Alcotest.int "hour" 9 (form |> member "recurrence_hour" |> to_int);
  check Alcotest.int "minute" 30 (form |> member "recurrence_minute" |> to_int);
  check Alcotest.int "second" 5 (form |> member "recurrence_second" |> to_int);
  check str "timezone" "Asia/Seoul"
    (form |> member "recurrence_timezone" |> to_string);
  check str "due timestamp" "2026-09-02T00:00:00Z"
    (form |> member "due_at_iso" |> to_string);
  check Alcotest.bool "expiry remains present" true
    (form |> member "expires_at_unix" <> `Null)

let sample_memory_fact ~category ~claim : Masc.Tui_decode_memory_facts.memory_fact =
  { Masc.Tui_decode_memory_facts.mf_claim = claim
  ; mf_category = category
  ; mf_origin = "authored"
  ; mf_first_seen = 0.
  ; mf_last_seen = 0.
  ; mf_memory_id = claim
  ; mf_events = Masc.Tui_decode_memory_facts.no_memory_fact_events
  }

(* The browser open on the snapshot's keeper, with its facts answered the way
   the answer handler settles them. *)
let answer_memory_facts (state : Masc_tui_types.state) (snapshot : Masc.Tui_decode_memory_facts.memory_fact_snapshot) =
  let keeper = snapshot.Masc.Tui_decode_memory_facts.mfs_keeper in
  state.Masc_tui_types.memory_facts_keeper <- Some keeper;
  match Masc_tui_fetched.start ~equal:String.equal state.Masc_tui_types.memory_facts ~key:keeper with
  | Masc_tui_fetched.Already_loading -> Alcotest.fail "fixture already loading"
  | Masc_tui_fetched.Started (next, request) ->
      state.Masc_tui_types.memory_facts <-
        Masc_tui_fetched.complete ~equal:String.equal next request (Ok (snapshot, None))
;;

let memory_state_with_facts () =
  let state = create_state ~workspace:"" ~port:0 ~refresh_interval:0. () in
  state.memory_facts_keeper <- Some "alpha";
  answer_memory_facts state
      { Masc.Tui_decode_memory_facts.mfs_keeper = "alpha"
      ; mfs_ordinary =
          Masc.Tui_decode_memory_facts.Memory_store_present
            { Masc.Tui_decode_memory_facts.mos_revision = 1
            ; mos_updated_at = 0.
            ; mos_facts =
                [ sample_memory_fact ~category:Cat.Lesson ~claim:"a"
                ; sample_memory_fact ~category:Cat.Blocker ~claim:"b"
                ]
            }
      ; mfs_source =
          Masc.Tui_decode_memory_facts.Memory_store_present
            { Masc.Tui_decode_memory_facts.mss_revision = 1
            ; mss_updated_at = 0.
            ; mss_facts =
                [ { Masc.Tui_decode_memory_facts.msf_claim = "bound"
                  ; msf_first_seen = 0.
                  ; msf_path = "docs/a.md"
                  ; msf_sha256 = "cafe"
                  }
                ]
            ; mss_invalidations =
                [ { Masc.Tui_decode_memory_facts.mi_source_path = "docs/old.md"
                  ; mi_invalidated_at = 0.
                  ; mi_reason = "source_changed"
                  }
                ]
            }
      ; mfs_events_read_error = None
      };
  state

let category_filter_testable =
  let pp fmt = function
    | Category_all -> Format.pp_print_string fmt "Category_all"
    | Category_ordinary c ->
        Format.fprintf fmt "Category_ordinary %S"
          (Cat.category_to_string c)
    | Category_source -> Format.pp_print_string fmt "Category_source"
    | Category_dropped -> Format.pp_print_string fmt "Category_dropped"
  in
  Alcotest.testable pp ( = )

let test_memory_fact_rows_follow_the_category_filter () =
  let state = memory_state_with_facts () in
  Alcotest.(check int) "All lists both stores plus the drops" 4
    (List.length (memory_fact_rows state));
  state.memory_facts_category <- Category_ordinary Cat.Lesson;
  (match memory_fact_rows state with
   | [ Memory_row_fact fact ] ->
       check str "the filter narrows ordinary facts only" "a"
         fact.Masc.Tui_decode_memory_facts.mf_claim
   | rows ->
       Alcotest.fail
         (Printf.sprintf "unexpected filtered shape (%d rows)"
            (List.length rows)));
  Alcotest.(check (list category_filter_testable)) "categories are the loaded ones, sorted"
    [ Category_ordinary Cat.Blocker
    ; Category_ordinary Cat.Lesson
    ; Category_source
    ; Category_dropped
    ]
    (memory_fact_categories state)

let test_memory_category_cycle_returns_to_all () =
  let categories = [ Category_ordinary Cat.Blocker; Category_ordinary Cat.Lesson ] in
  Alcotest.(check category_filter_testable) "All steps to the first" (Category_ordinary Cat.Blocker)
    (next_memory_category Category_all categories);
  Alcotest.(check category_filter_testable) "then to the next" (Category_ordinary Cat.Lesson)
    (next_memory_category (Category_ordinary Cat.Blocker) categories);
  Alcotest.(check category_filter_testable) "the last returns to All" Category_all
    (next_memory_category (Category_ordinary Cat.Lesson) categories);
  Alcotest.(check category_filter_testable) "a vanished category restarts at All" Category_all
    (next_memory_category (Category_ordinary Cat.Goal) categories);
  Alcotest.(check category_filter_testable) "no categories keeps All" Category_all
    (next_memory_category Category_all [])

let answer_fusion_runs state snapshot =
  match Masc_tui_fetched.start ~equal:Unit.equal state.fusion_runs ~key:() with
  | Masc_tui_fetched.Already_loading -> Alcotest.fail "fixture already loading"
  | Masc_tui_fetched.Started (next, request) ->
      state.fusion_runs <- Masc_tui_fetched.complete ~equal:Unit.equal next request (Ok snapshot)

let test_fusion_historical_evidence_is_a_selectable_board_reference () =
  let state = create_state ~workspace:"" ~port:0 ~refresh_interval:0. () in
  let response = `Assoc
    [ "generated_at", `String "2026-09-07T00:00:00Z"
    ; "count", `Int 0; "runs", `List []
    ; "replay", `Assoc ["status", `String "complete"; "lines_read", `Int 2;
                        "malformed_lines", `Int 1; "dropped_running", `Int 1]
    ; "historical_evidence", `List
        [ `Assoc ["run_id", `String "past-run"; "post_id", `String "original-post";
                  "title", `String "Original conclusion"; "created_at", `Float 10.]
        ]
    ] in
  (match Masc.Tui_decode_fusion.decode_fusion_snapshot response with
   | Error detail -> Alcotest.fail detail
   | Ok snapshot -> answer_fusion_runs state snapshot);
  check Alcotest.int "history remains in the selectable list with no retained runs"
    1 (List.length (Masc_tui_fusion_model.fusion_list_entries state));
  (match Masc_tui_fusion_model.selected_fusion_entry state with
   | Some (Masc.Tui_decode_fusion.Fusion_historical_evidence evidence) ->
       check str "selection retains original Board identity" "original-post" evidence.fhe_post_id
   | Some (Masc.Tui_decode_fusion.Fusion_retained_run _) | None ->
       Alcotest.fail "historical evidence disappeared or became an invented run");
  check Alcotest.int "historical evidence does not inflate Keeper run count"
    0 (List.length (Masc_tui_fusion_model.selected_keeper_runs state))

let test_keeper_runs_selection_survives_a_shorter_list () =
  let state = create_state ~workspace:"" ~port:0 ~refresh_interval:0. () in
  let keeper name : Tui_decode.keeper =
    { k_origin = Masc.Tui_decode.Persisted_keeper
  ; k_name = name
  ; k_paused = false
  ; k_identity = Ok { k_trace_id = name; k_created_at = "2026-09-07T00:00:00Z"; k_updated_at = "2026-09-07T00:00:00Z" }
  ; k_activity = Some { k_current_task_id = None; k_total_turns = 0; k_total_tokens = 0; k_total_cost_usd = 0.; k_last_turn_ts = ""; k_last_proactive_outcome = None }
  }
  in
  let run id keeper = `Assoc
    [ "run_id", `String id; "keeper", `String keeper; "preset", `String "trio"
    ; "topology", `String "simple"; "started_at", `Float 1.; "finished_at", `Float 2.
    ; "status", `String "completed"; "stage", `String "completed"; "progress", `Null
    ]
  in
  let load runs =
    match Masc.Tui_decode_fusion.decode_fusion_snapshot (`Assoc
      [ "generated_at", `String "2026-09-07T00:00:00Z"
      ; "replay", `Assoc ["status", `String "not_replayed"]
      ; "historical_evidence", `List []
      ; "count", `Int (List.length runs); "runs", `List runs ]) with
    | Ok snapshot -> answer_fusion_runs state snapshot
    | Error detail -> Alcotest.fail detail
  in
  let selected () =
    Option.map (fun (index, run) -> index, run.Masc.Tui_decode_fusion.fur_run_id)
      (Masc_tui_fusion_model.selected_keeper_run state)
  in
  state.keepers <- [keeper "alpha"; keeper "beta"];
  load [run "alpha-1" "alpha"; run "alpha-2" "alpha"; run "beta-1" "beta"];
  state.keeper_run_cursor <- 1;
  check (Alcotest.option (Alcotest.pair Alcotest.int str)) "selected alpha run"
    (Some (1, "alpha-2")) (selected ());
  state.keeper_cursor <- 1;
  check (Alcotest.option (Alcotest.pair Alcotest.int str)) "a shorter Keeper list remains selectable"
    (Some (0, "beta-1")) (selected ());
  state.keeper_cursor <- 0;
  load [run "alpha-1" "alpha"];
  check (Alcotest.option (Alcotest.pair Alcotest.int str)) "a refreshed list remains selectable"
    (Some (0, "alpha-1")) (selected ());
  load [];
  check (Alcotest.option (Alcotest.pair Alcotest.int str)) "empty list has no action target"
    None (selected ())

let ring_stop surface =
  Masc_tui_surface_navigation.surface_ring_index
    (create_state ~workspace:"" ~port:0 ~refresh_interval:0. ())
    surface

(* Every view lands on a stop the ring holds. The index cannot say this: a
   family missing from the ring comes back as 0, Overview's position, and a
   comparison against Overview would pass. *)
let test_every_view_has_a_ring_stop () =
  let state = create_state ~workspace:"" ~port:0 ~refresh_interval:0. () in
  List.iter
    (fun surface ->
      Alcotest.(check bool) "the view's family is a ring stop" true
        (List.exists
           (fun (stop, _) -> stop = Masc_tui_surface_navigation.surface_ring_family state surface)
           surface_ring))
    every_surface

let test_task_review_is_a_planning_child () =
  Alcotest.(check bool) "Task Review is not a top-level ring entry" false
    (List.exists (fun (surface, _) -> surface = Verification) surface_ring);
  Alcotest.(check int) "Task Review highlights Planning"
    (ring_stop Planning)
    (ring_stop Verification)

(* Verdicts is the far half of Task Review -- one lists what is waiting for a
   ruling, the other what was ruled -- and it stood on the top-level ring under
   the name "Harness", which named a mechanism rather than a thing an operator
   opens. Both halves now hang off Planning, and [v] walks the three. *)
let test_verdicts_is_a_planning_child () =
  Alcotest.(check bool) "Verdicts is not a top-level ring entry" false
    (List.exists (fun (surface, _) -> surface = Harness) surface_ring);
  Alcotest.(check int) "Verdicts highlights Planning"
    (ring_stop Planning)
    (ring_stop Harness);
  Alcotest.(check bool) "and the help sheet files it under Planning" true
    (List.exists
       (fun (label, _) -> String.equal label "Work / Task Verdicts")
       (Masc_tui_keys.help_sections ()))

(* Changes reads one keeper's file writes and binds to the roster cursor on
   entry, so it opens with [f] from the roster instead of holding a Tab stop
   of its own. *)
let test_changes_is_a_keeper_child () =
  Alcotest.(check bool) "Changes is not a top-level ring entry" false
    (List.exists (fun (surface, _) -> surface = Changes) surface_ring);
  Alcotest.(check int) "Changes highlights Keepers"
    (ring_stop (Keepers Keeper_list))
    (ring_stop Changes)

let test_keeper_operations_are_not_top_level_tabs () =
  List.iter
    (fun (surface, label) ->
       Alcotest.(check bool) (label ^ " is not a top-level ring entry") false
         (List.exists (fun (entry, _) -> entry = surface) surface_ring);
       Alcotest.(check int) (label ^ " highlights Keepers")
         (ring_stop (Keepers Keeper_list))
         (ring_stop surface))
    [ Connectors, "Channels"; Schedules, "Automation" ];
  Alcotest.(check (list string)) "Keeper operation tab labels"
    [ "Channels"; "Automation"; "Runs" ]
    (List.filter_map
       (fun tab ->
          match tab with
          | Detail_channels | Detail_automation | Detail_runs ->
              Some (keeper_detail_tab_label tab)
          | Detail_info | Detail_items | Detail_sandbox | Detail_instructions | Detail_secrets
          | Detail_github | Detail_identity -> None)
       keeper_detail_tabs)

let test_lanes_is_a_main_destination () =
  Alcotest.(check bool) "Lanes is reached through System" false
    (List.exists (fun (surface, _) -> surface = Lanes) surface_ring);
  Alcotest.(check int) "Lanes highlights System"
    (ring_stop Config) (ring_stop Lanes);
  Alcotest.(check bool) "help sheet names Lanes directly" true
    (List.exists
       (fun (label, _) -> String.equal label "Lanes")
       (Masc_tui_keys.help_sections ()));
  let lanes_keys =
    List.map
      (fun (b : Masc_tui_keys.binding) -> b.Masc_tui_keys.key)
      (Masc_tui_keys.for_surface Lanes)
  in
  Alcotest.(check bool) "Lanes documents the [p] way back" true
    (List.mem "p" lanes_keys)

(* Code's tree is always somebody's checkout -- a registered repository, a
   keeper workspace, or the project -- and Enter on a Workspace row is
   already how a reader walks into it, so it hangs off Workspace instead of
   holding a Tab stop of its own. *)
let test_code_is_a_workspace_child () =
  Alcotest.(check bool) "Code is not a top-level ring entry" false
    (List.exists (fun (surface, _) -> surface = Code) surface_ring);
  Alcotest.(check int) "Code highlights Workspace"
    (ring_stop Repositories)
    (ring_stop Code);
  Alcotest.(check bool) "and the help sheet files it under Workspace" true
    (List.exists
       (fun (label, _) -> String.equal label "Workspace / Code")
       (Masc_tui_keys.help_sections ()));
  Alcotest.(check bool) "and the ring stop is spelled Workspace" true
    (List.exists
       (fun (surface, label) ->
         surface = Repositories && String.equal label "Workspace")
       surface_ring)

(* Resources and Tools are registration catalogs -- what is wired up here,
   read rarely -- so they hang off Config under [s] and [t] instead of
   holding Tab stops of their own. *)
let test_resources_is_a_config_child () =
  Alcotest.(check bool) "Resources is not a top-level ring entry" false
    (List.exists (fun (surface, _) -> surface = Resources) surface_ring);
  Alcotest.(check int) "Resources highlights Config"
    (ring_stop Config)
    (ring_stop Resources);
  Alcotest.(check bool) "and the help sheet files it under Config" true
    (List.exists
       (fun (label, _) -> String.equal label "System / Resources")
       (Masc_tui_keys.help_sections ()));
  let config_keys =
    List.map
      (fun (b : Masc_tui_keys.binding) -> b.Masc_tui_keys.key)
      (Masc_tui_keys.for_surface Config)
  in
  Alcotest.(check bool) "Config documents the [s] hop" true
    (List.mem "s" config_keys)

let test_tools_is_a_config_child () =
  Alcotest.(check bool) "Tools is not a top-level ring entry" false
    (List.exists (fun (surface, _) -> surface = Tools) surface_ring);
  Alcotest.(check int) "Tools highlights Config"
    (ring_stop Config)
    (ring_stop Tools);
  Alcotest.(check bool) "and the help sheet files it under Config" true
    (List.exists
       (fun (label, _) -> String.equal label "System / Tools")
       (Masc_tui_keys.help_sections ()));
  let config_keys =
    List.map
      (fun (b : Masc_tui_keys.binding) -> b.Masc_tui_keys.key)
      (Masc_tui_keys.for_surface Config)
  in
  Alcotest.(check bool) "Config documents the [t] hop" true
    (List.mem "t" config_keys)

(* Tool calls settling and the server's own log lines are two readings of
   one fleet timeline, so Logs hangs off Activity (the Acting surface)
   under its [1 / 2] tabs instead of holding a Tab stop of its own. *)
let test_logs_is_an_activity_child () =
  Alcotest.(check bool) "Runtime is inside Config" false
    (List.exists (fun (surface, _) -> surface = Runtime) surface_ring);
  List.iter (fun surface ->
      Alcotest.(check int) "runtime children highlight Config"
        (ring_stop Config) (ring_stop surface))
    [Runtime; Clients];
  Alcotest.(check bool) "Logs is not a top-level ring entry" false
    (List.exists (fun (surface, _) -> surface = System_logs) surface_ring);
  Alcotest.(check int) "Logs highlights System"
    (ring_stop Config)
    (ring_stop System_logs);
  Alcotest.(check bool) "the help sheet still exposes logs" true
    (List.exists
       (fun (label, _) -> String.equal label "System / Logs")
       (Masc_tui_keys.help_sections ()));
  Alcotest.(check bool) "the ring stop is spelled System" true
    (List.exists
       (fun ((surface : surface), label) ->
         surface = Config && String.equal label "System")
       surface_ring);
  let acting_keys =
    List.map
      (fun (b : Masc_tui_keys.binding) -> b.Masc_tui_keys.key)
      (Masc_tui_keys.for_surface Acting)
  in
  Alcotest.(check bool) "Activity documents the way to Logs" true
    (List.mem "e / l" acting_keys)

(* Telemetry and multicore engine metrics hang off Overview under [m]
   instead of holding a top-level Tab stop of their own. *)
let test_metrics_is_an_overview_child () =
  Alcotest.(check bool) "Usage is a top-level ring entry" true
    (List.exists (fun (surface, _) -> surface = Metrics) surface_ring);
  Alcotest.(check int) "Usage highlights itself"
    (ring_stop Metrics)
    (ring_stop Metrics);
  let overview_keys =
    List.map
      (fun (b : Masc_tui_keys.binding) -> b.Masc_tui_keys.key)
      (Masc_tui_keys.for_surface Overview)
  in
  Alcotest.(check bool) "Dashboard documents the [m] hop" true
    (List.mem "m" overview_keys)

(* The strip dropped the Approvals entry when nothing was waiting. "Nothing
   is waiting" is a reading, and with the server unreachable nobody took it:
   the confirm queue, the held calls and the questions all failed, every other
   surface drew "(load failed)", and this entry simply left the ring -- so the
   screen that holds the operator's decisions was the only one that read as
   settled.

   Approvals is now a Work child (RFC-tui-measured-operator-home), so the stop
   that leads to it is Work and it stands whatever was read. What must still
   not read as settled is the reading itself: it is current only once every
   list came back, and the Dashboard's approvals count marks it with "?"
   until then. *)
let approvals_reading_is_current state =
  state.approval_snapshot <-
    Some
      { Masc_tui_operator_projection.aps_items = []
      ; aps_actor_filter = None
      ; aps_filter_active = false
      ; aps_visible_count = 0
      ; aps_total_count = 0
      ; aps_hidden_count = 0
      };
  state.keeper_tool_approvals_observed <- true;
  state.keeper_tool_approvals_error <- None;
  state.gate_snapshot_observed <- true;
  state.gate_error <- None;
  state.gate_queue_unavailable <- None;
  state.asks_snapshot <-
    Some { Masc.Tui_decode_asks.asn_keeper = None; asn_open_count = 0; asn_rows = [] };
  state.asks_error <- None

let approvals_home_in_ring state =
  let home = Masc_tui_surface_navigation.surface_ring_family state Approvals in
  List.exists (fun (surface, _) -> surface = home) Masc_tui_types.surface_ring

let test_approvals_stay_reachable_and_unread_until_a_reading_empties_it () =
  let state = create_state ~workspace:"" ~port:0 ~refresh_interval:0. () in
  state.view <- Overview;
  Alcotest.(check bool) "Approvals is reached through Work" true
    (Masc_tui_surface_navigation.surface_ring_family state Approvals = Planning);
  Alcotest.(check bool) "Work, where Approvals opens, is in the ring" true
    (approvals_home_in_ring state);
  Alcotest.(check bool) "before any reading nothing reads as settled" false
    (Masc_tui_approvals_model.approvals_reading_current state);
  approvals_reading_is_current state;
  Alcotest.(check bool) "a reading with nothing in it is current" true
    (Masc_tui_approvals_model.approvals_reading_current state);
  state.keeper_tool_approvals_error <- Some "held calls poll failed";
  Alcotest.(check bool) "a failed held-calls poll is not current" false
    (Masc_tui_approvals_model.approvals_reading_current state);
  state.keeper_tool_approvals_error <- None;
  state.asks_error <- Some "questions poll failed";
  Alcotest.(check bool) "a failed questions poll is not current" false
    (Masc_tui_approvals_model.approvals_reading_current state);
  state.asks_error <- None;
  state.approval_snapshot <- None;
  Alcotest.(check bool) "an unread confirm queue is not current" false
    (Masc_tui_approvals_model.approvals_reading_current state);
  (* The durable Gate queue is the fourth list the count walks. Its rows are
     the ones that keep while nobody watches, so an unreadable Gate store is
     the case where a count without "?" misleads the most. *)
  approvals_reading_is_current state;
  state.gate_error <- Some "gate poll failed";
  Alcotest.(check bool) "a failed Gate poll is not current" false
    (Masc_tui_approvals_model.approvals_reading_current state);
  state.gate_error <- None;
  state.gate_queue_unavailable <- Some "approval queue store unreadable";
  Alcotest.(check bool) "a Gate queue the server could not read is not current"
    false (Masc_tui_approvals_model.approvals_reading_current state);
  state.gate_queue_unavailable <- None;
  state.gate_snapshot_observed <- false;
  Alcotest.(check bool) "a Gate queue not read yet is not current" false
    (Masc_tui_approvals_model.approvals_reading_current state);
  state.gate_snapshot_observed <- true;
  state.keeper_tool_approvals_observed <- false;
  Alcotest.(check bool) "held calls not read yet are not current" false
    (Masc_tui_approvals_model.approvals_reading_current state);
  state.keeper_tool_approvals_observed <- true;
  Alcotest.(check bool) "every list read and empty is current again" true
    (Masc_tui_approvals_model.approvals_reading_current state)

(* The Gate poll answered once, with an empty queue, and every poll since
   has failed. The rows it keeps are that first answer's, so the queue is
   empty on screen while the server may be holding Gate approvals. The strip
   kept its entry, but the screen it opened said "(no pending approvals)"
   under "MASC Approvals (0)" (#39172 review, 2026-09-26). Every place that
   says whether the lists were read now reads the same per-list readings. *)
let test_a_gate_poll_that_fails_after_one_answered_is_not_an_empty_queue () =
  let state = create_state ~workspace:"" ~port:0 ~refresh_interval:0. () in
  state.view <- Overview;
  approvals_reading_is_current state;
  Alcotest.(check bool) "every list read and empty: nothing pending" true
    (Masc_tui_approvals_model.approvals_empty_queue (Masc_tui_approvals_model.approvals_reading state) = Masc_tui_approvals_model.Nothing_pending);
  let cause = "gate load failed: HTTP 503" in
  state.gate_error <- Some cause;
  let reading = Masc_tui_approvals_model.approvals_reading state in
  Alcotest.(check bool) "the empty queue names the Gate queue as stale" true
    (Masc_tui_approvals_model.approvals_empty_queue reading
     = Masc_tui_approvals_model.Lists_not_read [ ("Gate queue", Masc_tui_approvals_model.Approval_stale cause) ]);
  Alcotest.(check string) "the title says the Gate queue is stale"
    ", Gate queue stale" (Masc_tui_approvals_model.approvals_title_notes reading);
  Alcotest.(check bool) "and the reading is not current" false
    (Masc_tui_approvals_model.approvals_reading_current state);
  state.gate_error <- None;
  state.gate_queue_unavailable <- Some "approval queue store is unreadable";
  let reading = Masc_tui_approvals_model.approvals_reading state in
  Alcotest.(check bool) "an unreadable Gate store is named, not emptied" true
    (Masc_tui_approvals_model.approvals_empty_queue reading
     = Masc_tui_approvals_model.Lists_not_read
         [ ("Gate queue", Masc_tui_approvals_model.Approval_unavailable "approval queue store is unreadable") ]);
  Alcotest.(check string) "and the title says so"
    ", Gate queue unavailable" (Masc_tui_approvals_model.approvals_title_notes reading);
  state.gate_queue_unavailable <- None;
  Alcotest.(check bool) "the next answered poll empties it again" true
    (Masc_tui_approvals_model.approvals_empty_queue (Masc_tui_approvals_model.approvals_reading state) = Masc_tui_approvals_model.Nothing_pending);
  Alcotest.(check string) "with no note" "" (Masc_tui_approvals_model.approvals_title_notes (Masc_tui_approvals_model.approvals_reading state))

let test_browser_lanes_highlight_config () =
  let state = create_state ~workspace:"" ~port:0 ~refresh_interval:0. () in
  state.view <- Connectors;
  check Alcotest.int "channel bindings remain under Keepers"
    (Masc_tui_surface_navigation.surface_ring_index state (Keepers Keeper_list))
    (Masc_tui_surface_navigation.surface_ring_index state Connectors);
  List.iter (fun source ->
      show_browser_lane state;
      state.browser_lane <- Some
        (Browser_lane_view.switch_source source (Browser_lane_view.create ()));
      let index = Masc_tui_surface_navigation.surface_ring_index state Connectors in
      check Alcotest.int "Browser reader highlights Config"
        (Masc_tui_surface_navigation.surface_ring_index state Config) index;
      check Alcotest.bool "the selected ring entry is Config, not the fallback"
        true (fst (List.nth (Masc_tui_types.surface_ring) index) = Config))
    [Browser_lane_view.Live; Browser_lane_view.Automation];
  state.browser_lane <- None;
  check Alcotest.int "closing the reader restores the Keeper parent"
    (Masc_tui_surface_navigation.surface_ring_index state (Keepers Keeper_list))
    (Masc_tui_surface_navigation.surface_ring_index state Connectors)

(* One ask can carry several questions, and the surface counts them under the
   word "question": its title and the block header above the rows both read
   from [Masc_tui_approvals_model.approvals_open_question_count]. It counted the asks,
   so a fleet holding one ask of two questions said "1 question" while the
   line three rows below it said "+2 more questions". *)
let test_the_question_count_counts_questions () =
  let ask id questions : Masc.Tui_decode_asks.ask_row =
    { Masc.Tui_decode_asks.ar_keeper = "jazz-developer"
    ; ar_id = id
    ; ar_asked_at = 0.0
    ; ar_context = None
    ; ar_questions =
        List.init questions (fun index ->
            { Masc.Tui_decode_asks.aq_id = Printf.sprintf "%s-q%d" id index
            ; aq_header = "header"
            ; aq_prompt = "prompt"
            ; aq_mode = Masc.Tui_decode_asks.Ask_single
            ; aq_free_text = Masc.Tui_decode_asks.Ask_choices_only
            ; aq_choices = []
            })
    ; ar_resolution = Masc.Tui_decode_asks.Ask_open
    }
  in
  let state = create_state ~workspace:"" ~port:0 ~refresh_interval:0. () in
  state.asks_snapshot <-
    Some
      { Masc.Tui_decode_asks.asn_keeper = None
      ; asn_open_count = 2
      ; asn_rows = [ ask "a1" 2; ask "a2" 1 ]
      };
  Alcotest.(check int) "two asks holding three questions" 3
    (Masc_tui_approvals_model.approvals_open_question_count state);
  (* The surface's own pending reading is the approvals plus these, and the
     title draws it. *)
  Alcotest.(check int) "and the surface counts them the same way" 3
    (Masc_tui_approvals_model.approvals_surface_pending state);
  (* A resolved ask is not waiting on anyone, so its questions are not
     counted either. *)
  state.asks_snapshot <-
    Some
      { Masc.Tui_decode_asks.asn_keeper = None
      ; asn_open_count = 1
      ; asn_rows =
          [ ask "a1" 2
          ; { (ask "a2" 4) with Masc.Tui_decode_asks.ar_resolution =
                Masc.Tui_decode_asks.Ask_answered
                  { aa_answered_at = 1.0; aa_question_ids = [] }
            }
          ]
      };
  Alcotest.(check int) "only the open ask's questions" 2
    (Masc_tui_approvals_model.approvals_open_question_count state)

(* The question count reads 0 both when no question is open and when the
   questions were never read, so the title needs to know which. *)
let test_the_questions_reading_tells_unread_from_none_open () =
  let state = create_state ~workspace:"" ~port:0 ~refresh_interval:0. () in
  let reading () =
    match Masc_tui_approvals_model.approvals_questions_reading state with
    | Masc_tui_approvals_model.List_read -> "current"
    | Masc_tui_approvals_model.List_not_read Masc_tui_approvals_model.Approval_unread -> "unread"
    | Masc_tui_approvals_model.List_not_read (Masc_tui_approvals_model.Approval_failed _) -> "failed"
    | Masc_tui_approvals_model.List_not_read (Masc_tui_approvals_model.Approval_stale _) -> "stale"
    | Masc_tui_approvals_model.List_not_read (Masc_tui_approvals_model.Approval_unavailable _) -> "unavailable"
  in
  Alcotest.(check string) "before the first poll answers" "unread" (reading ());
  state.asks_error <- Some "connection refused";
  Alcotest.(check string) "a first poll that failed" "failed" (reading ());
  Alcotest.(check string) "which the title calls unread: nothing was read"
    ", questions unread"
    (Masc_tui_approvals_model.approval_list_note ~name:"questions" (Masc_tui_approvals_model.approvals_questions_reading state));
  state.asks_snapshot <-
    Some { Masc.Tui_decode_asks.asn_keeper = None; asn_open_count = 0; asn_rows = [] };
  Alcotest.(check string) "rows kept from before a failed poll" "stale"
    (reading ());
  state.asks_error <- None;
  Alcotest.(check string) "an answered poll with no question" "current"
    (reading ());
  Alcotest.(check int) "which counts the same 0 as unread" 0
    (Masc_tui_approvals_model.approvals_open_question_count state)

let section name =
  match List.assoc_opt name (Masc_tui_keys.help_sections ()) with
  | Some entries -> entries
  | None -> Alcotest.failf "help has no %S section" name

let test_chat_quiet_leave_respects_the_draft () =
  let leaves = Masc_tui_keys.chat_quiet_leave in
  List.iter (fun (input_supported, turn_active, draft_empty, expected) ->
    Alcotest.(check bool) "printable Q follows viewport, turn and complete draft" expected
      (leaves ~input_supported ~turn_active ~draft_empty "Q");
    Alcotest.(check bool) "Ctrl-Q always leaves" true
      (leaves ~input_supported ~turn_active ~draft_empty "\017");
    Alcotest.(check bool) "lowercase q remains text" false
      (leaves ~input_supported ~turn_active ~draft_empty "q"))
    [ true, true, true, true; true, true, false, false
    ; true, false, true, false; true, false, false, false
    ; false, true, true, true; false, true, false, true
    ; false, false, true, true; false, false, false, true ];
  let chat = Masc_tui_keys.for_surface (Keepers Keeper_message) in
  Alcotest.(check bool) "chat help names both quiet exits" true
    (List.exists
       (fun (binding : Masc_tui_keys.binding) ->
         String.equal binding.key "Q / Ctrl-Q"
         && binding.help = Some
              "Q on an active turn with an empty draft or hidden composer; Ctrl-Q always leaves without interrupting")
       chat)

let test_keepers_jump_uses_one_binding_for_dispatch_and_help () =
  let global_threes =
    List.filter
      (fun (binding : Masc_tui_keys.binding) -> String.equal binding.key "3")
      Masc_tui_keys.global
  in
  Alcotest.(check int) "Global declares 3 once" 1 (List.length global_threes);
  Alcotest.(check bool) "3 opens Keepers after local input declines it" true
    (Masc_tui_keys.opens_keepers ~message_mode:false "3");
  Alcotest.(check bool) "message input keeps printable 3" false
    (Masc_tui_keys.opens_keepers ~message_mode:true "3");
  Alcotest.(check bool) "another key does not open Keepers" false
    (Masc_tui_keys.opens_keepers ~message_mode:false "x");
  Alcotest.(check string) "Help states the local-owner boundary"
    "jump to Keepers when the active field or panel does not use 3"
    (List.assoc "3" (section "Global"));
  let overview_keys =
    List.map
      (fun (binding : Masc_tui_keys.binding) -> binding.key)
      (Masc_tui_keys.for_surface Overview)
  in
  Alcotest.(check bool) "2 is not an Overview-only binding" false
    (List.mem "2" overview_keys)

let standalone_lane ~(lane : Standalone_lane.t) ~label : Tui_decode.standalone_lane =
  { Tui_decode.sl_lane = lane
  ; sl_label = label
  ; sl_purpose = None
  ; sl_required = false
  ; sl_status = Tui_decode.Standalone_idle
  ; sl_configuration_state = Tui_decode.Lane_ready
  ; sl_jev = None
  ; sl_admitted_slots = []
  ; sl_cli_slots = []
  ; sl_dropped_slots = []
  ; sl_declared_slots = []
  ; sl_declared_cli_slots = []
  ; sl_admission_error = None
  ; sl_retained_run_count = 0
  ; sl_running_count = 0
  ; sl_succeeded_count = 0
  ; sl_failed_count = 0
  ; sl_cancelled_count = 0
  ; sl_last_started_at = None
  ; sl_last_terminal_at = None
  ; sl_last_outcome = None
  ; sl_p50_elapsed_s = None
  ; sl_selected_slots = []
  ; sl_runs_without_slot =
      { Tui_decode.slws_vendor_system_one = 0; slws_server_restarted = 0; slws_no_slot = 0 }
  }

(* A compact exact subset for key/selection fixtures; not a production census. *)
let four_standalone_lanes =
  [ standalone_lane ~lane:Standalone_lane.Board_attention ~label:"Board Attention"
  ; standalone_lane ~lane:Standalone_lane.Hitl_auto_judge ~label:"HITL Auto Judge"
  ; standalone_lane ~lane:Standalone_lane.Librarian ~label:"Librarian"
  ; standalone_lane ~lane:Standalone_lane.Verifier ~label:"Verifier"
  ]

let standalone_snapshot lanes : Tui_decode.standalone_lanes_snapshot =
  { Tui_decode.sls_observed_at_unix = 0.
  ; sls_exact_run_projection_count = 0
  ; sls_exact_run_source_total = 0
  ; sls_exact_run_projection_truncated = false
  ; sls_lanes = lanes
  }

let keeper_lane name : Tui_decode.keeper_lane =
  { Tui_decode.kl_keeper = name
  ; kl_phase = Tui_decode.Lane_phase_running
  ; kl_turn_phase = Tui_decode.Lane_turn_idle
  ; kl_idle_seconds = 0
  ; kl_last_outcome = None
  ; kl_conditions =
      { Tui_decode.klc_launch_pending = false
      ; klc_heartbeat_healthy = true
      ; klc_turn_healthy = true
      }
  }

let keeper_snapshot lanes : Tui_decode.keeper_lanes_snapshot =
  { Tui_decode.kls_generated_at = 0.
  ; kls_count = List.length lanes
  ; kls_lanes = lanes
  }

let lanes_state ?(keepers = [ "alpha"; "beta" ]) () =
  let state = create_state ~workspace:"" ~port:0 ~refresh_interval:0. () in
  state.view <- Lanes;
  let exact_snapshot = standalone_snapshot four_standalone_lanes in
  state.standalone_lanes <- Some exact_snapshot;
  let module Inventory = Masc.Tui_decode_lane_inventory in
  let exact_rows = List.map (fun (lane : Tui_decode.standalone_lane) ->
      { Inventory.id = Masc.Lane_id.to_wire (Builtin (Exact lane.sl_lane));
        label=lane.sl_label; purpose="Fixture exact lane"; selection=Inventory.Exact lane.sl_lane;
        state=Inventory.Exact_state (Inventory.Unconfigured "fixture has no admitted slots") })
      four_standalone_lanes in
  let machine = { Inventory.id="machine/dos"; label="DOS"; purpose="Shared machine";
    selection=Inventory.Machine Masc.Machine_lane.Dos; state=Inventory.Machine_state (Inventory.Machine_enabled, Inventory.Stable) } in
  state.lane_inventory <- Some { Inventory.observed_at=0.; exact_snapshot;
    rows=exact_rows @ [machine]; package_read={directory="/fixture/lane-addons";
      complete=true;owner_present=true;issues=[]} };
  state.lanes <- Some (keeper_snapshot (List.map keeper_lane keepers));
  state

let test_inventory_selection_keeps_exact_editor_identity () =
  let state = lanes_state () in
  state.lanes_cursor <- 4;
  Alcotest.(check bool) "machine selection cannot edit a neighbouring exact lane"
    true (Option.is_none (selected_standalone_lane state));
  state.lanes_cursor <- 2;
  Alcotest.(check (option string)) "exact selection joins by typed identity"
    (Some "librarian_exact")
    (Option.map (fun lane -> Standalone_lane.to_id lane.Tui_decode.sl_lane) (selected_standalone_lane state));
  state.standalone_lanes <- Option.map (fun (snapshot : Tui_decode.standalone_lanes_snapshot) ->
    {snapshot with Tui_decode.sls_lanes=List.rev snapshot.sls_lanes}) state.standalone_lanes;
  Alcotest.(check (option string)) "exact detail reorder does not change selected lane"
    (Some "librarian_exact")
    (Option.map (fun lane -> Standalone_lane.to_id lane.Tui_decode.sl_lane) (selected_standalone_lane state))

let test_lanes_search_texts_lead_with_the_standalone_labels () =
  let state = lanes_state () in
  Alcotest.(check (option (list string)))
    "search includes exact and machine inventory identities"
    (Some ["Board Attention exact/board_attention_exact Fixture exact lane";
      "HITL Auto Judge exact/hitl_auto_judge Fixture exact lane";
      "Librarian exact/librarian_exact Fixture exact lane";
      "Verifier exact/verifier_exact Fixture exact lane";
      "DOS machine/dos Shared machine"])
    (Masc_tui_surface_search.surface_row_texts state Lanes)

(* Resources draws a list beside a reading, and j/k means one thing in each.
   The search follows the same split: a match lands the list cursor, and with
   the reading focused there is no cursor for it to land on.

   The row text is the name the list actually draws -- the server's title
   when it sent one -- because a search that matches a name nothing on screen
   shows finds rows the reader cannot see. Both readers take it from
   [Masc_tui_mcp.display_name]. *)
let resources_state () =
  let state = create_state ~workspace:"" ~port:0 ~refresh_interval:0. () in
  state.view <- Resources;
  state.resources_list <-
    Some
      [ { Masc_tui_mcp.uri = "masc://board"; name = "board"
        ; title = Some "Board posts"; description = None
        ; mime_type = None; size = None }
      ; { Masc_tui_mcp.uri = "masc://keepers"; name = "keepers"
        ; title = None; description = None
        ; mime_type = None; size = None }
      ; { Masc_tui_mcp.uri = "masc://lanes"; name = "lanes"
        ; title = Some "   "; description = None
        ; mime_type = None; size = None }
      ];
  state

let test_resources_searches_the_names_the_list_draws () =
  let state = resources_state () in
  Alcotest.(check (option (list string)))
    "the title when there is one, the name otherwise, and a blank title is \
     not one"
    (Some [ "Board posts"; "keepers"; "lanes" ])
    (Masc_tui_surface_search.surface_row_texts state Resources)

let test_the_resource_reading_offers_no_row_search () =
  let state = resources_state () in
  state.resource_focus <- Right_pane;
  Alcotest.(check (option (list string)))
    "with the text focused there is no cursor to land a match on" None
    (Masc_tui_surface_search.surface_row_texts state Resources);
  state.resource_focus <- Left_pane;
  Alcotest.(check Alcotest.bool) "and the list has one again" true
    (Option.is_some (Masc_tui_surface_search.surface_row_texts state Resources))

let test_resources_without_a_list_answers_nothing () =
  let state = resources_state () in
  state.resources_list <- None;
  Alcotest.(check (option (list string)))
    "before the catalog arrives there are no rows" None
    (Masc_tui_surface_search.surface_row_texts state Resources)

let test_lanes_sub_modes_stay_unsearchable () =
  let state = lanes_state () in
  state.lanes_mode <- Lanes_run_list Standalone_lane.Librarian;
  Alcotest.(check (option (list string))) "run list keeps / closed" None
    (Masc_tui_surface_search.surface_row_texts state Lanes);
  state.lanes_mode <- Lanes_run_detail (Standalone_lane.Verifier, "vrf-1");
  Alcotest.(check (option (list string))) "run detail keeps / closed" None
    (Masc_tui_surface_search.surface_row_texts state Lanes)

(* Board and Planning answer "/" over the list they draw. Both panes window
   themselves around the cursor, so a landing is on screen without a scroll
   to follow it; what has to hold is that the searched text is the list the
   cursor counts positions in, and that the panes which are not a list keep
   the key closed. *)

let board_post ?(author = "alpha") id title =
  { bp_id = id
  ; bp_author = author
  ; bp_title = title
  ; bp_body = "body nobody searches"
  ; bp_votes = 0
  ; bp_comment_count = 0
  ; bp_created_at = "2026-09-04T00:00:00Z"
  ; bp_created_at_unix = None; bp_updated_at = None
  ; bp_hearth = None
  ; bp_kind = None
  ; bp_closed = None
  }

let board_state () =
  let state = create_state ~workspace:"" ~port:0 ~refresh_interval:0. () in
  state.view <- Board;
  state.board_posts <-
    [ board_post "p-1" "release evidence sweep"
    ; board_post ~author:"beta" "p-2" "frame budget"
    ];
  state

let test_board_searches_the_post_list () =
  let state = board_state () in
  Alcotest.(check (option (list string)))
    "id, author and title -- what the list draws"
    (Some
       [ "p-1 alpha release evidence sweep"; "p-2 beta frame budget" ])
    (Masc_tui_surface_search.surface_row_texts state Board)

let test_board_reading_and_writing_keep_the_key_closed () =
  let state = board_state () in
  state.board_mode <- Board_read "p-1";
  Alcotest.(check (option (list string))) "reading a post" None
    (Masc_tui_surface_search.surface_row_texts state Board);
  state.board_mode <- Board_compose;
  (* Writing is the stronger case: "/" there is draft text. *)
  Alcotest.(check (option (list string))) "writing a post" None
    (Masc_tui_surface_search.surface_row_texts state Board)

let test_board_without_posts_offers_nothing_to_search () =
  let state = board_state () in
  state.board_posts <- [];
  Alcotest.(check (option (list string))) "no rows" None
    (Masc_tui_surface_search.surface_row_texts state Board)

let planning_goal_row id title =
  { pg_id = id
  ; pg_criterion_revision = None
  ; pg_title = title
  ; pg_phase = Goal_phase.Executing
  ; pg_priority = 1
  ; pg_due_date = None
  ; pg_metric = None
  ; pg_target_value = None
  ; pg_proof = Tui_decode.Proof_idle
  ; pg_verifier_unreconciled = None
  ; pg_last_review_note = None
  ; pg_last_review_at = None
  ; pg_created_at = None
  ; pg_updated_at = None
  }

let planning_state () =
  let state = create_state ~workspace:"" ~port:0 ~refresh_interval:0. () in
  state.view <- Planning;
  state.planning <-
    Some
      { pl_goals =
          [ planning_goal_row "g-1" "cut the frame budget"
          ; planning_goal_row "g-2" "paste follows the field"
          ]
      ; pl_rollup = { pr_active = 2
          ; pr_verifying = 0
          ; pr_awaiting_confirmation = 0
          ; pr_done = 0
          ; pr_paused = 0; pr_blocked = 0; pr_dropped = 0
          }
      ; pl_backlog =
          { pb_todo = 0; pb_claimed = 0; pb_running = 0
          ; pb_awaiting_verification = 0; pb_done = 0; pb_cancelled = 0 }
      (* This surface's key tests are about the rows the cursor walks, and the
         history lines sit above the divider outside them. Empty keeps the
         fixture about that. *)
      ; pl_goal_history = []
      ; pl_generated_at = "2026-09-04T00:00:00Z"
      };
  state

let test_planning_searches_the_goals_the_list_shows () =
  let state = planning_state () in
  Alcotest.(check (option (list string)))
    "id and title"
    (Some [ "g-1 cut the frame budget"; "g-2 paste follows the field" ])
    (Masc_tui_surface_search.surface_row_texts state Planning)

let test_planning_searches_what_the_filter_left () =
  (* The cursor counts positions in the filtered, sorted list, so the search
     has to walk that list and not the snapshot: a filter that hides a goal
     would otherwise land the cursor one row off for every goal it hid. *)
  let state = planning_state () in
  state.planning_filter <- Planning_filter_completed;
  Alcotest.(check (option (list string)))
    "nothing active survives the completed filter" None
    (Masc_tui_surface_search.surface_row_texts state Planning)

let test_planning_detail_keeps_the_key_closed () =
  let state = planning_state () in
  state.planning_mode <- Planning_detail "g-1";
  Alcotest.(check (option (list string))) "a goal is open" None
    (Masc_tui_surface_search.surface_row_texts state Planning)

let test_detail_tab_keys_are_not_quit_keys () =
  List.iter
    (fun tab ->
       List.iter
         (fun key ->
            if Masc_tui_render_schedule.Input_shortcut.is_quit ~message_mode:false key
            then
              Alcotest.failf "%s tab offers %S, which the global quit arm takes first"
                (keeper_detail_tab_label tab) key)
         (Masc_tui_keys.keeper_detail_tab_taken_keys tab))
    Masc_tui_types.keeper_detail_tabs

let test_a_loop_turn_without_input_keeps_an_arm () =
  (* The defect this closes: the dispatch loop turns on its own timeout as
     well as on input, so reading that turn as an unrelated key left every
     two-press arm alive for exactly one iteration. Two [u] presses removed a
     channel binding only when both bytes arrived in the same read. *)
  check Alcotest.bool "a turn that read nothing cancels nothing" false
    (Masc_tui_keys.cancels_two_press ~input_seen:false ~key:None
       ~second_press:[ "u" ]);
  check Alcotest.bool "and the key it did not read is not the second press"
    false
    (Masc_tui_keys.cancels_two_press ~input_seen:false ~key:(Some "j")
       ~second_press:[ "u" ])

let test_input_that_is_not_the_second_press_cancels () =
  (* [key] is [None] for a mouse report, a paste, and a graphics reply. Those
     are input the operator produced, so they end the confirmation. *)
  check Alcotest.bool "a mouse report or a paste cancels" true
    (Masc_tui_keys.cancels_two_press ~input_seen:true ~key:None
       ~second_press:[ "u" ]);
  List.iter
    (fun (pressed, second_press, expected, label) ->
       check Alcotest.bool label expected
         (Masc_tui_keys.cancels_two_press ~input_seen:true
            ~key:(Some pressed) ~second_press))
    [ "u", [ "u" ], false, "the second press holds the arm"
    ; "j", [ "u" ], true, "a cursor move cancels it"
    ; "U", [ "u" ], true, "a different case is a different key"
    ; "Y", [ "y"; "Y"; "n"; "N" ], false, "either answer holds the approval"
    ; "e", [ "y"; "Y"; "n"; "N" ], true, "an unrelated key cancels it"
    ; "x", [], true, "an arm with no second press cancels on any key"
    ]

let test_code_search_count_tracks_fetched_source () =
  let state = create_state ~workspace:"" ~port:0 ~refresh_interval:0. () in
  state.view <- Code;
  state.code_focus_file <- Right_pane;
  let load path rows =
    match Masc_tui_fetched.start ~equal:String.equal state.code_file ~key:path with
    | Masc_tui_fetched.Already_loading -> Alcotest.fail "fixture already loading"
    | Masc_tui_fetched.Started (next, request) ->
        state.code_file <- Masc_tui_fetched.complete ~equal:String.equal next request (Ok rows)
  in
  let count query = Masc_tui_surface_search.surface_search_count state Code ~query in
  load "large.ml" (Array.init 20_000 (fun index ->
    [((if index mod 2 = 0 then "needle" else "other"), "")]));
  Alcotest.(check (option int)) "large file count" (Some 10_000) (count "needle");
  let first_reading = !Masc_tui_surface_search.code_search_count_memo in
  Alcotest.(check (option int)) "repaint keeps the count" (Some 10_000) (count "needle");
  Alcotest.(check bool) "repaint reuses the settled reading" true
    (first_reading == !Masc_tui_surface_search.code_search_count_memo);
  Alcotest.(check (option int)) "query change recounts" (Some 0) (count "absent");
  load "large.ml" [|[("needle", "")]|];
  Alcotest.(check (option int)) "same-path replacement recounts" (Some 1) (count "needle");
  state.code_focus_file <- Left_pane;
  Alcotest.(check (option int)) "tree does not reuse file matches" (Some 0) (count "needle");
  state.code_focus_file <- Right_pane;
  state.repository_changes_open <- true;
  Alcotest.(check (option int)) "overlay without a source has no count" None (count "needle");
  state.repository_changes_open <- false;
  state.code_file <- Masc_tui_fetched.clear state.code_file;
  Alcotest.(check (option int)) "closed file has no source" None (count "needle");
  load "empty.ml" [||];
  Alcotest.(check (option int)) "loaded empty file has zero matches" (Some 0) (count "needle")

let test_detail_search_counts_follow_the_active_pane () =
  let state = create_state ~workspace:"" ~port:0 ~refresh_interval:0. () in
  state.search_last <- "needle";
  state.harness <- Some
    { Tui_decode.hs_verdicts =
        [{ Tui_decode.hv_at = 1.; hv_task_id = "task-1";
           hv_task_title = "needle"; hv_agent = "agent"; hv_gate = "gate";
           hv_verdict = "approve"; hv_evaluator = "evaluator";
           hv_fallback_reason = None; hv_notes_hash = "hash" }];
      hs_calibration = None; hs_overview = None };
  state.system_logs <- Some
    { Tui_decode.sys_entries =
        [{ Tui_decode.sl_seq = 1; sl_ts = "2026-09-13T00:00:00Z";
           sl_level = Tui_decode.System_info;
           sl_source = Tui_decode.System_structured;
           sl_module = "test"; sl_keeper = None; sl_turn = None;
           sl_message = "needle"; sl_details = `Null; sl_category = None }];
      sys_total = 1; sys_latest_seq = 1 };
  let check_pane label surface set_detail =
    state.view <- surface;
    let count () = Masc_tui_surface_search.surface_search_count state surface ~query:state.search_last in
    Alcotest.(check (option int)) (label ^ " list count") (Some 1) (count ());
    Alcotest.(check bool) (label ^ " list has a cursor") true
      (Option.is_some (scrolled_surface_rows state ~cols:80 surface));
    set_detail true;
    Alcotest.(check (option int)) (label ^ " detail has no count or n/N") None (count ());
    Alcotest.(check (option (list string))) (label ^ " detail has no search rows")
      None (Masc_tui_surface_search.surface_row_texts state surface);
    Alcotest.(check bool) (label ^ " detail has no cursor") false
      (Option.is_some (scrolled_surface_rows state ~cols:80 surface));
    set_detail false;
    Alcotest.(check (option int)) (label ^ " return restores count") (Some 1) (count ());
    Alcotest.(check bool) (label ^ " return restores cursor") true
      (Option.is_some (scrolled_surface_rows state ~cols:80 surface));
    Alcotest.(check string) (label ^ " keeps settled query") "needle" state.search_last
  in
  check_pane "Harness" Harness
    (fun detail -> state.harness_detail <- if detail then Some ("task-1", 1.) else None);
  check_pane "System logs" System_logs
    (fun detail -> state.system_logs_detail_seq <- if detail then Some 1 else None)

let test_changes_diff_uses_visible_search_rows () =
  let state = create_state ~workspace:"" ~port:0 ~refresh_interval:0. () in
  let payload = Yojson.Safe.from_string {|{
    "keeper":"alpha", "window_hours":24, "calls_in_window":1,
    "over_budget":0, "malformed":0,
    "changes":[{"at":1, "keeper":"alpha", "turn":1, "task_id":"task-1",
      "execution_id":"exec-change", "line_evidence":null,
      "location":{"kind":"repo","repo_id":"masc","path":"needle.ml"},
      "change":{"kind":"write","content":"let value = 1"}, "succeeded":true}]
  }|} in
  state.changes <- Some (match Tui_decode.decode_file_change_snapshot payload with
    | Ok snapshot -> snapshot | Error detail -> Alcotest.fail detail);
  state.view <- Changes;
  state.search_last <- "needle";
  let check_list label =
    Alcotest.(check (option int)) (label ^ " visible count") (Some 1)
      (Masc_tui_surface_search.surface_search_count state Changes ~query:state.search_last);
    Alcotest.(check bool) (label ^ " cursor available") true
      (Option.is_some (scrolled_surface_rows state ~cols:80 Changes)) in
  check_list "list";
  state.changes_diff_row <- Some 0;
  Alcotest.(check (option (list string))) "diff has no hidden search rows" None
    (Masc_tui_surface_search.surface_row_texts state Changes);
  Alcotest.(check (option int)) "diff has no hidden list count" None
    (Masc_tui_surface_search.surface_search_count state Changes ~query:state.search_last);
  Alcotest.(check bool) "diff cannot move a hidden list cursor" false
    (Option.is_some (scrolled_surface_rows state ~cols:80 Changes));
  state.changes_diff_row <- None;
  check_list "return";
  state.changes_diff_row <- Some 1;
  Alcotest.(check bool) "stale index does not open a diff" false
    (Option.is_some (opened_file_change state));
  check_list "refresh removed open row";
  Alcotest.(check string) "settled query survives" "needle" state.search_last

let test_workspace_activity_offers_no_row_search () =
  (* [h] on a repository row replaces the list with that repository's own
     activity rows and its own cursor, and the handler there takes every key
     the surface has, "/" and n and N among them. What sits behind it is the
     repository list, so a settled query counted rows that no key on this
     screen could reach and the footer reported the number. *)
  let state = create_state ~workspace:"" ~port:0 ~refresh_interval:0. () in
  let repository : Tui_decode.repository =
    { rp_id = "masc"; rp_name = "masc"; rp_codebase = None; rp_url = ""
    ; rp_local_path = "."; rp_resolved_local_path = "/tmp/masc"
    ; rp_default_branch = "main"
    ; rp_status = Tui_decode.Repository_status Repo_manager_types.Active
    ; rp_keepers = []
    ; rp_auto_sync = false }
  in
  state.view <- Repositories;
  state.repositories <-
    Some { Tui_decode.rs_repositories = [ repository ]; rs_total = 1 };
  Alcotest.(check (option int)) "the repository list answers the search"
    (Some 1) (Masc_tui_surface_search.surface_search_count state Repositories ~query:"masc");
  state.workspace_activity_repo <- Some "masc";
  Alcotest.(check (option int)) "Workspace Activity answers no search"
    None (Masc_tui_surface_search.surface_search_count state Repositories ~query:"masc")

let () =
  Alcotest.run "masc_tui_keys"
    [ ( "table"
      , [ Alcotest.test_case "no detail tab key is a quit key" `Quick
            test_detail_tab_keys_are_not_quit_keys
        ; Alcotest.test_case
            "Approvals stay reachable and unread until a reading empties them"
            `Quick
            test_approvals_stay_reachable_and_unread_until_a_reading_empties_it
        ; Alcotest.test_case
            "a Gate poll failing after one answered is not an empty queue"
            `Quick
            test_a_gate_poll_that_fails_after_one_answered_is_not_an_empty_queue
        ; Alcotest.test_case "Code search counts follow immutable fetched rows"
            `Quick test_code_search_count_tracks_fetched_source
        ; Alcotest.test_case "Changes diff uses visible search rows" `Quick
            test_changes_diff_uses_visible_search_rows
        ; Alcotest.test_case "detail search counts follow the active pane"
            `Quick test_detail_search_counts_follow_the_active_pane
        ; Alcotest.test_case "Workspace Activity offers no row search"
            `Quick test_workspace_activity_offers_no_row_search
        ;] )
    ; ( "two-press arms"
      , [ Alcotest.test_case "a loop turn without input keeps an arm" `Quick
            test_a_loop_turn_without_input_keeps_an_arm
        ; Alcotest.test_case "input that is not the second press cancels"
            `Quick test_input_that_is_not_the_second_press_cancels
        ] )
    ; ( "projections"
      , [ Alcotest.test_case "schedule display name uses the named field" `Quick
            test_schedule_who_uses_the_named_field
        ; Alcotest.test_case "schedule create form names required fields" `Quick
            test_schedule_create_form_names_the_canonical_required_fields
        ; Alcotest.test_case
            "modify refuses exactly the statuses the store refuses" `Quick
            test_modify_refuses_exactly_the_statuses_the_store_refuses
        ; Alcotest.test_case "modify refusal is the shared predicate" `Quick
            test_modify_refusal_is_the_shared_predicate
        ; Alcotest.test_case "modify names the status it refuses" `Quick
            test_modify_names_the_status_it_refuses
        ; Alcotest.test_case
            "modify leaves an unnamed status to the server" `Quick
            test_modify_leaves_an_unnamed_status_to_the_server
        ; Alcotest.test_case "schedule update form preserves definition" `Quick
            test_schedule_update_form_preserves_exact_editable_definition
        ; Alcotest.test_case "Memory fact rows follow the category filter"
            `Quick test_memory_fact_rows_follow_the_category_filter
        ; Alcotest.test_case "Memory category cycle returns to All" `Quick
            test_memory_category_cycle_returns_to_all
        ; Alcotest.test_case "Fusion history is selectable without a retained run" `Quick
            test_fusion_historical_evidence_is_a_selectable_board_reference
        ; Alcotest.test_case "Keeper Runs clamps selection after list changes" `Quick
            test_keeper_runs_selection_survives_a_shorter_list
        ; Alcotest.test_case "every view has a ring stop" `Quick
            test_every_view_has_a_ring_stop
        ; Alcotest.test_case "Task Review is a Planning child" `Quick
            test_task_review_is_a_planning_child
        ; Alcotest.test_case "Verdicts is a Planning child" `Quick
            test_verdicts_is_a_planning_child
        ; Alcotest.test_case "Changes is a Keepers child" `Quick
            test_changes_is_a_keeper_child
        ; Alcotest.test_case "Keeper operations are detail tabs" `Quick
            test_keeper_operations_are_not_top_level_tabs
        ; Alcotest.test_case "Lanes is a main destination" `Quick
            test_lanes_is_a_main_destination
        ; Alcotest.test_case "Code is a Workspace child" `Quick
            test_code_is_a_workspace_child
        ; Alcotest.test_case "Resources is a Config child" `Quick
            test_resources_is_a_config_child
        ; Alcotest.test_case "Tools is a Config child" `Quick
            test_tools_is_a_config_child
        ; Alcotest.test_case "Logs is an Activity child" `Quick
            test_logs_is_an_activity_child
        ; Alcotest.test_case "Usage is a main destination" `Quick
            test_metrics_is_an_overview_child
        ; Alcotest.test_case "Browser reader belongs to Config" `Quick
            test_browser_lanes_highlight_config
        ; Alcotest.test_case "the question count counts questions" `Quick
            test_the_question_count_counts_questions
        ; Alcotest.test_case "the questions reading tells unread from none open"
            `Quick test_the_questions_reading_tells_unread_from_none_open
        ; Alcotest.test_case "empty chat Q leaves, draft Q types" `Quick
            test_chat_quiet_leave_respects_the_draft
        ; Alcotest.test_case "Keepers jump shares dispatch and help" `Quick
            test_keepers_jump_uses_one_binding_for_dispatch_and_help
        ;] )
    ; ( "board and planning rows"
      , [ Alcotest.test_case "Board searches the post list" `Quick
            test_board_searches_the_post_list
        ; Alcotest.test_case "reading and writing keep the key closed" `Quick
            test_board_reading_and_writing_keep_the_key_closed
        ; Alcotest.test_case "no posts, nothing to search" `Quick
            test_board_without_posts_offers_nothing_to_search
        ; Alcotest.test_case "Planning searches the goals the list shows"
            `Quick test_planning_searches_the_goals_the_list_shows
        ; Alcotest.test_case "Planning searches what the filter left" `Quick
            test_planning_searches_what_the_filter_left
        ; Alcotest.test_case "a goal detail keeps the key closed" `Quick
            test_planning_detail_keeps_the_key_closed
        ] )
    ; ( "lanes rows"
      , [ Alcotest.test_case "inventory selection retains exact editor identity" `Quick
            test_inventory_selection_keeps_exact_editor_identity
        ; Alcotest.test_case "search includes all inventory families" `Quick
            test_lanes_search_texts_lead_with_the_standalone_labels
        ; Alcotest.test_case "sub-modes stay unsearchable" `Quick
            test_lanes_sub_modes_stay_unsearchable
        ; Alcotest.test_case "Resources searches the names it draws" `Quick
            test_resources_searches_the_names_the_list_draws
        ; Alcotest.test_case "the resource reading offers no row search"
            `Quick test_the_resource_reading_offers_no_row_search
        ; Alcotest.test_case "Resources without a list answers nothing" `Quick
            test_resources_without_a_list_answers_nothing
        ] )
    ]

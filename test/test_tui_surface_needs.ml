(** What each TUI surface asks a refresh tick to fetch.

    The record exists so a surface added later answers every question at once
    and cannot quietly default to false in the one that was missed. The chat
    pane was missed anyway: it had no field, so it read its history when it
    opened and never again, and a message that arrived while it was on screen
    waited for the operator to leave and come back. *)

open Alcotest

module Types = Masc_tui_types

(* The Keeper pane is the one reading a surface cannot answer for: these
   cases ask what the surface itself fetches, so they ask with the pane
   down. [test_the_keeper_pane_asks_for_the_roster_wherever_it_is_drawn]
   asks the other way. *)
let needs surface = Types.surface_needs ~about_open:false ~keeper_pane_drawn:false surface

let test_only_the_chat_pane_asks_for_chat_history () =
  check bool "the chat pane asks for it" true
    (needs (Types.Keepers Types.Keeper_message)).Types.needs_keeper_chat;
  List.iter
    (fun (label, surface) ->
       check bool (label ^ " does not") false
         (needs surface).Types.needs_keeper_chat)
    [ "the keeper list", Types.Keepers Types.Keeper_list
    ; "keeper detail", Types.Keepers Types.Keeper_detail
    ; "keeper logs", Types.Keepers Types.Keeper_logs
    ; "keeper calls", Types.Keepers Types.Keeper_calls
    ; "overview", Types.Overview
    ; "board", Types.Board
    ; "planning", Types.Planning
    ; "system logs", Types.System_logs
    ]
;;

let test_every_keeper_sub_mode_still_asks_for_the_roster () =
  check bool "Overview reads the Candle envelope with its Keeper pane hidden" true
    (needs Types.Overview).Types.needs_keeper_roster;
  List.iter
    (fun (label, mode) ->
       let n = needs (Types.Keepers mode) in
       check bool (label ^ " asks for the roster") true n.Types.needs_keeper_roster;
       check bool (label ^ " asks for fleet safety") true n.Types.needs_fleet_safety)
    [ "the list", Types.Keeper_list
    ; "detail", Types.Keeper_detail
    ; "logs", Types.Keeper_logs
    ; "calls", Types.Keeper_calls
    ; "the chat pane", Types.Keeper_message
    ]
;;

(* The pane on the right of the screen draws a health mark per Keeper, and
   it is up on every surface but Activity. Read from the surface alone, the
   marks were the unread dash everywhere but Keepers and Metrics: the roster
   the pane draws from was never fetched there. *)
let test_the_keeper_pane_asks_for_the_roster_wherever_it_is_drawn () =
  List.iter
    (fun (label, surface) ->
      check bool
        (label ^ " does not fetch the roster for itself")
        false
        (Types.surface_needs ~about_open:false ~keeper_pane_drawn:false surface)
          .Types.needs_keeper_roster;
      check bool
        (label ^ " fetches it while the pane draws it")
        true
        (Types.surface_needs ~about_open:false ~keeper_pane_drawn:true surface)
          .Types.needs_keeper_roster)
    [ ("approvals", Types.Approvals)
    ; ("board", Types.Board)
    ; ("planning", Types.Planning)
    ; ("config", Types.Config)
    ; ("memory", Types.Memory)
    ];
  (* And the pane changes nothing else: a surface asks for what it draws. *)
  let board_without = Types.surface_needs ~about_open:false ~keeper_pane_drawn:false Types.Board in
  let board_with = Types.surface_needs ~about_open:false ~keeper_pane_drawn:true Types.Board in
  check bool "the board still asks for the board" true
    board_with.Types.needs_board;
  check bool "and for nothing else the pane does not draw" true
    ({ board_with with Types.needs_keeper_roster = false } = board_without)

let test_about_refreshes_observed_outfits_over_another_surface () =
  let closed = Types.surface_needs ~keeper_pane_drawn:false
    ~about_open:false Types.Config in
  let opened = Types.surface_needs ~keeper_pane_drawn:false
    ~about_open:true Types.Config in
  let opening = Types.surface_needs_delta ~previous:closed ~next:opened in
  check bool "opening About reads outfit observations through the existing scoped owner"
    true opening.Types.needs_keeper_roster;
  check bool "closing About requests no additional read" false
    (Types.surface_needs_any (Types.surface_needs_delta ~previous:opened ~next:closed));
  let cadence = Types.full_refresh_needs ~scoped_refresh_inflight:false
    ~keeper_pane_drawn:false ~about_open:true Types.Config in
  check bool "a settled About gallery keeps observing outfit changes"
    true cadence.Types.needs_keeper_roster;
  let concurrent = Types.full_refresh_needs ~scoped_refresh_inflight:true
    ~keeper_pane_drawn:false ~about_open:true Types.Config in
  check bool "the full refresh does not duplicate an in-flight scoped read"
    false (Types.surface_needs_any concurrent)
;;

let test_forward_navigation_fetches_only_new_surface_datasets () =
  (* Walk the whole ring forward from Overview. A named stop marker rotted
     twice as ring surfaces moved under parents, so the walk now takes the
     ring as it is: the pinned sum only moves when a ring surface actually
     starts or stops fetching a dataset. *)
  let destinations =
    match Types.surface_ring with
    | [] -> fail "the surface ring is empty"
    | _overview :: rest -> List.map fst rest
  in
  let add_delta (previous, count) surface =
    let next = needs surface in
    let delta = Types.surface_needs_delta ~previous ~next in
    let dataset_count =
      [ delta.Types.needs_transport
      ; delta.needs_keeper_roster
      ; delta.needs_fleet_safety
      ; delta.needs_board
      ; delta.needs_planning
      ; delta.needs_system_logs
      ; delta.needs_keeper_chat
      ; delta.needs_operator_approvals
      ; delta.needs_asks
      ; delta.needs_runtime_quota
      ; delta.needs_keeper_usage
      ; delta.needs_provider_history
      ; delta.needs_overview_goals
      ; delta.needs_account_emails
      ]
      |> List.fold_left (fun total wanted -> if wanted then total + 1 else total) 0
    in
    (next, count + dataset_count)
  in
  let _, dataset_count =
    List.fold_left add_delta (needs Types.Overview, 0) destinations
  in
  (* Home no longer fetches Goal measurement. Entering Work now adds that
     request beside planning: Work 2 + Keepers 2 + Usage 5 + Board 1. *)
  let work_delta =
    Types.surface_needs_delta ~previous:(needs Types.Overview)
      ~next:(needs Types.Planning)
  in
  check bool "entering Work adds the Goal measurement absent from Home" true
    work_delta.Types.needs_overview_goals;
  check int "only newly visible scoped requests are planned" 10 dataset_count
;;

let test_equal_needs_have_no_delta () =
  let previous = needs (Types.Keepers Types.Keeper_list) in
  let next = needs (Types.Keepers Types.Keeper_detail) in
  check bool "keeper modes share an already loaded dataset set" false
    (Types.surface_needs_any
       (Types.surface_needs_delta ~previous ~next))
;;

let test_full_refresh_omits_scoped_datasets_while_their_owner_is_running () =
  let concurrent =
    Types.full_refresh_needs ~about_open:false ~scoped_refresh_inflight:true
      ~keeper_pane_drawn:true Types.Board
  in
  let alone =
    Types.full_refresh_needs ~about_open:false ~scoped_refresh_inflight:false
      ~keeper_pane_drawn:true Types.Board
  in
  check bool "concurrent full refresh is global-only" false
    (Types.surface_needs_any concurrent);
  check bool "an unopposed full refresh still updates the visible board" true
    alone.Types.needs_board
;;

let test_authoritative_refresh_waits_for_both_owners_then_runs_once () =
  let pending =
    Types.note_full_refresh_intent ~intent:Types.Revalidate
      ~full_refresh_inflight:false ~scoped_refresh_inflight:true
      Types.No_scoped_followup
  in
  let while_full, launch_while_full =
    Types.take_scoped_refresh_followup ~full_refresh_inflight:true
      ~scoped_refresh_inflight:false pending
  in
  check bool "a concurrent full keeps the followup queued" false
    launch_while_full;
  let after_both, launch_after_both =
    Types.take_scoped_refresh_followup ~full_refresh_inflight:false
      ~scoped_refresh_inflight:false while_full
  in
  check bool "the authoritative revalidate launches once" true
    launch_after_both;
  check bool "the launch consumes the pending intent" true
    (after_both = Types.No_scoped_followup);
  let cadence =
    Types.note_full_refresh_intent ~intent:Types.Cadence
      ~full_refresh_inflight:true ~scoped_refresh_inflight:true
      Types.No_scoped_followup
  in
  check bool "cadence does not manufacture an authoritative followup" true
    (cadence = Types.No_scoped_followup)
;;

(* Work owns exact Goal measurement; Home reads the confirmation projection. *)
let test_only_work_asks_for_the_goal_tree () =
  check bool "Dashboard does not ask for the measurement tree" false
    (needs Types.Overview).Types.needs_overview_goals;
  check bool "Work asks for it" true
    (needs Types.Planning).Types.needs_overview_goals;
  List.iter
    (fun (label, surface) ->
      check bool (label ^ " does not") false
        (needs surface).Types.needs_overview_goals)
    [ ("board", Types.Board)
    ; ("metrics", Types.Metrics)
    ; ("the keeper list", Types.Keepers Types.Keeper_list)
    ]
;;

let test_usage_asks_for_keeper_usage () =
  check bool "Usage fetches Keeper metrics" true
    (needs Types.Metrics).Types.needs_keeper_usage;
  check bool "Usage fetches provider history" true
    (needs Types.Metrics).Types.needs_provider_history;
  check bool "Dashboard does not fetch Keeper detail" false
    (needs Types.Overview).Types.needs_keeper_usage

(* Account emails are read on every Usage refresh, like its other readings,
   so a sign-in, a failed read or another server on the port shows on the
   next tick. Plan usage is on Usage, and no other surface draws them. *)
let test_only_usage_asks_for_account_emails () =
  check bool "Usage asks for them" true
    (needs Types.Metrics).Types.needs_account_emails;
  check bool "and so does its full refresh" true
    (Types.full_refresh_needs ~about_open:false ~scoped_refresh_inflight:false
       ~keeper_pane_drawn:false Types.Metrics)
      .Types.needs_account_emails;
  List.iter
    (fun (label, surface) ->
      check bool (label ^ " does not") false
        (needs surface).Types.needs_account_emails)
    [ ("the dashboard", Types.Overview)
    ; ("planning", Types.Planning)
    ; ("board", Types.Board)
    ; ("the keeper list", Types.Keepers Types.Keeper_list)
    ]
;;

let () =
  run "tui_surface_needs"
    [ ( "refresh scope"
      , [ test_case "only the chat pane asks for chat history" `Quick
            test_only_the_chat_pane_asks_for_chat_history
        ; test_case "only Work asks for the goal tree" `Quick
            test_only_work_asks_for_the_goal_tree
        ; test_case "Usage owns Keeper usage" `Quick
            test_usage_asks_for_keeper_usage
        ; test_case "only Usage asks for account emails" `Quick
            test_only_usage_asks_for_account_emails
        ; test_case "every keeper sub-mode asks for the roster" `Quick
            test_every_keeper_sub_mode_still_asks_for_the_roster
        ; test_case "the keeper pane asks for the roster wherever it is drawn"
            `Quick test_the_keeper_pane_asks_for_the_roster_wherever_it_is_drawn
        ; test_case "About observes outfits while its underlying surface stays open"
            `Quick test_about_refreshes_observed_outfits_over_another_surface
        ; test_case "forward navigation fetches only new datasets" `Quick
            test_forward_navigation_fetches_only_new_surface_datasets
        ; test_case "equal needs have no delta" `Quick
            test_equal_needs_have_no_delta
        ; test_case "full refresh does not race a scoped owner" `Quick
            test_full_refresh_omits_scoped_datasets_while_their_owner_is_running
        ; test_case "authoritative refresh coalesces to one followup" `Quick
            test_authoritative_refresh_waits_for_both_owners_then_runs_once
        ] )
    ]
;;

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
  (* A newer full bundle supersedes an in-flight scoped ticket, so it reads
     every currently visible dataset, including About outfit observations. *)
  let cadence = Types.surface_needs
    ~keeper_pane_drawn:false ~about_open:true Types.Config in
  check bool "a newer full bundle keeps observing the visible About gallery"
    true cadence.Types.needs_keeper_roster
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
     request beside planning: Work 2 + Keepers 2 + Usage 5 + Board 1. Config
     adds one: the Models pane names the account behind a provider id, so
     entering Config reads account emails. *)
  let work_delta =
    Types.surface_needs_delta ~previous:(needs Types.Overview)
      ~next:(needs Types.Planning)
  in
  check bool "entering Work adds the Goal measurement absent from Home" true
    work_delta.Types.needs_overview_goals;
  check int "only newly visible scoped requests are planned" 11 dataset_count
;;

let test_equal_needs_have_no_delta () =
  let previous = needs (Types.Keepers Types.Keeper_list) in
  let next = needs (Types.Keepers Types.Keeper_detail) in
  check bool "keeper modes share an already loaded dataset set" false
    (Types.surface_needs_any
       (Types.surface_needs_delta ~previous ~next))
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
   next tick. Plan usage is on Usage, and the Models pane on Config names the
   account behind a provider id. No other surface draws them. *)
let test_usage_and_config_ask_for_account_emails () =
  check bool "Usage asks for them" true
    (needs Types.Metrics).Types.needs_account_emails;
  check bool "Config asks for them" true
    (needs Types.Config).Types.needs_account_emails;
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

let test_navigation_settles_while_a_full_reader_is_pending () =
  let module Order = Types.Surface_read_order in
  let full_ticket = Types.Http_refresh_order.dispatch Types.Http_refresh_order.initial in
  let navigation_ticket = Types.Http_refresh_order.for_navigation
    ~collection_inflight:true full_ticket in
  check bool "foreground collection keeps the current enclosing interval" true
    (Types.Http_refresh_order.is_current full_ticket navigation_ticket);
  let reads, full = Order.dispatch ~kind:Order.Full ~needs:(needs Types.Metrics)
    ~started_ns:1L Order.initial in
  check bool "full publication ownership does not stand in for scoped execution progress" true
    (Order.pending_scoped ~needs:(needs Types.Metrics) reads = []);
  let reads, navigation = Order.dispatch ~kind:Order.Navigation ~needs:(needs Types.Board)
    ~started_ns:2L reads in
  check bool "the actual foreground request has its own pending dataset" true
    (Order.pending_scoped ~needs:(needs Types.Board) reads = [Order.Board]);
  let reads, accepted = Order.take reads navigation in
  check bool "Board can be admitted before the unrelated full read finishes" true
    (List.mem Order.Board (List.map Order.dataset_source accepted));
  check bool "the provider history still has its original pending owner" true
    (List.mem Order.Provider_history (Order.pending ~needs:(needs Types.Metrics) reads));
  check bool "settled navigation is not kept pending by full publication ownership" true
    (Order.pending_scoped ~needs:(needs Types.Board) reads = []);
  let _, accepted = Order.take reads full in
  check bool "the full read retains its independent provider result" true
    (List.mem Order.Provider_history (List.map Order.dataset_source accepted));
  let successor = Types.Http_refresh_order.for_navigation
    ~collection_inflight:false full_ticket in
  check bool "navigation without a full pass starts a new interval" false
    (Types.Http_refresh_order.is_current full_ticket successor)

let test_navigation_owns_overlapping_data_and_cleanup () =
  let module Order = Types.Surface_read_order in
  let reads, full = Order.dispatch ~kind:Order.Full ~needs:(needs Types.Metrics)
    ~started_ns:1L Order.initial in
  let reads, navigation = Order.dispatch ~kind:Order.Navigation ~needs:(needs Types.Config)
    ~started_ns:2L reads in
  let reads, accepted = Order.take reads full in
  check bool "late full accounts do not replace the newer request" false
    (List.mem Order.Account_emails (List.map Order.dataset_source accepted));
  check bool "full completion does not release the newer accounts owner" true
    (List.mem Order.Account_emails (Order.pending ~needs:(needs Types.Config) reads));
  let reads = Order.finish reads full in
  let reads, accepted = Order.take reads navigation in
  check bool "original navigation admits its accounts" true
    (List.mem Order.Account_emails (List.map Order.dataset_source accepted));
  let _, duplicate = Order.take reads navigation in
  check bool "a repeated completion cannot apply again" true (duplicate = [])

let test_withdrawn_surface_source_cannot_settle_its_successor () =
  let module Order = Types.Surface_read_order in
  let reads, old = Order.dispatch ~kind:Order.Navigation ~needs:(needs Types.Board)
    ~started_ns:1L Order.initial in
  let reads = Order.invalidate reads in
  let reads, current = Order.dispatch ~kind:Order.Navigation ~needs:(needs Types.Board)
    ~started_ns:2L reads in
  let reads, stale = Order.take reads old in
  check bool "withdrawn result has no publication ownership" true (stale = []);
  let reads = Order.finish reads old in
  let _, accepted = Order.take reads current in
  check bool "old completion and cleanup leave the successor intact" true
    (List.mem Order.Board (List.map Order.dataset_source accepted))

let test_navigation_collectors_settle_independently_and_revalidate_once () =
  let module Order = Types.Surface_read_order in
  let reads, work = Order.dispatch ~kind:Order.Navigation ~needs:(needs Types.Planning)
    ~started_ns:1L Order.initial in
  let root = Types.Http_refresh_order.dispatch Types.Http_refresh_order.initial in
  let next_root = Types.Http_refresh_order.for_navigation
    ~collection_inflight:(Order.navigation_in_flight reads) root in
  check bool "a second collector retains its sibling's generation" true
    (Types.Http_refresh_order.is_current root next_root);
  let reads, board = Order.dispatch ~kind:Order.Navigation ~needs:(needs Types.Board)
    ~started_ns:2L reads in
  check int "both collectors are tracked" 2 (Order.navigation_count reads);
  let reads, accepted = Order.take reads board in
  check bool "the destination can apply before the old collector finishes" true
    (List.mem Order.Board (List.map Order.dataset_source accepted));
  check bool "application alone does not complete its collector" true
    (Order.navigation_active reads board);
  let reads = Order.finish reads board in
  let reads = Order.finish reads board in
  check bool "duplicate completion leaves the first collector active" true
    (Order.navigation_active reads work);
  let followup, launch = Types.take_scoped_refresh_followup
    ~full_refresh_inflight:false ~scoped_refresh_inflight:(Order.navigation_in_flight reads)
    Types.Revalidate_after_scoped in
  check bool "a retained revalidation still sees the real remaining collector" false launch;
  let reads, accepted = Order.take reads work in
  check bool "the first collector retains its independent source" true
    (List.mem Order.Planning (List.map Order.dataset_source accepted));
  let reads = Order.finish reads work in
  let followup, launch = Types.take_scoped_refresh_followup
    ~full_refresh_inflight:false ~scoped_refresh_inflight:(Order.navigation_in_flight reads)
    followup in
  check bool "the last completion permits the retained revalidation" true launch;
  let _, duplicate = Types.take_scoped_refresh_followup
    ~full_refresh_inflight:false ~scoped_refresh_inflight:false followup in
  check bool "the retained full revalidation starts once" false duplicate

let test_completed_newer_navigation_does_not_restore_old_identity_authority () =
  let module Order = Types.Surface_read_order in
  let reads, usage = Order.dispatch ~kind:Order.Navigation ~needs:(needs Types.Metrics)
    ~started_ns:1L Order.initial in
  let reads, board = Order.dispatch ~kind:Order.Navigation ~needs:(needs Types.Board)
    ~started_ns:2L reads in
  check bool "the new navigation owns identity observation" true
    (Order.latest_navigation reads board);
  let reads = Order.finish reads board in
  check bool "an older failure cannot regain identity authority" false
    (Order.latest_navigation reads usage);
  let reads, config = Order.dispatch ~kind:Order.Navigation ~needs:(needs Types.Config)
    ~started_ns:3L reads in
  let reads, accepted = Order.take reads usage in
  check bool "the old collector cannot overwrite newer shared accounts" false
    (List.mem Order.Account_emails (List.map Order.dataset_source accepted));
  check bool "the old collector keeps independent history" true
    (List.mem Order.Provider_history (List.map Order.dataset_source accepted));
  let reads = Order.finish reads usage in
  check bool "old cleanup leaves the current collector active" true
    (Order.navigation_active reads config);
  check bool "the current collector keeps identity authority" true
    (Order.latest_navigation reads config)

let test_withdrawal_retires_authority_without_losing_live_collectors () =
  let module Order = Types.Surface_read_order in
  let reads, old = Order.dispatch ~kind:Order.Navigation ~needs:(needs Types.Board)
    ~started_ns:1L Order.initial in
  let reads = Order.invalidate reads in
  check bool "withdrawal revokes the old identity observation" false
    (Order.latest_navigation reads old);
  check bool "the actual old collector remains tracked" true
    (Order.navigation_active reads old);
  let reads, current = Order.dispatch ~kind:Order.Navigation ~needs:(needs Types.Board)
    ~started_ns:2L reads in
  let reads, old_sources = Order.take reads old in
  check bool "the old reply owns no successor data" true (old_sources = []);
  let reads = Order.finish reads old in
  check bool "old completion preserves the current collector" true
    (Order.navigation_active reads current);
  check int "only the current collector remains" 1 (Order.navigation_count reads)

let test_asks_and_approvals_collectors_have_independent_lifetimes () =
  let module Order = Types.Surface_read_order in
  let reads, asks = Order.dispatch ~kind:Order.Navigation ~needs:(needs Types.Approvals)
    ~started_ns:1L Order.initial in
  (* These payloads have their own Snapshot_read/Listing_order owners rather
     than dataset claims. Their enclosing verified collection is still live. *)
  let reads, accepted = Order.take reads asks in
  check bool "no unrelated dataset claim is fabricated" true (accepted = []);
  check bool "the collection remains tracked after source handling" true
    (Order.navigation_active reads asks);
  let reads, board = Order.dispatch ~kind:Order.Navigation ~needs:(needs Types.Board)
    ~started_ns:2L reads in
  let reads = Order.finish reads asks in
  check bool "its completion cannot clear another collection" true
    (Order.navigation_active reads board)

let test_log_filter_read_supersedes_old_collectors_without_releasing_them () =
  let module Order = Types.Surface_read_order in
  let full_reads, full = Order.dispatch ~kind:Order.Full ~needs:(needs Types.System_logs)
    ~started_ns:1L Order.initial in
  let full_reads, current_filter = Order.dispatch ~kind:Order.Independent
    ~needs:(needs Types.System_logs) ~started_ns:2L full_reads in
  check bool "independent filter reads remain visible as scoped pending data" true
    (Order.pending_scoped ~needs:(needs Types.System_logs) full_reads = [Order.System_logs]);
  let full_reads, old_full_sources = Order.take full_reads full in
  check bool "a late full page cannot replace the filtered page" true (old_full_sources = []);
  let _, current_filter_sources = Order.take full_reads current_filter in
  check bool "the filter retains its source against full completion" true
    (List.mem Order.System_logs (List.map Order.dataset_source current_filter_sources));
  let reads, navigation = Order.dispatch ~kind:Order.Navigation ~needs:(needs Types.System_logs)
    ~started_ns:1L Order.initial in
  let reads, filter = Order.dispatch ~kind:Order.Independent ~needs:(needs Types.System_logs)
    ~started_ns:2L reads in
  let reads, old_sources = Order.take reads navigation in
  check bool "the old collector cannot replace the filtered page" true (old_sources = []);
  check bool "the actual navigation collector still needs its own completion" true
    (Order.navigation_active reads navigation);
  let reads, newer_filter = Order.dispatch ~kind:Order.Independent ~needs:(needs Types.System_logs)
    ~started_ns:3L reads in
  let reads, old_filter_sources = Order.take reads filter in
  check bool "an older filter result owns no current log data" true (old_filter_sources = []);
  let reads = Order.finish reads navigation in
  check bool "independent filters add no navigation collector" false
    (Order.navigation_in_flight reads);
  let _, current_sources = Order.take reads newer_filter in
  check bool "the newest filter keeps the log data owner" true
    (List.mem Order.System_logs (List.map Order.dataset_source current_sources))

let () =
  run "tui_surface_needs"
    [ ( "refresh scope"
      , [ test_case "only the chat pane asks for chat history" `Quick
            test_only_the_chat_pane_asks_for_chat_history
        ; test_case "only Work asks for the goal tree" `Quick
            test_only_work_asks_for_the_goal_tree
        ; test_case "Usage owns Keeper usage" `Quick
            test_usage_asks_for_keeper_usage
        ; test_case "Usage and Config ask for account emails" `Quick
            test_usage_and_config_ask_for_account_emails
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
        ; test_case "authoritative refresh coalesces to one followup" `Quick
            test_authoritative_refresh_waits_for_both_owners_then_runs_once
        ; test_case "foreground navigation settles while full readers remain pending" `Quick
            test_navigation_settles_while_a_full_reader_is_pending
        ; test_case "navigation owns overlapping data and cleanup" `Quick
            test_navigation_owns_overlapping_data_and_cleanup
        ; test_case "withdrawn source cannot settle its successor" `Quick
            test_withdrawn_surface_source_cannot_settle_its_successor
        ; test_case "navigation collectors settle independently and revalidate once" `Quick
            test_navigation_collectors_settle_independently_and_revalidate_once
        ; test_case "new completion never restores old identity authority" `Quick
            test_completed_newer_navigation_does_not_restore_old_identity_authority
        ; test_case "withdrawal retains live collector tracking" `Quick
            test_withdrawal_retires_authority_without_losing_live_collectors
        ; test_case "Ask and approval collectors keep independent lifetimes" `Quick
            test_asks_and_approvals_collectors_have_independent_lifetimes
        ; test_case "log filter supersedes old collectors without releasing them" `Quick
            test_log_filter_read_supersedes_old_collectors_without_releasing_them
        ] )
    ]
;;

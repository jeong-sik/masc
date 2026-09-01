(** What each TUI surface asks a refresh tick to fetch.

    The record exists so a surface added later answers every question at once
    and cannot quietly default to false in the one that was missed. The chat
    pane was missed anyway: it had no field, so it read its history when it
    opened and never again, and a message that arrived while it was on screen
    waited for the operator to leave and come back. *)

open Alcotest

module Types = Masc_tui_types

let needs surface = Types.surface_needs surface

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

let test_forward_navigation_fetches_only_new_surface_datasets () =
  (* Walk the ring forward from Overview up to the last stop, exclusive.
     Logs is excluded the way Tools was when it held this position: the
     walk is about the surfaces between the two ends, and the pinned sum
     should not move when the ring's tail changes owners. *)
  let rec through_logs = function
    | [] -> fail "System logs is absent from the surface ring"
    | (Types.System_logs, _) :: _ -> []
    | (surface, _) :: rest -> surface :: through_logs rest
  in
  let destinations =
    match Types.surface_ring with
    | [] -> fail "the surface ring is empty"
    | _overview :: rest -> through_logs rest
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
      ]
      |> List.fold_left (fun total wanted -> if wanted then total + 1 else total) 0
    in
    (next, count + dataset_count)
  in
  let _, dataset_count =
    List.fold_left add_delta (needs Types.Overview, 0) destinations
  in
  check int "only newly visible scoped requests are planned" 6 dataset_count
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
    Types.full_refresh_needs ~scoped_refresh_inflight:true Types.Board
  in
  let alone =
    Types.full_refresh_needs ~scoped_refresh_inflight:false Types.Board
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

let () =
  run "tui_surface_needs"
    [ ( "refresh scope"
      , [ test_case "only the chat pane asks for chat history" `Quick
            test_only_the_chat_pane_asks_for_chat_history
        ; test_case "every keeper sub-mode asks for the roster" `Quick
            test_every_keeper_sub_mode_still_asks_for_the_roster
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

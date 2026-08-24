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

let () =
  run "tui_surface_needs"
    [ ( "refresh scope"
      , [ test_case "only the chat pane asks for chat history" `Quick
            test_only_the_chat_pane_asks_for_chat_history
        ; test_case "every keeper sub-mode asks for the roster" `Quick
            test_every_keeper_sub_mode_still_asks_for_the_roster
        ] )
    ]
;;

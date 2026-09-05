(** The cross-lane "why did the last turn stop" cell.

    Until 2026-09-02 the stop reason lived in a ref the keepalive loop owned:
    a turn that yielded on another lane (measured, direct/TUI-attached turns)
    left nothing for the next turn to read, so the loop guard's notice never
    rendered there. These tests pin the cell the way the cycle wrapper uses
    it: record after a cycle, read before the next one, keyed by root and
    keeper so test roots in one process stay separate. *)

open Alcotest

module Stop = Masc.Keeper_turn_checkpoint_reason
module Cell = Masc.Keeper_last_turn_stop

let repeated_tool tool count =
  Stop.Repeated_tool_call { tool_name = tool; repeated_count = count }
;;

let test_records_and_clears () =
  Cell.set ~base_path:"/t/root-a" ~keeper:"analyst"
    (Some (repeated_tool "keeper_artifact_read" 3));
  let stop = Cell.get ~base_path:"/t/root-a" ~keeper:"analyst" in
  (match stop with
   | Some (Stop.Repeated_tool_call { tool_name = "keeper_artifact_read"; repeated_count = 3 }) ->
     ()
   | Some (Stop.Repeated_tool_call _) -> fail "the stop came back with another tool or count"
   | Some Stop.Operation_queued
   | Some Stop.Durable_stimulus_arrived
   | Some (Stop.Repeated_assistant_text _) -> fail "a different stop came back"
   | None -> fail "the recorded stop came back None");
  Cell.set ~base_path:"/t/root-a" ~keeper:"analyst" None;
  check bool "a completed turn clears the cell" true
    (Cell.get ~base_path:"/t/root-a" ~keeper:"analyst" = None)
;;

let test_keys_do_not_cross_keepers_or_roots () =
  Cell.set ~base_path:"/t/root-a" ~keeper:"analyst"
    (Some (repeated_tool "keeper_artifact_read" 3));
  check bool "another keeper on the same root starts empty" true
    (Cell.get ~base_path:"/t/root-a" ~keeper:"spruce" = None);
  check bool "the same name on another root starts empty" true
    (Cell.get ~base_path:"/t/root-b" ~keeper:"analyst" = None)
;;

let test_unwritten_cell_reads_none () =
  check bool "a keeper that never ran reads None" true
    (Cell.get ~base_path:"/t/root-c" ~keeper:"polisher" = None)
;;

let () =
  run "Keeper last turn stop"
    [ ( "cell",
        [ test_case "records and clears" `Quick test_records_and_clears
        ; test_case "keys do not cross keepers or roots" `Quick
            test_keys_do_not_cross_keepers_or_roots
        ; test_case "unwritten cell reads None" `Quick test_unwritten_cell_reads_none
        ] )
    ]
;;

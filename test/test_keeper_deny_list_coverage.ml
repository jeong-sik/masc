(** Coverage tests for keeper deny list in keeper_hooks_oas.

    Verifies that keeper_denied_tools blocks the expected tools. *)

open Masc_mcp

let () = Printf.printf "\n=== Keeper Deny List Coverage Tests ===\n"

let test name f =
  try
    f ();
    Printf.printf "  pass %s\n" name
  with e ->
    Printf.printf "  FAIL %s: %s\n" name (Printexc.to_string e);
    exit 1

(* ================================================================ *)
(* Deny list membership tests                                       *)
(* ================================================================ *)

let () = test "room_delete_denied" (fun () ->
  assert (List.mem "masc_room_delete" Keeper_hooks_oas.keeper_denied_tools))

let () = test "spawn_denied" (fun () ->
  assert (List.mem "masc_spawn" Keeper_hooks_oas.keeper_denied_tools))

let () = test "force_leave_denied" (fun () ->
  assert (List.mem "masc_force_leave" Keeper_hooks_oas.keeper_denied_tools))

let () = test "config_set_denied" (fun () ->
  assert (List.mem "masc_config_set" Keeper_hooks_oas.keeper_denied_tools))

let () = test "neo4j_query_denied" (fun () ->
  assert (List.mem "masc_neo4j_query" Keeper_hooks_oas.keeper_denied_tools))

let () = test "pg_query_denied" (fun () ->
  assert (List.mem "masc_pg_query" Keeper_hooks_oas.keeper_denied_tools))

(* ================================================================ *)
(* Allowed tools NOT in deny list                                   *)
(* ================================================================ *)

let () = test "board_post_allowed" (fun () ->
  assert (not (List.mem "keeper_board_post" Keeper_hooks_oas.keeper_denied_tools)))

let () = test "broadcast_allowed" (fun () ->
  assert (not (List.mem "masc_broadcast" Keeper_hooks_oas.keeper_denied_tools)))

let () = test "status_allowed" (fun () ->
  assert (not (List.mem "masc_status" Keeper_hooks_oas.keeper_denied_tools)))

let () = test "tasks_allowed" (fun () ->
  assert (not (List.mem "masc_tasks" Keeper_hooks_oas.keeper_denied_tools)))

let () = test "keeper_bash_not_denied" (fun () ->
  (* keeper_bash is handled by destructive pattern check, not deny list *)
  assert (not (List.mem "keeper_bash" Keeper_hooks_oas.keeper_denied_tools)))

(* ================================================================ *)
(* Deny list size sanity check                                      *)
(* ================================================================ *)

let () = test "operator_action_denied" (fun () ->
  assert (List.mem "masc_operator_action" Keeper_hooks_oas.keeper_denied_tools))

let () = test "operator_confirm_denied" (fun () ->
  assert (List.mem "masc_operator_confirm" Keeper_hooks_oas.keeper_denied_tools))

let () = test "execute_denied" (fun () ->
  assert (List.mem "masc_execute" Keeper_hooks_oas.keeper_denied_tools))

let () = test "deny_list_not_empty" (fun () ->
  assert (List.length Keeper_hooks_oas.keeper_denied_tools > 0))

let () = test "deny_list_reasonable_size" (fun () ->
  let n = List.length Keeper_hooks_oas.keeper_denied_tools in
  (* Should be focused: 5-30 tools, not hundreds *)
  assert (n >= 5 && n <= 30))

let () = Printf.printf "=== Keeper Deny List: all tests passed ===\n"

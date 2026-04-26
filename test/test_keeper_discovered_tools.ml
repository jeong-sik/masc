(** Tests for Keeper_discovered_tools — turn-based decay tracking. *)

let dt = Masc_mcp.Keeper_discovered_tools.create

let test_add_and_active () =
  let t = dt ~decay_turns:5 in
  Masc_mcp.Keeper_discovered_tools.add
    t
    ~turn:0
    ~names:[ "masc_worktree_create"; "masc_worktree_remove" ];
  let active = Masc_mcp.Keeper_discovered_tools.active_names t ~turn:0 in
  Alcotest.(check int) "two tools active" 2 (List.length active);
  Alcotest.(check bool)
    "worktree_create present"
    true
    (List.mem "masc_worktree_create" active);
  Alcotest.(check bool)
    "worktree_remove present"
    true
    (List.mem "masc_worktree_remove" active)
;;

let test_decay_removes_old () =
  let t = dt ~decay_turns:3 in
  Masc_mcp.Keeper_discovered_tools.add t ~turn:0 ~names:[ "tool_a" ];
  Masc_mcp.Keeper_discovered_tools.add t ~turn:2 ~names:[ "tool_b" ];
  (* At turn 4: tool_a last active at 0, decay_turns=3, 4-0=4 > 3 → expired *)
  let expired = Masc_mcp.Keeper_discovered_tools.decay t ~turn:4 in
  Alcotest.(check int) "one expired" 1 (List.length expired);
  Alcotest.(check bool) "tool_a expired" true (List.mem "tool_a" expired);
  let active = Masc_mcp.Keeper_discovered_tools.active_names t ~turn:4 in
  Alcotest.(check int) "one still active" 1 (List.length active);
  Alcotest.(check bool) "tool_b still active" true (List.mem "tool_b" active)
;;

let test_mark_used_resets_decay () =
  let t = dt ~decay_turns:3 in
  Masc_mcp.Keeper_discovered_tools.add t ~turn:0 ~names:[ "tool_a" ];
  (* Without mark_used, tool_a would decay at turn 4 *)
  Masc_mcp.Keeper_discovered_tools.mark_used t ~turn:3 ~name:"tool_a";
  let active = Masc_mcp.Keeper_discovered_tools.active_names t ~turn:4 in
  Alcotest.(check int) "still active after mark_used" 1 (List.length active);
  (* Now it should decay at turn 7 (3 + 3 + 1? no: 3 + 3 = 6, so turn 7 decays) *)
  let expired = Masc_mcp.Keeper_discovered_tools.decay t ~turn:7 in
  Alcotest.(check int) "expired after decay window" 1 (List.length expired)
;;

let test_readd_resets_decay () =
  let t = dt ~decay_turns:2 in
  Masc_mcp.Keeper_discovered_tools.add t ~turn:0 ~names:[ "tool_a" ];
  (* Re-add at turn 3 resets the clock *)
  Masc_mcp.Keeper_discovered_tools.add t ~turn:3 ~names:[ "tool_a" ];
  let active = Masc_mcp.Keeper_discovered_tools.active_names t ~turn:4 in
  Alcotest.(check int) "still active after re-add" 1 (List.length active)
;;

let test_mark_used_unknown_is_noop () =
  let t = dt ~decay_turns:3 in
  Masc_mcp.Keeper_discovered_tools.mark_used t ~turn:0 ~name:"nonexistent";
  Alcotest.(check int) "count is 0" 0 (Masc_mcp.Keeper_discovered_tools.count t)
;;

let test_clear () =
  let t = dt ~decay_turns:5 in
  Masc_mcp.Keeper_discovered_tools.add t ~turn:0 ~names:[ "a"; "b"; "c" ];
  Alcotest.(check int) "count is 3" 3 (Masc_mcp.Keeper_discovered_tools.count t);
  Masc_mcp.Keeper_discovered_tools.clear t;
  Alcotest.(check int)
    "count is 0 after clear"
    0
    (Masc_mcp.Keeper_discovered_tools.count t)
;;

let test_to_json () =
  let t = dt ~decay_turns:5 in
  Masc_mcp.Keeper_discovered_tools.add t ~turn:1 ~names:[ "tool_x" ];
  let json = Masc_mcp.Keeper_discovered_tools.to_json t in
  let count = Yojson.Safe.Util.(member "count" json |> to_int) in
  Alcotest.(check int) "json count matches" 1 count
;;

let test_decay_turns_minimum () =
  (* decay_turns is clamped to min 1 *)
  let t = dt ~decay_turns:0 in
  Masc_mcp.Keeper_discovered_tools.add t ~turn:0 ~names:[ "tool_a" ];
  (* At turn 1: 1 - 0 = 1 <= 1 → still active *)
  let active = Masc_mcp.Keeper_discovered_tools.active_names t ~turn:1 in
  Alcotest.(check int) "active at boundary" 1 (List.length active);
  (* At turn 2: 2 - 0 = 2 > 1 → expired *)
  let expired = Masc_mcp.Keeper_discovered_tools.decay t ~turn:2 in
  Alcotest.(check int) "expired past boundary" 1 (List.length expired)
;;

let () =
  Alcotest.run
    "Keeper discovered tools"
    [ ( "add"
      , [ Alcotest.test_case "add and active_names" `Quick test_add_and_active
        ; Alcotest.test_case "re-add resets decay" `Quick test_readd_resets_decay
        ] )
    ; ( "decay"
      , [ Alcotest.test_case "decay removes old tools" `Quick test_decay_removes_old
        ; Alcotest.test_case
            "mark_used resets decay clock"
            `Quick
            test_mark_used_resets_decay
        ; Alcotest.test_case "decay_turns minimum is 1" `Quick test_decay_turns_minimum
        ] )
    ; ( "misc"
      , [ Alcotest.test_case
            "mark_used on unknown is noop"
            `Quick
            test_mark_used_unknown_is_noop
        ; Alcotest.test_case "clear empties set" `Quick test_clear
        ; Alcotest.test_case "to_json returns valid count" `Quick test_to_json
        ] )
    ]
;;

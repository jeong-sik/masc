(** Test Tool_name: roundtrip, coverage, and invariant checks. *)

open Masc_mcp

let all_keeper : Tool_name.Keeper.t list =
  [ Bash; Board_cleanup; Board_comment; Board_comment_vote; Board_delete
  ; Board_get; Board_list; Board_post; Board_search; Board_stats; Board_vote
  ; Broadcast; Code_read; Context_status; Discovery; Fs_edit; Fs_read
  ; Handoff; Library_read; Library_search; Memory_search
  ; Pr_review_comment; Pr_review_read; Pr_review_reply
  ; Preflight_check; Shell; Stay_silent
  ; Task_claim; Task_create; Task_done; Task_force_done; Task_force_release
  ; Tasks_audit; Tasks_list; Time_now; Tool_search; Tools_list
  ; Voice_agent; Voice_listen; Voice_session_end; Voice_session_start
  ; Voice_sessions; Voice_speak; Write ]

let all_masc : Tool_name.Masc.t list =
  [ A2a_delegate; Add_task; Agent_card; Agent_fitness; Agent_update; Agents
  ; Autoresearch_cycle; Autoresearch_inject; Autoresearch_start
  ; Autoresearch_status; Autoresearch_stop
  ; Batch_add_tasks; Board_cleanup; Board_comment; Board_comment_vote
  ; Board_delete; Board_get; Board_hearths; Board_list; Board_post
  ; Board_profile; Board_search
  ; Board_stats; Board_vote; Broadcast; Cancel_task; Check; Claim_next
  ; Claim_task; Cleanup_zombies; Code_delete; Code_edit; Code_git; Code_read
  ; Code_search; Code_shell; Code_symbols; Code_write; Complete_task
  ; Dashboard; Deliver; Dispatch_assign; Dispatch_plan; Find_by_capability
  ; Heartbeat; Join; Leave; List_tasks; Messages; Note_add
  ; Operation_checkpoint; Operation_finalize; Operation_pause
  ; Operation_resume; Operation_start; Operation_status; Operation_stop
  ; Operator_action; Operator_confirm; Operator_digest; Operator_snapshot
  ; Plan_clear_task; Plan_get; Plan_get_task; Plan_init; Plan_set_task
  ; Plan_update; Register_capabilities; Release_task; Reset; Coord_status
  ; Set_current_task; Status; Task_history; Tasks; Tool_grant; Tool_help
  ; Tool_list; Tool_revoke; Transition; Update_priority; Web_search; Who
  ; Workflow_guide; Worktree_create; Worktree_list; Worktree_remove
  ; Worktree_status
  ; Approval_get; Collaboration_graph; Config; Gc; Get_metrics; Mcp_session
  ; Pause; Resume; Spawn; Start; Tool_admin_snapshot; Tool_admin_update
  ; Tool_stats; Webrtc_answer; Webrtc_offer ]

let all_masc_keeper : Tool_name.Masc_keeper.t list =
  [ Clear; Compact; Create_from_persona; Down; List; Msg; Repair; Reset
  ; Status; Up ]

let all_tool_names : Tool_name.t list =
  List.map (fun k -> Tool_name.Keeper k) all_keeper
  @ List.map (fun m -> Tool_name.Masc m) all_masc
  @ List.map (fun mk -> Tool_name.Masc_keeper mk) all_masc_keeper

(* ── Roundtrip ─────────────────────────────────────────────── *)

let test_roundtrip_keeper () =
  List.iter (fun k ->
    let s = Tool_name.Keeper.to_string k in
    let parsed = Tool_name.Keeper.of_string s in
    Alcotest.(check (option (of_pp Tool_name.Keeper.pp)))
      (Printf.sprintf "roundtrip %s" s) (Some k) parsed
  ) all_keeper

let test_roundtrip_masc () =
  List.iter (fun m ->
    let s = Tool_name.Masc.to_string m in
    let parsed = Tool_name.Masc.of_string s in
    Alcotest.(check (option (of_pp Tool_name.Masc.pp)))
      (Printf.sprintf "roundtrip %s" s) (Some m) parsed
  ) all_masc

let test_roundtrip_masc_keeper () =
  List.iter (fun mk ->
    let s = Tool_name.Masc_keeper.to_string mk in
    let parsed = Tool_name.Masc_keeper.of_string s in
    Alcotest.(check (option (of_pp Tool_name.Masc_keeper.pp)))
      (Printf.sprintf "roundtrip %s" s) (Some mk) parsed
  ) all_masc_keeper

let test_roundtrip_toplevel () =
  List.iter (fun t ->
    let s = Tool_name.to_string t in
    let parsed = Tool_name.of_string s in
    Alcotest.(check (option (of_pp Tool_name.pp)))
      (Printf.sprintf "roundtrip %s" s) (Some t) parsed
  ) all_tool_names

(* ── Prefix invariants ─────────────────────────────────────── *)

let test_keeper_prefix () =
  List.iter (fun k ->
    let s = Tool_name.Keeper.to_string k in
    Alcotest.(check bool)
      (Printf.sprintf "%s starts with keeper_" s)
      true
      (String.length s > 7 && String.sub s 0 7 = "keeper_")
  ) all_keeper

let test_masc_prefix () =
  List.iter (fun m ->
    let s = Tool_name.Masc.to_string m in
    Alcotest.(check bool)
      (Printf.sprintf "%s starts with masc_" s)
      true
      (String.length s > 5 && String.sub s 0 5 = "masc_")
  ) all_masc

let test_masc_keeper_prefix () =
  List.iter (fun mk ->
    let s = Tool_name.Masc_keeper.to_string mk in
    Alcotest.(check bool)
      (Printf.sprintf "%s starts with masc_keeper_" s)
      true
      (String.length s > 12 && String.sub s 0 12 = "masc_keeper_")
  ) all_masc_keeper

(* ── Uniqueness ────────────────────────────────────────────── *)

let test_all_names_unique () =
  let names = List.map Tool_name.to_string all_tool_names in
  let sorted = List.sort String.compare names in
  let rec check = function
    | a :: b :: rest ->
      if a = b then
        Alcotest.fail (Printf.sprintf "duplicate tool name: %s" a)
      else check (b :: rest)
    | _ -> ()
  in
  check sorted

(* ── Unknown strings fail closed ───────────────────────────── *)

let test_unknown_returns_none () =
  let unknowns = [ "keeper_nonexistent"; "masc_fake"; "foobar"; "" ] in
  List.iter (fun s ->
    Alcotest.(check (option (of_pp Tool_name.pp)))
      (Printf.sprintf "unknown %s -> None" s)
      None (Tool_name.of_string s)
  ) unknowns

(* ── Group predicates ──────────────────────────────────────── *)

let test_is_keeper () =
  List.iter (fun k ->
    Alcotest.(check bool) "is_keeper" true
      (Tool_name.is_keeper (Keeper k))
  ) all_keeper;
  List.iter (fun m ->
    Alcotest.(check bool) "masc is not keeper" false
      (Tool_name.is_keeper (Masc m))
  ) all_masc

(* ── Coverage: all shard tool schemas must parse ───────────── *)

let test_shard_tools_parse () =
  let shard_names = [ "base"; "board"; "filesystem"; "shell"; "voice";
                      "coding"; "pr"; "autoresearch"; "library" ] in
  let tool_names =
    List.concat_map (fun sn ->
      match Tool_shard.get_shard sn with
      | Some shard ->
        List.map (fun (t : Types.tool_schema) -> t.name) shard.tools
      | None -> []
    ) shard_names
  in
  let unparsed = List.filter (fun name ->
    Tool_name.of_string name = None
  ) tool_names in
  if unparsed <> [] then
    Alcotest.fail
      (Printf.sprintf "Tool_shard names not in Tool_name: [%s]"
         (String.concat "; " unparsed))

let test_prefilter_synonyms_parse () =
  let unparsed = List.filter (fun name ->
    Tool_name.of_string name = None
  ) Tool_prefilter.synonym_keys in
  if unparsed <> [] then
    Alcotest.fail
      (Printf.sprintf "Tool_prefilter synonyms not in Tool_name: [%s]"
         (String.concat "; " unparsed))

let () =
  Alcotest.run "Tool_name" [
    "roundtrip", [
      Alcotest.test_case "keeper" `Quick test_roundtrip_keeper;
      Alcotest.test_case "masc" `Quick test_roundtrip_masc;
      Alcotest.test_case "masc_keeper" `Quick test_roundtrip_masc_keeper;
      Alcotest.test_case "toplevel" `Quick test_roundtrip_toplevel;
    ];
    "invariants", [
      Alcotest.test_case "keeper prefix" `Quick test_keeper_prefix;
      Alcotest.test_case "masc prefix" `Quick test_masc_prefix;
      Alcotest.test_case "masc_keeper prefix" `Quick test_masc_keeper_prefix;
      Alcotest.test_case "all unique" `Quick test_all_names_unique;
      Alcotest.test_case "unknown -> None" `Quick test_unknown_returns_none;
      Alcotest.test_case "is_keeper" `Quick test_is_keeper;
    ];
    "coverage", [
      Alcotest.test_case "shard tools parse" `Quick test_shard_tools_parse;
      Alcotest.test_case "prefilter synonyms parse" `Quick test_prefilter_synonyms_parse;
    ];
  ]

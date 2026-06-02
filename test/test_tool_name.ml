module Types = Masc_domain

(** Test Tool_name: roundtrip, coverage, and invariant checks. *)

open Masc_mcp

(* PR-S1: Task/Board/Goal/Operator tool names are owned by domain submodules
   and wrapped into [Masc.t] via the [Task]/[Board]/[Goal]/[Operator]
   constructors. The remaining names stay flat. *)
let all_masc : Tool_name.Masc.t list =
  let open Tool_name in
  [ Masc.Task Task_name.Add_task; Masc.Agent_fitness; Masc.Agent_update
  ; Masc.Agent_card; Masc.Agents
  ; Masc.Task Task_name.Batch_add_tasks
  ; Masc.Board Board_name.Board_cleanup; Masc.Board Board_name.Board_comment
  ; Masc.Board Board_name.Board_comment_vote
  ; Masc.Board Board_name.Board_curation_read
  ; Masc.Board Board_name.Board_curation_submit
  ; Masc.Board Board_name.Board_delete; Masc.Board Board_name.Board_get
  ; Masc.Board Board_name.Board_hearths; Masc.Board Board_name.Board_list
  ; Masc.Board Board_name.Board_post
  ; Masc.Board Board_name.Board_profile; Masc.Board Board_name.Board_reaction
  ; Masc.Board Board_name.Board_search
  ; Masc.Board Board_name.Board_stats
  ; Masc.Board Board_name.Board_sub_board_create
  ; Masc.Board Board_name.Board_sub_board_delete
  ; Masc.Board Board_name.Board_sub_board_get
  ; Masc.Board Board_name.Board_sub_board_list
  ; Masc.Board Board_name.Board_sub_board_update
  ; Masc.Board Board_name.Board_vote; Masc.Broadcast; Masc.Check
  ; Masc.Task Task_name.Claim_next
  ; Masc.Cleanup_zombies; Masc.Dashboard; Masc.Deliver
  ; Masc.Goal Goal_name.Goal_list; Masc.Goal Goal_name.Goal_transition
  ; Masc.Goal Goal_name.Goal_upsert; Masc.Goal Goal_name.Goal_verify
  ; Masc.Heartbeat; Masc.Messages; Masc.Note_add
  ; Masc.Operator Operator_name.Operator_action
  ; Masc.Operator Operator_name.Operator_confirm
  ; Masc.Operator Operator_name.Operator_digest
  ; Masc.Operator Operator_name.Operator_snapshot
  ; Masc.Plan_clear_task; Masc.Plan_get; Masc.Plan_get_task; Masc.Plan_init
  ; Masc.Plan_set_task
  ; Masc.Plan_update; Masc.Reset
  ; Masc.Status; Masc.Task Task_name.Task_history; Masc.Task Task_name.Tasks
  ; Masc.Tool_grant; Masc.Tool_help
  ; Masc.Tool_list; Masc.Tool_revoke; Masc.Task Task_name.Transition
  ; Masc.Task Task_name.Update_priority; Masc.Web_fetch; Masc.Web_search
  ; Masc.Approval_pending; Masc.Approval_get; Masc.Config; Masc.Gc
  ; Masc.Get_metrics; Masc.Mcp_session
  ; Masc.Pause; Masc.Resume; Masc.Start; Masc.Tool_admin_snapshot
  ; Masc.Tool_admin_update
  ; Masc.Tool_stats ]

let all_tool_names : Tool_name.t list =
  List.map (fun m -> Tool_name.Masc m) all_masc

(* ── Roundtrip ─────────────────────────────────────────────── *)

let test_roundtrip_masc () =
  List.iter (fun m ->
    let s = Tool_name.Masc.to_string m in
    let parsed = Tool_name.Masc.of_string s in
    Alcotest.(check (option (of_pp Tool_name.Masc.pp)))
      (Printf.sprintf "roundtrip %s" s) (Some m) parsed
  ) all_masc

let test_roundtrip_toplevel () =
  List.iter (fun t ->
    let s = Tool_name.to_string t in
    let parsed = Tool_name.of_string s in
    Alcotest.(check (option (of_pp Tool_name.pp)))
      (Printf.sprintf "roundtrip %s" s) (Some t) parsed
  ) all_tool_names

(* ── Prefix invariants ─────────────────────────────────────── *)

let test_masc_prefix () =
  List.iter (fun m ->
    let s = Tool_name.Masc.to_string m in
    Alcotest.(check bool)
      (Printf.sprintf "%s starts with masc_" s)
      true
      (String.length s > 5 && String.sub s 0 5 = "masc_")
  ) all_masc

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

let test_board_predicate_facade_uses_typed_contract () =
  let check_tool label expected name =
    Alcotest.(check bool) label expected
      (match Tool_name.of_string name with
       | Some tool -> Tool_name.is_board tool
       | None -> false)
  in
  check_tool "masc board post is board" true "masc_board_post";
  check_tool "masc board profile is board" true "masc_board_profile";
  check_tool "masc fake board prefix fails closed" false "masc_board_fake"

(* ── Coverage: all shard tool schemas must parse ───────────── *)

let test_shard_tools_parse () =
  let shard_names =
    [ "base"; "board"; "filesystem"; "search_files"; "voice"; "pr"; "library" ]
  in
  let tool_names =
    List.concat_map (fun sn ->
      match Tool_shard.get_shard sn with
      | Some shard ->
        List.map (fun (t : Masc_domain.tool_schema) -> t.name) shard.tools
      | None -> []
    ) shard_names
  in
  let unparsed = List.filter (fun name ->
    Tool_name.of_string name = None && Keeper_tool_name.of_string name = None
  ) tool_names in
  if unparsed <> [] then
    Alcotest.fail
      (Printf.sprintf "Tool_shard names not in Tool_name: [%s]"
         (String.concat "; " unparsed))

let test_prefilter_synonyms_parse () =
  let unparsed = List.filter (fun name ->
    Tool_name.of_string name = None && Keeper_tool_name.of_string name = None
  ) Tool_prefilter.synonym_keys in
  if unparsed <> [] then
    Alcotest.fail
      (Printf.sprintf "Tool_prefilter synonyms not in Tool_name: [%s]"
         (String.concat "; " unparsed))

let () =
  Alcotest.run "Tool_name" [
    "roundtrip", [
      Alcotest.test_case "masc" `Quick test_roundtrip_masc;
      Alcotest.test_case "toplevel" `Quick test_roundtrip_toplevel;
    ];
    "invariants", [
      Alcotest.test_case "masc prefix" `Quick test_masc_prefix;
      Alcotest.test_case "all unique" `Quick test_all_names_unique;
      Alcotest.test_case "unknown -> None" `Quick test_unknown_returns_none;
      Alcotest.test_case "board predicate facade" `Quick
        test_board_predicate_facade_uses_typed_contract;
    ];
    "coverage", [
      Alcotest.test_case "shard tools parse" `Quick test_shard_tools_parse;
      Alcotest.test_case "prefilter synonyms parse" `Quick test_prefilter_synonyms_parse;
    ];
  ]

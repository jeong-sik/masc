module Types = Masc_domain

(** Test Tool_name: roundtrip, coverage, and invariant checks. *)

open Masc_mcp

let all_keeper : Tool_name.Keeper.t list =
  [ Execute; Board_comment; Board_comment_vote
  ; Board_curation_read; Board_curation_submit
  ; Board_get; Board_list; Board_post; Board_search; Board_stats; Board_vote
  ; Broadcast; Context_status; Fs_edit; Fs_write; Fs_read
  ; Handoff; Library_read; Library_search; Memory_search
  ; Search_files; Stay_silent
  ; Task_claim; Task_create; Task_done; Task_submit_for_verification
  ; Task_force_done; Task_force_release
  ; Tasks_audit; Tasks_list; Time_now; Tool_search; Tools_list
  ; Voice_agent; Voice_listen; Voice_session_end; Voice_session_start
  ; Voice_sessions; Voice_speak ]

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

let all_masc_keeper : Tool_name.Masc_keeper.t list =
  [ Clear; Compact; Create_from_persona; Down; List; Msg; Persona_audit; Repair
  ; Reset; Status; Up ]

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

(* Keeper variants that intentionally use a non-keeper_ prefix.
   These are shared-surface tools whose canonical string id starts
   with "tool_" rather than "keeper_" (see PR #18520, #18779). *)
let keeper_shared_surface_prefixes =
  [ "tool_execute"; "tool_edit_file"; "tool_read_file"; "tool_search_files"
  ; "tool_write_file" ]

let test_keeper_prefix () =
  List.iter (fun k ->
    let s = Tool_name.Keeper.to_string k in
    if not (List.mem s keeper_shared_surface_prefixes) then
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

let test_keeper_board_write_helpers () =
  let open Tool_name.Keeper in
  List.iter
    (fun tool ->
       Alcotest.(check bool)
         (Printf.sprintf "%s is board" (to_string tool))
         true
         (is_board tool))
    [ Board_comment; Board_comment_vote; Board_curation_read
    ; Board_curation_submit; Board_get; Board_list; Board_post
    ; Board_search; Board_stats; Board_vote ];
  List.iter
    (fun tool ->
       Alcotest.(check bool)
         (Printf.sprintf "%s is not board" (to_string tool))
         false
         (is_board tool))
    [ Broadcast; Task_done ];
  Alcotest.(check (list string)) "canonical board write names"
    [ "keeper_board_post"; "keeper_board_comment"; "keeper_board_vote"; "keeper_board_curation_submit" ]
    board_write_tool_names;
  List.iter
    (fun tool ->
       Alcotest.(check bool)
         (Printf.sprintf "%s is board write" (to_string tool))
         true
         (is_board_write tool))
    board_write_tools;
  List.iter
    (fun tool ->
       Alcotest.(check bool)
         (Printf.sprintf "%s is not board write" (to_string tool))
         false
         (is_board_write tool))
    [ Board_list; Board_get; Board_curation_read; Board_comment_vote; Task_done ];
  Alcotest.(check (option string)) "post action kind"
    (Some "post") (board_write_action_kind Board_post);
  Alcotest.(check (option string)) "comment action kind"
    (Some "comment") (board_write_action_kind Board_comment);
  Alcotest.(check (option string)) "vote action kind"
    (Some "vote") (board_write_action_kind Board_vote);
  Alcotest.(check (option string)) "curation action kind"
    (Some "curation") (board_write_action_kind Board_curation_submit);
  Alcotest.(check (option string)) "non-board action kind"
    None (board_write_action_kind Board_list)

let test_keeper_board_write_facade_uses_typed_contract () =
  Alcotest.(check (list string)) "exec context names mirror Tool_name"
    Tool_name.Keeper.board_write_tool_names
    Keeper_context_runtime.keeper_board_write_tool_names;
  Alcotest.(check bool) "comment is board write" true
    (Keeper_context_runtime.keeper_write_done [ "keeper_board_comment" ]);
  Alcotest.(check bool) "comment vote is not board write" false
    (Keeper_context_runtime.keeper_write_done [ "keeper_board_comment_vote" ]);
  Alcotest.(check string) "post has stable priority" "post"
    (Keeper_context_runtime.keeper_action_kind_of_tool_names
       [ "keeper_board_vote"; "keeper_board_post" ]);
  Alcotest.(check string) "non-board action kind is none" "none"
    (Keeper_context_runtime.keeper_action_kind_of_tool_names
       [ "keeper_board_comment_vote"; "unknown" ])

let test_board_predicate_facade_uses_typed_contract () =
  let check_tool label expected name =
    Alcotest.(check bool) label expected
      (match Tool_name.of_string name with
       | Some tool -> Tool_name.is_board tool
       | None -> false)
  in
  check_tool "keeper board post is board" true "keeper_board_post";
  check_tool "keeper comment vote is board" true "keeper_board_comment_vote";
  check_tool "masc board post is board" true "masc_board_post";
  check_tool "masc board profile is board" true "masc_board_profile";
  check_tool "keeper fake board prefix fails closed" false "keeper_board_fake";
  check_tool "masc fake board prefix fails closed" false "masc_board_fake";
  check_tool "broadcast is not board" false "keeper_broadcast"

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
      Alcotest.test_case "keeper board write helpers" `Quick
        test_keeper_board_write_helpers;
      Alcotest.test_case "keeper board write facade" `Quick
        test_keeper_board_write_facade_uses_typed_contract;
      Alcotest.test_case "board predicate facade" `Quick
        test_board_predicate_facade_uses_typed_contract;
      Alcotest.test_case "is_keeper" `Quick test_is_keeper;
    ];
    "coverage", [
      Alcotest.test_case "shard tools parse" `Quick test_shard_tools_parse;
      Alcotest.test_case "prefilter synonyms parse" `Quick test_prefilter_synonyms_parse;
    ];
  ]

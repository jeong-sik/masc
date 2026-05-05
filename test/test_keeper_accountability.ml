module Types = Masc_domain

open Alcotest
open Masc_mcp

let temp_dir () =
  let dir =
    Filename.concat (Filename.get_temp_dir_name ())
      (Printf.sprintf "test_keeper_accountability_%d" (Random.int 1_000_000))
  in
  (try Unix.mkdir dir 0o755 with Unix.Unix_error (Unix.EEXIST, _, _) -> ());
  dir

let cleanup_dir dir =
  let rec rm path =
    if Sys.file_exists path then
      if Sys.is_directory path then (
        Sys.readdir path
        |> Array.iter (fun name -> rm (Filename.concat path name));
        Unix.rmdir path)
      else
        Sys.remove path
  in
  try rm dir with _ -> ()

let iso_of_unix ts =
  let tm = Unix.gmtime ts in
  Printf.sprintf "%04d-%02d-%02dT%02d:%02d:%02dZ"
    (tm.Unix.tm_year + 1900)
    (tm.Unix.tm_mon + 1)
    tm.Unix.tm_mday tm.Unix.tm_hour tm.Unix.tm_min tm.Unix.tm_sec

let make_test_meta ?(name = "keeper-sangsu") ?(agent_name = "keeper-sangsu-agent") ()
    : Keeper_types.keeper_meta =
  match Masc_test_deps.meta_of_json_fixture
          (`Assoc
             [
               ("name", `String name);
               ("agent_name", `String agent_name);
               ("trace_id", `String "test-trace-accountability");
               ( "tool_access",
                 Keeper_types.tool_access_to_json
                   (Keeper_types.Preset
                      { preset = Keeper_types.Full; also_allow = [] }) );
             ])
  with
  | Ok meta -> meta
  | Error e -> failwith (Printf.sprintf "make_test_meta failed: %s" e)

let make_ctx_work () =
  Keeper_exec_context.create ~system_prompt:"test" ~max_tokens:4000

let with_room ?(agent_name = "keeper-sangsu-agent") f =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let dir = temp_dir () in
  let saved_pg = Sys.getenv_opt "MASC_POSTGRES_URL" in
  let saved_sb = Sys.getenv_opt "SB_PG_URL" in
  Unix.putenv "MASC_POSTGRES_URL" "";
  Unix.putenv "SB_PG_URL" "";
  Fun.protect
    ~finally:(fun () ->
      (match saved_pg with
       | Some value -> Unix.putenv "MASC_POSTGRES_URL" value
       | None -> Unix.putenv "MASC_POSTGRES_URL" "");
      (match saved_sb with
       | Some value -> Unix.putenv "SB_PG_URL" value
       | None -> Unix.putenv "SB_PG_URL" "");
      cleanup_dir dir)
    (fun () ->
      let config = Coord.default_config dir in
      ignore (Coord.init config ~agent_name:(Some agent_name));
      f config)

let append_jsonl path json =
  let oc =
    open_out_gen [ Open_creat; Open_text; Open_append ] 0o644 path
  in
  Fun.protect
    ~finally:(fun () -> close_out_noerr oc)
    (fun () ->
      output_string oc (Yojson.Safe.to_string json);
      output_char oc '\n')

let append_accountability_event base_dir ~created_at json =
  let month = String.sub created_at 0 7 in
  let day = String.sub created_at 8 2 in
  let dir = Filename.concat base_dir ".masc/accountability" |> fun root ->
    Filename.concat root month
  in
  Fs_compat.mkdir_p dir;
  let path = Filename.concat dir (day ^ ".jsonl") in
  append_jsonl path json

let string_member key json = Yojson.Safe.Util.(json |> member key |> to_string)
let int_member key json = Yojson.Safe.Util.(json |> member key |> to_int)
let float_member key json = Yojson.Safe.Util.(json |> member key |> to_float)
let bool_member key json = Yojson.Safe.Util.(json |> member key |> to_bool)

let string_member_opt key json =
  match Yojson.Safe.Util.(json |> member key) with
  | `String value -> Some value
  | _ -> None

let read_jsonl_file path =
  if not (Sys.file_exists path) then []
  else
    let ic = open_in path in
    Fun.protect
      ~finally:(fun () -> close_in_noerr ic)
      (fun () ->
        let rows = ref [] in
        (try
           while true do
             let line = input_line ic in
             if String.trim line <> "" then
               try rows := Yojson.Safe.from_string line :: !rows
               with Yojson.Json_error _ -> ()
           done
         with End_of_file -> ());
        List.rev !rows)

let read_accountability_events base_dir =
  let root = Filename.concat base_dir ".masc/accountability" in
  let rec gather path =
    if not (Sys.file_exists path) then []
    else if Sys.is_directory path then
      Sys.readdir path
      |> Array.to_list
      |> List.concat_map (fun child -> gather (Filename.concat path child))
    else if Filename.check_suffix path ".jsonl" then
      read_jsonl_file path
    else
      []
  in
  gather root

let append_decision_log_event config keeper_name json =
  let path = Keeper_types.keeper_decision_log_path config keeper_name in
  Fs_compat.mkdir_p (Filename.dirname path);
  append_jsonl path json

let test_same_turn_evidence_marks_claim_supported () =
  with_room (fun config ->
      Keeper_accountability.record_completion_claim config
        ~keeper_name:"keeper-sangsu"
        ~agent_name:"keeper-sangsu-agent"
        ~trace_id:"trace-1"
        ~turn_number:7
        ~subject:"Ship v1"
        ~task_id:"T-1"
        ~evidence_refs:[ "task:T-1" ]
        ~strong_evidence:true
        ~strong_evidence_refs:[ "tool:keeper_task_done" ]
        ();
      let summary =
        Keeper_accountability.accountability_summary_json config
          ~keeper_name:"keeper-sangsu" ~agent_name:"keeper-sangsu-agent"
      in
      check string "risk band" "low" (string_member "risk_band" summary);
      check string "routing hint" "normal_routing"
        (string_member "routing_hint" summary);
      check int "recent supported claims" 1
        (int_member "recent_supported_claims" summary);
      check (float 0.0001) "evidence coverage" 1.0
        (float_member "evidence_coverage" summary);
      let history = Yojson.Safe.Util.(summary |> member "history" |> to_list) in
      check int "history count" 1 (List.length history);
      let first = List.hd history in
      check string "history status" "supported" (string_member "status" first);
      let supporting_refs =
        Yojson.Safe.Util.(
          first |> member "supporting_evidence_refs" |> to_list
          |> List.map to_string)
      in
      check bool "contains turn reference" true
        (List.mem "turn:trace-1:7" supporting_refs))

let test_stale_completion_claim_sets_high_risk () =
  with_room (fun config ->
      let created_at =
        iso_of_unix (Unix.gettimeofday () -. (25.0 *. 3600.0))
      in
      append_accountability_event config.base_path ~created_at
        (`Assoc
           [
             ("event_type", `String "claim_created");
             ("claim_id", `String "acct-old-unsupported");
             ("agent_name", `String "keeper-sangsu-agent");
             ("keeper_name", `String "keeper-sangsu");
             ("kind", `String "completion_claim");
             ("subject", `String "Ship v1");
             ("surface", `String "keeper_turn");
             ("created_at", `String created_at);
             ("task_id", `String "T-1");
             ("evidence_refs", `List [ `String "task:T-1" ]);
             ("synthetic", `Bool false);
           ]);
      let summary =
        Keeper_accountability.accountability_summary_json config
          ~keeper_name:"keeper-sangsu" ~agent_name:"keeper-sangsu-agent"
      in
      check string "risk band" "high" (string_member "risk_band" summary);
      check string "routing hint" "manual_review_recommended"
        (string_member "routing_hint" summary);
      check (float 0.0001) "unsupported completion rate" 1.0
        (float_member "unsupported_completion_rate" summary);
      check bool "risk helper" true
        (Keeper_accountability.accountability_risk_is_high config
           ~keeper_name:"keeper-sangsu" ~agent_name:"keeper-sangsu-agent");
      let history = Yojson.Safe.Util.(summary |> member "history" |> to_list) in
      check int "history count" 1 (List.length history);
      let first = List.hd history in
      check string "history status" "unsupported" (string_member "status" first))

let test_agent_reputation_penalizes_unsupported_claims () =
  with_room ~agent_name:"keeper-rep-agent" (fun config ->
      ignore
        (Coord.add_task config ~title:"Reputation task" ~priority:1
           ~description:"desc");
      ignore
        (Coord.claim_task config ~agent_name:"keeper-rep-agent"
           ~task_id:"task-001");
      (match
         Coord.transition_task_r config ~agent_name:"keeper-rep-agent"
           ~task_id:"task-001" ~action:Types.Done_action ()
       with
      | Ok _ -> ()
      | Error err ->
          Alcotest.failf "done transition failed: %s"
            (Types.masc_error_to_string err));
      let created_at =
        iso_of_unix (Unix.gettimeofday () -. (25.0 *. 3600.0))
      in
      append_accountability_event config.base_path ~created_at
        (`Assoc
           [
             ("event_type", `String "claim_created");
             ("claim_id", `String "acct-rep-unsupported");
             ("agent_name", `String "keeper-rep-agent");
             ("keeper_name", `String "keeper-rep");
             ("kind", `String "completion_claim");
             ("subject", `String "Unsupported claim");
             ("surface", `String "keeper_turn");
             ("created_at", `String created_at);
             ("evidence_refs", `List []);
             ("synthetic", `Bool false);
           ]);
      let unpenalized =
        Agent_reputation.compute_overall_score ~completion_rate:1.0
          ~response_rate:0.0 ~board_posts:0 ~board_comments:0
          ~thompson_confidence:0.5
      in
      let rep =
        Agent_reputation.compute_reputation config
          ~agent_name:"keeper-rep-agent"
      in
      check int "tasks completed" 1 rep.tasks_completed;
      check int "tasks claimed" 1 rep.tasks_claimed;
      check string "accountability risk band" "high"
        rep.accountability_risk_band;
      check (float 0.0001) "unsupported completion rate" 1.0
        rep.accountability_unsupported_completion_rate;
      check (float 0.0001) "accountability score clamps to zero" 0.0
        rep.accountability_score;
      check bool "overall reputation penalized" true
        (rep.overall_score < unpenalized))

let test_generated_alias_inherits_accountability_penalty () =
  with_room ~agent_name:"adversary-eager-viper" (fun config ->
      let created_at =
        iso_of_unix (Unix.gettimeofday () -. (25.0 *. 3600.0))
      in
      append_accountability_event config.base_path ~created_at
        (`Assoc
           [
             ("event_type", `String "claim_created");
             ("claim_id", `String "acct-adversary-unsupported");
             ("agent_name", `String "keeper-adversary-agent");
             ("keeper_name", `String "adversary");
             ("kind", `String "completion_claim");
             ("subject", `String "Unsupported canonical claim");
             ("surface", `String "keeper_turn");
             ("created_at", `String created_at);
             ("evidence_refs", `List []);
             ("synthetic", `Bool false);
           ]);
      let summary =
        Keeper_accountability.accountability_summary_json config
          ~keeper_name:"adversary" ~agent_name:"adversary-eager-viper"
      in
      check string "alias summary inherits canonical keeper risk" "high"
        (string_member "risk_band" summary);
      check string "alias summary source" "canonical_keeper_fallback"
        (string_member "source" summary);
      check string "alias summary source label"
        "Inherited from canonical identity: adversary"
        (string_member "source_label" summary);
      check (float 0.0001) "alias summary inherits unsupported rate" 1.0
        (float_member "unsupported_completion_rate" summary);
      let rep =
        Agent_reputation.compute_reputation config
          ~agent_name:"adversary-eager-viper"
      in
      check string "generated alias risk band" "high"
        rep.accountability_risk_band;
      check (float 0.0001) "generated alias unsupported rate" 1.0
        rep.accountability_unsupported_completion_rate;
      check (float 0.0001) "generated alias accountability score" 0.0
        rep.accountability_score;
      check string "generated alias keeper provenance" "adversary"
        rep.accountability_keeper_name;
      check string "generated alias reputation source"
        "canonical_keeper_fallback" rep.accountability_source;
      check string "generated alias reputation source label"
        "Inherited from canonical identity: adversary"
        rep.accountability_source_label)

let test_generated_alias_inherits_legacy_keeper_history () =
  with_room ~agent_name:"adversary-eager-viper" (fun config ->
      let created_at =
        iso_of_unix (Unix.gettimeofday () -. (25.0 *. 3600.0))
      in
      append_accountability_event config.base_path ~created_at
        (`Assoc
           [
             ("event_type", `String "claim_created");
             ("claim_id", `String "acct-adversary-legacy-unsupported");
             ("agent_name", `String "keeper-adversary-agent");
             ("keeper_name", `String "keeper-adversary");
             ("kind", `String "completion_claim");
             ("subject", `String "Unsupported legacy claim");
             ("surface", `String "keeper_turn");
             ("created_at", `String created_at);
             ("evidence_refs", `List []);
             ("synthetic", `Bool false);
           ]);
      let summary =
        Keeper_accountability.accountability_summary_json config
          ~keeper_name:"adversary" ~agent_name:"adversary-eager-viper"
      in
      check string "legacy keeper summary source" "canonical_keeper_fallback"
        (string_member "source" summary);
      check string "legacy keeper source label"
        "Inherited from canonical identity: adversary"
        (string_member "source_label" summary);
      check (float 0.0001) "legacy keeper unsupported rate" 1.0
        (float_member "unsupported_completion_rate" summary))

let test_direct_agent_history_exposes_direct_source () =
  with_room ~agent_name:"keeper-direct-agent" (fun config ->
      let created_at =
        iso_of_unix (Unix.gettimeofday () -. (25.0 *. 3600.0))
      in
      append_accountability_event config.base_path ~created_at
        (`Assoc
           [
             ("event_type", `String "claim_created");
             ("claim_id", `String "acct-direct-agent-unsupported");
             ("agent_name", `String "keeper-direct-agent");
             ("keeper_name", `String "keeper-direct");
             ("kind", `String "completion_claim");
             ("subject", `String "Unsupported direct claim");
             ("surface", `String "keeper_turn");
             ("created_at", `String created_at);
             ("evidence_refs", `List []);
             ("synthetic", `Bool false);
           ]);
      let summary =
        Keeper_accountability.accountability_summary_json config
          ~keeper_name:"keeper-direct" ~agent_name:"keeper-direct-agent"
      in
      check string "direct summary source" "direct_agent"
        (string_member "source" summary);
      check string "direct summary source label"
        "Direct runtime alias history"
        (string_member "source_label" summary);
      let rep =
        Agent_reputation.compute_reputation config
          ~agent_name:"keeper-direct-agent"
      in
      check string "direct reputation keeper provenance" "direct"
        rep.accountability_keeper_name;
      check string "direct reputation source" "direct_agent"
        rep.accountability_source;
      check string "direct reputation source label"
        "Direct runtime alias history"
        rep.accountability_source_label)

let test_task_transition_normalizes_keeper_name_in_history () =
  with_room ~agent_name:"keeper-sangsu-agent" (fun config ->
      Keeper_accountability.record_task_transition config
        ~agent_name:"keeper-sangsu-agent" ~task_id:"task-legacy"
        ~transition:Types.Claim ~details:(`Assoc []);
      let summary =
        Keeper_accountability.accountability_summary_json config
          ~keeper_name:"sangsu" ~agent_name:"keeper-sangsu-agent"
      in
      let history = Yojson.Safe.Util.(summary |> member "history" |> to_list) in
      check int "history count" 1 (List.length history);
      let first = List.hd history in
      check string "history keeper_name is canonical" "sangsu"
        (string_member "keeper_name" first))

let test_task_transition_resolution_rows_include_identity () =
  with_room ~agent_name:"keeper-sangsu-agent" (fun config ->
      Keeper_accountability.record_task_transition config
        ~agent_name:"keeper-sangsu-agent" ~task_id:"task-resolution"
        ~transition:Types.Claim ~details:(`Assoc []);
      Keeper_accountability.record_task_transition config
        ~agent_name:"keeper-sangsu-agent" ~task_id:"task-resolution"
        ~transition:Types.Done_action ~details:(`Assoc []);
      let resolution =
        read_accountability_events config.base_path
        |> List.find_opt (fun json ->
               string_member_opt "event_type" json = Some "claim_resolved")
      in
      match resolution with
      | None -> Alcotest.fail "expected claim_resolved row"
      | Some row ->
          check string "resolution agent_name" "keeper-sangsu-agent"
            (string_member "agent_name" row);
          check string "resolution keeper_name" "sangsu"
            (string_member "keeper_name" row);
          check string "resolution task_id" "task-resolution"
            (string_member "task_id" row);
          check string "resolution kind" "task_commitment"
            (string_member "kind" row);
          check string "resolution subject" "task-resolution"
            (string_member "subject" row))

let test_recent_decision_without_claim_exposes_coverage_gap () =
  with_room ~agent_name:"keeper-sangsu-agent" (fun config ->
      let now = Unix.gettimeofday () in
      append_decision_log_event config "sangsu"
        (`Assoc
           [
             ("id", `String "decision-active-no-accountability");
             ("ts", `String (iso_of_unix now));
             ("ts_unix", `Float now);
             ("keeper_name", `String "sangsu");
             ("agent_name", `String "keeper-sangsu-agent");
             ("outcome", `String "success");
             ("tools_used", `List [ `String "keeper_task_claim" ]);
           ]);
      let summary =
        Keeper_accountability.accountability_summary_json config
          ~keeper_name:"sangsu" ~agent_name:"keeper-sangsu-agent"
      in
      check string "summary source still no accountability history" "none"
        (string_member "source" summary);
      check string "coverage health" "coverage_gap"
        (string_member "coverage_health" summary);
      check bool "coverage gap" true (bool_member "coverage_gap" summary);
      check string "coverage reason"
        "recent_decisions_without_accountability_claims"
        (string_member "coverage_gap_reason" summary);
      check string "routing hint" "accountability_coverage_gap_review"
        (string_member "routing_hint" summary);
      check string "source label mentions decision activity"
        "No accountability history; recent decision activity exists"
        (string_member "source_label" summary);
      check int "decision signal count" 1
        (int_member "decision_signal_count" summary);
      check int "claim count" 0
        (int_member "accountability_claim_count" summary))

let test_unmapped_alias_exposes_no_history_source () =
  with_room ~agent_name:"orphan-eager-viper" (fun config ->
      let summary =
        Keeper_accountability.accountability_summary_json config
          ~keeper_name:"orphan" ~agent_name:"orphan-eager-viper"
      in
      check string "unmapped alias source" "none"
        (string_member "source" summary);
      check string "unmapped alias source label"
        "No accountability history"
        (string_member "source_label" summary);
      check string "unmapped alias coverage health" "no_recent_activity"
        (string_member "coverage_health" summary);
      check bool "unmapped alias coverage gap" false
        (bool_member "coverage_gap" summary);
      check string "unmapped alias risk remains low" "low"
        (string_member "risk_band" summary);
      let rep =
        Agent_reputation.compute_reputation config
          ~agent_name:"orphan-eager-viper"
      in
      check string "unmapped alias keeper provenance" "orphan"
        rep.accountability_keeper_name;
      check string "unmapped alias reputation source" "none"
        rep.accountability_source;
      check string "unmapped alias reputation source label"
        "No accountability history"
        rep.accountability_source_label)

let test_claim_tool_exposes_routing_warning_for_high_risk_keeper () =
  with_room (fun config ->
      let meta = make_test_meta () in
      let created_at =
        iso_of_unix (Unix.gettimeofday () -. (25.0 *. 3600.0))
      in
      append_accountability_event config.base_path ~created_at
        (`Assoc
           [
             ("event_type", `String "claim_created");
             ("claim_id", `String "acct-high-risk");
             ("agent_name", `String "keeper-sangsu-agent");
             ("keeper_name", `String "keeper-sangsu");
             ("kind", `String "completion_claim");
             ("subject", `String "Prior claim");
             ("surface", `String "keeper_turn");
             ("created_at", `String created_at);
             ("evidence_refs", `List []);
             ("synthetic", `Bool false);
           ]);
      ignore (Coord.add_task config ~title:"Task to claim" ~priority:1 ~description:"desc");
      let result =
        Keeper_exec_tools.execute_keeper_tool_call
          ~config ~meta ~ctx_work:(make_ctx_work ()) ~exec_cache:None
          ~name:"keeper_task_claim" ~input:(`Assoc []) ()
        |> Yojson.Safe.from_string
      in
      check string "warning present"
        "Accountability risk is high for this keeper. Prefer manual review or lower-risk routing when equivalent."
        (string_member "routing_warning" result))

let test_preflight_exposes_routing_hint_for_high_risk_keeper () =
  with_room (fun config ->
      let meta = make_test_meta () in
      let created_at =
        iso_of_unix (Unix.gettimeofday () -. (25.0 *. 3600.0))
      in
      append_accountability_event config.base_path ~created_at
        (`Assoc
           [
             ("event_type", `String "claim_created");
             ("claim_id", `String "acct-high-risk-preflight");
             ("agent_name", `String "keeper-sangsu-agent");
             ("keeper_name", `String "keeper-sangsu");
             ("kind", `String "completion_claim");
             ("subject", `String "Prior claim");
             ("surface", `String "keeper_turn");
             ("created_at", `String created_at);
             ("evidence_refs", `List []);
             ("synthetic", `Bool false);
           ]);
      let result =
        Keeper_exec_tools.execute_keeper_tool_call
          ~config ~meta ~ctx_work:(make_ctx_work ()) ~exec_cache:None
          ~name:"keeper_preflight_check" ~input:(`Assoc []) ()
        |> Yojson.Safe.from_string
      in
      check bool "accountability risk present" true
        (Yojson.Safe.Util.(result |> member "accountability_risk" |> to_bool));
      check string "risk band exposed" "high" (string_member "risk_band" result);
      check string "routing hint exposed" "manual_review_recommended"
        (string_member "routing_hint" result);
      let repo_readiness =
        Yojson.Safe.Util.(result |> member "repo_readiness")
      in
      check string "repo readiness state exposed" "missing_clone"
        (Yojson.Safe.Util.(repo_readiness |> member "state" |> to_string));
      check bool "repo readiness blocks code start without clone" false
        (Yojson.Safe.Util.(repo_readiness |> member "ok" |> to_bool)))

let test_synthetic_claims_do_not_dilute_unsupported_rate () =
  (* Regression: synthetic completion claims (created by task_transition "done")
     must NOT be counted in total_completion_claims, otherwise they dilute the
     unsupported_completion_rate and mask genuine risk. *)
  with_room (fun config ->
      let created_at =
        iso_of_unix (Unix.gettimeofday () -. (25.0 *. 3600.0))
      in
      (* 1 real unsupported completion claim older than the expiry window *)
      append_accountability_event config.base_path ~created_at
        (`Assoc
           [
             ("event_type", `String "claim_created");
             ("claim_id", `String "acct-real-unsupported");
             ("agent_name", `String "keeper-test-agent");
             ("keeper_name", `String "keeper-test");
             ("kind", `String "completion_claim");
             ("subject", `String "Real claim");
             ("surface", `String "keeper_turn");
             ("created_at", `String created_at);
             ("evidence_refs", `List []);
             ("synthetic", `Bool false);
           ]);
      (* 10 synthetic Supported completion claims — these should be ignored *)
      for i = 1 to 10 do
        let cid = Printf.sprintf "acct-synthetic-%d" i in
        let created_at_s = iso_of_unix (Unix.gettimeofday () -. 1800.0) in
        append_accountability_event config.base_path
          ~created_at:created_at_s
          (`Assoc
             [
               ("event_type", `String "claim_created");
               ("claim_id", `String cid);
               ("agent_name", `String "keeper-test-agent");
               ("keeper_name", `String "keeper-test");
               ("kind", `String "completion_claim");
               ("subject", `String (Printf.sprintf "Synthetic %d" i));
               ("surface", `String "task_transition");
               ("created_at", `String created_at_s);
               ("evidence_refs", `List []);
               ("synthetic", `Bool true);
             ]);
        append_accountability_event config.base_path
          ~created_at:created_at_s
          (`Assoc
             [
               ("event_type", `String "claim_resolved");
               ("claim_id", `String cid);
               ("status", `String "supported");
               ("resolved_at", `String created_at_s);
               ("reason", `String "task_done");
               ("supporting_evidence_refs", `List []);
             ])
      done;
      let summary =
        Keeper_accountability.accountability_summary_json config
          ~keeper_name:"keeper-test" ~agent_name:"keeper-test-agent"
      in
      (* Without the fix: 0/11 = 0.0 unsupported rate. With fix: 1/1 = 1.0 *)
      check (float 0.0001) "unsupported rate should be 1.0 not diluted" 1.0
        (float_member "unsupported_completion_rate" summary);
      check string "risk band should be high" "high"
        (string_member "risk_band" summary))

let test_summary_lookup_reads_window_once_for_multiple_agents () =
  with_room (fun config ->
      let created_at =
        iso_of_unix (Unix.gettimeofday () -. (25.0 *. 3600.0))
      in
      List.iter
        (fun (claim_id, keeper_name, agent_name, subject) ->
          append_accountability_event config.base_path ~created_at
            (`Assoc
               [
                 ("event_type", `String "claim_created");
                 ("claim_id", `String claim_id);
                 ("agent_name", `String agent_name);
                 ("keeper_name", `String keeper_name);
                 ("kind", `String "completion_claim");
                 ("subject", `String subject);
                 ("surface", `String "keeper_turn");
                 ("created_at", `String created_at);
                 ("evidence_refs", `List []);
                 ("synthetic", `Bool false);
               ]))
        [
          ("acct-a", "keeper-a", "keeper-a-agent", "Ship A");
          ("acct-b", "keeper-b", "keeper-b-agent", "Ship B");
        ];
      Keeper_accountability.enable_window_read_count_for_testing ();
      let read_count =
        Fun.protect
          ~finally:Keeper_accountability.disable_window_read_count_for_testing
          (fun () ->
            let lookup =
              Keeper_accountability.accountability_summary_lookup config
            in
            let summary_a =
              lookup ~keeper_name:"keeper-a" ~agent_name:"keeper-a-agent"
            in
            let summary_b =
              lookup ~keeper_name:"keeper-b" ~agent_name:"keeper-b-agent"
            in
            check string "agent a risk" "high"
              (string_member "risk_band" summary_a);
            check string "agent b risk" "high"
              (string_member "risk_band" summary_b);
            Keeper_accountability.window_read_count_for_testing ())
      in
      check int "window read count" 1 read_count)

let test_summary_json_rereads_window_per_agent () =
  with_room (fun config ->
      let created_at =
        iso_of_unix (Unix.gettimeofday () -. (25.0 *. 3600.0))
      in
      List.iter
        (fun (claim_id, keeper_name, agent_name, subject) ->
          append_accountability_event config.base_path ~created_at
            (`Assoc
               [
                 ("event_type", `String "claim_created");
                 ("claim_id", `String claim_id);
                 ("agent_name", `String agent_name);
                 ("keeper_name", `String keeper_name);
                 ("kind", `String "completion_claim");
                 ("subject", `String subject);
                 ("surface", `String "keeper_turn");
                 ("created_at", `String created_at);
                 ("evidence_refs", `List []);
                 ("synthetic", `Bool false);
               ]))
        [
          ("acct-json-a", "keeper-json-a", "keeper-json-a-agent", "Ship A");
          ("acct-json-b", "keeper-json-b", "keeper-json-b-agent", "Ship B");
        ];
      Keeper_accountability.enable_window_read_count_for_testing ();
      let read_count =
        Fun.protect
          ~finally:Keeper_accountability.disable_window_read_count_for_testing
          (fun () ->
            ignore
              (Keeper_accountability.accountability_summary_json config
                 ~keeper_name:"keeper-json-a"
                 ~agent_name:"keeper-json-a-agent");
            ignore
              (Keeper_accountability.accountability_summary_json config
                 ~keeper_name:"keeper-json-b"
                 ~agent_name:"keeper-json-b-agent");
            Keeper_accountability.window_read_count_for_testing ())
      in
      check int "window read count" 2 read_count)

(* --- Attribution tests --- *)

module A = Masc_mcp.Attribution
module KA = Masc_mcp.Keeper_accountability

let outcome_kind = function
  | A.Passed -> "passed"
  | A.Policy_failed _ -> "policy_failed"
  | A.Transition_blocked _ -> "transition_blocked"
  | A.Partial_pass _ -> "partial_pass"

let sample_evidence : Yojson.Safe.t =
  `Assoc [ ("claim_id", `String "acct-test"); ("agent", `String "t-agent") ]

let test_attr_pending_none () =
  check bool "Pending yields None" true
    (KA.attribution_from_status KA.Pending ~evidence:sample_evidence () = None)

let test_attr_supported () =
  match
    KA.attribution_from_status KA.Supported ~evidence:sample_evidence ()
  with
  | Some attr ->
    check string "gate" "accountability" attr.gate;
    check string "outcome" "passed" (outcome_kind attr.outcome)
  | None -> Alcotest.fail "expected Some for Supported"

let test_attr_unsupported_with_reason () =
  match
    KA.attribution_from_status KA.Unsupported ~evidence:sample_evidence
      ~resolution_reason:"conflicting evidence" ()
  with
  | Some { outcome = A.Policy_failed { reason }; _ } ->
    check string "reason uses resolution_reason" "conflicting evidence" reason
  | _ -> Alcotest.fail "expected Policy_failed"

let test_attr_unsupported_default_reason () =
  match
    KA.attribution_from_status KA.Unsupported ~evidence:sample_evidence ()
  with
  | Some { outcome = A.Policy_failed { reason }; _ } ->
    check bool "default reason mentions evidence" true
      (Astring.String.is_infix ~affix:"evidence" reason)
  | _ -> Alcotest.fail "expected Policy_failed"

let test_attr_expired () =
  match
    KA.attribution_from_status KA.Expired ~evidence:sample_evidence ()
  with
  | Some { outcome = A.Policy_failed { reason }; _ } ->
    check bool "reason mentions expired" true
      (Astring.String.is_infix ~affix:"expired" reason)
  | _ -> Alcotest.fail "expected Policy_failed"

let test_attr_partial_score_clamped () =
  (* 0 evidence → 0.5; 10+ evidence → clamped to 1.0. *)
  let get_score refs_count =
    match
      KA.attribution_from_status KA.Partial ~evidence:sample_evidence
        ~evidence_refs_count:refs_count ()
    with
    | Some { outcome = A.Partial_pass { score; _ }; _ } -> score
    | _ -> Alcotest.fail "expected Partial_pass"
  in
  check (float 0.0001) "0 refs → 0.5 baseline" 0.5 (get_score 0);
  check (float 0.0001) "3 refs → 0.8" 0.8 (get_score 3);
  check (float 0.0001) "10 refs → clamped to 1.0" 1.0 (get_score 10);
  check (float 0.0001) "50 refs → still 1.0" 1.0 (get_score 50)

let test_attr_gate_invariants () =
  List.iter
    (fun status ->
      match KA.attribution_from_status status ~evidence:sample_evidence () with
      | Some attr ->
        check string "gate=accountability" "accountability" attr.gate;
        check bool "origin=Det" true (attr.origin = A.Det)
      | None -> () (* Pending is legit None *))
    [ KA.Pending; KA.Supported; KA.Unsupported; KA.Expired; KA.Partial ]

let () =
  let base_path = Masc_test_deps.find_project_root () in
  ignore (Result.get_ok (Keeper_exec_tools.init_policy_config ~base_path));
  Alcotest.run "Keeper_accountability"
    [
      ( "accountability",
        [
          test_case "same turn evidence marks claim supported" `Quick
            test_same_turn_evidence_marks_claim_supported;
          test_case "stale completion claim sets high risk" `Quick
            test_stale_completion_claim_sets_high_risk;
          test_case "agent reputation penalizes unsupported claims" `Quick
            test_agent_reputation_penalizes_unsupported_claims;
          test_case "generated alias inherits accountability penalty" `Quick
            test_generated_alias_inherits_accountability_penalty;
          test_case "generated alias inherits legacy keeper history" `Quick
            test_generated_alias_inherits_legacy_keeper_history;
          test_case "direct agent history exposes direct source" `Quick
            test_direct_agent_history_exposes_direct_source;
          test_case "task transition canonicalizes keeper name in history"
            `Quick test_task_transition_normalizes_keeper_name_in_history;
          test_case "task transition resolution rows include identity"
            `Quick test_task_transition_resolution_rows_include_identity;
          test_case "recent decision without claim exposes coverage gap"
            `Quick test_recent_decision_without_claim_exposes_coverage_gap;
          test_case "unmapped alias exposes no-history source" `Quick
            test_unmapped_alias_exposes_no_history_source;
          test_case "claim tool exposes routing warning for high risk keeper"
            `Quick test_claim_tool_exposes_routing_warning_for_high_risk_keeper;
          test_case "preflight exposes routing hint for high risk keeper"
            `Quick test_preflight_exposes_routing_hint_for_high_risk_keeper;
          test_case "synthetic claims do not dilute unsupported rate" `Quick
            test_synthetic_claims_do_not_dilute_unsupported_rate;
          test_case "summary lookup reads window once" `Quick
            test_summary_lookup_reads_window_once_for_multiple_agents;
          test_case "summary json rereads window per agent" `Quick
            test_summary_json_rereads_window_per_agent;
        ] );
      ( "attribution",
        [
          test_case "Pending → None" `Quick test_attr_pending_none;
          test_case "Supported → Passed" `Quick test_attr_supported;
          test_case "Unsupported → Policy_failed (resolution reason)"
            `Quick test_attr_unsupported_with_reason;
          test_case "Unsupported → Policy_failed (default reason)" `Quick
            test_attr_unsupported_default_reason;
          test_case "Expired → Policy_failed" `Quick test_attr_expired;
          test_case "Partial score clamped [0.5, 1.0]" `Quick
            test_attr_partial_score_clamped;
          test_case "gate=accountability origin=Det invariant" `Quick
            test_attr_gate_invariants;
        ] );
    ]

open Alcotest
open Masc_mcp

module Coord = Masc_mcp.Coord
module KT = Masc_mcp.Keeper_types

let counter = ref 0

let tmpdir prefix =
  incr counter;
  let dir =
    Filename.concat
      (Filename.get_temp_dir_name ())
      (Printf.sprintf "%s_%d_%d_%d"
         prefix (Unix.getpid ()) !counter
         (int_of_float (Unix.gettimeofday () *. 1000.0)))
  in
  Fs_compat.mkdir_p dir;
  dir

let with_store f =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let base_dir = tmpdir "keeper_feature_proof" in
  let config = Coord.default_config base_dir in
  ignore (Coord.init config ~agent_name:None);
  Keeper_tool_call_log.reset_for_testing ();
  Keeper_tool_call_log.init ~base_path:base_dir ();
  Fun.protect
    ~finally:(fun () ->
      Keeper_tool_call_log.reset_for_testing ();
      ignore (Sys.command (Printf.sprintf "rm -rf %s" (Filename.quote base_dir))))
    (fun () -> f config)

let make_meta ?(name = "alpha") () =
  match
    KT.meta_of_json
      (`Assoc
        [
          ("name", `String name);
          ("agent_name", `String (name ^ "-agent"));
          ("trace_id", `String ("trace-" ^ name));
          ("cascade_name", `String Keeper_config.default_cascade_name);
          ("last_model_used", `String "openai:gpt-5.4");
          ("sandbox_profile", `String "local");
          ("network_mode", `String "none");
          ("goal", `String "Prove keeper feature coverage");
          ("short_goal", `String "Exercise feature gates");
          ("mid_goal", `String "Keep autonomy observable");
          ("long_goal", `String "Reach product-grade safe autonomy");
        ])
  with
  | Ok meta -> meta
  | Error err -> fail ("meta_of_json failed: " ^ err)

let persist_keeper
      config
      ~name
      ~total_turns
      ~autonomous_action_count
      ~autonomous_tool_turn_count
      ~board_reactive_turn_count
      ~proactive_count_total
  =
  let base = make_meta ~name () in
  let now = Unix.gettimeofday () in
  let meta =
    {
      base with
      proactive = { enabled = true; idle_sec = 1; cooldown_sec = 1 };
      runtime =
        {
          base.runtime with
          usage =
            {
              base.runtime.usage with
              total_turns;
              last_turn_ts = now;
              last_model_used = "openai:gpt-5.4";
            };
          proactive_rt =
            {
              base.runtime.proactive_rt with
              count_total = proactive_count_total;
              last_ts = (if proactive_count_total > 0 then now else 0.0);
              last_outcome =
                (if proactive_count_total > 0
                 then KT.Proactive_tool_use
                 else KT.Proactive_never_started);
            };
          autonomous_action_count;
          autonomous_turn_count = autonomous_action_count;
          autonomous_tool_turn_count;
          board_reactive_turn_count;
        };
    }
  in
  match KT.write_meta ~force:true config meta with
  | Ok () -> meta
  | Error err -> fail ("write_meta failed: " ^ err)

let log_tool ?(success = true) tool_name =
  Keeper_tool_call_log.log_call
    ~keeper_name:"alpha"
    ~tool_name
    ~input:(`Assoc [])
    ~output_text:
      (if success then "ok" else {|{"ok":false,"error":"fixture_failure"}|})
    ~success
    ~duration_ms:1.0
    ()

let feature id json =
  Yojson.Safe.Util.(json |> member "features" |> to_list)
  |> List.find_opt (fun item ->
    Safe_ops.json_string_opt "id" item = Some id)
  |> Option.value
       ~default:
         (`Assoc [
           ("id", `String id);
           ("status", `String "missing");
         ])

let feature_status id json =
  feature id json
  |> Safe_ops.json_string_opt "status"
  |> Option.value ~default:"missing"

let test_json_reports_feature_gaps () =
  with_store @@ fun config ->
  ignore
    (persist_keeper config ~name:"alpha" ~total_turns:3
       ~autonomous_action_count:2 ~autonomous_tool_turn_count:2
       ~board_reactive_turn_count:1 ~proactive_count_total:1);
  ignore
    (persist_keeper config ~name:"beta" ~total_turns:2
       ~autonomous_action_count:1 ~autonomous_tool_turn_count:1
       ~board_reactive_turn_count:1 ~proactive_count_total:0);
  List.iter log_tool
    [
      "keeper_board_get";
      "keeper_board_list";
      "keeper_board_post";
      "keeper_board_comment";
      "keeper_board_vote";
      "masc_code_read";
    ];
  log_tool ~success:false "masc_worktree_create";
  let json =
    Dashboard_keeper_feature_proof.json
      ~config
      ~n:100
      ~success_threshold_pct:80.0
      ()
  in
  let summary = Yojson.Safe.Util.member "summary" json in
  check string "overall status has proof gaps" "fail"
    (Safe_ops.json_string ~default:"missing" "status" summary);
  check int "keeper_count" 2
    (Safe_ops.json_int ~default:0 "keeper_count" summary);
  check bool "gap_count is positive" true
    (Safe_ops.json_int ~default:0 "gap_count" summary > 0);
  check string "scheduled proactive gap is visible" "warn"
    (feature_status "scheduled_proactive_autonomy" json);
  check string "board tools are fully proved" "pass"
    (feature_status "board_tools" json);
  check string "coding tools are partial/weak proof" "warn"
    (feature_status "coding_tools" json)

let () =
  run "dashboard_keeper_feature_proof"
    [
      ( "dashboard_keeper_feature_proof",
        [
          test_case "json reports feature gaps" `Quick
            test_json_reports_feature_gaps;
        ] );
    ]

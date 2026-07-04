(** Tests for Agent_observation -> IDE Bridge adapter wiring. *)

open Alcotest

let with_temp_dir f =
  let dir = Filename.temp_file "agent_observation_bridge_test" "" in
  Sys.remove dir;
  Unix.mkdir dir 0o755;
  (try f dir with exn ->
     ignore (Sys.command (Printf.sprintf "rm -rf %s" dir));
     raise exn);
  ignore (Sys.command (Printf.sprintf "rm -rf %s" dir))
;;

let json_string key json =
  Yojson.Safe.Util.member key json |> Yojson.Safe.Util.to_string
;;

let json_int key json =
  Yojson.Safe.Util.member key json |> Yojson.Safe.Util.to_int
;;

let install_fresh_ide_sink () =
  Agent_observation.reset_for_testing ();
  Ide_bridge.install_agent_observation_sinks ()
;;

let test_tool_observation_reaches_ide_storage_and_cursor () =
  with_temp_dir (fun base_dir ->
    install_fresh_ide_sink ();
    Agent_observation.emit_tool_event
      { base_path = base_dir
      ; partition = Agent_observation.Legacy_default
      ; tool_name = "keeper_ide_annotate"
      ; keeper_id = "keeper-alpha"
      ; turn_id = "turn-9"
      ; outcome = "ok"
      ; typed_outcome = "progress"
      ; duration_ms = 12.0
      ; output_text = "annotated"
      ; input = `Assoc [ "file_path", `String "lib/test.ml"; "line_start", `Int 42 ]
      };
    (match Ide_bridge.list_events ~base_path:base_dir ~kind:Ide_bridge.Tool ~limit:1 () with
     | [ event ] ->
       check string "tool_name" "keeper_ide_annotate" (json_string "tool_name" event);
       check string "keeper_id" "keeper-alpha" (json_string "keeper_id" event)
     | _ -> fail "expected one tool event");
    match Ide_bridge.list_cursors ~base_path:base_dir () with
    | [ cursor ] ->
      check string "cursor file" "lib/test.ml" (json_string "file_path" cursor);
      check int "cursor line" 42 (json_int "line" cursor)
    | _ -> fail "expected one cursor")
;;

let test_turn_observation_reaches_ide_storage () =
  with_temp_dir (fun base_dir ->
    install_fresh_ide_sink ();
    Agent_observation.emit_turn_event
      { base_path = base_dir
      ; partition = Agent_observation.Legacy_default
      ; turn_id = "turn-10"
      ; keeper_id = "keeper-beta"
      ; phase = "completed"
      ; model_used = Some "test-model"
      ; tools_used = [ "execute" ]
      ; stop_reason = Some "end_turn"
      ; duration_ms = Some 123
      ; timestamp_ms = 1717400000000L
      };
    match Ide_bridge.list_events ~base_path:base_dir ~kind:Ide_bridge.Turn ~limit:1 () with
    | [ event ] ->
      check string "phase" "completed" (json_string "phase" event);
      check string "keeper_id" "keeper-beta" (json_string "keeper_id" event)
    | _ -> fail "expected one turn event")
;;

let test_pr_observation_reaches_ide_storage () =
  with_temp_dir (fun base_dir ->
    install_fresh_ide_sink ();
    Agent_observation.emit_pr_event
      { base_path = base_dir
      ; partition = Agent_observation.Legacy_default
      ; keeper_id = "keeper-gamma"
      ; turn_id = "turn-11"
      ; output_text =
          {|{"command_descriptor":{"kind":"gh_pr_create","title":"feat: test","base":"main","draft":true}}|}
      ; tool_name = "execute"
      ; success = true
      };
    match Ide_bridge.list_events ~base_path:base_dir ~kind:Ide_bridge.Pr ~limit:1 () with
    | [ event ] ->
      check int "pr_number fallback" 0 (json_int "pr_number" event);
      check string "title" "feat: test" (json_string "pr_title" event)
    | _ -> fail "expected one pr event")
;;

let test_write_region_observation_reaches_ide_storage () =
  with_temp_dir (fun base_dir ->
    install_fresh_ide_sink ();
    let partition = Agent_observation.By_url "github.com_owner_repo" in
    Agent_observation.emit_write_region_event
      { base_path = base_dir
      ; partition
      ; keeper_id = "keeper-delta"
      ; turn = 12
      ; tool_call_json =
          `Assoc
            [ "name", `String "write_file"
            ; ( "arguments"
              , `Assoc
                  [ "path", `String "lib/region.ml"
                  ; "content", `String "let a = 1\nlet b = 2\n"
                  ] )
            ]
      };
    match
      Ide_region_tracker.read_regions
        ~base_dir
        ~partition:(Ide_paths.By_url "github.com_owner_repo")
        ()
    with
    | [ region ] ->
      check string "region file" "lib/region.ml" region.file_path;
      check int "line start" 1 region.line_start;
      check int "line end" 2 region.line_end;
      check string "keeper id" "keeper-delta" region.keeper_id;
      (match region.source with
       | Ide_annotation_types.Tool_call { tool_name; turn } ->
         check string "tool name" "write_file" tool_name;
         check int "turn" 12 turn
       | Ide_annotation_types.Manual _ -> fail "expected tool-call region source")
    | _ -> fail "expected one region")
;;

let test_annotation_request_reaches_ide_storage () =
  with_temp_dir (fun base_dir ->
    install_fresh_ide_sink ();
    let result =
      Agent_observation.emit_annotation_request
        { base_path = base_dir
        ; partition = Agent_observation.Legacy_default
        ; keeper_id = "keeper-epsilon"
        ; file_path = "lib/annotated.ml"
        ; line_start = 7
        ; line_end = 9
        ; kind = Agent_observation.Decision
        ; content = "route through neutral observation bus"
        ; goal_id = Some "goal-17"
        ; task_id = None
        ; board_post_id = Some "post-3"
        ; comment_id = None
        ; pr_id = None
        ; git_ref = None
        ; log_id = None
        ; session_id = None
        ; operation_id = None
        ; worker_run_id = None
        }
    in
    match result with
    | Error msg -> failf "annotation request failed: %s" msg
    | Ok created ->
      check string "result file" "lib/annotated.ml" created.file_path;
      check int "result line start" 7 created.line_start;
      check int "result line end" 9 created.line_end;
      let filter : Ide_annotation_types.annotation_filter =
        { file_path = Some "lib/annotated.ml"
        ; keeper_id = Some "keeper-epsilon"
        ; goal_id = Some "goal-17"
        ; task_id = None
        }
      in
      (match Ide_annotations.list ~base_dir ~filter () with
       | [ annotation ] ->
         check string "id" created.id annotation.id;
         check string "content" "route through neutral observation bus" annotation.content;
         check (option string) "board post" (Some "post-3") annotation.board_post_id;
         (match annotation.kind with
          | Ide_annotation_types.Decision -> ()
          | _ -> fail "expected Decision annotation kind")
       | rows -> failf "expected one annotation, got %d" (List.length rows)))
;;

let () =
  run
    "agent_observation_bridge"
    [ ( "adapter"
      , [ test_case
            "tool observation reaches IDE storage and cursor"
            `Quick
            test_tool_observation_reaches_ide_storage_and_cursor
        ; test_case "turn observation reaches IDE storage" `Quick test_turn_observation_reaches_ide_storage
        ; test_case "pr observation reaches IDE storage" `Quick test_pr_observation_reaches_ide_storage
        ; test_case
            "write-region observation reaches IDE storage"
            `Quick
            test_write_region_observation_reaches_ide_storage
        ; test_case
            "annotation request reaches IDE storage"
            `Quick
            test_annotation_request_reaches_ide_storage
        ] )
    ]
;;

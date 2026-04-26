(** Coverage tests for Tool_agent — Agent management, fitness, and meta-cognition

    Tests dispatch routing, handler execution, helper functions for:
    masc_agents, masc_register_capabilities, masc_agent_update,
    masc_get_metrics, masc_agent_fitness, masc_collaboration_graph,
    masc_agent_card
*)
module Tool_args = Masc_mcp.Tool_args

module Meta_cognition = Masc_mcp.Meta_cognition
module Tool_agent = Masc_mcp.Tool_agent
module Coord = Masc_mcp.Coord

let test_counter = ref 0

let temp_dir () =
  incr test_counter;
  let dir = Filename.temp_file (Printf.sprintf "test_agent_%d_" !test_counter) "" in
  Unix.unlink dir;
  Unix.mkdir dir 0o755;
  dir
;;

let cleanup_dir dir =
  let rec rm path =
    if Sys.file_exists path
    then
      if Sys.is_directory path
      then (
        Array.iter (fun name -> rm (Filename.concat path name)) (Sys.readdir path);
        Unix.rmdir path)
      else Unix.unlink path
  in
  try rm dir with
  | _ -> ()
;;

let with_ctx f =
  Eio_main.run
  @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let base_dir = temp_dir () in
  let config = Coord.default_config base_dir in
  ignore (Coord.init config ~agent_name:(Some "test-agent"));
  let ctx : Tool_agent.context = { config; agent_name = "test-agent" } in
  Fun.protect ~finally:(fun () -> cleanup_dir base_dir) (fun () -> f ctx)
;;

let dispatch_exn ctx ~name ~args =
  match Tool_agent.dispatch ctx ~name ~args with
  | Some result -> result
  | None -> failwith ("dispatch returned None for " ^ name)
;;

let save_jsonl path entries =
  let body = entries |> List.map Yojson.Safe.to_string |> String.concat "\n" in
  Fs_compat.save_file path (if body = "" then "" else body ^ "\n")
;;

let post_json
      ~id
      ~author
      ?(title = "")
      ?(body = "")
      ?hearth
      ?thread_id
      ?(created_at = 1000.0)
      ()
  =
  let fields =
    [ "id", `String id
    ; "author", `String author
    ; "title", `String title
    ; "body", `String body
    ; "content", `String body
    ; "post_kind", `String "automation"
    ; "visibility", `String "internal"
    ; "created_at", `Float created_at
    ; "updated_at", `Float created_at
    ; "expires_at", `Float 0.0
    ; "votes_up", `Int 0
    ; "votes_down", `Int 0
    ; "reply_count", `Int 0
    ]
  in
  let fields =
    match hearth with
    | Some value -> ("hearth", `String value) :: fields
    | None -> fields
  in
  let fields =
    match thread_id with
    | Some value -> ("thread_id", `String value) :: fields
    | None -> fields
  in
  `Assoc fields
;;

let comment_json ~id ~post_id ~author ~content ?(created_at = 1000.0) () =
  `Assoc
    [ "id", `String id
    ; "post_id", `String post_id
    ; "author", `String author
    ; "content", `String content
    ; "created_at", `Float created_at
    ; "expires_at", `Float 0.0
    ; "votes_up", `Int 0
    ; "votes_down", `Int 0
    ]
;;

let json_list_ids key json =
  let open Yojson.Safe.Util in
  json
  |> member key
  |> to_list
  |> List.filter_map (fun item ->
    match item |> member "id" with
    | `String value -> Some value
    | _ -> None)
;;

let json_member_float key json =
  let open Yojson.Safe.Util in
  json |> member key |> to_float
;;

(* ============================================================
   Dispatch routing tests
   ============================================================ *)

let test_dispatch_unknown () =
  with_ctx (fun ctx ->
    let result = Tool_agent.dispatch ctx ~name:"unknown_tool" ~args:(`Assoc []) in
    Alcotest.(check bool) "unknown returns None" true (result = None))
;;

let test_dispatch_agents () =
  with_ctx (fun ctx ->
    let result = Tool_agent.dispatch ctx ~name:"masc_agents" ~args:(`Assoc []) in
    Alcotest.(check bool) "agents dispatches" true (result <> None))
;;

let test_dispatch_register_capabilities () =
  with_ctx (fun ctx ->
    let result =
      Tool_agent.dispatch ctx ~name:"masc_register_capabilities" ~args:(`Assoc [])
    in
    Alcotest.(check bool) "register_capabilities dispatches" true (result <> None))
;;

let test_dispatch_agent_update () =
  with_ctx (fun ctx ->
    let result = Tool_agent.dispatch ctx ~name:"masc_agent_update" ~args:(`Assoc []) in
    Alcotest.(check bool) "agent_update dispatches" true (result <> None))
;;

(* ============================================================
   Handler tests — masc_agents
   ============================================================ *)

let test_handle_agents () =
  with_ctx (fun ctx ->
    let ok, msg = Tool_agent.handle_agents ctx (`Assoc []) in
    Alcotest.(check bool) "agents succeeds" true ok;
    Alcotest.(check bool) "has response" true (String.length msg > 0))
;;

(* ============================================================
   Handler tests — register_capabilities
   ============================================================ *)

let test_register_capabilities () =
  with_ctx (fun ctx ->
    let args = `Assoc [ "capabilities", `List [ `String "test"; `String "code" ] ] in
    let ok, _msg = Tool_agent.handle_register_capabilities ctx args in
    Alcotest.(check bool) "registers capabilities" true ok)
;;

(* ============================================================
   Handler tests — agent_update
   ============================================================ *)

let test_agent_update_status () =
  with_ctx (fun ctx ->
    let args = `Assoc [ "status", `String "busy" ] in
    let _ok, msg = Tool_agent.handle_agent_update ctx args in
    Alcotest.(check bool) "has response" true (String.length msg > 0))
;;

let test_agent_update_capabilities () =
  with_ctx (fun ctx ->
    let args =
      `Assoc [ "capabilities", `List [ `String "review"; `String "refactor" ] ]
    in
    let _ok, msg = Tool_agent.handle_agent_update ctx args in
    Alcotest.(check bool) "has response" true (String.length msg > 0))
;;

(* ============================================================
   Handler tests — get_metrics
   ============================================================ *)

let test_get_metrics_no_data () =
  with_ctx (fun ctx ->
    let args = `Assoc [ "agent_name", `String "nonexistent"; "days", `Int 7 ] in
    let ok, msg = dispatch_exn ctx ~name:"masc_get_metrics" ~args in
    Alcotest.(check bool) "no data fails" false ok;
    let open Yojson.Safe.Util in
    let json = Yojson.Safe.from_string msg in
    Alcotest.(check string)
      "error_code"
      "not_found"
      (json |> member "error_code" |> to_string);
    Alcotest.(check string)
      "message"
      "no metrics found for agent: nonexistent"
      (json |> member "message" |> to_string))
;;

let test_get_metrics_missing_agent_name () =
  with_ctx (fun ctx ->
    let ok, msg = dispatch_exn ctx ~name:"masc_get_metrics" ~args:(`Assoc []) in
    Alcotest.(check bool) "missing agent_name fails" false ok;
    let open Yojson.Safe.Util in
    let json = Yojson.Safe.from_string msg in
    Alcotest.(check string) "status" "error" (json |> member "status" |> to_string);
    Alcotest.(check string)
      "message"
      "agent_name is required"
      (json |> member "message" |> to_string))
;;

(* ============================================================
   Handler tests — agent_fitness
   ============================================================ *)

let test_agent_fitness_no_agents () =
  with_ctx (fun ctx ->
    let ok, msg = Tool_agent.handle_agent_fitness ctx (`Assoc []) in
    Alcotest.(check bool) "fitness succeeds" true ok;
    Alcotest.(check bool) "has response" true (String.length msg > 0))
;;

let test_agent_fitness_specific () =
  with_ctx (fun ctx ->
    let args = `Assoc [ "agent_name", `String "test-agent"; "days", `Int 7 ] in
    let ok, msg = Tool_agent.handle_agent_fitness ctx args in
    Alcotest.(check bool) "fitness with agent" true ok;
    Alcotest.(check bool) "has response" true (String.length msg > 0))
;;

(* ============================================================
   Handler tests — collaboration_graph
   ============================================================ *)

let test_collaboration_graph_text () =
  with_ctx (fun ctx ->
    let args = `Assoc [ "format", `String "text" ] in
    let ok, msg = Tool_agent.handle_collaboration_graph ctx args in
    Alcotest.(check bool) "text format succeeds" true ok;
    Alcotest.(check bool) "has response" true (String.length msg > 0))
;;

let test_collaboration_graph_json () =
  with_ctx (fun ctx ->
    let args = `Assoc [ "format", `String "json" ] in
    let ok, msg = Tool_agent.handle_collaboration_graph ctx args in
    Alcotest.(check bool) "json format succeeds" true ok;
    Alcotest.(check bool) "returns JSON" true (String.contains msg '{'))
;;

(* ============================================================
   Handler tests — agent_card
   ============================================================ *)

let test_agent_card_get () =
  with_ctx (fun ctx ->
    let args = `Assoc [ "action", `String "get" ] in
    let ok, msg = Tool_agent.handle_agent_card ctx args in
    Alcotest.(check bool) "get succeeds" true ok;
    Alcotest.(check bool) "returns JSON" true (String.contains msg '{'))
;;

let test_agent_card_refresh () =
  with_ctx (fun ctx ->
    let args = `Assoc [ "action", `String "refresh" ] in
    let ok, msg = Tool_agent.handle_agent_card ctx args in
    Alcotest.(check bool) "refresh succeeds" true ok;
    Alcotest.(check bool) "has response" true (String.length msg > 0))
;;

(* ============================================================
   Handler tests — meta_cognition_snapshot
   ============================================================ *)

let test_meta_cognition_snapshot_detects_signals () =
  with_ctx (fun ctx ->
    ignore (Coord.join ctx.config ~agent_name:"peer" ~capabilities:[] ());
    ignore (Coord.join ctx.config ~agent_name:"observer" ~capabilities:[] ());
    let masc_dir = Coord.masc_dir ctx.config in
    save_jsonl
      (Filename.concat masc_dir "board_posts.jsonl")
      [ post_json
          ~id:"p-root"
          ~author:"admin-keeper"
          ~title:"RBAC blockage"
          ~body:
            "All masc_* tools tested return unregistered_masc_tool. Operator \
             intervention needed. keeper_* tools function normally."
          ~hearth:"ops"
          ~created_at:1000.0
          ()
      ; post_json
          ~id:"p-follow"
          ~author:"detail-demo"
          ~title:"Cross-check"
          ~body:
            "Confirmed same unregistered_masc_tool block. This is a policy restriction."
          ~hearth:"ops"
          ~thread_id:"p-root"
          ~created_at:1005.0
          ()
      ; post_json
          ~id:"p-idle"
          ~author:"detail-demo"
          ~title:"Idle status"
          ~body:
            "No active tasks. backlog empty. idle and available for new work. This could \
             be a good window to seed new tasks or run a synthetic multi-agent exercise."
          ~hearth:"ops"
          ~created_at:1010.0
          ()
      ];
    save_jsonl
      (Filename.concat masc_dir "board_comments.jsonl")
      [ comment_json
          ~id:"c-1"
          ~post_id:"p-root"
          ~author:"audit-keeper-decision"
          ~content:"Corroborated. This aligns with admin-keeper's finding."
          ~created_at:1006.0
          ()
      ];
    let ok, body =
      true, Yojson.Safe.to_string (Meta_cognition.snapshot_json ~limit:5 ctx.config)
    in
    Alcotest.(check bool) "snapshot succeeds" true ok;
    let json = Yojson.Safe.from_string body in
    let belief_ids = json_list_ids "beliefs" json in
    let tension_ids = json_list_ids "tensions" json in
    let desire_ids = json_list_ids "collective_desires" json in
    let open Yojson.Safe.Util in
    let edges = json |> member "social_edges" |> to_list in
    let has_corroborate_edge =
      List.exists
        (fun edge ->
           edge |> member "from_agent" |> to_string = "audit-keeper-decision"
           && edge |> member "to_agent" |> to_string = "admin-keeper"
           && edge |> member "edge_type" |> to_string = "corroborates")
        edges
    in
    Alcotest.(check bool)
      "tool blockage belief detected"
      true
      (List.mem "belief:masc_tools_blocked" belief_ids);
    Alcotest.(check bool)
      "idle backlog belief detected"
      true
      (List.mem "belief:idle_backlog_empty" belief_ids);
    Alcotest.(check bool)
      "tool blockage tension detected"
      true
      (List.mem "tension:masc_tool_blockage" tension_ids);
    Alcotest.(check bool)
      "task seeding desire detected"
      true
      (List.mem "desire:task_seeding" desire_ids);
    Alcotest.(check bool)
      "synthetic exercise desire detected"
      true
      (List.mem "desire:synthetic_exercise" desire_ids);
    Alcotest.(check bool) "social edge extracted" true has_corroborate_edge;
    Alcotest.(check bool)
      "stagnation score elevated"
      true
      (json_member_float "stagnation_score" json > 0.5))
;;

let test_meta_cognition_snapshot_marks_contested_belief () =
  with_ctx (fun ctx ->
    let masc_dir = Coord.masc_dir ctx.config in
    save_jsonl
      (Filename.concat masc_dir "board_posts.jsonl")
      [ post_json
          ~id:"p-root"
          ~author:"admin-keeper"
          ~title:"RBAC blockage"
          ~body:
            "All masc_* tools tested return unregistered_masc_tool. keeper_* tools \
             function normally."
          ~hearth:"ops"
          ~created_at:1000.0
          ()
      ];
    save_jsonl
      (Filename.concat masc_dir "board_comments.jsonl")
      [ comment_json
          ~id:"c-1"
          ~post_id:"p-root"
          ~author:"keeper-a"
          ~content:
            "This contradicts the uniform block hypothesis. Access may be per-agent."
          ~created_at:1010.0
          ()
      ];
    let ok, body =
      true, Yojson.Safe.to_string (Meta_cognition.snapshot_json ~limit:5 ctx.config)
    in
    Alcotest.(check bool) "snapshot succeeds" true ok;
    let json = Yojson.Safe.from_string body in
    let contested_ids = json_list_ids "contested_beliefs" json in
    Alcotest.(check bool)
      "contested belief captured"
      true
      (List.mem "belief:masc_tools_blocked" contested_ids))
;;

(* ============================================================
   Helper function tests
   ============================================================ *)

let test_get_string_present () =
  let args = `Assoc [ "key", `String "value" ] in
  Alcotest.(check string)
    "extracts string"
    "value"
    (Tool_args.get_string args "key" "default")
;;

let test_get_string_missing () =
  let args = `Assoc [] in
  Alcotest.(check string)
    "uses default"
    "default"
    (Tool_args.get_string args "key" "default")
;;

let test_get_string_opt_present () =
  let args = `Assoc [ "key", `String "value" ] in
  Alcotest.(check (option string))
    "extracts Some"
    (Some "value")
    (Tool_args.get_string_opt args "key")
;;

let test_get_string_opt_missing () =
  let args = `Assoc [] in
  Alcotest.(check (option string))
    "returns None"
    None
    (Tool_args.get_string_opt args "key")
;;

let test_get_int_present () =
  let args = `Assoc [ "key", `Int 42 ] in
  Alcotest.(check int) "extracts int" 42 (Tool_args.get_int args "key" 0)
;;

let test_get_int_missing () =
  let args = `Assoc [] in
  Alcotest.(check int) "uses default" 99 (Tool_args.get_int args "key" 99)
;;

let test_get_string_list_present () =
  let args = `Assoc [ "key", `List [ `String "a"; `String "b" ] ] in
  Alcotest.(check (list string))
    "extracts list"
    [ "a"; "b" ]
    (Tool_args.get_string_list args "key")
;;

let test_get_string_list_missing () =
  let args = `Assoc [] in
  Alcotest.(check (list string)) "empty list" [] (Tool_args.get_string_list args "key")
;;

(* ============================================================
   Test runner
   ============================================================ *)

let () =
  Alcotest.run
    "Tool_agent"
    [ ( "dispatch"
      , [ Alcotest.test_case "unknown returns None" `Quick test_dispatch_unknown
        ; Alcotest.test_case "agents dispatches" `Quick test_dispatch_agents
        ; Alcotest.test_case
            "register_capabilities dispatches"
            `Quick
            test_dispatch_register_capabilities
        ; Alcotest.test_case "agent_update dispatches" `Quick test_dispatch_agent_update
        ] )
    ; "agents", [ Alcotest.test_case "handle_agents" `Quick test_handle_agents ]
    ; ( "register_capabilities"
      , [ Alcotest.test_case "with capabilities" `Quick test_register_capabilities ] )
    ; ( "agent_update"
      , [ Alcotest.test_case "status update" `Quick test_agent_update_status
        ; Alcotest.test_case "capabilities update" `Quick test_agent_update_capabilities
        ] )
    ; ( "get_metrics"
      , [ Alcotest.test_case "no data" `Quick test_get_metrics_no_data
        ; Alcotest.test_case
            "missing agent_name"
            `Quick
            test_get_metrics_missing_agent_name
        ] )
    ; ( "agent_fitness"
      , [ Alcotest.test_case "no agents" `Quick test_agent_fitness_no_agents
        ; Alcotest.test_case "specific agent" `Quick test_agent_fitness_specific
        ] )
    ; ( "collaboration_graph"
      , [ Alcotest.test_case "text format" `Quick test_collaboration_graph_text
        ; Alcotest.test_case "json format" `Quick test_collaboration_graph_json
        ] )
    ; ( "agent_card"
      , [ Alcotest.test_case "get action" `Quick test_agent_card_get
        ; Alcotest.test_case "refresh action" `Quick test_agent_card_refresh
        ] )
    ; ( "meta_cognition_snapshot"
      , [ Alcotest.test_case
            "detects beliefs tensions desires and edges"
            `Quick
            test_meta_cognition_snapshot_detects_signals
        ; Alcotest.test_case
            "marks contested belief"
            `Quick
            test_meta_cognition_snapshot_marks_contested_belief
        ] )
    ; ( "helpers"
      , [ Alcotest.test_case "get_string present" `Quick test_get_string_present
        ; Alcotest.test_case "get_string missing" `Quick test_get_string_missing
        ; Alcotest.test_case "get_string_opt present" `Quick test_get_string_opt_present
        ; Alcotest.test_case "get_string_opt missing" `Quick test_get_string_opt_missing
        ; Alcotest.test_case "get_int present" `Quick test_get_int_present
        ; Alcotest.test_case "get_int missing" `Quick test_get_int_missing
        ; Alcotest.test_case "get_string_list present" `Quick test_get_string_list_present
        ; Alcotest.test_case "get_string_list missing" `Quick test_get_string_list_missing
        ] )
    ]
;;

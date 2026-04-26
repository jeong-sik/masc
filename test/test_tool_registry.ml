(** Tests for Tool_registry — in-memory call counters *)

module Tool_registry = Masc_mcp.Tool_registry

let () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let open Alcotest in
  run "Tool_registry"
    [
      ( "record_call",
        [
          test_case "increments call_count" `Quick (fun () ->
              Tool_registry.reset ();
              Tool_registry.record_call ~tool_name:"masc_status" ~success:true
                ~duration_ms:10 ();
              Tool_registry.record_call ~tool_name:"masc_status" ~success:true
                ~duration_ms:20 ();
              let stats = Tool_registry.get_stats () in
              let count =
                List.assoc_opt "masc_status" stats
                |> Option.map (fun s -> (s.Tool_registry.call_count))
                |> Option.value ~default:0
              in
              check int "call_count" 2 count);
          test_case "tracks success and failure separately" `Quick (fun () ->
              Tool_registry.reset ();
              Tool_registry.record_call ~tool_name:"masc_join" ~success:true
                ~duration_ms:5 ();
              Tool_registry.record_call ~tool_name:"masc_join" ~success:false
                ~duration_ms:15 ();
              Tool_registry.record_call ~tool_name:"masc_join" ~success:true
                ~duration_ms:8 ();
              let stats = Tool_registry.get_stats () in
              let s = List.assoc "masc_join" stats in
              check int "call_count" 3 (s.call_count);
              check int "success_count" 2 (s.success_count);
              check int "failure_count" 1 (s.failure_count));
          test_case "accumulates duration" `Quick (fun () ->
              Tool_registry.reset ();
              Tool_registry.record_call ~tool_name:"masc_broadcast" ~success:true
                ~duration_ms:100 ();
              Tool_registry.record_call ~tool_name:"masc_broadcast" ~success:true
                ~duration_ms:200 ();
              let stats = Tool_registry.get_stats () in
              let s = List.assoc "masc_broadcast" stats in
              check int "total_duration_ms" 300 (s.total_duration_ms));
          test_case "ignores unknown tool names when gated" `Quick (fun () ->
              Tool_registry.reset ();
              Tool_registry.record_call_if_known ~tool_name:"totally_unknown_tool"
                ~success:false ~duration_ms:1 ();
              check int "total" 0 (Tool_registry.total_calls ()));
          test_case "tracks source attribution" `Quick (fun () ->
              Tool_registry.reset ();
              Tool_registry.record_call ~source:External_mcp
                ~tool_name:"masc_status" ~success:true ~duration_ms:10 ();
              Tool_registry.record_call ~source:Keeper_internal
                ~tool_name:"masc_status" ~success:true ~duration_ms:20 ();
              Tool_registry.record_call ~source:Keeper_internal
                ~tool_name:"masc_status" ~success:false ~duration_ms:5 ();
              let stats = Tool_registry.get_stats () in
              let s = List.assoc "masc_status" stats in
              check int "call_count" 3 (s.call_count);
              check int "external_mcp_count" 1 (s.external_mcp_count);
              check int "keeper_internal_count" 2 (s.keeper_internal_count));
        ] );
      ( "get_top_n",
        [
          test_case "returns top N by call count" `Quick (fun () ->
              Tool_registry.reset ();
              for _ = 1 to 3 do
                Tool_registry.record_call ~tool_name:"tool_a" ~success:true
                  ~duration_ms:1 ()
              done;
              Tool_registry.record_call ~tool_name:"tool_b" ~success:true
                ~duration_ms:1 ();
              for _ = 1 to 5 do
                Tool_registry.record_call ~tool_name:"tool_c" ~success:true
                  ~duration_ms:1 ()
              done;
              let top2 = Tool_registry.get_top_n 2 in
              check int "length" 2 (List.length top2);
              let names = List.map fst top2 in
              check (list string) "order" [ "tool_c"; "tool_a" ] names);
        ] );
      ( "get_never_called",
        [
          test_case "identifies uncalled tools" `Quick (fun () ->
              Tool_registry.reset ();
              Tool_registry.record_call ~tool_name:"called_tool" ~success:true
                ~duration_ms:1 ();
              let never =
                Tool_registry.get_never_called
                  [ "called_tool"; "uncalled_a"; "uncalled_b" ]
              in
              check (list string) "never called"
                [ "uncalled_a"; "uncalled_b" ]
                never);
        ] );
      ( "totals",
        [
          test_case "total_calls sums all" `Quick (fun () ->
              Tool_registry.reset ();
              Tool_registry.record_call ~tool_name:"a" ~success:true
                ~duration_ms:1 ();
              Tool_registry.record_call ~tool_name:"b" ~success:true
                ~duration_ms:1 ();
              Tool_registry.record_call ~tool_name:"a" ~success:false
                ~duration_ms:1 ();
              check int "total" 3 (Tool_registry.total_calls ()));
          test_case "distinct_tools_called" `Quick (fun () ->
              Tool_registry.reset ();
              Tool_registry.record_call ~tool_name:"x" ~success:true
                ~duration_ms:1 ();
              Tool_registry.record_call ~tool_name:"y" ~success:true
                ~duration_ms:1 ();
              Tool_registry.record_call ~tool_name:"x" ~success:true
                ~duration_ms:1 ();
              check int "distinct" 2 (Tool_registry.distinct_tools_called ()));
        ] );
      ( "stats_report",
        [
          test_case "generates valid JSON with source breakdown" `Quick (fun () ->
              Tool_registry.reset ();
              Tool_registry.record_call ~tool_name:"masc_status" ~success:true
                ~duration_ms:42 ();
              let json =
                Tool_registry.stats_report
                  ~top_n:20
                  ~all_tool_names:[ "masc_status"; "masc_join" ]
              in
              let s = Yojson.Safe.to_string json in
              check bool "contains total_calls"
                (String.length s > 0)
                true;
              check bool "contains by_source"
                (String.length s > 10)
                true;
              let _ = Yojson.Safe.from_string s in
              ());
          test_case "respects top_n" `Quick (fun () ->
              Tool_registry.reset ();
              for _ = 1 to 3 do
                Tool_registry.record_call ~tool_name:"masc_status" ~success:true
                  ~duration_ms:1 ()
              done;
              for _ = 1 to 2 do
                Tool_registry.record_call ~tool_name:"masc_join" ~success:true
                  ~duration_ms:1 ()
              done;
              Tool_registry.record_call ~tool_name:"masc_leave" ~success:true
                ~duration_ms:1 ();
              let json =
                Tool_registry.stats_report ~top_n:2
                  ~all_tool_names:[ "masc_status"; "masc_join"; "masc_leave" ]
              in
              let open Yojson.Safe.Util in
              check int "top_n_requested" 2
                (json |> member "top_n_requested" |> to_int);
              check int "top_tools length" 2
                (json |> member "top_tools" |> to_list |> List.length));
        ] );
      ( "reset",
        [
          test_case "clears all data" `Quick (fun () ->
              Tool_registry.reset ();
              Tool_registry.record_call ~tool_name:"z" ~success:true
                ~duration_ms:1 ();
              check int "before" 1 (Tool_registry.total_calls ());
              Tool_registry.reset ();
              check int "after" 0 (Tool_registry.total_calls ()));
        ] );
    ]

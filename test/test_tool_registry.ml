(** Tests for Tool_registry — in-memory call counters *)

module Tool_registry = Masc_mcp.Tool_registry

let () =
  let open Alcotest in
  run "Tool_registry"
    [
      ( "record_call",
        [
          test_case "increments call_count" `Quick (fun () ->
              Tool_registry.reset ();
              Tool_registry.record_call ~tool_name:"masc_status" ~success:true
                ~duration_ms:10;
              Tool_registry.record_call ~tool_name:"masc_status" ~success:true
                ~duration_ms:20;
              let stats = Tool_registry.get_stats () in
              let count =
                List.assoc_opt "masc_status" stats
                |> Option.map (fun s -> s.Tool_registry.call_count)
                |> Option.value ~default:0
              in
              check int "call_count" 2 count);
          test_case "tracks success and failure separately" `Quick (fun () ->
              Tool_registry.reset ();
              Tool_registry.record_call ~tool_name:"masc_join" ~success:true
                ~duration_ms:5;
              Tool_registry.record_call ~tool_name:"masc_join" ~success:false
                ~duration_ms:15;
              Tool_registry.record_call ~tool_name:"masc_join" ~success:true
                ~duration_ms:8;
              let stats = Tool_registry.get_stats () in
              let s = List.assoc "masc_join" stats in
              check int "call_count" 3 s.call_count;
              check int "success_count" 2 s.success_count;
              check int "failure_count" 1 s.failure_count);
          test_case "accumulates duration" `Quick (fun () ->
              Tool_registry.reset ();
              Tool_registry.record_call ~tool_name:"masc_broadcast" ~success:true
                ~duration_ms:100;
              Tool_registry.record_call ~tool_name:"masc_broadcast" ~success:true
                ~duration_ms:200;
              let stats = Tool_registry.get_stats () in
              let s = List.assoc "masc_broadcast" stats in
              check int "total_duration_ms" 300 s.total_duration_ms);
        ] );
      ( "get_top_n",
        [
          test_case "returns top N by call count" `Quick (fun () ->
              Tool_registry.reset ();
              (* tool_a: 3 calls, tool_b: 1 call, tool_c: 5 calls *)
              for _ = 1 to 3 do
                Tool_registry.record_call ~tool_name:"tool_a" ~success:true
                  ~duration_ms:1
              done;
              Tool_registry.record_call ~tool_name:"tool_b" ~success:true
                ~duration_ms:1;
              for _ = 1 to 5 do
                Tool_registry.record_call ~tool_name:"tool_c" ~success:true
                  ~duration_ms:1
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
                ~duration_ms:1;
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
                ~duration_ms:1;
              Tool_registry.record_call ~tool_name:"b" ~success:true
                ~duration_ms:1;
              Tool_registry.record_call ~tool_name:"a" ~success:false
                ~duration_ms:1;
              check int "total" 3 (Tool_registry.total_calls ()));
          test_case "distinct_tools_called" `Quick (fun () ->
              Tool_registry.reset ();
              Tool_registry.record_call ~tool_name:"x" ~success:true
                ~duration_ms:1;
              Tool_registry.record_call ~tool_name:"y" ~success:true
                ~duration_ms:1;
              Tool_registry.record_call ~tool_name:"x" ~success:true
                ~duration_ms:1;
              check int "distinct" 2 (Tool_registry.distinct_tools_called ()));
        ] );
      ( "stats_report",
        [
          test_case "generates valid JSON" `Quick (fun () ->
              Tool_registry.reset ();
              Tool_registry.record_call ~tool_name:"masc_status" ~success:true
                ~duration_ms:42;
              let json =
                Tool_registry.stats_report
                  ~all_tool_names:[ "masc_status"; "masc_join" ]
              in
              let s = Yojson.Safe.to_string json in
              check bool "contains total_calls"
                (String.length s > 0)
                true;
              (* Verify it parses back *)
              let _ = Yojson.Safe.from_string s in
              ());
        ] );
      ( "reset",
        [
          test_case "clears all data" `Quick (fun () ->
              Tool_registry.reset ();
              Tool_registry.record_call ~tool_name:"z" ~success:true
                ~duration_ms:1;
              check int "before" 1 (Tool_registry.total_calls ());
              Tool_registry.reset ();
              check int "after" 0 (Tool_registry.total_calls ()));
        ] );
    ]

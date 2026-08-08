(** Tests for Tool_registry — in-memory call counters *)

module Tool_registry = Tool_registry

let () =
  Eio_main.run
  @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let open Alcotest in
  run
    "Tool_registry"
    [ ( "record_call"
      , [ test_case "increments call_count" `Quick (fun () ->
            Tool_registry.reset ();
            Tool_registry.record_call
              ~tool_name:"masc_status"
              ~disposition:(Tool_result.Completed ())
              ~duration_ms:10
              ();
            Tool_registry.record_call
              ~tool_name:"masc_status"
              ~disposition:(Tool_result.Completed ())
              ~duration_ms:20
              ();
            let stats = Tool_registry.get_stats () in
            let count =
              List.assoc_opt "masc_status" stats
              |> Option.map (fun s -> Atomic.get s.Tool_registry.call_count)
              |> Option.value ~default:0
            in
            check int "call_count" 2 count)
        ; test_case "tracks all dispositions separately" `Quick (fun () ->
            Tool_registry.reset ();
            Tool_registry.record_call
              ~tool_name:"masc_bind"
              ~disposition:(Tool_result.Completed ())
              ~duration_ms:5
              ();
            Tool_registry.record_call
              ~tool_name:"masc_bind"
              ~disposition:(Tool_result.Failed ())
              ~duration_ms:15
              ();
            Tool_registry.record_call
              ~tool_name:"masc_bind"
              ~disposition:(Tool_result.Completed ())
              ~duration_ms:8
              ();
            Tool_registry.record_call
              ~tool_name:"masc_bind"
              ~disposition:(Tool_result.Deferred ())
              ~duration_ms:3
              ();
            let stats = Tool_registry.get_stats () in
            let s = List.assoc "masc_bind" stats in
            check int "call_count" 4 (Atomic.get s.call_count);
            check int "success_count" 2 (Atomic.get s.success_count);
            check int "deferred_count" 1 (Atomic.get s.deferred_count);
            check int "failure_count" 1 (Atomic.get s.failure_count))
        ; test_case "accumulates duration" `Quick (fun () ->
            Tool_registry.reset ();
            Tool_registry.record_call
              ~tool_name:"masc_broadcast"
              ~disposition:(Tool_result.Completed ())
              ~duration_ms:100
              ();
            Tool_registry.record_call
              ~tool_name:"masc_broadcast"
              ~disposition:(Tool_result.Completed ())
              ~duration_ms:200
              ();
            let stats = Tool_registry.get_stats () in
            let s = List.assoc "masc_broadcast" stats in
            check int "total_duration_ms" 300 (Atomic.get s.total_duration_ms))
        ; test_case "ignores unknown tool names when gated" `Quick (fun () ->
            Tool_registry.reset ();
            Tool_registry.record_call_if_known
              ~tool_name:"totally_unknown_tool"
              ~disposition:(Tool_result.Failed ())
              ~duration_ms:1
              ();
            check int "total" 0 (Tool_registry.total_calls ()))
        ; test_case "keeper prefix does not invent tool identity" `Quick (fun () ->
            Tool_registry.reset ();
            Tool_registry.record_call_if_known
              ~tool_name:"keeper_totally_unknown"
              ~disposition:(Tool_result.Failed ())
              ~duration_ms:1
              ();
            check int "total" 0 (Tool_registry.total_calls ()))
        ; test_case "gated recording includes keeper-internal tools" `Quick (fun () ->
            Tool_registry.reset ();
            Tool_registry.record_call_if_known
              ~source:Agent_internal
              ~tool_name:"keeper_time_now"
              ~disposition:(Tool_result.Completed ())
              ~duration_ms:1
              ();
            let stats = Tool_registry.get_stats () in
            let s = List.assoc "keeper_time_now" stats in
            check int "call_count" 1 (Atomic.get s.call_count);
            check int "agent_internal_count" 1 (Atomic.get s.agent_internal_count))
        ; test_case "tracks source attribution" `Quick (fun () ->
            Tool_registry.reset ();
            Tool_registry.record_call
              ~source:External_mcp
              ~tool_name:"masc_status"
              ~disposition:(Tool_result.Completed ())
              ~duration_ms:10
              ();
            Tool_registry.record_call
              ~source:Agent_internal
              ~tool_name:"masc_status"
              ~disposition:(Tool_result.Completed ())
              ~duration_ms:20
              ();
            Tool_registry.record_call
              ~source:Agent_internal
              ~tool_name:"masc_status"
              ~disposition:(Tool_result.Failed ())
              ~duration_ms:5
              ();
            let stats = Tool_registry.get_stats () in
            let s = List.assoc "masc_status" stats in
            check int "call_count" 3 (Atomic.get s.call_count);
            check int "external_mcp_count" 1 (Atomic.get s.external_mcp_count);
            check int "agent_internal_count" 2 (Atomic.get s.agent_internal_count))
        ] )
    ; ( "get_top_n"
      , [ test_case "returns top N by call count" `Quick (fun () ->
            Tool_registry.reset ();
            for _ = 1 to 3 do
              Tool_registry.record_call
                ~tool_name:"tool_a"
                ~disposition:(Tool_result.Completed ())
                ~duration_ms:1
                ()
            done;
            Tool_registry.record_call ~tool_name:"tool_b" ~disposition:(Tool_result.Completed ()) ~duration_ms:1 ();
            for _ = 1 to 5 do
              Tool_registry.record_call
                ~tool_name:"tool_c"
                ~disposition:(Tool_result.Completed ())
                ~duration_ms:1
                ()
            done;
            let top2 = Tool_registry.get_top_n 2 in
            check int "length" 2 (List.length top2);
            let names = List.map fst top2 in
            check (list string) "order" [ "tool_c"; "tool_a" ] names)
        ] )
    ; ( "get_never_called"
      , [ test_case "identifies uncalled tools" `Quick (fun () ->
            Tool_registry.reset ();
            Tool_registry.record_call
              ~tool_name:"called_tool"
              ~disposition:(Tool_result.Completed ())
              ~duration_ms:1
              ();
            let never =
              Tool_registry.get_never_called [ "called_tool"; "uncalled_a"; "uncalled_b" ]
            in
            check (list string) "never called" [ "uncalled_a"; "uncalled_b" ] never)
        ] )
    ; ( "totals"
      , [ test_case "total_calls sums all" `Quick (fun () ->
            Tool_registry.reset ();
            Tool_registry.record_call ~tool_name:"a" ~disposition:(Tool_result.Completed ()) ~duration_ms:1 ();
            Tool_registry.record_call ~tool_name:"b" ~disposition:(Tool_result.Completed ()) ~duration_ms:1 ();
            Tool_registry.record_call ~tool_name:"a" ~disposition:(Tool_result.Failed ()) ~duration_ms:1 ();
            check int "total" 3 (Tool_registry.total_calls ()))
        ; test_case "distinct_tools_called" `Quick (fun () ->
            Tool_registry.reset ();
            Tool_registry.record_call ~tool_name:"x" ~disposition:(Tool_result.Completed ()) ~duration_ms:1 ();
            Tool_registry.record_call ~tool_name:"y" ~disposition:(Tool_result.Completed ()) ~duration_ms:1 ();
            Tool_registry.record_call ~tool_name:"x" ~disposition:(Tool_result.Completed ()) ~duration_ms:1 ();
            check int "distinct" 2 (Tool_registry.distinct_tools_called ()))
        ] )
    ; ( "reset"
      , [ test_case "clears all data" `Quick (fun () ->
            Tool_registry.reset ();
            Tool_registry.record_call ~tool_name:"z" ~disposition:(Tool_result.Completed ()) ~duration_ms:1 ();
            check int "before" 1 (Tool_registry.total_calls ());
            Tool_registry.reset ();
            check int "after" 0 (Tool_registry.total_calls ()))
        ] )
    ]
;;

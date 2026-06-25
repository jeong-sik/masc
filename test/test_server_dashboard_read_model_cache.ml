open Alcotest

let dummy_json label = `Assoc [ ("label", `String label) ]

let cache_tests =
  [ ( "put then get returns entry",
      `Quick,
      fun () ->
        let cache = Server_dashboard_read_model_cache.create () in
        let key = Server_dashboard_read_model_cache.Runtime_probe { force = false } in
        let entry =
          { Server_dashboard_read_model_cache.generated_at = Time_compat.now ()
          ; json = dummy_json "probe"
          ; source = `On_demand
          }
        in
        Server_dashboard_read_model_cache.put cache key entry;
        match Server_dashboard_read_model_cache.get cache key with
        | Some got -> check bool "same json" true (got.json = entry.json)
        | None -> fail "expected cache hit" )
  ; ( "get_fresh returns entry within TTL",
      `Quick,
      fun () ->
        let cache = Server_dashboard_read_model_cache.create () in
        let key = Server_dashboard_read_model_cache.Execution
                    { actor = None; fixture = None; full = false; force = false }
        in
        let entry =
          { Server_dashboard_read_model_cache.generated_at = Time_compat.now ()
          ; json = dummy_json "execution"
          ; source = `Proactive
          }
        in
        Server_dashboard_read_model_cache.put cache key entry;
        match Server_dashboard_read_model_cache.get_fresh cache key ~ttl_s:60.0 with
        | Some got -> check bool "same json" true (got.json = entry.json)
        | None -> fail "expected fresh hit" )
  ; ( "get_fresh misses after TTL",
      `Quick,
      fun () ->
        let cache = Server_dashboard_read_model_cache.create () in
        let key = Server_dashboard_read_model_cache.Runtime_trace
                    { keeper_name = "qa-king"
                    ; trace_id = None
                    ; turn_id = None
                    ; limit = 200
                    }
        in
        let entry =
          { Server_dashboard_read_model_cache.generated_at = Time_compat.now () -. 61.0
          ; json = dummy_json "trace"
          ; source = `On_demand
          }
        in
        Server_dashboard_read_model_cache.put cache key entry;
        match Server_dashboard_read_model_cache.get_fresh cache key ~ttl_s:60.0 with
        | Some _ -> fail "expected stale miss"
        | None -> () )
  ; ( "get_or_compute caches compute result",
      `Quick,
      fun () ->
        let cache = Server_dashboard_read_model_cache.create () in
        let key = Server_dashboard_read_model_cache.Fleet_composite in
        let calls = ref 0 in
        let compute () =
          incr calls;
          dummy_json "fleet"
        in
        let json1 = Server_dashboard_read_model_cache.get_or_compute cache key ~ttl_s:60.0 ~compute in
        let json2 = Server_dashboard_read_model_cache.get_or_compute cache key ~ttl_s:60.0 ~compute in
        check bool "same result" true (json1 = json2);
        check int "compute called once" 1 !calls )
  ; ( "invalidate_by_keeper removes keeper-specific entries",
      `Quick,
      fun () ->
        let cache = Server_dashboard_read_model_cache.create () in
        let keeper = "qa-king" in
        let other = "other-king" in
        let trace_key k =
          Server_dashboard_read_model_cache.Runtime_trace
            { keeper_name = k; trace_id = None; turn_id = None; limit = 200 }
        in
        let composite_key k =
          Server_dashboard_read_model_cache.Keeper_composite { keeper_name = k }
        in
        let now = Time_compat.now () in
        Server_dashboard_read_model_cache.put cache (trace_key keeper)
          { generated_at = now; json = dummy_json "trace-qa"; source = `On_demand };
        Server_dashboard_read_model_cache.put cache (trace_key other)
          { generated_at = now; json = dummy_json "trace-other"; source = `On_demand };
        Server_dashboard_read_model_cache.put cache (composite_key keeper)
          { generated_at = now; json = dummy_json "composite-qa"; source = `On_demand };
        Server_dashboard_read_model_cache.invalidate_by_keeper cache keeper;
        check bool "qa trace removed"
          true
          (Option.is_none (Server_dashboard_read_model_cache.get cache (trace_key keeper)));
        check bool "other trace kept"
          false
          (Option.is_none (Server_dashboard_read_model_cache.get cache (trace_key other)));
        check bool "qa composite removed"
          true
          (Option.is_none (Server_dashboard_read_model_cache.get cache (composite_key keeper))) )
  ; ( "clear removes all entries",
      `Quick,
      fun () ->
        let cache = Server_dashboard_read_model_cache.create () in
        let key = Server_dashboard_read_model_cache.Runtime_probe { force = false } in
        Server_dashboard_read_model_cache.put cache key
          { generated_at = Time_compat.now (); json = dummy_json "x"; source = `On_demand };
        Server_dashboard_read_model_cache.clear cache;
        check bool "empty after clear"
          true
          (Option.is_none (Server_dashboard_read_model_cache.get cache key)) )
  ]
;;

let () = run "Dashboard read-model cache" [ ("cache", cache_tests) ]

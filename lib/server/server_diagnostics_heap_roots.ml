let report_json () =
  Log.Server.warn
    "heap-roots walk requested: Obj.reachable_words holds this domain's runtime lock \
     for the whole walk and every other domain waits at its next stop-the-world";
  (* NDT-OK: wall time only measures how long the walk took. *)
  let now = Unix.gettimeofday in
  let started = now () in
  let readings = Heap_roots.measure ~now () in
  let walk_ms = (now () -. started) *. 1000.0 in
  `Assoc
    [ "walk_ms", `Float walk_ms
    ; "gc", Server_routes_http_runtime_health_helpers.quick_gc_json ()
    ; "roots", `List (List.map Heap_roots.reading_to_yojson readings)
    ]
;;

let report_json () =
  Log.Server.warn
    "heap-roots walk requested: Obj.reachable_words holds this domain's runtime lock \
     for the whole walk, every other domain waits at its next stop-the-world, and the \
     runtime keeps an out-of-heap position table of tens of bytes per visited block \
     until the walk ends";
  (* NDT-OK: wall time only measures how long each walk took. *)
  let readings = Heap_roots.measure ~now:Unix.gettimeofday () in
  `Assoc
    [ "walk_ms", `Float (Heap_roots.total_walk_ms readings)
    ; "gc", Server_routes_http_runtime_health_helpers.quick_gc_json ()
    ; "roots", `List (List.map Heap_roots.reading_to_yojson readings)
    ]
;;

(** GET /api/v1/diagnostics/heap-roots — walk every {!Heap_roots} root and
    report the reachable size of each next to the [Gc.quick_stat] counters.

    Operator-only ([CanAdmin]). The walk holds this domain's runtime lock and
    stalls every other domain at its next stop-the-world for as long as it
    runs; a two-gigabyte live heap takes seconds. Call it to answer "what is
    holding the heap", not on a schedule. *)

val report_json : unit -> Yojson.Safe.t
(** Logs a warning naming the cost, walks the roots, and returns
    [{ walk_ms; gc; roots }] where [roots] is the registration-ordered list
    of {!Heap_roots.reading_to_yojson} objects. *)

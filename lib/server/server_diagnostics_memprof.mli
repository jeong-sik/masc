(** GET /api/v1/diagnostics/memprof — the {!Alloc_profile} tables: which call
    sites allocated, promoted, and still hold sampled blocks since the
    process started sampling.

    Operator-only ([CanAdmin]). Reading the tables takes the profile's mutex
    for a snapshot of the site table; it does not walk the heap and does not
    stall other domains. *)

val report_json : unit -> Yojson.Safe.t

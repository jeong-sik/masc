(** GET /api/v1/diagnostics/memprof — the {!Alloc_profile} tables: which call
    sites allocated, promoted, and still hold sampled blocks since the
    process started sampling, and which of them allocated on the main domain
    ([starting_domain_allocated]).

    Operator-only ([CanAdmin]). Reading the tables takes the profile's mutex
    for a snapshot of the site table; it does not walk the heap and does not
    stall other domains. *)

val report_json : unit -> Yojson.Safe.t

type request_error = Invalid_query | Instance_changed | Profile_changed | Unknown_site
val error_json : request_error -> Yojson.Safe.t
val error_status : request_error -> [ `Bad_request | `Conflict | `Not_found ]

val counters_json :
  query:(string * string list) list -> (Yojson.Safe.t, request_error) result
(** Every registered site's raw counters, without stack strings or ranking.
    Optional [runtime_instance_id], [epoch] and [sampling_rate] query fields
    must occur together exactly once, and guard a second observation. Workspace
    query preconditions are handled by the enclosing token-auth read wrapper. *)

val stacks_json :
  query:(string * string list) list -> (Yojson.Safe.t, request_error) result
(** The same identity fields are required. Repeated [id] query fields select
    the stacks to return; duplicates are collapsed. No full-stack default. *)

val counters_path : string
val stacks_path : string
val register_counter_routes : Http_server_eio.Router.t -> Http_server_eio.Router.t
(** Register uncached, token-bound CanAdmin GETs. The same wrapper as the
    existing diagnostic preserves read quota and workspace preconditions.
    Neither endpoint starts/stops sampling or modifies durable workspace state. *)

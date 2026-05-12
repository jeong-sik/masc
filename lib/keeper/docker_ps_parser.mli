(** RFC-0070 Phase 3b-iv.2.5 — pure parser for [docker ps --format '\{\{json .\}\}'] output.

    Extracted from {!Docker_client_real} so the parser surface can be
    exercised directly by hermetic unit tests with synthetic JSON
    fixtures (no docker daemon dependency). Phase 3b-iv.2.4 (#14871)
    left these helpers [private] in [docker_client_real.ml]; this PR
    promotes them to a typed boundary so each silent-drop path
    (empty / Yojson.Json_error / schema-mismatch / unknown State) is
    individually testable.

    {!Docker_client_real.ps_query} now delegates to {!parse_output};
    no other production caller is intended.

    Reference: docs/rfc/RFC-0070-keeper-sandbox-pure-edge-separation.md §3.3 *)

(** [parse_labels s] decodes docker's comma-joined label string
    [["k1=v1,k2=v2"]] into an association list.

    - Empty input → [[]].
    - Tokens without ['='] → dropped (no [Some (k, "")] permissive
      default; the absence of a key/value separator is parser-defined
      noise, not a typed value).
    - Order-preserving: the result mirrors docker's emission order.
      Canonical re-ordering (e.g. sort by key) is the caller's
      responsibility — {!Docker_response.equal_ps_record} treats
      label order as significant. *)
val parse_labels : string -> (string * string) list

(** [parse_line line] decodes one JSON-formatted [docker ps] line
    into a {!Docker_response.ps_record}.

    Returns [None] when *any* of the four enumerated failure paths
    fires:
    + [line] is empty (after [String.trim])
    + [line] is not valid JSON (Yojson raises [Json_error])
    + [line] is valid JSON but does not satisfy the required schema
      (missing [ID] / [Names] / [State] / [Labels])
    + [line] is schema-valid but carries an unknown [State] token
      (one that {!Docker_response.parse_state} rejects)

    All four are *deliberate silent drops* — RFC §3.3 documented
    trade-off. They are *enumerated*, not a catch-all [_ -> None]:
    every code path is reachable and individually exercisable by
    {!test_docker_ps_parser}.

    The [Names] string is wrapped via
    {!Keeper_container_name.of_external_string} — *unsafe*. docker
    may emit container names that did not originate from
    {!Keeper_container_name.derive}, and the parser does not enforce
    the [masc-keeper-] prefix invariant. The result is opaque to the
    parser; downstream consumers that need the prefix invariant must
    re-validate. *)
val parse_line : string -> Docker_response.ps_record option

(** [parse_output stdout] splits stdout by ['\n'] and parses each
    line via {!parse_line}, dropping [None] results. The cumulative
    silent-drop count is *not* reported — observability is the
    consumer's responsibility (see RFC §3.3 follow-up note re:
    [masc_docker_ps_parse_drop_total] counter, if it becomes
    operationally noisy). *)
val parse_output : string -> Docker_response.ps_record list

(** Dashboard_execution_fixture — synthetic execution-dashboard
    JSON for smoke tests and dev preview.

    {b Cascade chain}: starts with
    [include Dashboard_execution_helpers].
    {!Dashboard_execution} does
    [include Dashboard_execution_fixture] to make the fixture
    accessor visible bare in the [?fixture] dispatch branch.

    Single external entry: {!execution_smoke_fixture_json}.  The
    rest of the 434-line file is a hardcoded JSON tree (sessions /
    agents / keepers / operations) constructed inline.  No
    helpers to expose. *)

include module type of struct
  include Dashboard_execution_helpers
end

val execution_smoke_fixture_json : unit -> Yojson.Safe.t
(** [execution_smoke_fixture_json ()] returns a synthetic
    {!Dashboard_execution} JSON payload covering the canonical
    smoke-test shape (one mission session + linked operation +
    typical keeper / agent briefs).

    Used by {!Dashboard_execution.json} when the [?fixture]
    parameter is [Some "execution_smoke"].  Pure — same JSON
    shape on every call (no clock / random sources) so smoke
    tests can assert against a stable golden. *)

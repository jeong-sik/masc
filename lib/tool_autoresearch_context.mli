
(** Tool_autoresearch_context — shared environment record passed
    into autoresearch tool handlers.

    All fields except [base_path] are optional and represent
    optional integration points: [agent_name] is set when a
    handler runs on behalf of a specific agent (used to scope
    Hebbian / journal writes); [start_operation] is the OAS
    bridge that actually launches a research run; [config] /
    [sw] / [clock] expose the Eio runtime handles a handler
    needs only when it persists state or sleeps.

    The record is exposed concretely (not as an abstract type)
    because the test suite constructs it directly across 6
    fixtures in [test_autoresearch_target_score] and
    [test_autoresearch_oas_primitives]; hiding the shape would
    force the tests through factory helpers without making the
    abstraction any richer.

    [Tool_autoresearch] re-exports this type as
    [Tool_autoresearch.context] for the public tool surface;
    [Tool_autoresearch_cycle] consumes it directly. *)

type t = {
  base_path : string;
  agent_name : string option;
  start_operation :
    (goal:string ->
     target_file:string ->
     (Yojson.Safe.t, string) Result.t)
    option;
  config : Coord.config option;
  sw : Eio.Switch.t option;
  clock : float Eio.Time.clock_ty Eio.Resource.t option;
}

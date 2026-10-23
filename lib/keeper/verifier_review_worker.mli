(** Worker bridge that runs one retained verifier review attempt.

    The host retains an immutable {!Verifier_review_original.t} for an
    attempt (see {!Verifier_review_owner}) and owns the reviewer's tools
    through {!Verification_authority_tools}. This module is the narrow
    seam between the two: it reads the retained original back, hands the
    review to the tool-capable reviewer the host already built, and returns
    the review result. It does not extract a verdict, call
    {!Task.Anti_rationalization.report_review_verdict}, advance a Task or
    Goal, or ask a human; those stay on the host side of the E06 boundary.

    The immutable original's lookup grants and evidence image are what make
    the worker unable to re-read current state or reapply a different
    verification's evidence; the host-built [lookup] surface and
    [lookup_root] are exactly the grants the original fixed. *)

val run_attempt
  :  ?on_verdict:(Task.Anti_rationalization.review_result -> unit)
  -> ?on_tool_result:(input:Yojson.Safe.t -> Tool_result.result -> unit)
  -> ?sw:Eio.Switch.t option
  -> store:Verifier_review_owner.store
  -> verification_id:string
  -> attempt:int
  -> installation_id:string
  -> package_id:string
  -> question:Task.Anti_rationalization.verdict_question
  -> lookup:Task.Anti_rationalization.lookup_surface
  -> lookup_root:Task.Anti_rationalization.lookup_root
  -> provider_rest:(string -> Task.Anti_rationalization.provider_rest)
  -> base_path:string
  -> (Task.Anti_rationalization.review_result, error) result
(** [run_attempt] reads the original retained at [verification_id:attempt],
    then runs the review the host prepared. The original's fixed
    [review_request] (its subject and evidence) is what [review] judges; the
    host-built [lookup] and [lookup_root] are the reviewer's grants, which the
    original froze. This binds no lane, calls no verdict tool and performs no
    Task/Goal transition — the caller owns those.

    [question] is the verifier's question (its completion contract, required
    evidence and posture), not the worker's. The worker cannot widen it; it
    can only run the review the original and the question together describe.

    The host owns workspace authority for [base_path]; the worker passes it
    through to [review] rather than rediscovering it from process-global
    environment state. *)

and error =
  | Original_not_found
  | Original_corrupt of string
  | Review_failed of string

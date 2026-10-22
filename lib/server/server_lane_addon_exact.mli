(** The host's runner for a Lane Add-on package's exact-output requests (RFC
    operator-quiz §4.3, Execution). It runs a request the way the Candle
    appraiser runs its own: the package schema with [Json_syntax] is the
    requirement, the HTTP slots run in order and an answer that does not match
    the schema advances to the next one, then [cli_slots] run as one-shot
    official clients. HTTP preserves each user/assistant role. The one-shot
    CLI tail accepts user-only requests; an assistant turn is reported as a
    configuration refusal without starting a CLI process. A future event can
    retry through a newly configured HTTP slot, with the original history.

    How the call ends:
    - a slot's answer matches the schema: [answered];
    - any slot failed in a way that may pass without changing the input
      (transient, credentials, configuration): not final, with the reason;
    - otherwise, a slot refused the input itself: [input_refused];
    - otherwise, a slot exhausted its output limit: [output_limit_reached];
    - otherwise every slot answered and none could be used: [invalid_output].

    Resolution sends nothing. A lane that is unconfigured, off, without
    slots, or a registry that is not published, is reported before any call. *)

val runner : base_path:string -> Lane_addon_exact.runner
val validate_request : base_path:string -> Lane_addon_exact.validation_authority
(** Host-owned consumer authority. Register together with [runner]; the common
    Exact owner composes it with mandatory package/request schema checks before
    accepting a candidate and when delivering a retained answer. *)

module For_testing : sig
  val runner : base_path:string -> cli_runner:Keeper_lane_cli_oneshot.runner -> Lane_addon_exact.runner
end

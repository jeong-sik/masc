(* RFC-0070 Phase 3c.1 — Sandbox_executor + retry. See .mli. *)

module Make (D : Docker_client.S) = struct
  let execute_plan plan = D.run plan

  let execute_plan_with_retry ~retry plan =
    let budget = Keeper_backoff_policy.max_attempts retry in
    let rec loop attempt =
      match D.run plan with
      | Ok _ as ok -> ok
      | Error err when attempt < budget && Keeper_backoff_policy.should_retry retry err ->
        loop (attempt + 1)
      | Error _ as e -> e
    in
    loop 1
end

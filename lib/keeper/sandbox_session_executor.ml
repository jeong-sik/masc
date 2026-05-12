(* RFC-0070 Phase 3e (f) — Sandbox_session_executor. See .mli.

   A thin orchestrator over the {!Docker_client.S} session primitives:
   [start] → [D.run_detached] (the edge — writes identity files, the
   seccomp probe, the spawn-time labels, prepends [docker_command_argv ()],
   spawns); [exec] → [D.exec] (threading the plan's [user] / [workdir]);
   [cleanup] → [D.rm]. No I/O, no clock, no Random in this module —
   those are all behind [D]. *)

module Make (D : Docker_client.S) = struct
  type t =
    { container_name : Keeper_container_name.t
    ; plan : Keeper_sandbox_session_plan.t
        (* Retained only so [exec] can thread [user] / [workdir]; not
           inspected for anything else. *)
    }

  let start plan =
    match D.run_detached plan with
    | Ok container_name -> Ok { container_name; plan }
    | Error err -> Error err

  let exec t ~cmd =
    D.exec
      ?user:(Keeper_sandbox_session_plan.user t.plan)
      ?workdir:(Keeper_sandbox_session_plan.workdir t.plan)
      ~container:t.container_name
      ~cmd
      ()

  let cleanup t = D.rm t.container_name
  let container_name t = t.container_name
end

(* RFC-0070 Phase 3c.0 — Sandbox_executor scaffold. See .mli. *)

module Make (D : Docker_client.S) = struct
  let execute_plan plan = D.run plan
end

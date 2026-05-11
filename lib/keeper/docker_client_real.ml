(* RFC-0070 Phase 3b-iv.2.0 — Real Docker_client skeleton. See .mli.

   Every function returns a typed placeholder [Error Cleanup_failed].
   Sub-phases 3b-iv.2.{1,2,3,4} replace each function body with the
   real Process_eio-backed spawn; the public signature does not
   change between sub-phases so callers can wire this module today
   and pick up new behaviour as it lands. *)

let placeholder = Error Docker_client.Cleanup_failed

let run (_ : Keeper_sandbox_plan.t) = placeholder
let exec ~container:_ ~cmd:_ = placeholder
let ps_query ~labels:_ = placeholder
let rm (_ : Keeper_container_name.t) = Error Docker_client.Cleanup_failed

(** OAS approval callbacks shared across system-agent call sites. *)

(* #7883 *)

(** OAS callback used when authorization belongs to the MASC executor. It
    prevents a second, tool-name-aware approval layer inside the SDK; concrete
    external effects must still pass their normalized MASC Gate boundary. *)
let auto_approve : Agent_sdk.Hooks.approval_callback =
  Agent_sdk.Approval.(create [ always_approve ] |> as_callback)

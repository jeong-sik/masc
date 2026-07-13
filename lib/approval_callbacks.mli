(** OAS approval callbacks shared across system-agent call sites. *)

val auto_approve : Agent_sdk.Hooks.approval_callback
(** OAS callback for agents whose concrete effect executor owns the MASC Gate.
    It avoids a second hidden SDK approval hierarchy; it does not authorize an
    external effect by itself. *)

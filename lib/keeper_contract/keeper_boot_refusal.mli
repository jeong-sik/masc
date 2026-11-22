(** Wire refusal codes for keeper lifecycle boot requests. *)

val keeper_boot_phase_conflict_code : string
(** Refusal ["code"] returned on HTTP 409 when [/boot] is requested while a
    keeper registry entry is in a transient lifecycle phase ([Draining] or
    [Restarting]). *)

(* Fusion config <-> JSON for the dashboard settings endpoints (RFC-0306 §3.1,
   RFC fusion-seat-routes §2.5). The write path decodes a preset from the same
   shape [to_yojson] emits; TOML is written by Fusion_config_writer. *)

(** [to_yojson c] is the structured JSON projection of the product-relevant
    active fusion config: [enabled], [default_preset], staged reducer group size,
    and every validated preset (panel roster, meta judge, JoJ first-round
    judges). Judge record fields lose their [j] prefix in the output so panel
    and judge shapes read symmetrically. *)
val to_yojson : Fusion_policy.t -> Yojson.Safe.t


val preset_to_yojson : Fusion_policy.preset -> Yojson.Safe.t

val preset_of_yojson : Yojson.Safe.t -> (Fusion_policy.preset, string) result
(** The inverse of {!preset_to_yojson}. Every key is required and no other key
    is accepted: a client that drops a field or misspells one gets an error
    naming it, not a default. Absent optional numbers are [null]. The result
    is not validated; run {!Fusion_policy.Validated_preset.of_preset}. *)

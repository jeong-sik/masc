(* Fusion config -> JSON projection for the dashboard read endpoint (RFC-0306 §3.1).
   Read-only; does not round-trip back to TOML. *)

(** [to_yojson c] is the structured JSON projection of the product-relevant
    active fusion config: [enabled], [default_preset], staged reducer group size,
    and every validated preset (panel roster, meta judge, JoJ first-round
    judges). Judge record fields lose their [j] prefix in the output so panel
    and judge shapes read symmetrically. *)
val to_yojson : Fusion_policy.t -> Yojson.Safe.t


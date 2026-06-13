(** Checked_shell_ir — Proof bundle for classified Shell IR.

    P1 of the Shell IR Effect Proof Design (RFC-0208 extension).

    Wraps a [Shell_ir.t] with a proof bundle containing:
    - Effect decomposition (from [Exec_effect])
    - Typed IR hit status
    - Source span provenance
    - Legacy risk_class projection

    The proof bundle is additive — it does not change dispatch behavior.
    It provides richer metadata for logging, telemetry, and future
    runtime capability minting (P2+). *)


(** {1 Proof bundle} *)

type proof = {
  effects : Exec_effect.set;
  (** Effect decomposition of the command. *)
  typed_hit : bool;
  (** Whether the typed IR matched a real constructor (vs Generic fallback). *)
  source_span : string;
  (** Human-readable provenance for the classification. *)
  risk : Shell_ir_risk.risk_class;
  (** Legacy scalar projection. Equal to [Shell_ir_risk.classify ir]. *)
}

val pp_proof : Format.formatter -> proof -> unit


(** {1 Checked IR} *)

type t = {
  ir : Shell_ir.t;
  (** The original Shell IR. *)
  proof : proof;
  (** The classification proof bundle. *)
}

val pp : Format.formatter -> t -> unit
val ir : t -> Shell_ir.t
val proof : t -> proof


(** {1 Classification with proof} *)

val classify_proof : Shell_ir.t -> t
(** Classify a [Shell_ir.t] and produce a proof bundle.

    Combines:
    - [Shell_ir_risk.classify] for legacy risk_class
    - [Exec_effect.extract] for effect decomposition
    - [Shell_ir_risk.typed_hit_of_ir] for typed coverage

    Invariants:
    - [proof.risk = Shell_ir_risk.classify ir]
    - [Exec_effect.project_risk proof.effects = proof.risk] *)


(** {1 Legacy compatibility} *)

val to_decided_ir : t -> Shell_ir_risk.decided Shell_ir_risk.decided_ir
(** Extract the legacy [decided_ir] for dispatch compatibility. *)

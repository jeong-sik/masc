(** Checked_shell_ir — Proof bundle for classified Shell IR.

    P1 of the Shell IR Effect Proof Design (RFC-0208 extension).
    See [checked_shell_ir.mli] for specification. *)


(* --- Proof bundle --------------------------------------------------- *)

type proof = {
  effects : Exec_effect.set;
  typed_hit : bool;
  source_span : string;
  risk : Shell_ir_risk.risk_class;
}

let pp_proof fmt p =
  Format.fprintf fmt
    "@[<v 2>{ risk = %s;@ typed_hit = %b;@ effects = %a;@ source = %S }@]"
    (Shell_ir_risk.string_of_risk_class p.risk)
    p.typed_hit
    Exec_effect.pp_set
    p.effects
    p.source_span
;;

(* --- Checked IR ----------------------------------------------------- *)

type t = {
  ir : Shell_ir.t;
  proof : proof;
}

let pp fmt c =
  Format.fprintf fmt
    "@[<v 2>Checked_shell_ir {@ ir = %a;@ proof = %a;@ }@]"
    Shell_ir.pp c.ir
    pp_proof c.proof
;;

let ir c = c.ir
let proof c = c.proof


(* --- Classification with proof -------------------------------------- *)

let classify_proof (ir : Shell_ir.t) : t =
  (* 1. Legacy risk classification *)
  let envelope = Shell_ir_risk.classify (Shell_ir_risk.undecided ir) in
  let risk = envelope.risk in
  (* 2. Effect decomposition (P0: delegates to classify) *)
  let effects = Exec_effect.extract ir in
  (* 3. Typed IR hit status *)
  let typed_hit = Shell_ir_risk.typed_hit_of_ir ir in
  (* 4. Source span *)
  let source_span =
    let risk_str = Shell_ir_risk.string_of_risk_class risk in
    let hit_str = if typed_hit then "typed" else "generic" in
    Printf.sprintf "%s:%s" risk_str hit_str
  in
  { ir
  ; proof =
      { effects
      ; typed_hit
      ; source_span
      ; risk
      }
  }
;;


(* --- Legacy compatibility ------------------------------------------- *)

let to_decided_ir (c : t) : Shell_ir_risk.decided Shell_ir_risk.decided_ir =
  { Shell_ir_risk.ir = c.ir; risk = c.proof.risk }
;;

(* Cycle 20 / Tier I9 tests — [@@tla.phantom_param] for GADT existentials
   with phantom type parameters.

   Tier I9 scope: extends the deriver to accept 1+ type-parameter GADTs
   when the user marks the type with [@@tla.phantom_param], asserting
   that no constructor specialises any parameter in its body. The
   deriver then emits [to_tla_symbol] / [all_symbols] structurally
   identical to the 0-param GADT case (Tier I8). The user's contract is
   enforced by the OCaml type-checker — a constructor that lies about
   phantom-ness produces a clean compile error at the call site. *)

(* ─── 1-parameter phantom GADT (Tier I9 core case) ────────────────── *)

module Phantom_perceiving = struct
  type 'a perceiving =
    | P_observe : 'a perceiving
    | P_wait : 'a perceiving
  [@@deriving tla] [@@tla.phantom_param]
end

let test_phantom_perceiving_to_tla_symbol () =
  let observe : unit Phantom_perceiving.perceiving =
    Phantom_perceiving.P_observe
  in
  let wait : int Phantom_perceiving.perceiving =
    Phantom_perceiving.P_wait
  in
  assert (Phantom_perceiving.to_tla_symbol observe = "p_observe");
  assert (Phantom_perceiving.to_tla_symbol wait = "p_wait")

let test_phantom_perceiving_all_symbols () =
  assert (Phantom_perceiving.all_symbols = [ "p_observe"; "p_wait" ])

(* ─── Phantom GADT with [@tla.symbol] override ─────────────────────── *)

module Phantom_with_override = struct
  type 'a action =
    | A_run : 'a action [@tla.symbol "execute"]
    | A_skip : 'a action
    | A_halt : 'a action [@tla.symbol "stop"]
  [@@deriving tla] [@@tla.phantom_param]
end

let test_phantom_with_override () =
  let run : unit Phantom_with_override.action = Phantom_with_override.A_run in
  let skip : int Phantom_with_override.action = Phantom_with_override.A_skip in
  let halt : string Phantom_with_override.action =
    Phantom_with_override.A_halt
  in
  assert (Phantom_with_override.to_tla_symbol run = "execute");
  assert (Phantom_with_override.to_tla_symbol skip = "a_skip");
  assert (Phantom_with_override.to_tla_symbol halt = "stop");
  assert
    (Phantom_with_override.all_symbols = [ "execute"; "a_skip"; "stop" ])

(* ─── Phantom GADT in module signature (sig_type_decl path) ─────────
   This validates that derive_sig_for_variant emits
   [val to_tla_symbol : 'a Phase.t -> string] — i.e. the type
   parameters are applied to the type name in the signature, free
   type variables remaining implicitly universally quantified. *)

module Phase : sig
  type 'a t =
    | Idle : 'a t
    | Active : 'a t
    | Done : 'a t
  [@@deriving tla] [@@tla.phantom_param]
end = struct
  type 'a t =
    | Idle : 'a t
    | Active : 'a t
    | Done : 'a t
  [@@deriving tla] [@@tla.phantom_param]
end

let test_phase_signature () =
  let idle : unit Phase.t = Phase.Idle in
  let active : int Phase.t = Phase.Active in
  let dn : string Phase.t = Phase.Done in
  assert (Phase.to_tla_symbol idle = "idle");
  assert (Phase.to_tla_symbol active = "active");
  assert (Phase.to_tla_symbol dn = "done");
  assert (Phase.all_symbols = [ "idle"; "active"; "done" ])

(* ─── 2-parameter phantom GADT (e.g. ('from, 'to_) transition shape) ──
   Models the eventual Tier B5 transition GADT shape, where both
   parameters are phantom and the deriver must emit
   [val to_tla_symbol : ('a, 'b) bridge -> string]. *)

module Multi_param_phantom = struct
  type ('a, 'b) bridge =
    | B_pending : ('a, 'b) bridge
    | B_active : ('a, 'b) bridge
    | B_closed : ('a, 'b) bridge
  [@@deriving tla] [@@tla.phantom_param]
end

let test_multi_param_phantom () =
  let p : (unit, int) Multi_param_phantom.bridge =
    Multi_param_phantom.B_pending
  in
  let a : (string, bool) Multi_param_phantom.bridge =
    Multi_param_phantom.B_active
  in
  assert (Multi_param_phantom.to_tla_symbol p = "b_pending");
  assert (Multi_param_phantom.to_tla_symbol a = "b_active");
  assert
    (Multi_param_phantom.all_symbols
     = [ "b_pending"; "b_active"; "b_closed" ])

let () =
  test_phantom_perceiving_to_tla_symbol ();
  test_phantom_perceiving_all_symbols ();
  test_phantom_with_override ();
  test_phase_signature ();
  test_multi_param_phantom ();
  print_endline "test_phantom_param: all assertions passed"

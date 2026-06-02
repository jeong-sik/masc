module type TLA_STATE_MACHINE = sig
  type state
  type action
  type variables

  val initial : variables
  val next : variables -> action -> variables option
  val invariant : variables -> bool
end

(* RFC-0331 — Typed tool effect class.

   Replaces the former free-text read-only substring classifier in
   [Verifier_core] with a declared, closed-sum property resolved from tool
   registration. [Read_only] means the tool is registered as read-only;
   [Mutating] is everything else. Unknown / undeclared tools resolve to
   [Mutating] by construction (fail-closed): the verifier can never skip
   verification for a tool that has not declared itself read-only. Parse,
   don't validate — the permissive branch is unrepresentable. *)

type t =
  | Read_only
  | Mutating

let to_string = function
  | Read_only -> "read_only"
  | Mutating -> "mutating"
;;

let equal a b =
  match a, b with
  | Read_only, Read_only | Mutating, Mutating -> true
  | Read_only, _ | Mutating, _ -> false
;;

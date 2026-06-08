(** Exec_effect — Effect axis types for Shell IR execution.

    P0 of the Shell IR Effect Proof Design (RFC-0208 extension).

    Note: [effect] is a reserved keyword in OCaml 5, so the primary
    type is named [t] (idiomatic: [Exec_effect.t]) and the collection
    is [set] ([Exec_effect.set]). *)


(** {1 Effect types} *)

type effect_kind =
  | Fs_read
  | Fs_write
  | Fs_delete
  | Process_spawn
  | Shell_interpreter
  | Net_egress
  | Credential_use
  | External_mutation

val string_of_effect_kind : effect_kind -> string
val pp_effect_kind : Format.formatter -> effect_kind -> unit
val compare_effect_kind : effect_kind -> effect_kind -> int

type t =
  { kind : effect_kind
  ; scope : string list
  ; source : string
  }

type set = t list

val pp : Format.formatter -> t -> unit
val pp_set : Format.formatter -> set -> unit


(** {1 Effect-level risk mapping} *)

val effect_kind_floor : effect_kind -> Shell_ir_risk.risk_class
(** The minimum risk_class for a given effect kind. *)


(** {1 Projection (legacy compatibility)} *)

val project_risk : set -> Shell_ir_risk.risk_class
(** Project an effect set back to the legacy scalar risk_class.

    P0 golden invariant:
        [project_risk (extract ir) = classify ir]
    for every command in the test corpus. *)


(** {1 Extraction} *)

val extract : Shell_ir.t -> set
(** Decompose a [Shell_ir.t] into its effect set.

    P0 delegates to [Shell_ir_risk.classify] and maps the scalar
    result to a single named effect. P1 will replace this with
    per-constructor fine-grained decomposition. *)

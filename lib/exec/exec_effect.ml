(** Exec_effect — Effect axis types for Shell IR execution.

    P0 of the Shell IR Effect Proof Design (RFC-0208 extension).
    See [exec_effect.mli] for specification.

    Note: [effect] is a reserved keyword in OCaml 5, so the primary
    type is named [t] and the collection is [set]. *)

(* --------------------------------------------------------------------------- *)
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

let string_of_effect_kind = function
  | Fs_read -> "Fs_read"
  | Fs_write -> "Fs_write"
  | Fs_delete -> "Fs_delete"
  | Process_spawn -> "Process_spawn"
  | Shell_interpreter -> "Shell_interpreter"
  | Net_egress -> "Net_egress"
  | Credential_use -> "Credential_use"
  | External_mutation -> "External_mutation"
;;

let pp_effect_kind fmt k = Format.pp_print_string fmt (string_of_effect_kind k)

let compare_effect_kind a b =
  String.compare (string_of_effect_kind a) (string_of_effect_kind b)
;;

type t =
  { kind : effect_kind
  ; scope : string list
  ; source : string
  }

type set = t list

let pp fmt e =
  Format.fprintf
    fmt
    "{ kind = %a; scope = [%a]; source = %S }"
    pp_effect_kind
    e.kind
    (Format.pp_print_list
       ~pp_sep:(fun fmt () -> Format.fprintf fmt "; ")
       Format.pp_print_string)
    e.scope
    e.source
;;

let pp_set fmt es =
  Format.fprintf
    fmt
    "[%a]"
    (Format.pp_print_list ~pp_sep:(fun fmt () -> Format.fprintf fmt ";@ ") pp)
    es
;;

(* --------------------------------------------------------------------------- *)
(** {1 Effect-level risk mapping} *)

let effect_kind_floor = function
  | Fs_read -> Shell_ir_risk.R0_Read
  | Fs_write -> Shell_ir_risk.R1_Reversible_mutation
  | Fs_delete -> Shell_ir_risk.R2_Irreversible
  | Process_spawn -> Shell_ir_risk.R1_Reversible_mutation
  | Shell_interpreter -> Shell_ir_risk.Destructive_protected
  | Net_egress -> Shell_ir_risk.R1_Reversible_mutation
  | Credential_use -> Shell_ir_risk.R1_Reversible_mutation
  | External_mutation -> Shell_ir_risk.R1_Reversible_mutation
;;

(* --------------------------------------------------------------------------- *)
(** {1 Projection (legacy compatibility)} *)

let project_risk (effects : set) : Shell_ir_risk.risk_class =
  let max_risk a b =
    let rank = function
      | Shell_ir_risk.R0_Read -> 0
      | Shell_ir_risk.R1_Reversible_mutation -> 1
      | Shell_ir_risk.R2_Irreversible -> 2
      | Shell_ir_risk.Destructive_protected -> 3
    in
    if rank a >= rank b then a else b
  in
  List.fold_left
    (fun acc e -> max_risk acc (effect_kind_floor e.kind))
    Shell_ir_risk.R0_Read
    effects
;;

(* --------------------------------------------------------------------------- *)
(** {1 Extraction} *)

(** Gather path-like arguments from a [Shell_ir.simple] via the typed
    lowering.  Falls back to an empty list if the lowering fails
    (should not happen for well-formed IR). *)
let scope_of_simple (s : Shell_ir.simple) : string list =
  try Shell_ir_typed.path_args (Shell_ir_typed.of_simple s) with
  | _ -> []
;;

(** P0 extraction delegates to the existing [Shell_ir_risk.classify]
    analysis to guarantee the golden property:

        project_risk (extract ir) = classify ir

    The returned effect uses the classified risk as its kind floor,
    and the typed-lowering path arguments as its scope.  P1 will
    replace this with a fine-grained per-constructor decomposition. *)
let extract (ir : Shell_ir.t) : set =
  let risk = (Shell_ir_risk.classify (Shell_ir_risk.undecided ir)).risk in
  let kind, source =
    match risk with
    | Shell_ir_risk.R0_Read -> Fs_read, "classify:R0"
    | Shell_ir_risk.R1_Reversible_mutation -> Fs_write, "classify:R1"
    | Shell_ir_risk.R2_Irreversible -> Fs_delete, "classify:R2"
    | Shell_ir_risk.Destructive_protected -> Shell_interpreter, "classify:Destructive"
  in
  let scope =
    match ir with
    | Shell_ir.Simple s -> scope_of_simple s
    | Shell_ir.Pipeline _ -> []
  in
  [ { kind; scope; source } ]
;;

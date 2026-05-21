(** Internal_error_substrate — implementation. *)

type t =
  | Contract_rejected of { reason : string }

(* Mirrors [Cascade_error_classify.masc_internal_error_prefix].  Any
   change to the prefix here MUST be mirrored upstream — see the test
   [test_internal_error_substrate.ml] which pins the literal. *)
let masc_internal_error_prefix = "[masc_oas_error] "

let to_json = function
  | Contract_rejected { reason } ->
    `Assoc
      [
        ("kind", `String "internal_contract_rejected");
        ("reason", `String reason);
      ]

let sdk_error_of (t : t) : Error.sdk_error =
  Error.Internal (masc_internal_error_prefix ^ Yojson.Safe.to_string (to_json t))

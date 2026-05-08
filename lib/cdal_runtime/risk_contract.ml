type runtime_constraints =
  { requested_execution_mode : Execution_mode.t
  ; risk_class : Risk_class.t
  ; allowed_mutations : string list
  ; review_requirement : string option
  }
[@@deriving yojson, show]

type eval_criteria = Yojson.Safe.t [@@deriving yojson, show]

type t =
  { runtime_constraints : runtime_constraints
  ; eval_criteria : eval_criteria
  }
[@@deriving yojson, show]

let canonical_json contract =
  contract |> to_yojson |> Yojson.Safe.sort |> Yojson.Safe.to_string
;;

let contract_id contract =
  let canonical = canonical_json contract in
  let hash = Digest.string canonical |> Digest.to_hex in
  "md5:" ^ hash
;;

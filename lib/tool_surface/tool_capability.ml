(* RFC-0084 §3.2 — Typed tool dispatch capability.
   See tool_capability.mli for the contract. *)

type kind =
  | Read_only
  | Mcp_context_required
  | Idempotent

let to_string = function
  | Read_only -> "read_only"
  | Mcp_context_required -> "mcp_context_required"
  | Idempotent -> "idempotent"
;;

let of_string = function
  | "read_only" -> Some Read_only
  | "mcp_context_required" -> Some Mcp_context_required
  | "idempotent" -> Some Idempotent
  | _unknown -> None
;;

let all_kinds = [ Read_only; Mcp_context_required; Idempotent ]

module Set = Stdlib.Set.Make (struct
    type t = kind

    let compare a b =
      (* Stable ordering by [to_string] so set comparisons are deterministic. *)
      String.compare (to_string a) (to_string b)
    ;;
  end)

let has kind tool_name =
  let metadata = Tool_catalog.metadata tool_name in
  match kind with
  | Read_only ->
    (match metadata.readonly with
     | Some true -> true
     | Some false | None -> false)
  | Mcp_context_required ->
    (match metadata.mcp_context_required with
     | Some true -> true
     | Some false | None -> false)
  | Idempotent ->
    (match metadata.idempotent with
     | Some true -> true
     | Some false | None -> false)
;;

let granted tool_name =
  List.fold_left
    (fun acc kind -> if has kind tool_name then Set.add kind acc else acc)
    Set.empty
    all_kinds
;;

let check ~required ~granted =
  let missing = Set.diff required granted in
  if Set.is_empty missing then Stdlib.Result.Ok () else Stdlib.Result.Error missing
;;

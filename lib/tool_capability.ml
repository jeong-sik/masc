(* RFC-0084 §3.2 — Typed tool dispatch capability.
   See tool_capability.mli for the contract. *)

type kind =
  | Read_only
  | Requires_join
  | Mcp_context_required
  | Destructive
  | Idempotent

let to_string = function
  | Read_only -> "read_only"
  | Requires_join -> "requires_join"
  | Mcp_context_required -> "mcp_context_required"
  | Destructive -> "destructive"
  | Idempotent -> "idempotent"
;;

let of_string = function
  | "read_only" -> Some Read_only
  | "requires_join" -> Some Requires_join
  | "mcp_context_required" -> Some Mcp_context_required
  | "destructive" -> Some Destructive
  | "idempotent" -> Some Idempotent
  | _ -> None
;;

let all_kinds =
  [ Read_only; Requires_join; Mcp_context_required; Destructive; Idempotent ]
;;

module Set = Stdlib.Set.Make (struct
    type t = kind

    let compare a b =
      (* Stable ordering by [to_string] so set comparisons are deterministic. *)
      String.compare (to_string a) (to_string b)
    ;;
  end)

let rec has kind tool_name =
  let metadata = Tool_catalog.metadata tool_name in
  match kind with
  | Read_only ->
    (match metadata.readonly, metadata.effect_domain with
     | Some true, _ | _, Some Tool_catalog.Read_only -> true
     | Some false, _ | None, _ -> false)
  | Requires_join ->
    (match metadata.requires_join with
     | Some true -> true
     | Some false | None -> false)
  | Mcp_context_required ->
    (match metadata.mcp_context_required with
     | Some true -> true
     | Some false | None -> false)
  | Destructive ->
    (match metadata.destructive with
     | Some true -> true
     | Some false | None -> false)
  | Idempotent ->
    (match metadata.idempotent with
     | Some true -> true
     | Some false -> false
     | None -> has Read_only tool_name)
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

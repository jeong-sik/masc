(* RFC-0084 §1.6, §3.5 — Typed keeper disclosure strategy.
   See keeper_disclosure_strategy.mli for the contract. *)

type t =
  | Full
  | Hybrid of
      { full_names : string list
      ; demote_on_error : bool
      }
  | Minimal_index

let default = Full

let to_string = function
  | Full -> "full"
  | Hybrid _ -> "hybrid"
  | Minimal_index -> "minimal_index"
;;

let of_toml ~strategy ~full_names ~demote_on_error =
  match strategy with
  | "full" -> Ok Full
  | "hybrid" ->
    (match full_names with
     | [] ->
       Error
         "RFC-0084 §3.5: [disclosure] strategy = \"hybrid\" requires non-empty \
          full_names list (RFC-OAS-013 §2.1 v2 core_tool_names)."
     | _ ->
       (* RFC-OAS-013 §2.4: sort for prefix-cache stability. *)
       let sorted = List.sort String.compare full_names in
       Ok (Hybrid { full_names = sorted; demote_on_error }))
  | "minimal_index" -> Ok Minimal_index
  | other ->
    Error
      (Printf.sprintf
         "RFC-0084 §3.5: unknown [disclosure] strategy %S \
          (expected: full | hybrid | minimal_index)"
         other)
;;

let is_full = function
  | Full -> true
  | Hybrid _ | Minimal_index -> false
;;

let pp fmt = function
  | Full -> Format.fprintf fmt "Full"
  | Hybrid { full_names; demote_on_error } ->
    Format.fprintf
      fmt
      "Hybrid(full_names=[%s]; demote_on_error=%b)"
      (String.concat "; " full_names)
      demote_on_error
  | Minimal_index -> Format.fprintf fmt "Minimal_index"
;;

(* RFC-0084 host-config-cleanup-G — OAS Builder bridges. *)

let to_oas_disclosure_level = function
  | Full ->
    (* SDK default is already Full_schema; no builder call required. *)
    None
  | Hybrid { full_names; demote_on_error = _ } ->
    Some (Agent_sdk.Tool.Hybrid { full_names })
  | Minimal_index -> Some Agent_sdk.Tool.Minimal_index
;;

let to_oas_resolver = function
  | Full | Minimal_index | Hybrid { demote_on_error = false; _ } -> None
  | Hybrid { demote_on_error = true; _ } ->
    let resolver (results : Agent_sdk.Types.tool_result list) =
      (* [Agent_sdk.Types.tool_result] is a [Stdlib.result] of
         [(tool_output, tool_error)]; pattern-match on the standard
         constructors directly. *)
      let has_error =
        List.exists
          (function
            | Stdlib.Error _ -> true
            | Stdlib.Ok _ -> false)
          results
      in
      if has_error then Some Agent_sdk.Tool.Full_schema else None
    in
    Some resolver
;;

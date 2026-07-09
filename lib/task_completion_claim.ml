(* SSOT for deliverable completion-claim detection. See task_completion_claim.mli
   for the contract and the RFC-0323 escalation note on the string-match limit. *)

let first_line text =
  match String.index_opt text '\n' with
  | Some i -> String.sub text 0 i
  | None -> text

let deliverable_claims_completion ~task_id deliverable =
  let normalized = deliverable |> String.trim |> String.lowercase_ascii |> first_line in
  normalized <> ""
  && (String.starts_with
        ~prefix:(String.lowercase_ascii task_id ^ " completed")
        normalized
      || String.starts_with ~prefix:"completed" normalized)

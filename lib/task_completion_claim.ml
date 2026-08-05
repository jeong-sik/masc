(* SSOT for deliverable completion-claim detection. See task_completion_claim.mli
   for the contract and the standing note on the string-match limit. *)

let deliverable_claims_completion ~task_id deliverable =
  let normalized =
    deliverable |> String.trim |> String.lowercase_ascii |> String_util.first_line
  in
  normalized <> ""
  && (String.starts_with
        ~prefix:(String.lowercase_ascii task_id ^ " completed")
        normalized
      || String.starts_with ~prefix:"completed" normalized)

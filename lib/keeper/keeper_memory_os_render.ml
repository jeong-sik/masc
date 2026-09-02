open Keeper_memory_os_types

let recorded_at fact = Masc_domain.iso8601_of_unix_seconds fact.first_seen

(* A Board source is rendered as the ids the Board tools accept, so the model
   can open it; no prose is added here. *)
let basis_label fact =
  match fact.basis with
  | Observed Transcript -> "observed"
  | Observed (Board { post_id; comment_id = None }) ->
    Printf.sprintf "observed board=%s" post_id
  | Observed (Board { post_id; comment_id = Some comment_id }) ->
    Printf.sprintf "observed board=%s comment=%s" post_id comment_id
  | Derived _ -> "derived"
;;

let render_fact fact =
  Printf.sprintf
    "- [category=%s recorded=%s origin=%s basis=%s] %s"
    (category_to_string fact.category)
    (recorded_at fact)
    (origin_kind_to_string fact.origin.kind)
    (basis_label fact)
    fact.claim
;;

let render_facts facts =
  facts |> List.map render_fact |> String.concat "\n"
;;

open Keeper_memory_os_types

let recorded_at fact = Masc_domain.iso8601_of_unix_seconds fact.first_seen

let basis_label fact =
  match fact.basis with
  | Observed -> "observed"
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

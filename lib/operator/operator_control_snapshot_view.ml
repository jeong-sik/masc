(** Operator snapshot view selector, extracted from
    [operator_control_snapshot.ml] (godfile decomp).

    The variant + parser cluster used to thread the operator
    dashboard's per-section snapshot selector through the HTTP layer
    and the [tool_operator] schema. Issue #8471 keeps
    [snapshot_view_to_string] exhaustive against the variant and
    derives [valid_snapshot_view_strings] from [all_snapshot_views]
    so adding a constructor flows through to both the parser and
    the schema's user-visible catalogue automatically (the previous
    sparse string-list version silently dropped [Sessions]). *)

type snapshot_view =
  | Summary
  | Sessions
  | Keepers
  | Messages
  | Full

(* Issue #8471: Variant SSOT for [snapshot_view]. Adding a constructor
   forces [snapshot_view_to_string] exhaustiveness AND extends
   [valid_snapshot_view_strings]; the schema in [tool_operator.ml]
   derives its enum from this list, so a new constructor flows
   through automatically instead of silently dropping (as [Sessions]
   did before this fix). *)
let snapshot_view_to_string = function
  | Summary -> "summary"
  | Sessions -> "sessions"
  | Keepers -> "keepers"
  | Messages -> "messages"
  | Full -> "full"
;;

let all_snapshot_views = [ Summary; Sessions; Keepers; Messages; Full ]
let valid_snapshot_view_strings = List.map snapshot_view_to_string all_snapshot_views

(* Sound partial parser — Some for canonical strings, None otherwise.
   Callers that need tool/HTTP back-compat should make their fallback
   explicit at the boundary. *)
let snapshot_view_of_string_opt raw =
  match String.trim raw |> String.lowercase_ascii with
  | "summary" -> Some Summary
  | "sessions" -> Some Sessions
  | "keepers" -> Some Keepers
  | "messages" -> Some Messages
  | "full" -> Some Full
  | _ -> None
;;

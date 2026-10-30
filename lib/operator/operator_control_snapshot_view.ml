(** Operator snapshot view selector, extracted from
    [operator_control_snapshot.ml] (godfile decomp).

    The variant + parser cluster used to thread the operator
    dashboard's per-section snapshot selector through the HTTP layer
    and the [tool_operator] schema. Issue #8471 keeps
    [snapshot_view_to_string] exhaustive against the variant and
    derives [valid_snapshot_view_strings] from [all_snapshot_views],
    so adding a constructor flows through to the parser
    automatically; the schema's enum literal lives in
    [config/tools/masc_operator_snapshot.toml], guarded by the
    enum-mirror test. *)

type snapshot_view =
  | Summary
  | Keepers
  | Messages
  | Full

(* Issue #8471: Variant SSOT for [snapshot_view]. Adding a constructor
   forces [snapshot_view_to_string] exhaustiveness AND extends
   [valid_snapshot_view_strings]. The tool schema's enum is a literal in
   [config/tools/masc_operator_snapshot.toml]; the enum-mirror test
   ([test_enum_mirror_sync]) compares it against this list, so a new
   constructor fails the suite until the file follows. *)
let snapshot_view_to_string = function
  | Summary -> "summary"
  | Keepers -> "keepers"
  | Messages -> "messages"
  | Full -> "full"
;;

let all_snapshot_views = [ Summary; Keepers; Messages; Full ]
let valid_snapshot_view_strings = List.map snapshot_view_to_string all_snapshot_views

(* Sound partial parser — Some for canonical strings, None otherwise.
   Callers that need tool/HTTP back-compat should make their fallback
   explicit at the boundary. *)
let snapshot_view_of_string_opt raw =
  match String.trim raw |> String.lowercase_ascii with
  | "summary" -> Some Summary
  | "keepers" -> Some Keepers
  | "messages" -> Some Messages
  | "full" -> Some Full
  | _ -> None
;;

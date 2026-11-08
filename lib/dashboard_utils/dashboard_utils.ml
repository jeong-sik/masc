let parse_iso_opt = function
  | Some raw when String.trim raw <> "" -> Masc_domain.parse_iso8601_opt raw
  | _ -> None

let first_some a b = match a with Some _ as v -> v | None -> b

let dedup_strings (xs : string list) : string list = Json_util.dedupe_keep_order xs

let string_list_of_json json =
  match json with
  | `List items ->
      items
      |> List.filter_map (function
             | `String value -> String_util.trim_nonempty value
             | _ -> None)
  | _ -> []

let member_assoc key json =
  match json with
  | `Assoc fields -> (match List.assoc_opt key fields with Some v -> v | None -> `Null)
  | _ -> `Null

let string_field ?(default = "") key json =
  match member_assoc key json with
  | `String v -> v
  | _ -> default

let list_field key json =
  match member_assoc key json with
  | `List items -> items
  | _ -> []

(* The wire carries [agent_status_to_string]'s output, so ranking a serialized
   status means decoding it first. Ranking the raw string instead left an arm
   for "idle" — a spelling this producer never emits — while the real fourth
   constructor, [Inactive], fell through to the catch-all and ranked the same
   as garbage. *)
let status_rank raw =
  match Masc_domain.agent_status_of_string_opt (String.lowercase_ascii (String.trim raw)) with
  | Some status -> Masc_domain.agent_status_rank status
  | None -> 0

let rec take n items =
  if n <= 0 then [] else match items with [] -> [] | x :: xs -> x :: take (n - 1) xs

let compact_text = String_util.compact_text

let normalized_text_key text =
  compact_text ~max_len:512 text |> String.trim |> String.lowercase_ascii

(** Health severity level — ordered by {!Health_status.rank}.
    Parsed from dashboard/operator JSON at the call site via
    [health_level_of_string], then used in typed predicates below. *)
type health_level = Health_status.t

let health_level_of_string = Health_status.of_string

let string_of_health_level = Health_status.to_string

let severity_rank_of_health_level = Health_status.rank

(** Status/health classification predicates — single source of truth.
    Used across dashboard, briefing, and operator modules. *)

let is_health_critical = Health_status.requires_operator_action

let is_health_warning health =
  match Health_status.rank health with
  | 1 | 2 -> true
  | _ -> false

let is_health_at_risk health = Health_status.rank health >= 2

(** Dashboard tone — severity indicator for UI rendering.
    ADT eliminates catch-all patterns and enforces exhaustive matching.
    Serialized to string at JSON boundaries only. *)
type tone = Tone_ok | Tone_warn | Tone_bad

let string_of_tone = function
  | Tone_ok -> "ok"
  | Tone_warn -> "warn"
  | Tone_bad -> "bad"

let tone_rank = function
  | Tone_bad -> 2
  | Tone_warn -> 1
  | Tone_ok -> 0

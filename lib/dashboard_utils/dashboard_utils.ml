let iso_of_unix unix_ts =
  let tm = Unix.gmtime unix_ts in
  Printf.sprintf "%04d-%02d-%02dT%02d:%02d:%02dZ"
    (tm.Unix.tm_year + 1900) (tm.Unix.tm_mon + 1) tm.Unix.tm_mday
    tm.Unix.tm_hour tm.Unix.tm_min tm.Unix.tm_sec

let parse_iso_opt = function
  | Some raw when String.trim raw <> "" -> (
      try Some (Types.parse_iso8601 raw) with Failure _ -> None)
  | _ -> None

(* Delegate to Base — qualified access, no `open Base` *)
let first_some = Base.Option.first_some

let string_contains ~needle haystack =
  Base.String.is_substring haystack ~substring:needle

let string_contains_ci ~needle haystack =
  Base.String.is_substring
    (Base.String.lowercase haystack)
    ~substring:(Base.String.lowercase needle)

let trim_to_option text =
  let trimmed = String.trim text in
  if trimmed = "" then None else Some trimmed

let dedup_strings (xs : string list) : string list =
  let rec go seen acc = function
    | [] -> List.rev acc
    | x :: rest ->
      if Base.String.Set.mem x seen then go seen acc rest
      else go (Base.String.Set.add x seen) (x :: acc) rest
  in
  go Base.String.Set.empty [] xs

let string_list_of_json json =
  match json with
  | `List items ->
      items
      |> List.filter_map (function
             | `String value -> trim_to_option value
             | _ -> None)
  | _ -> []

let json_string_option value =
  match value with
  | Some text when String.trim text <> "" -> `String (String.trim text)
  | _ -> `Null

let option_to_json f = function
  | Some value -> f value
  | None -> `Null

let member_assoc key json =
  match json with
  | `Assoc fields -> (match List.assoc_opt key fields with Some v -> v | None -> `Null)
  | _ -> `Null

let int_field ?(default = 0) key json =
  match member_assoc key json with
  | `Int v -> v
  | `Intlit raw -> (Option.value ~default:default (int_of_string_opt raw))
  | `Float v -> int_of_float v
  | _ -> default

let string_field ?(default = "") key json =
  match member_assoc key json with
  | `String v -> v
  | _ -> default

let list_field key json =
  match member_assoc key json with
  | `List items -> items
  | _ -> []

let severity_rank = function
  | "bad" | "risk" | "critical" -> 2
  | "warn" | "watch" | "interrupted" | "degraded" -> 1
  | _ -> 0

let status_rank = function
  | "busy" -> 4
  | "active" -> 3
  | "listening" -> 2
  | "idle" -> 1
  | _ -> 0

let rec take n items =
  if n <= 0 then [] else match items with [] -> [] | x :: xs -> x :: take (n - 1) xs

let compact_text ?(max_len = 160) raw =
  let normalized =
    String.trim raw
    |> String.split_on_char '\n'
    |> List.map String.trim
    |> List.filter (fun v -> v <> "")
    |> String.concat " "
    |> String.trim
  in
  if normalized = "" then ""
  else if String.length normalized <= max_len then normalized
  else String.sub normalized 0 (max_len - 1) ^ "\xe2\x80\xa6"

let string_list_json values =
  `List (List.map (fun v -> `String v) values)

let normalized_text_key text =
  compact_text ~max_len:512 text |> String.trim |> String.lowercase_ascii

(** Status/health classification predicates — single source of truth.
    Used across dashboard, briefing, operator, command_plane modules.
    Adding a new status/health value? Update here, not at each call site. *)

let is_keeper_offline status =
  List.mem status [ "offline"; "inactive"; "error" ]

let is_health_critical health =
  List.mem health [ "bad"; "critical" ]

let is_health_warning health =
  List.mem health [ "warn"; "degraded" ]

let is_health_at_risk health =
  List.mem health [ "bad"; "risk"; "critical" ]

let is_session_terminal status =
  List.mem status [ "completed"; "cancelled"; "failed"; "stopped" ]

let is_session_blocked status =
  List.mem status [ "failed"; "cancelled"; "interrupted" ]

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

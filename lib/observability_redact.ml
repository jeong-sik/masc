(** Observability_redact — redact sensitive data for observability fields.

    Truncation plus structural secret redaction. Every tool call remains
    observable; tool names never decide whether evidence exists.

    The pattern layer (secret-shaped prefixes, PEM blocks, sensitive JSON
    keys) lives in [Secret_patterns] — a leaf library shared with the
    [masc_log] sink — and is delegated to below so the pattern list has a
    single source of truth. *)

let default_max_len = 200

let is_sensitive_key = Secret_patterns.is_sensitive_key

let redact_patterns = Secret_patterns.redact_text

let redact_text (s : string) : string =
  redact_patterns s

(* [max_len] is a byte budget, but the strings that reach here are UTF-8 and
   [String.sub s 0 max_len] lands inside a multibyte character whenever one
   straddles the boundary, leaving a lead byte with no continuation. The damage
   is not local to the field: a consumer that decodes the whole payload fails on
   all of it. The dashboard's exact-lane panel rendered nothing for this reason
   — one Korean board comment crossing the 1024-byte preview boundary made
   [response.json()] throw, and 68 runs went unshown.

   [String_util.utf8_char_boundary] is the existing answer to this (8+ callers
   already route through that module's UTF-8 helpers); only the cut index moves,
   so the byte budget and the suffix behave exactly as before. *)
let truncate ?(max_len = default_max_len) (s : string) : string =
  let s = String.trim s in
  if String.length s <= max_len then s
  else String.sub s 0 (String_util.utf8_char_boundary s max_len) ^ "...(truncated)"

(* Blob markers (see [Tool_output.encode_for_agent_core]) carry structural fields
   (sha256/bytes/mime) the dashboard needs to render the marker as a "Stored
   blob" preview. Decode, redact only the user-visible preview body, then
   re-encode so those fields survive intact. The prefix matchers do not match a
   64-hex sha256, but scoping redaction to the preview body keeps the marker
   structure correct regardless of which patterns run. *)
let redact_preview ?(max_len = default_max_len) (s : string) : string =
  if Tool_output.is_marker s then
    match Tool_output.decode_from_agent_core s with
    | Tool_output.Decoded artifact_ref ->
        let preview =
          artifact_ref.Tool_output.preview |> truncate ~max_len
          |> redact_patterns
        in
        Tool_output.encode_for_agent_core
          (Tool_output.Stored (Tool_output.with_preview artifact_ref preview))
    | Tool_output.Not_marker | Tool_output.Invalid_marker _ ->
        s |> truncate ~max_len |> redact_patterns
  else s |> truncate ~max_len |> redact_patterns

let rec preview_json_strings ?(max_len = default_max_len) (json : Yojson.Safe.t)
    : Yojson.Safe.t =
  match json with
  | `String s -> `String (redact_preview ~max_len s)
  | `Assoc fields ->
      `Assoc
        (List.map (fun (k, v) -> (k, preview_json_strings ~max_len v)) fields)
  | `List items -> `List (List.map (preview_json_strings ~max_len) items)
  | (`Null | `Bool _ | `Int _ | `Intlit _ | `Float _) as j -> j

let redact_json_strings = Secret_patterns.redact_json_strings

let rec redact_json_value = function
  | `Assoc fields ->
      `Assoc
        (List.map
           (fun (key, value) ->
             if is_sensitive_key key then (key, `String "[REDACTED]")
             else (key, redact_json_value value))
           fields)
  | `List items -> `List (List.map redact_json_value items)
  | (`Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _) as json ->
      json

let preview_of_json ?(max_len = default_max_len) (json : Yojson.Safe.t) =
  Yojson.Safe.to_string (redact_json_value json) |> redact_preview ~max_len

let redact_tool_input ~tool_name:_ (input : Yojson.Safe.t) : string option =
  Some (preview_of_json input)

let redact_tool_output ~tool_name:_ (output : string) : string option =
  Some (redact_preview output)

let redacted_tool_input_json ~tool_name:_ input =
  Some (input |> redact_json_value |> preview_json_strings)

let redacted_tool_output_json ~tool_name:_ output =
  let redacted =
    try Yojson.Safe.from_string output |> redact_json_value |> preview_json_strings
    with
    | Yojson.Json_error _ -> `String (redact_preview output)
  in
  Some redacted

(* A tool output that is a JSON document must not be cut at a byte boundary:
   the stored string stops parsing, so the TUI falls back to raw bytes instead
   of the structure (issue #37804). Shrink the document itself — drop trailing
   members/elements and mark the cut — so the stored value stays valid JSON.
   [budget] is a byte budget for the serialized form. *)
let rec shrink_json_to_budget (budget : int) (json : Yojson.Safe.t) : Yojson.Safe.t =
  if String.length (Yojson.Safe.to_string json) <= budget then json
  else
    match json with
    | `Assoc fields ->
      let rec keep acc budget = function
        | [] -> List.rev acc
        | (key, value) :: rest ->
          let value' = shrink_json_to_budget (max 8 (budget / 2)) value in
          let acc' = (key, value') :: acc in
          if String.length (Yojson.Safe.to_string (`Assoc (List.rev acc'))) <= budget
          then keep acc' budget rest
          else List.rev acc
      in
      `Assoc
        (keep [] (max 8 (budget - 24)) fields @ [ ("_truncated", `Bool true) ])
    | `List items ->
      let rec keep acc budget = function
        | [] -> List.rev acc
        | value :: rest ->
          let value' = shrink_json_to_budget (max 8 (budget / 2)) value in
          let acc' = value' :: acc in
          if String.length (Yojson.Safe.to_string (`List (List.rev acc'))) <= budget
          then keep acc' budget rest
          else List.rev acc
      in
      `List (keep [] (max 8 (budget - 24)) items @ [ `String "..." ])
    | `String s ->
      let cut =
        String_util.utf8_char_boundary s
          (min (String.length s) (max 0 (budget - 2)))
      in
      `String (String.sub s 0 cut)
    | (`Null | `Bool _ | `Int _ | `Intlit _ | `Float _) as scalar -> scalar
;;

let truncate_json_document ?(max_len = default_max_len) (s : string) : string =
  if String.length s <= max_len then redact_preview ~max_len s
  else
    match Yojson.Safe.from_string s with
    | exception Yojson.Json_error _ -> redact_preview ~max_len s
    | json ->
      json |> redact_json_value |> shrink_json_to_budget max_len
      |> Yojson.Safe.to_string |> redact_patterns
;;


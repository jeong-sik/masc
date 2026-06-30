(** Stable tool-call progress identity for no-progress detection. *)

type io_fingerprints =
  { input_fingerprint : string
  ; output_fingerprint : string
  }

type call =
  { tool_name : string
  ; typed_outcome : Keeper_tool_outcome.t option
  ; task_id : string option
  ; input_fingerprint : string option
  ; output_fingerprint : string option
  }

type t = string

let volatile_json_keys =
  [ "approval_id"
  ; "created_at"
  ; "duration_ms"
  ; "execution_id"
  ; "keeper_turn_id"
  ; "latency_ms"
  ; "nonce"
  ; "requested_at"
  ; "requested_at_iso"
  ; "rule_id"
  ; "session_id"
  ; "tool_use_id"
  ; "trace_id"
  ; "ts"
  ; "turn"
  ; "updated_at"
  ]
;;

let is_volatile_json_key key =
  List.exists (String.equal key) volatile_json_keys
;;

let sort_json_fields fields =
  List.stable_sort (fun (left, _) (right, _) -> String.compare left right) fields
;;

let rec normalize_json = function
  | `Assoc fields ->
    fields
    |> List.filter (fun (key, _) -> not (is_volatile_json_key key))
    |> List.map (fun (key, value) -> key, normalize_json value)
    |> sort_json_fields
    |> fun fields -> `Assoc fields
  | `List items -> `List (List.map normalize_json items)
  | (`Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _) as json -> json
;;

let sha256_hex raw = Digestif.SHA256.(digest_string raw |> to_hex)

let digest_json json =
  json |> normalize_json |> Yojson.Safe.to_string |> sha256_hex
;;

let redacted_input input =
  input
  |> Observability_redact.redact_json_value
  |> Observability_redact.redact_json_strings
;;

let digest_tool_input ~tool_name input =
  if Observability_redact.is_denied_tool ~tool_name
  then None
  else Some (digest_json (redacted_input input))
;;

let stored_output_identity_json ~sha256 ~bytes ~mime =
  `Assoc
    [ "kind", `String "stored"
    ; "sha256", `String sha256
    ; "bytes", `Int bytes
    ; "mime", `String mime
    ]
;;

let inline_output_fingerprint value =
  let text =
    value
    |> Safe_ops.sanitize_text_utf8
    |> Observability_redact.redact_preview ~max_len:4000
  in
  try Some (digest_json (Yojson.Safe.from_string text |> Observability_redact.redact_json_strings))
  with
  | Yojson.Json_error _ -> Some (sha256_hex text)
;;

let output_fingerprint output_text =
  match Tool_output.decode_from_oas output_text with
  | Tool_output.Stored { sha256; bytes; mime; _ } ->
    Some (digest_json (stored_output_identity_json ~sha256 ~bytes ~mime))
  | Tool_output.Inline value -> inline_output_fingerprint value
;;

let digest_tool_output ~tool_name output_text =
  if Observability_redact.is_denied_tool ~tool_name
  then None
  else output_fingerprint output_text
;;

let digest_tool_io ~tool_name ~input ~output_text =
  match digest_tool_input ~tool_name input, digest_tool_output ~tool_name output_text with
  | Some input_fingerprint, Some output_fingerprint ->
    Some { input_fingerprint; output_fingerprint }
  | None, _ | _, None -> None
;;

let outcome_identity (outcome : Keeper_tool_outcome.t option) =
  match outcome with
  | None -> `String "none"
  | Some outcome -> Keeper_tool_outcome.to_json outcome
;;

let call_identity_json (call : call) =
  match call.input_fingerprint, call.output_fingerprint with
  | Some input_fingerprint, Some output_fingerprint ->
    Some
      (`Assoc
          [ ( "tool_name"
            , `String (Keeper_tool_resolution.canonical_tool_name call.tool_name) )
          ; "typed_outcome", outcome_identity call.typed_outcome
          ; "input_fingerprint", `String input_fingerprint
          ; "output_fingerprint", `String output_fingerprint
          ; "task_id", Json_util.string_opt_to_json call.task_id
          ])
  | None, _ | _, None -> None
;;

let of_calls calls =
  let rec collect acc = function
    | [] -> (
      (match acc with
       | [] -> None
       | _ :: _ ->
         let items =
           acc
           |> List.map Yojson.Safe.to_string
           |> List.sort String.compare
           |> List.map (fun raw -> `String raw)
         in
         Some (digest_json (`List items))))
    | call :: rest ->
      (match call_identity_json call with
       | Some json -> collect (json :: acc) rest
       | None -> None)
  in
  collect [] calls
;;

let equal = String.equal
let to_string t = t

module For_testing = struct
  let normalize_json = normalize_json
end

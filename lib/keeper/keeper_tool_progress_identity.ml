(** Opaque tool I/O fingerprints for observability. *)

type io_fingerprints =
  { input_fingerprint : string
  ; output_fingerprint : string
  }

let sort_json_fields fields =
  List.stable_sort (fun (left, _) (right, _) -> String.compare left right) fields
;;

let rec normalize_json = function
  | `Assoc fields ->
    fields
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

let digest_tool_input ~tool_name:_ input =
  Some (digest_json (redacted_input input))
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
  Some (sha256_hex text)
;;

let output_fingerprint output_text =
  match Tool_output.decode_from_oas output_text with
  | Tool_output.Stored { sha256; bytes; mime; _ } ->
    Some (digest_json (stored_output_identity_json ~sha256 ~bytes ~mime))
  | Tool_output.Inline value -> inline_output_fingerprint value
;;

let digest_tool_output ~tool_name:_ output_text =
  output_fingerprint output_text
;;

let digest_tool_io ~tool_name ~input ~output_text =
  match digest_tool_input ~tool_name input, digest_tool_output ~tool_name output_text with
  | Some input_fingerprint, Some output_fingerprint ->
    Some { input_fingerprint; output_fingerprint }
  | None, _ | _, None -> None
;;

module For_testing = struct
  let normalize_json = normalize_json
end

module Exact_output = Agent_core.Exact_output

(* AGENT_CORE renders the exact-output error family
   ([Exact_output.flow_execution_error_to_string] and its leaves). What it
   cannot do is redact a provider body, so masc passes this excerpt as the
   [raw_response_to_string] argument.

   Log lines are single-line records; the excerpt bound keeps one failed call
   from flooding them while the sha256 keeps the full body identifiable in
   wire captures. Provider bodies can echo prompt, memory, or credential
   material, so the excerpt passes through [Observability_redact.redact_text]
   before any truncation — cutting first could split a secret across the
   boundary where the redactor no longer matches it. The cut itself lands on
   a UTF-8 character boundary so the log line stays valid UTF-8 for the log
   ring and its JSON serialization. Byte count and sha256 always describe
   the original wire body, not the redacted excerpt. *)
let raw_response_excerpt_max_bytes = 240

let raw_response_excerpt = function
  | None -> "raw_response=none"
  | Some (raw : Exact_output.raw_response) ->
    let flattened =
      String.map
        (fun char ->
           if Char.equal char '\n' || Char.equal char '\r' then ' ' else char)
        raw.body
    in
    let redacted = Observability_redact.redact_text flattened in
    if String.length redacted <= raw_response_excerpt_max_bytes
    then Printf.sprintf "raw_response=%s" redacted
    else
      Printf.sprintf
        "raw_response=%s... (%d bytes total sha256=%s)"
        (String_util.utf8_prefix
           ~max_bytes:raw_response_excerpt_max_bytes
           redacted)
        (String.length raw.body)
        raw.body_sha256
;;

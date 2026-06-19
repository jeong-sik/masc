(* Legacy OpenAI-compatible protocol aliases [provider_d-http] / [provider-d-cli]
   were renamed to [openai-compatible-http] / [openai-compatible-cli]
   (CHANGELOG v0.19.43, 2026-06-12). The parser rejects the legacy spellings
   outright via [Runtime_toml.api_format_of_protocol] — there is no
   canonicalization branch — so a checked-in config still using an old label
   fails to load: [Runtime.init_default] returns [Error] with no silent
   fallback.

   This locks that rejection. The .mli for [api_format_of_protocol] previously
   claimed legacy provider-letter aliases were "accepted for live config
   compatibility"; the code has no such branch, so that claim was stale and is
   corrected alongside this test.

   Driven through the public [parse_string] entry. The canonical and legacy
   TOMLs differ only in the protocol value, isolating it as the cause; the
   legacy cases additionally assert the error message names the unknown
   protocol, pinning the protocol field (not transport) as the failure. *)

open Alcotest

let toml_with_protocol proto =
  Printf.sprintf
    {|[providers.p]
protocol = "%s"
endpoint = "https://example.com"
|}
    proto

let is_ok = function Ok _ -> true | Error _ -> false

(* Stdlib has no substring search; this is a plain left-to-right scan. *)
let contains ~needle haystack =
  let nl = String.length needle in
  let hl = String.length haystack in
  let rec go i =
    i + nl <= hl
    && (String.equal (String.sub haystack i nl) needle || go (i + 1))
  in
  nl = 0 || go 0

let rejected_as_unknown_protocol toml =
  match Runtime_toml.parse_string toml with
  | Ok _ -> false
  | Error errs ->
    List.exists
      (fun (err : Runtime_toml.parse_error) ->
        contains ~needle:"unknown protocol" err.message)
      errs

let test_canonical_http_loads () =
  check bool "canonical openai-compatible-http loads" true
    (is_ok (Runtime_toml.parse_string (toml_with_protocol "openai-compatible-http")))

let test_legacy_http_alias_rejected () =
  check bool "legacy provider_d-http rejected as unknown protocol" true
    (rejected_as_unknown_protocol (toml_with_protocol "provider_d-http"))

let test_legacy_cli_alias_rejected () =
  check bool "legacy provider-d-cli rejected as unknown protocol" true
    (rejected_as_unknown_protocol (toml_with_protocol "provider-d-cli"))

let () =
  run "legacy_protocol_alias_rejected"
    [
      ( "parse_string",
        [
          test_case "canonical http loads" `Quick test_canonical_http_loads;
          test_case "legacy provider_d-http rejected" `Quick
            test_legacy_http_alias_rejected;
          test_case "legacy provider-d-cli rejected" `Quick
            test_legacy_cli_alias_rejected;
        ] );
    ]

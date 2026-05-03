(** Verifier_core — Pure verification types, parsing, and read-only detection.

    No Agent_sdk or OAS dependency. Extracted from verifier_oas.ml to enforce
    the MASC-OAS boundary: core domain logic stays OAS-free.

    @since 2.61.0 (verifier core)
    @since 2.223.0 (structured verdict via report_verdict tool)
    @since 2.233.0 (extracted from verifier_oas.ml) *)

open Printf

(* ================================================================ *)
(* Types                                                            *)
(* ================================================================ *)

type verification_request = {
  action_description : string;
  action_result : string;
  goal : string;
  context_summary : string;
}

type verdict =
  | Pass
  | Warn of string
  | Fail of string

(* ================================================================ *)
(* Read-Only Detection                                              *)
(* ================================================================ *)

let read_only_patterns = [
  "read"; "glob"; "grep";
  "search"; "find"; "list"; "ls"; "cat"; "head"; "tail";
  "git status"; "git log"; "git diff";
  "status"; "view"; "get"; "fetch"; "query";
]

let is_word_char c =
  match c with
  | 'a' .. 'z' | 'A' .. 'Z' | '0' .. '9' | '_' -> true
  | _ -> false

let has_pattern_with_word_boundary ~text ~pat =
  let tlen = String.length text in
  let plen = String.length pat in
  if plen = 0 || tlen < plen then false
  else
    let rec loop i =
      if i > tlen - plen then false
      else if String.sub text i plen = pat then
        let before_ok = i = 0 || not (is_word_char text.[i - 1]) in
        let after_idx = i + plen in
        let after_ok = after_idx >= tlen || not (is_word_char text.[after_idx]) in
        if before_ok && after_ok then true else loop (i + 1)
      else
        loop (i + 1)
    in
    loop 0

let should_skip ~action_description =
  let text = String.lowercase_ascii action_description in
  List.exists (fun pat ->
    has_pattern_with_word_boundary ~text ~pat
  ) read_only_patterns

(* ================================================================ *)
(* Verdict Parsing                                                  *)
(* ================================================================ *)

let verdict_to_string = function
  | Pass -> "PASS"
  | Warn reason -> sprintf "WARN: %s" reason
  | Fail reason -> sprintf "FAIL: %s" reason

(** Issue #8436: schema enum for [verdict] used to be hand-rolled as
    a 3-element string list. Payload-bearing variants ([Warn _],
    [Fail _]) prevent the simple [List.map verdict_to_string list]
    trick (it would emit [WARN: <reason>] etc.). Instead we expose the
    canonical constructor names directly + a witness function that
    [test_types.ml] uses to assert every variant maps to a name in
    [valid_verdict_strings]. Adding a 4th constructor will fail
    compilation in [verdict_to_string] and in [verdict_constructor_name]. *)
let verdict_constructor_name = function
  | Pass -> "PASS"
  | Warn _ -> "WARN"
  | Fail _ -> "FAIL"

let valid_verdict_strings = [ "PASS"; "WARN"; "FAIL" ]

let has_keyword_boundary upper len =
  let tlen = String.length upper in
  len >= tlen || not (is_word_char upper.[len])

let extract_reason trimmed keyword_len default_reason =
  let reason =
    if String.length trimmed > keyword_len + 1 then
      String.trim (String.sub trimmed (keyword_len + 1) (String.length trimmed - keyword_len - 1))
    else default_reason
  in
  if String.length reason > 0 && (reason.[0] = ':' || reason.[0] = '-') then
    String.trim (String.sub reason 1 (String.length reason - 1))
  else reason

let parse_verdict (text : string) : (verdict, string) result =
  let trimmed = String.trim text in
  let upper = String.uppercase_ascii trimmed in
  let len = String.length upper in
  if String.starts_with upper ~prefix:"PASS" && has_keyword_boundary upper 4 then
    Ok Pass
  else if String.starts_with upper ~prefix:"WARN" && has_keyword_boundary upper 4 then
    Ok (Warn (extract_reason trimmed 4 "unspecified concern"))
  else if String.starts_with upper ~prefix:"FAIL" && has_keyword_boundary upper 4 then
    Ok (Fail (extract_reason trimmed 4 "action did not achieve goal"))
  else if len = 0 then
    Error "empty verifier output"
  else
    Error (sprintf "unrecognized verdict format: %s"
      (let _ = len in
       String_util.utf8_safe ~max_bytes:83 ~suffix:"..." trimmed
       |> String_util.to_string))

(* ================================================================ *)
(* Structured Verdict: Tool Schema + JSON Parsing (ADR D3)          *)
(* ================================================================ *)

let report_verdict_schema : Types.tool_schema =
  { name = "report_verdict";
    description =
      "Report your verification verdict. You MUST call this tool \
       with your assessment. verdict must be exactly PASS, WARN, or FAIL.";
    input_schema = `Assoc [
      "type", `String "object";
      "properties", `Assoc [
        "verdict", `Assoc [
          "type", `String "string";
          (* Issue #8436: derived from Variant SSOT. Hand-rolled enum
             risks dropping a constructor on extension. *)
          "enum", `List (List.map (fun s -> `String s) valid_verdict_strings);
          "description", `String "PASS if correct, WARN if acceptable with concerns, FAIL if wrong or harmful";
        ];
        "reason", `Assoc [
          "type", `String "string";
          "description", `String "Brief explanation for the verdict (required for WARN and FAIL)";
        ];
      ];
      "required", `List [`String "verdict"];
    ];
  }

let parse_verdict_from_json (args : Yojson.Safe.t) : (verdict, string) result =
  let open Yojson.Safe.Util in
  try
    let verdict_str =
      args |> member "verdict" |> to_string |> String.uppercase_ascii
    in
    let reason =
      try args |> member "reason" |> to_string
      with Type_error _ -> ""
    in
    match verdict_str with
    | "PASS" -> Ok Pass
    | "WARN" ->
      let r = if reason = "" then "unspecified concern" else reason in
      Ok (Warn r)
    | "FAIL" ->
      let r = if reason = "" then "action did not achieve goal" else reason in
      Ok (Fail r)
    | other ->
      Error (sprintf "unexpected verdict value: %s" other)
  with
  | Type_error (msg, _) ->
    Error (sprintf "verdict JSON type error: %s" msg)
  | exn ->
    Error (sprintf "verdict JSON parse error: %s" (Printexc.to_string exn))

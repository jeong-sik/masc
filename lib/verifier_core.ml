(** Verifier_core — Pure verification types and structured verdict parsing.

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

type grounded_ref = {
  path : string;
  line : int option;
  quote : string;
}

type grounded_verdict = {
  verdict : verdict;
  evidence : grounded_ref list;
}

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

let validate_grounded_ref idx (ref_ : grounded_ref) =
  let path = String.trim ref_.path in
  let quote = String.trim ref_.quote in
  if path = "" then Error (sprintf "evidence[%d].path is required" idx)
  else if quote = "" then Error (sprintf "evidence[%d].quote is required" idx)
  else
    match ref_.line with
    | Some line when line <= 0 ->
      Error (sprintf "evidence[%d].line must be >= 1" idx)
    | Some _ | None -> Ok ()

let validate_grounded_refs refs =
  let rec loop idx = function
    | [] -> Ok ()
    | ref_ :: rest -> (
      match validate_grounded_ref idx ref_ with
      | Error _ as e -> e
      | Ok () -> loop (idx + 1) rest)
  in
  loop 0 refs

let grounded_of verdict evidence =
  match verdict with
  | Pass -> Ok { verdict; evidence = [] }
  | Warn _ | Fail _ ->
    if evidence = [] then
      Error "WARN/FAIL verdicts require at least one evidence item"
    else
      match validate_grounded_refs evidence with
      | Error _ as e -> e
      | Ok () -> Ok { verdict; evidence }

let reason_field = function
  | Pass -> []
  | Warn reason | Fail reason -> [ ("reason", `String reason) ]

let grounded_ref_to_yojson ref_ =
  `Assoc
    [
      ("path", `String ref_.path);
      ( "line",
        match ref_.line with
        | Some line -> `Int line
        | None -> `Null );
      ("quote", `String ref_.quote);
    ]

let grounded_verdict_to_yojson grounded =
  `Assoc
    ([
       ("verdict", `String (verdict_constructor_name grounded.verdict));
       ( "evidence",
         `List (List.map grounded_ref_to_yojson grounded.evidence) );
     ]
     @ reason_field grounded.verdict)

(* ================================================================ *)
(* Structured Verdict: Tool Schema + JSON Parsing (ADR D3)          *)
(* ================================================================ *)

let report_verdict_schema : Masc_domain.tool_schema =
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
        "evidence", `Assoc [
          "type", `String "array";
          "description", `String "Optional grounding references: each item cites a repo-relative path, optional 1-based line, and verbatim quote";
          "items", `Assoc [
            "type", `String "object";
            "properties", `Assoc [
              "path", `Assoc [
                "type", `String "string";
                "description", `String "Repo-relative file path inspected by the reviewer";
              ];
              "line", `Assoc [
                "type", `String "integer";
                "minimum", `Int 1;
                "description", `String "Optional 1-based line number";
              ];
              "quote", `Assoc [
                "type", `String "string";
                "description", `String "Verbatim excerpt from the cited file";
              ];
            ];
            "required", `List [ `String "path"; `String "quote" ];
          ];
        ];
      ];
      "required", `List [`String "verdict"];
    ];
  }

let parse_verdict_from_json (args : Yojson.Safe.t) : (verdict, string) result =
  try
    let verdict_str =
      Json_util.get_string args "verdict"
      |> Option.value ~default:""
    in
    let reason =
      Json_util.get_string args "reason"
      |> Option.value ~default:""
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
  | Yojson.Safe.Util.Type_error (msg, _) ->
    Error (sprintf "verdict JSON type error: %s" msg)
  | exn ->
    Error (sprintf "verdict JSON parse error: %s" (Printexc.to_string exn))

let parse_evidence_line ~idx json =
  match Json_util.assoc_member_opt "line" json with
  | None | Some `Null -> Ok None
  | Some (`Int line) when line > 0 -> Ok (Some line)
  | Some (`Intlit raw) -> (
    match int_of_string_opt raw with
    | Some line when line > 0 -> Ok (Some line)
    | _ -> Error (sprintf "evidence[%d].line must be >= 1" idx))
  | Some (`Int _) -> Error (sprintf "evidence[%d].line must be >= 1" idx)
  | Some other ->
    Error
      (sprintf "evidence[%d].line must be an integer, got %s" idx
         (Json_util.kind_name other))

let parse_evidence_item idx = function
  | `Assoc _ as json -> (
    match Json_util.require_string json "path" with
    | Error msg -> Error (sprintf "evidence[%d]: %s" idx msg)
    | Ok path -> (
      match Json_util.require_string json "quote" with
      | Error msg -> Error (sprintf "evidence[%d]: %s" idx msg)
      | Ok quote -> (
        match parse_evidence_line ~idx json with
        | Error _ as e -> e
        | Ok line ->
          let ref_ = { path; line; quote } in
          match validate_grounded_ref idx ref_ with
          | Error _ as e -> e
          | Ok () -> Ok ref_)))
  | other ->
    Error
      (sprintf "evidence[%d] must be an object, got %s" idx
         (Json_util.kind_name other))

let parse_evidence_from_json args =
  match Json_util.assoc_member_opt "evidence" args with
  | None | Some `Null -> Ok []
  | Some (`List items) ->
    let rec loop idx acc = function
      | [] -> Ok (List.rev acc)
      | item :: rest -> (
        match parse_evidence_item idx item with
        | Error _ as e -> e
        | Ok ref_ -> loop (idx + 1) (ref_ :: acc) rest)
    in
    loop 0 [] items
  | Some other ->
    Error (sprintf "evidence must be an array, got %s" (Json_util.kind_name other))

let parse_grounded_verdict_from_json args =
  match parse_verdict_from_json args with
  | Error _ as e -> e
  | Ok Pass -> grounded_of Pass []
  | Ok verdict -> (
    match parse_evidence_from_json args with
    | Error _ as e -> e
    | Ok evidence -> grounded_of verdict evidence)

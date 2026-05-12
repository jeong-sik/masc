(** RFC-0070 Phase 3b-iv.2.5 — unit tests for {!Docker_ps_parser}.

    Each of the 4 enumerated silent-drop paths
    (empty / Yojson.Json_error / schema-mismatch / unknown State) is
    exercised individually with synthetic JSON fixtures so the parser
    contract is pinned independently of docker daemon state. *)

open Alcotest
open Masc_mcp

(* Synthetic line that matches docker's [--format '{{json .}}']
   emission shape closely enough for the parser: required fields
   (ID, Names, State, Labels) plus a few unknown fields that the
   [strict = false] yojson derivation must tolerate. *)
let happy_line ~name ~state ~labels =
  Printf.sprintf
    {|{"ID":"abc123","Names":"%s","State":"%s","Labels":"%s","CreatedAt":"2026-05-12 09:00:00 +0900 KST","Status":"Up 5 minutes","Ports":""}|}
    name
    state
    labels
;;

(* ── parse_labels ────────────────────────────────────────────── *)

let test_parse_labels_empty () =
  let actual = Docker_ps_parser.parse_labels "" in
  check (list (pair string string)) "empty → []" [] actual
;;

let test_parse_labels_single () =
  let actual = Docker_ps_parser.parse_labels "k=v" in
  check (list (pair string string)) "single pair" [ "k", "v" ] actual
;;

let test_parse_labels_multi_preserves_order () =
  let actual = Docker_ps_parser.parse_labels "z=last,a=first,m=mid" in
  (* Order-preserving per .mli contract — caller must canonicalise
     if comparing via Docker_response.equal_ps_record. *)
  check
    (list (pair string string))
    "docker emission order preserved"
    [ "z", "last"; "a", "first"; "m", "mid" ]
    actual
;;

let test_parse_labels_drops_no_equals_token () =
  let actual = Docker_ps_parser.parse_labels "good=ok,malformed,also=fine" in
  (* "malformed" has no '=' — dropped silently. NOT mapped to
     ("malformed", "") which would be a permissive default. *)
  check
    (list (pair string string))
    "tokens without '=' dropped, not given empty-value default"
    [ "good", "ok"; "also", "fine" ]
    actual
;;

let test_parse_labels_empty_value_allowed () =
  let actual = Docker_ps_parser.parse_labels "key=" in
  (* '=' present but value empty — that IS a valid (key, "") pair.
     Distinct from the "no =" drop case above. *)
  check (list (pair string string)) "trailing '=' → empty value" [ "key", "" ] actual
;;

let test_parse_labels_value_contains_equals () =
  let actual = Docker_ps_parser.parse_labels "url=https://x.com/?a=b" in
  (* Only the FIRST '=' splits — subsequent '=' chars stay in value.
     This matches docker's behaviour and protects label values that
     happen to contain '='. *)
  check
    (list (pair string string))
    "split on first '=' only"
    [ "url", "https://x.com/?a=b" ]
    actual
;;

(* ── parse_line — 4 enumerated silent-drop paths ─────────────── *)

let test_parse_line_drop_empty () =
  check (option (of_pp Fmt.nop)) "empty line → None" None (Docker_ps_parser.parse_line "");
  check
    (option (of_pp Fmt.nop))
    "whitespace-only line → None"
    None
    (Docker_ps_parser.parse_line "   \t  ")
;;

let test_parse_line_drop_malformed_json () =
  (* Drop path 2: Yojson.Json_error. Caught and converted to None. *)
  check
    (option (of_pp Fmt.nop))
    "non-JSON line → None"
    None
    (Docker_ps_parser.parse_line "not a json line at all");
  check
    (option (of_pp Fmt.nop))
    "truncated JSON → None"
    None
    (Docker_ps_parser.parse_line "{\"ID\":\"abc\"")
;;

let test_parse_line_drop_schema_mismatch () =
  (* Drop path 3: valid JSON but missing required fields. *)
  check
    (option (of_pp Fmt.nop))
    "JSON without required keys → None"
    None
    (Docker_ps_parser.parse_line {|{"foo":"bar"}|});
  check
    (option (of_pp Fmt.nop))
    "JSON missing one required key (Labels) → None"
    None
    (Docker_ps_parser.parse_line {|{"ID":"x","Names":"n","State":"running"}|})
;;

let test_parse_line_drop_unknown_state () =
  (* Drop path 4: schema-valid but State not in {Created, Running,
     Paused, Restarting, Exited, Dead}. *)
  check
    (option (of_pp Fmt.nop))
    "unknown State → None"
    None
    (Docker_ps_parser.parse_line (happy_line ~name:"x" ~state:"zombie" ~labels:""))
;;

(* ── parse_line — happy path ─────────────────────────────────── *)

let test_parse_line_happy_running () =
  match
    Docker_ps_parser.parse_line
      (happy_line ~name:"masc-keeper-abc" ~state:"running" ~labels:"k=v")
  with
  | None -> fail "expected Some on well-formed input"
  | Some record ->
    check string "id preserved" "abc123" record.Docker_response.id;
    check
      string
      "name unsafe-wrapped from external string"
      "masc-keeper-abc"
      (Keeper_container_name.to_string record.Docker_response.name);
    check
      bool
      "state parsed to typed variant Running"
      true
      Docker_response.(equal_ps_status record.status Running);
    check (list (pair string string)) "labels parsed" [ "k", "v" ] record.labels
;;

let test_parse_line_happy_all_states () =
  (* Each of the 6 valid State tokens accepted by Docker_response.parse_state
     must round-trip through parse_line. *)
  let cases =
    [ "created", Docker_response.Created
    ; "running", Docker_response.Running
    ; "paused", Docker_response.Paused
    ; "restarting", Docker_response.Restarting
    ; "exited", Docker_response.Exited
    ; "dead", Docker_response.Dead
    ]
  in
  List.iter
    (fun (token, expected) ->
       match
         Docker_ps_parser.parse_line (happy_line ~name:"x" ~state:token ~labels:"")
       with
       | None -> failf "state token %S unexpectedly dropped" token
       | Some r ->
         check
           bool
           (Printf.sprintf "state %S → typed" token)
           true
           (Docker_response.equal_ps_status r.status expected))
    cases
;;

let test_parse_line_unknown_fields_tolerated () =
  (* [@@deriving yojson { strict = false }] should accept lines with
     fields not in the required-subset schema (CreatedAt, Status,
     Ports, Image, Command, ...) without dropping. *)
  let line =
    {|{"ID":"x","Names":"n","State":"running","Labels":"","CreatedAt":"now","Status":"Up","Ports":"","Image":"alpine","Command":"sh","Mounts":"","Networks":"bridge","Size":"0B","RunningFor":"1m","LocalVolumes":"0","LogStatus":"none"}|}
  in
  match Docker_ps_parser.parse_line line with
  | None -> fail "unknown fields should be tolerated by strict=false"
  | Some _ -> ()
;;

(* ── parse_output ────────────────────────────────────────────── *)

let test_parse_output_empty () =
  check int "empty stdout → []" 0 (List.length (Docker_ps_parser.parse_output ""));
  check
    int
    "whitespace-only stdout → []"
    0
    (List.length (Docker_ps_parser.parse_output "\n\n  \n"))
;;

let test_parse_output_mixed () =
  (* Realistic stress: 2 happy lines + 1 of each drop type. *)
  let stdout =
    String.concat
      "\n"
      [ happy_line ~name:"k1" ~state:"running" ~labels:"app=keeper"
      ; "" (* drop: empty *)
      ; "not json" (* drop: Yojson error *)
      ; {|{"foo":"bar"}|} (* drop: schema *)
      ; happy_line ~name:"k2" ~state:"alien" ~labels:"" (* drop: unknown state *)
      ; happy_line ~name:"k3" ~state:"exited" ~labels:""
      ]
  in
  let records = Docker_ps_parser.parse_output stdout in
  check int "2 happy + 4 drops → 2 records" 2 (List.length records);
  match records with
  | [ r1; r2 ] ->
    check
      string
      "first record name"
      "k1"
      (Keeper_container_name.to_string r1.Docker_response.name);
    check
      string
      "second record name (skipping all 4 drops)"
      "k3"
      (Keeper_container_name.to_string r2.Docker_response.name)
  | _ -> fail "expected exactly 2 records"
;;

(* ── Suite ───────────────────────────────────────────────────── *)

let () =
  run
    "Docker_ps_parser (Phase 3b-iv.2.5)"
    [ ( "parse_labels"
      , [ test_case "empty → []" `Quick test_parse_labels_empty
        ; test_case "single k=v" `Quick test_parse_labels_single
        ; test_case
            "preserves docker emission order"
            `Quick
            test_parse_labels_multi_preserves_order
        ; test_case
            "drops tokens without '='"
            `Quick
            test_parse_labels_drops_no_equals_token
        ; test_case
            "trailing '=' → empty value"
            `Quick
            test_parse_labels_empty_value_allowed
        ; test_case
            "splits on first '=' only"
            `Quick
            test_parse_labels_value_contains_equals
        ] )
    ; ( "parse_line silent-drop paths"
      , [ test_case "drop 1: empty line" `Quick test_parse_line_drop_empty
        ; test_case "drop 2: malformed JSON" `Quick test_parse_line_drop_malformed_json
        ; test_case "drop 3: schema mismatch" `Quick test_parse_line_drop_schema_mismatch
        ; test_case "drop 4: unknown State" `Quick test_parse_line_drop_unknown_state
        ] )
    ; ( "parse_line happy paths"
      , [ test_case "running state + labels" `Quick test_parse_line_happy_running
        ; test_case "all 6 valid State tokens" `Quick test_parse_line_happy_all_states
        ; test_case
            "strict=false tolerates unknown fields"
            `Quick
            test_parse_line_unknown_fields_tolerated
        ] )
    ; ( "parse_output"
      , [ test_case "empty / whitespace-only stdout" `Quick test_parse_output_empty
        ; test_case "mixed happy + all 4 drops" `Quick test_parse_output_mixed
        ] )
    ]
;;

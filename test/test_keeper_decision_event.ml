(** Tests for the typed keeper decision-log projection
    ([Dashboard_http_keeper_feeds.parse_decision_event] /
    [decision_event_to_yojson]). The feed routes themselves are not unit-testable
    here (they need a live workspace), but extracting the per-line transform into a
    pure typed parse makes exactly that transform testable — which is the point
    of parsing into a record at the boundary. These pin field extraction, the
    keeper-name fallback, malformed-line rejection, and that the rendered payload
    keeps the field set/values the dashboard depends on. *)

open Alcotest
module F = Dashboard_http_keeper_feeds

let member key (json : Yojson.Safe.t) : Yojson.Safe.t option =
  match json with `Assoc fields -> List.assoc_opt key fields | _ -> None

let contains haystack needle =
  let hl = String.length haystack and nl = String.length needle in
  let rec loop i =
    if i + nl > hl then false
    else if String.sub haystack i nl = needle then true
    else loop (i + 1)
  in
  nl = 0 || loop 0

let sample =
  {|{"ts_unix": 100.5, "id": "d1", "ts": "2020-01-01T00:00:00Z", "outcome": "decide", "channel": "board", "duration_ms": 42, "evidence_refs": ["e1", "e2"]}|}

let test_parse_fields () =
  match F.parse_decision_event ~keeper_name:"fallback-k" sample with
  | None -> Alcotest.fail "expected a parsed decision_event"
  | Some ev ->
      check string "id" "d1" ev.F.id;
      check string "ts" "2020-01-01T00:00:00Z" ev.F.ts;
      check (float 0.0001) "ts_unix" 100.5 ev.F.ts_unix;
      check string "keeper falls back to argument" "fallback-k" ev.F.keeper;
      check string "decision_type from outcome" "decide" ev.F.decision_type;
      check (option (float 0.0001)) "duration_ms" (Some 42.0) ev.F.duration_ms;
      check (list string) "evidence_refs" [ "e1"; "e2" ] ev.F.evidence_refs;
      check bool "summary mentions channel" true (contains ev.F.summary "via board")

let test_render_payload () =
  match F.parse_decision_event ~keeper_name:"fallback-k" sample with
  | None -> Alcotest.fail "expected a parsed decision_event"
  | Some ev ->
      let json = F.decision_event_to_yojson ev in
      check (option string) "rendered id"
        (Some "d1")
        (match member "id" json with Some (`String s) -> Some s | _ -> None);
      check (option string) "rendered decision_type"
        (Some "decide")
        (match member "decision_type" json with
         | Some (`String s) -> Some s
         | _ -> None);
      check bool "rendered duration_ms is 42" true
        (match member "duration_ms" json with
         | Some (`Float f) -> Float.abs (f -. 42.0) < 0.0001
         | _ -> false);
      check bool "rendered evidence_refs preserved" true
        (match member "evidence_refs" json with
         | Some (`List [ `String "e1"; `String "e2" ]) -> true
         | _ -> false)

let test_keeper_name_from_line () =
  let line = {|{"ts_unix": 1.0, "id": "d2", "ts": "t", "keeper_name": "real-k"}|} in
  match F.parse_decision_event ~keeper_name:"fallback-k" line with
  | Some ev -> check string "keeper_name in line wins" "real-k" ev.F.keeper
  | None -> Alcotest.fail "expected a parsed event"

let test_malformed_rejected () =
  check bool "non-JSON line -> None" true
    (Option.is_none (F.parse_decision_event ~keeper_name:"k" "not json {"))

let () =
  run "keeper_decision_event"
    [
      ( "typed",
        [
          test_case "parses fields" `Quick test_parse_fields;
          test_case "renders dashboard payload" `Quick test_render_payload;
          test_case "keeper_name in line overrides fallback" `Quick
            test_keeper_name_from_line;
          test_case "malformed line rejected" `Quick test_malformed_rejected;
        ] );
    ]

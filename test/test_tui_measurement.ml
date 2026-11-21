module UI = Masc_tui_types

let envelope content =
  `Assoc [ "sha256", `String (Agent_core_sha256.(to_hex (digest_string content))); "bytes", `Int (String.length content)
         ; "content", `String content ]

let test_temporal_observations () =
  let module T = Masc.Tui_decode_temporal_continuity in
  let sha = String.make 64 'a' in
  let range first_atom = `Assoc ["capture_id", `String "fixture-request";
    "body_sha256", `String sha; "first_atom", `Int first_atom; "summary_end_atom", `Int 5] in
  let omission first_atom = `Assoc ["status", `String "observed";
    "target_boundary", `Assoc ["end_atom", `Int 5]; "requests", `List [range first_atom]] in
  let step ~w ~omitted ~probability ~model = `Assoc [
    "step_id", `String "probe"; "kind", `String "message"; "status", `String "captured";
    "operation_state", `String "Succeeded"; "turn_ref", `String "trace#12";
    "working_state_messages", w; "reply", `List [`String "The corrected observation continues."];
    "working_state", (match w with `Null -> `Null | `Int 0 -> `List [] | _ -> `List [`Assoc []]);
    "prefix_omission", omitted; "target_boundary", `Null;
    "judgments", `List [`Assoc ["criterion_id", `String "latest correction";
      "scope", `String "reply"; "status", `String "measured";
      "probability", probability; "response_model", model]]] in
  let view ?(passed = `Null) row = `Assoc [
    "schema", `String T.schema; "keeper", `String "fixture";
    "provenance", `String "assessment_of_captured_keeper_evidence";
    "measurement_status", `String "incomplete"; "error", `String "later observation unavailable";
    "started_at", `String "2026-10-30T00:00:00Z"; "finished_at", `Null;
    "report_path", `String "/private/report.json"; "report_sha256", `String sha;
    "harness_source_sha256", `String sha; "source_capture_sha256", `String sha;
    "binary_commit", `Null; "executable_sha256", `Null;
    "body_response_binding", `String "not_established";
    "librarian_causal_attribution", `String "not_established";
    "continuity_pass", passed; "timeline", `List [row]] in
  let row = step ~w:`Null ~omitted:(omission 5) ~probability:(`Float 0.) ~model:(`String "actual-judge") in
  (* A wait step carries its saved-state readiness separately from prefix
     omission, and the view carries the campaign-level memory readiness. *)
  let wait_row = `Assoc [
    "step_id", `String "wait"; "kind", `String "await_summary";
    "status", `String "summary_ready_observed";
    "operation_state", `Null; "turn_ref", `String "trace#12";
    "working_state_messages", `Null; "reply", `List [];
    "working_state", `Null;
    "prefix_omission", `Null; "target_boundary", `Assoc ["end_atom", `Int 5];
    "judgments", `List [];
    "summary_readiness", `Assoc ["state", `String "covered"; "end_atom", `Int 5;
      "last_atom_digest", `String sha]] in
  let set field value json = match json with
    | `Assoc fields ->
      if List.exists (fun (key, _) -> String.equal key field) fields
      then `Assoc (List.map (fun (key, old) ->
          if String.equal key field then key, value else key, old) fields)
      else `Assoc (fields @ [field, value])
    | _ -> assert false in
  let content = Yojson.Safe.to_string (view row) in
  let sha256 = Agent_core_sha256.(to_hex (digest_string content)) in
  (match UI.Measurement.decode_artifact ~sha256 (envelope content) with
   | Ok (UI.Measurement.Temporal loaded) ->
     Alcotest.(check bool) "incomplete capture remains incomplete" true (loaded.status = T.Incomplete);
     (match loaded.timeline with
      | [{working_state_messages = None; omission = T.Observed detail;
          judgments = [{result = T.Measured {probability = 0.; model = "actual-judge"}; _}]; _}] ->
        Alcotest.(check int) "exclusive target end retained" 5 detail.target_end_atom
      | _ -> Alcotest.fail "lost unknown W, exact cut or raw boundary probability")
   | Ok _ -> Alcotest.fail "expected temporal view" | Error detail -> Alcotest.fail detail);
  let rejects label json = Alcotest.(check bool) label true (Result.is_error (T.of_yojson json)) in
  (match T.of_yojson
     (set "memory_execution_readiness"
        (`Assoc ["state", `String "operations";
          "operations", `List [`Assoc ["tool", `String "admit_memory";
            "state", `String "addon_unattached"]]])
        (view wait_row)) with
   | Ok { memory_readiness =
            Some (T.Memory_operations [("admit_memory", "addon_unattached")]);
          timeline = [ { readiness =
                           Some (T.Covered { end_atom = 5; last_atom_digest = digest });
                         _ } ];
          _ }
     when String.equal digest sha -> ()
   | Ok _ -> Alcotest.fail "readiness observations were lost or untyped"
   | Error detail -> Alcotest.fail detail);
  rejects "report does not certify pass" (view ~passed:(`Bool true) row);
  (* A step carries the operation API's state word. The five words the server
     writes are read; another case of a word, or a word it never writes, is not. *)
  List.iter (fun word ->
    Alcotest.(check bool) ("operation state " ^ word ^ " is read") true
      (Result.is_ok (T.of_yojson (view (set "operation_state" (`String word) row)))))
    ["Queued"; "Running"; "Succeeded"; "Failed"; "Cancelled"];
  List.iter (fun word ->
    rejects ("operation state " ^ word ^ " is not a server state")
      (view (set "operation_state" (`String word) row)))
    ["queued"; "Paused"];
  rejects "earlier request cannot certify omission"
    (view (step ~w:(`Int 1) ~omitted:(omission 4) ~probability:(`Float 1.) ~model:(`String "actual")));
  rejects "measured probability requires actual model"
    (view (step ~w:(`Int 0) ~omitted:`Null ~probability:(`Float 0.5) ~model:`Null));
  rejects "probability is a bounded raw observation"
    (view (step ~w:`Null ~omitted:`Null ~probability:(`Float 1.1) ~model:(`String "actual")));
  rejects "unsupported readiness state is not readied aside"
    (view (set "summary_readiness"
        (`Assoc ["state", `String "maybe"; "end_atom", `Int 5;
          "last_atom_digest", `String sha]) wait_row))

let () =
  Alcotest.run "TUI measurement artifacts"
    [ "reader", [ Alcotest.test_case "temporal evidence retains uncertainty" `Quick test_temporal_observations ] ]

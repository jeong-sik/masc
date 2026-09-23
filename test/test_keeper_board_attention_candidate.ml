module A = Masc.Keeper_board_attention_candidate
module Event_queue = Keeper_event_queue
module Event_queue_persistence_source = Keeper_event_queue_persistence
module Event_queue_persistence = struct
  include Event_queue_persistence_source

  let load ~base_path ~keeper_name =
    match load_result ~base_path ~keeper_name with
    | Ok queue -> queue
    | Error detail -> Alcotest.fail detail
  ;;
end
module J = Masc.Keeper_board_attention_judgment
module Wake = Masc.Keeper_board_attention_worker_wake

let rec remove_tree path =
  if Sys.file_exists path
  then
    if Sys.is_directory path
    then (
      Sys.readdir path
      |> Array.iter (fun name -> remove_tree (Filename.concat path name));
      Unix.rmdir path)
    else Sys.remove path
;;

let with_temp_base name f =
  let base_path = Filename.temp_dir name "" in
  Fun.protect ~finally:(fun () -> remove_tree base_path) (fun () -> f base_path)
;;

let ok label = function
  | Ok value -> value
  | Error detail -> Alcotest.failf "%s: %s" label detail
;;

let comment_id raw =
  match Masc.Board.Comment_id.of_string raw with
  | Ok id -> id
  | Error error -> Alcotest.fail (Masc.Board.show_board_error error)
;;

(* Every case in this file delivers against a candidate it just persisted, so
   [Candidate_absent] here is a bug in the fixture, not the outcome under
   test — see test_keeper_board_attention_worker.ml for the terminal-settlement
   coverage of an actually-missing candidate. *)
let delivered label = function
  | Ok (A.Delivered candidate) -> candidate
  | Ok A.Candidate_absent ->
    Alcotest.failf "%s: candidate absent (fixture did not persist it)" label
  | Error detail -> Alcotest.failf "%s: %s" label detail
;;

let signal ?(content = "Persisted Board evidence") ?(updated_at = 42.0) post_id :
  Masc.Board_dispatch.board_signal
  =
  { kind = Masc.Board_dispatch.Board_post_created
  ; post_id
  ; author = "external-author"
  ; title = "Board update"
  ; content
  ; hearth = Some "hearth-1"
  ; updated_at = Some updated_at
  }
;;

let keeper_context ?(board_interests = [ "OCaml"; "runtime" ]) () =
  `Assoc
    [ "lane_keeper_name", `String "alpha"
    ; ( "board_interests"
      , `List (List.map (fun interest -> `String interest) board_interests) )
    ]
;;

(* The writer correctly refuses non-finite floats, so render the row textually
   to model out-of-band corruption of an otherwise current-schema ledger and
   verify that the reader fails closed through its recorded_at finite guard. *)
let render_row_with_non_finite ~field ~literal json =
  match json with
  | `Assoc fields ->
    let rendered =
      List.map
        (fun (key, value) ->
           Printf.sprintf
             "%s:%s"
             (Yojson.Safe.to_string (`String key))
             (if String.equal key field then literal else Yojson.Safe.to_string value))
        fields
    in
    Printf.sprintf "{%s}" (String.concat "," rendered)
  | _ -> Alcotest.fail "candidate JSON is not an object"
;;

let candidate ?(context = keeper_context ()) signal :
  A.candidate
  =
  let keeper_name = "alpha" in
  let candidate_id = A.candidate_id_of_signal ~keeper_name signal in
  { candidate_id
  ; keeper_name
  ; signal
  ; keeper_context = context
  ; recorded_at = 1.0
  ; status = A.Pending { last_delivery_failure = None }
  }
;;

let judgment decision : A.judgment =
  { verdict = { J.decision; rationale = "typed structured verdict" }
  ; slot_id = "board-attention-primary"
  ; source =
      A.Exact_attempt
        { call_id = "call-board-attention"
        ; plan_fingerprint = "plan-board-attention"
        ; request_body_sha256 = "request-board-attention"
        }
  ; judged_at = 2.0
  }
;;

let quarantine_state ~phase prior_status : A.quarantine_state =
  { quarantine =
      { quarantine_id = "ba-quarantine-status-view"
      ; partition_id = "ba-partition-status-view"
      ; partition_generation =
          Masc.Keeper_board_attention_partition_generation.initial
      ; failure_category = A.Unexpected_worker_failure
      ; attempt_provenance = None
      ; quarantined_at = 3.0
      ; prior_status
      }
  ; phase
  }
;;

let test_status_view_preserves_resumability_and_quarantine () =
  let pending = A.Resumable_pending { last_delivery_failure = None } in
  (match A.status_view (A.Pending { last_delivery_failure = None }) with
   | A.Direct_resumable observed when observed = pending -> ()
   | A.Direct_resumable _
   | A.Requeued_resumable _
   | A.Suspended_quarantine _ ->
     Alcotest.fail "direct Pending status lost its typed resumable value");
  let suspended = quarantine_state ~phase:A.Quarantined pending in
  (match A.status_view (A.Quarantine suspended) with
   | A.Suspended_quarantine observed when observed = suspended -> ()
   | A.Direct_resumable _
   | A.Requeued_resumable _
   | A.Suspended_quarantine _ ->
     Alcotest.fail "active quarantine was not classified as suspended");
  let requeued =
    quarantine_state ~phase:(A.Requeued { requeued_at = 4.0; requested_by = "operator-test" }) pending
  in
  match A.status_view (A.Quarantine requeued) with
  | A.Requeued_resumable { resumable; quarantine }
    when resumable = pending && quarantine = requeued -> ()
  | A.Direct_resumable _
  | A.Requeued_resumable _
  | A.Suspended_quarantine _ ->
    Alcotest.fail "requeued quarantine lost resumability or quarantine identity"
;;

let invalid_judgment_fixtures () =
  let valid = judgment J.Not_relevant in
  let vendor_provenance : A.system_one_provenance =
    { destination_uri = "https://api.typesafe.ai/v1/systemone"
    ; answering_model_id = "jev-latest"
    ; request_body_sha256 = String.make 64 'a'
    }
  in
  [ ( "blank verdict rationale"
    , { valid with
        verdict = { valid.verdict with rationale = " \t" }
      } )
  ; "blank slot_id", { valid with slot_id = "\n" }
  ; ( "blank call_id"
    , { valid with
        source =
          A.Exact_attempt
            { call_id = " "
            ; plan_fingerprint = "plan-board-attention"
            ; request_body_sha256 = "request-board-attention"
            }
      } )
  ; ( "blank plan_fingerprint"
    , { valid with
        source =
          A.Exact_attempt
            { call_id = "call-board-attention"
            ; plan_fingerprint = "\t"
            ; request_body_sha256 = "request-board-attention"
            }
      } )
  ; ( "blank request_body_sha256"
    , { valid with
        source =
          A.Exact_attempt
            { call_id = "call-board-attention"
            ; plan_fingerprint = "plan-board-attention"
            ; request_body_sha256 = "\r\n"
            }
      } )
  ; ( "blank vendor destination"
    , { valid with
        source =
          A.Vendor_system_one { vendor_provenance with destination_uri = "\t" }
      } )
  ; ( "blank vendor answering model"
    , { valid with
        source =
          A.Vendor_system_one
            { vendor_provenance with answering_model_id = "\t" }
      } )
  ; ( "blank vendor request digest"
    , { valid with
        source =
          A.Vendor_system_one
            { vendor_provenance with request_body_sha256 = "\t" }
      } )
  ; ( "vendor answering model differs from slot_id"
    , { valid with
        source = A.Vendor_system_one vendor_provenance
      } )
  ; "NaN judged_at", { valid with judged_at = Float.nan }
  ; "+Infinity judged_at", { valid with judged_at = Float.infinity }
  ; "-Infinity judged_at", { valid with judged_at = Float.neg_infinity }
  ]
;;

let record ~base_path candidate =
  match A.record ~base_path candidate with
  | A.Recorded candidate -> candidate
  | A.Duplicate _ -> Alcotest.fail "first record was a duplicate"
  | A.Record_error detail -> Alcotest.failf "candidate record failed: %s" detail
;;

let load_one ~base_path =
  match ok "load candidate" (A.load_candidates ~base_path ~keeper_name:"alpha") with
  | [ candidate ] -> candidate
  | candidates -> Alcotest.failf "expected one candidate, got %d" (List.length candidates)
;;

(* A vote signal round-trips through the v7 candidate codec with its payload
   under the [vote] key that only vote rows carry. *)
let test_vote_signal_codec_round_trips_without_widening_other_rows () =
  let vote_signal : Masc.Board_dispatch.board_signal =
    { (signal "post-vote") with
      kind =
        Masc.Board_dispatch.Board_vote_cast
          { target = Masc.Board_dispatch.Vote_on_comment "c-1"
          ; target_author = "alpha-agent"
          ; voter = "external-author"
          ; direction = Masc.Board.Up
          }
    }
  in
  let original = candidate vote_signal in
  let encoded = A.candidate_to_json original in
  Alcotest.(check bool)
    "vote candidate roundtrip"
    true
    (ok "decode vote candidate" (A.candidate_of_json encoded) = original);
  let signal_keys (json : Yojson.Safe.t) =
    match json with
    | `Assoc fields -> List.map fst fields |> List.sort String.compare
    | _ -> Alcotest.fail "signal codec did not produce an object"
  in
  Alcotest.(check (list string))
    "vote row carries the vote key"
    [ "author"
    ; "comment_id"
    ; "content"
    ; "hearth"
    ; "kind"
    ; "parent_id"
    ; "post_id"
    ; "reaction"
    ; "title"
    ; "updated_at"
    ; "vote"
    ]
    (signal_keys (A.signal_to_yojson vote_signal));
  Alcotest.(check (list string))
    "post row keeps the v7 non-vote shape"
    [ "author"
    ; "comment_id"
    ; "content"
    ; "hearth"
    ; "kind"
    ; "parent_id"
    ; "post_id"
    ; "reaction"
    ; "title"
    ; "updated_at"
    ]
    (signal_keys (A.signal_to_yojson (signal "post-plain")));
  Alcotest.(check bool)
    "a vote and a post on the same post_id are distinct candidates"
    false
    (String.equal
       (A.candidate_id_of_signal ~keeper_name:"alpha" vote_signal)
       (A.candidate_id_of_signal ~keeper_name:"alpha" (signal "post-vote")))
;;

let test_codec_and_context_identity_are_strict () =
  let original =
    candidate
      ~context:(keeper_context ~board_interests:[ "OCaml"; "runtime" ] ())
      (signal "post-codec")
  in
  let encoded = A.candidate_to_json original in
  Alcotest.(check bool)
    "candidate roundtrip"
    true
    (ok "decode candidate" (A.candidate_of_json encoded) = original);
  let old_schema =
    match encoded with
    | `Assoc fields ->
      `Assoc
        (List.map
           (fun (name, value) ->
              if String.equal name "schema_version"
              then name, `Int 6
              else name, value)
           fields)
    | _ -> Alcotest.fail "candidate codec did not produce an object"
  in
  (match A.candidate_of_json old_schema with
   | Error _ -> ()
   | Ok _ -> Alcotest.fail "candidate schema v6 was accepted");
  let left = ok "left context" (A.Context_key.of_candidate original) in
  let reordered =
    candidate
      ~context:
        (match keeper_context ~board_interests:[ "OCaml"; "runtime" ] () with
         | `Assoc fields -> `Assoc (List.rev fields)
         | _ -> assert false)
      (signal "post-reordered")
    |> A.Context_key.of_candidate
    |> ok "reordered context"
  in
  Alcotest.(check bool)
    "object field order is not context identity"
    true
    (A.Context_key.equal left reordered);
  let changed_list =
    candidate
      ~context:(keeper_context ~board_interests:[ "Board"; "runtime" ] ())
      (signal "post-list-order")
    |> A.Context_key.of_candidate
    |> ok "changed list context"
  in
  Alcotest.(check bool)
    "a different normalized interest list changes context identity"
    false
    (A.Context_key.equal left changed_list);
  let noncanonical =
    candidate
      ~context:(keeper_context ~board_interests:[ "runtime"; "OCaml" ] ())
      (signal "post-noncanonical-interests")
    |> A.candidate_to_json
  in
  (match A.candidate_of_json noncanonical with
   | Error _ -> ()
   | Ok _ -> Alcotest.fail "non-normalized Board interests were accepted");
  (* 중복 keeper_context 키를 거부하는지 보던 검사가 있었다. keeper_context 가
     재료의 필드가 된 뒤로는 그 상태를 만들 수 없어 지웠다. RFC-0424. *)
  ()
;;

let ledger_path ~base_path =
  Filename.concat
    (Filename.concat
       (Common.masc_dir_from_base_path ~base_path)
       "board_attention_candidates")
    "alpha.jsonl"
;;

(* Fixtures replace the ledger through a sibling file and a rename, so the
   store gets a new inode. The ledger is read through the [Fs_compat] private
   JSONL cursor family, which treats a same-inode file that grew as appended
   bytes; only the rename models what an operator or another process does. *)
let replace_ledger_bytes path bytes =
  let staged = path ^ ".replace" in
  Out_channel.with_open_bin staged (fun channel -> output_string channel bytes);
  Sys.rename staged path
;;

let write_ledger_rows ~base_path rows =
  replace_ledger_bytes
    (ledger_path ~base_path)
    (String.concat "" (List.map (fun row -> Yojson.Safe.to_string row ^ "\n") rows))
;;

let expect_record_error ?expected_detail ~base_path label candidate =
  match A.record ~base_path candidate with
  | A.Record_error detail ->
    Option.iter
      (fun expected ->
         Alcotest.(check string) (label ^ " error") expected detail)
      expected_detail
  | A.Recorded _ | A.Duplicate _ -> Alcotest.fail (label ^ " was recorded")
;;

(* 요청은 후보의 현재 signal 과 최소 Keeper 역할로만 만든다. 원장의
   과거 Board thread 는 이 경계를 넘지 않는다. *)
let test_judgment_requests_project_only_current_signal_and_keeper_role () =
  let source = signal "post-canonical-request" in
  let original = candidate source in
  let role =
    `Assoc
      [ "name", `String original.keeper_name
      ; "board_interests", `List [ `String "OCaml"; `String "runtime" ]
      ]
  in
  let item =
    `Assoc
      [ "candidate_id", `String original.candidate_id
      ; "signal", A.signal_to_yojson original.signal
      ]
  in
  Alcotest.(check bool)
    "run-record request has the exact narrow shape"
    true
    (ok "build judgment request" (A.judgment_request original)
     = `Assoc
         [ "candidate_id", `String original.candidate_id
         ; "signal", A.signal_to_yojson original.signal
         ; "keeper_role", role
         ]);
  Alcotest.(check bool)
    "singleton request has the exact narrow shape"
    true
    (ok "build singleton judgment request" (A.singleton_judgment_request original)
     = `Assoc [ "keeper_role", role; "items", `List [ item ] ])
;;

let test_old_relevant_comment_cannot_override_current_unrelated_signal () =
  let current_signal =
    { (signal
         ~content:"Lunch is available in the kitchen."
         "post-current-unrelated-comment") with
      kind =
        Masc.Board_dispatch.Board_comment_added
          { comment_id = comment_id "c-00000000000000000000000000000002"
          ; parent_id = None
          }
    }
  in
  let original = candidate current_signal in
  let old_relevant_comment =
    `Assoc
      [ "id", `String "c-00000000000000000000000000000001"
      ; "content", `String "@alpha perform the specialist review"
      ]
  in
  let legacy_v6 =
    match A.candidate_to_json original with
    | `Assoc fields ->
      `Assoc
        (List.map
           (function
             | "schema_version", _ -> "schema_version", `Int 6
             | "status", _ ->
               ( "status"
               , `Assoc
                   [ "kind", `String "pending"
                   ; ( "material"
                     , `Assoc
                         [ "post", `Null
                         ; "comments", `List [ old_relevant_comment ]
                         ] )
                   ; "last_delivery_failure", `Null
                   ] )
             | field -> field)
           fields)
    | _ -> Alcotest.fail "candidate codec did not produce an object"
  in
  (match A.candidate_of_json legacy_v6 with
   | Error _ -> ()
   | Ok _ -> Alcotest.fail "v6 history-bearing candidate was accepted");
  let request =
    ok
      "build current-signal-only request"
      (A.singleton_judgment_request original)
  in
  Alcotest.(check bool)
    "the current unrelated comment is the only Board content sent"
    true
    (request
     = `Assoc
         [ ( "keeper_role"
           , `Assoc
               [ "name", `String "alpha"
               ; "board_interests", `List [ `String "OCaml"; `String "runtime" ]
               ] )
         ; ( "items"
           , `List
               [ `Assoc
                   [ "candidate_id", `String original.candidate_id
                   ; "signal", A.signal_to_yojson current_signal
                   ] ] )
         ])
;;

let test_distinct_comment_ids_with_the_same_body_are_distinct_candidates () =
  let make raw_comment_id =
    { (signal ~content:"same body" "post-comment-identity") with
      kind =
        Masc.Board_dispatch.Board_comment_added
          { comment_id = comment_id raw_comment_id; parent_id = None }
    }
  in
  let first = make "c-00000000000000000000000000000001" in
  let second = make "c-00000000000000000000000000000002" in
  Alcotest.(check bool)
    "producer comment identity, not body text, owns candidate identity"
    false
    (String.equal
       (A.candidate_id_of_signal ~keeper_name:"alpha" first)
       (A.candidate_id_of_signal ~keeper_name:"alpha" second))
;;

let test_edit_candidates_preserve_revision_identity () =
  with_temp_base "board-edit-candidates" @@ fun base_path ->
  let edited at =
    { (signal "post-edited") with
      kind = Masc.Board_dispatch.Board_post_updated { content_updated_at = at }
    }
  in
  let first = candidate (edited 10.0) in
  let persisted = record ~base_path first in
  let replay = candidate { (edited 10.0) with updated_at = Some 99.0 } in
  (match A.record ~base_path replay with
   | A.Duplicate existing ->
     Alcotest.(check bool) "same edit converges" true (existing = persisted)
   | _ -> Alcotest.fail "same edit was not deduplicated");
  let next = candidate (edited 20.0) in
  ignore (record ~base_path next);
  let loaded = ok "reload edits" (A.load_candidates ~base_path ~keeper_name:"alpha") in
  Alcotest.(check int) "different edits remain separate" 2 (List.length loaded);
  Alcotest.(check bool) "typed edit survives persistence" true
    (List.exists (fun item -> item.A.signal = next.signal) loaded);
  let invalid fields =
    match A.candidate_to_json first with
    | `Assoc candidate_fields ->
      let json = `Assoc (List.map (function
        | "signal", `Assoc signal_fields -> "signal", `Assoc (fields signal_fields)
        | field -> field) candidate_fields) in
      Alcotest.(check bool) "invalid edit coordinate rejected" true
        (Result.is_error (A.candidate_of_json json))
    | _ -> Alcotest.fail "candidate encoder did not emit an object"
  in
  invalid (List.remove_assoc "content_updated_at");
  invalid (fun fields -> ("content_updated_at", `Float nan)
    :: List.remove_assoc "content_updated_at" fields)
;;

let test_codec_rejects_malformed_comment_identity () =
  let valid = candidate (signal "post-record-validation") in
  let invalid_signal replacements =
    let replace fields =
      List.map
        (fun (key, value) ->
           key, Option.value ~default:value (List.assoc_opt key replacements))
        fields
    in
    match A.candidate_to_json valid with
    | `Assoc candidate_fields ->
      `Assoc
        (List.map
           (function
             | "signal", `Assoc signal_fields -> "signal", `Assoc (replace signal_fields)
             | field -> field)
           candidate_fields)
    | _ -> Alcotest.fail "candidate codec did not produce an object"
  in
  let expect_rejected label json =
    match A.candidate_of_json json with
    | Error _ -> ()
    | Ok _ -> Alcotest.fail (label ^ " was decoded")
  in
  expect_rejected
    "comment signal without producer identity"
    (invalid_signal [ "kind", `String "comment_added" ]);
  expect_rejected
    "comment signal with a non-Board id"
    (invalid_signal
       [ "kind", `String "comment_added"; "comment_id", `String "comment-two" ]);
  expect_rejected
    "non-comment signal carrying comment identity"
    (invalid_signal
       [ "comment_id", `String "c-00000000000000000000000000000003" ])
;;

let test_pending_row_has_no_board_thread_history () =
  let pending = candidate (signal "post-no-history") in
  let status =
    match A.candidate_to_json pending with
    | `Assoc fields -> List.assoc "status" fields
    | _ -> Alcotest.fail "candidate codec did not produce an object"
  in
  Alcotest.(check bool)
    "pending v7 row has no post or comments snapshot"
    true
    (status
     = `Assoc
         [ "kind", `String "pending"
         ; "last_delivery_failure", `Null
         ])
;;

let test_judgment_write_invariant_rejects_blank_provenance () =
  with_temp_base "board-attention-candidate-judgment-invariant" @@ fun base_path ->
  let persisted =
    record ~base_path (candidate (signal "post-judgment-invariant"))
  in
  let valid = judgment J.Not_relevant in
  let invalid_judgments = invalid_judgment_fixtures () in
  List.iter
    (fun (label, invalid) ->
       match A.record_judgment ~base_path persisted invalid with
       | Error _ -> ()
       | Ok _ -> Alcotest.fail (label ^ " judgment was recorded"))
    invalid_judgments;
  let terminal = candidate (signal "post-consumed-invariant") in
  let invalid_terminal =
    { terminal with
      status =
        A.Consumed
          { judgment =
              { valid with
                verdict = { valid.verdict with rationale = " " }
              }
          ; delivery = A.Not_relevant
          ; consumed_at = 3.0
          }
    }
  in
  expect_record_error
    ~base_path
    "Consumed candidate with blank verdict"
    invalid_terminal;
  match (load_one ~base_path).status with
  | A.Pending { last_delivery_failure = None } -> ()
  | A.Pending { last_delivery_failure = Some _ }
  | A.Judged _
  | A.Consumed _
  | A.Quarantine _ ->
    Alcotest.fail "rejected judgment changed the durable Pending candidate"
;;

(* A cli-slot judgment carries no receipt, so the decoder must accept it
   without one -- and must still refuse the receipt keys, which would say an
   AGENT_CORE attempt happened when none did. *)
let test_cli_lane_slot_judgment_round_trips_without_a_receipt () =
  let judgment : A.judgment =
    { verdict = { J.decision = J.Relevant; rationale = "answered by a cli slot" }
    ; slot_id = "claude_code.claude-sonnet-5"
    ; source = A.Cli_lane_slot
    ; judged_at = 3.0
    }
  in
  (match A.judgment_of_yojson (A.judgment_to_yojson judgment) with
   | Error detail -> Alcotest.failf "cli judgment did not round-trip: %s" detail
   | Ok decoded ->
     Alcotest.(check string)
       "the answering client survives the round trip"
       judgment.slot_id
       decoded.slot_id;
     (match decoded.source with
      | A.Cli_lane_slot -> ()
      | A.Exact_attempt _ ->
        Alcotest.fail "a cli judgment decoded as an exact attempt"
      | A.Vendor_system_one _ ->
        Alcotest.fail "a cli judgment decoded as a vendor answer"));
  let with_receipt =
    match A.judgment_to_yojson judgment with
    | `Assoc fields ->
      `Assoc
        (List.map
           (function
             | "source", `Assoc source ->
               "source", `Assoc (source @ [ "call_id", `String "call-invented" ])
             | field -> field)
           fields)
    | other -> other
  in
  (match A.judgment_of_yojson with_receipt with
   | Error _ -> ()
   | Ok _ -> Alcotest.fail "a cli source carrying a receipt key was accepted")
;;

(* A vendor judgment names the exact outbound request and the response that
   answered it. The decoder keeps those coordinates and refuses an incomplete
   source or an AGENT_CORE receipt key. *)
let test_vendor_judgment_round_trips_with_its_provenance () =
  let expected_digest = String.make 64 'a' in
  let judgment : A.judgment =
    { verdict = { J.decision = J.Not_relevant; rationale = "answered by a vendor" }
    ; slot_id = "jev-latest"
    ; source =
        A.Vendor_system_one
          { destination_uri = "https://api.typesafe.ai/v1/systemone"
          ; answering_model_id = "jev-latest"
          ; request_body_sha256 = expected_digest
          }
    ; judged_at = 4.0
    }
  in
  (match A.judgment_of_yojson (A.judgment_to_yojson judgment) with
   | Error detail -> Alcotest.failf "vendor judgment did not round-trip: %s" detail
   | Ok decoded ->
     (match decoded.source with
      | A.Vendor_system_one provenance ->
        Alcotest.(check string)
          "the destination survives the round trip"
          "https://api.typesafe.ai/v1/systemone"
          provenance.destination_uri;
        Alcotest.(check string)
          "the answering model survives the round trip"
          "jev-latest"
          provenance.answering_model_id;
        Alcotest.(check string)
          "the exact request digest survives the round trip"
          expected_digest
          provenance.request_body_sha256
      | A.Cli_lane_slot -> Alcotest.fail "a vendor judgment decoded as a cli slot"
      | A.Exact_attempt _ ->
        Alcotest.fail "a vendor judgment decoded as an exact attempt"));
  let with_source source =
    match A.judgment_to_yojson judgment with
    | `Assoc fields ->
      `Assoc
        (List.map
           (function
             | "source", _ -> "source", source
             | field -> field)
           fields)
    | other -> other
  in
  List.iter
    (fun (label, source) ->
       match A.judgment_of_yojson (with_source source) with
       | Error _ -> ()
       | Ok _ -> Alcotest.fail (label ^ " was accepted"))
    [ ( "a vendor source carrying a receipt key"
      , `Assoc
          [ "kind", `String "vendor_system_one"
          ; "endpoint", `String "https://api.typesafe.ai/v1/systemone"
          ; "model", `String "jev-latest"
          ; "request_body_sha256", `String expected_digest
          ; "call_id", `String "call-invented"
          ] )
    ; ( "an incomplete vendor source"
      , `Assoc [ "kind", `String "vendor_system_one" ] )
    ]
;;

let test_direct_judgment_decoder_enforces_invariant () =
  List.iter
    (fun (label, invalid) ->
       match A.judgment_of_yojson (A.judgment_to_yojson invalid) with
       | Error _ -> ()
       | Ok _ -> Alcotest.fail (label ^ " was accepted by judgment decoder"))
    (invalid_judgment_fixtures ())
;;

let test_non_finite_lifecycle_times_are_rejected () =
  with_temp_base "board-attention-candidate-finite-times" @@ fun base_path ->
  let valid = candidate (signal "post-finite-times") in
  expect_record_error
    ~base_path
    "NaN recorded_at"
    { valid with recorded_at = Float.nan };
  let infinite_failure : A.delivery_failure =
    { kind = A.Durable_delivery_unavailable
    ; detail = "injected non-finite failure time"
    ; failed_at = Float.infinity
    }
  in
  expect_record_error
    ~base_path
    "infinite delivery failed_at"
    { valid with
      status =
        A.Pending
          { last_delivery_failure = Some infinite_failure }
    };
  expect_record_error
    ~base_path
    "negative-infinite consumed_at"
    { valid with
      status =
        A.Consumed
          { judgment = judgment J.Not_relevant
          ; delivery = A.Not_relevant
          ; consumed_at = Float.neg_infinity
          }
    };
  Alcotest.(check int)
    "non-finite records did not poison the ledger"
    0
    (ok
       "load after rejected non-finite records"
       (A.load_candidates ~base_path ~keeper_name:valid.keeper_name)
     |> List.length);
  ignore (record ~base_path valid : A.candidate);
  let ledger_path =
    Filename.concat
      (Filename.concat
         (Common.masc_dir_from_base_path ~base_path)
         "board_attention_candidates")
      "alpha.jsonl"
  in
  let non_finite_row =
    render_row_with_non_finite
      ~field:"recorded_at"
      ~literal:"Infinity"
      (A.candidate_to_json valid)
  in
  replace_ledger_bytes ledger_path (non_finite_row ^ "\n");
  (* The row must never become a candidate. It no longer fails the whole read —
     one bad row used to stop the lane and block the compaction that removes it
     — so the reason is asserted where it is now carried, in the rejection
     list. *)
  (match
     A.load_candidates_with_rejections ~base_path ~keeper_name:valid.keeper_name
   with
   | Error detail -> Alcotest.failf "reader failed instead of rejecting a row: %s" detail
   | Ok (candidates, rejected) ->
     Alcotest.(check int)
       "non-finite row is not loaded"
       0
       (List.length candidates);
     (match rejected with
      | [ (_, detail) ] ->
        let expected = "board attention candidate.recorded_at must be finite" in
        if not (String.ends_with ~suffix:expected detail)
        then
          Alcotest.failf
            "non-finite durable candidate returned the wrong reader error: %s"
            detail
      | rejected ->
        Alcotest.failf
          "expected exactly one rejected row, got %d"
          (List.length rejected)));
  match A.load_candidates ~base_path ~keeper_name:valid.keeper_name with
  | Error detail -> Alcotest.failf "load_candidates failed on a skippable row: %s" detail
  | Ok candidates ->
    Alcotest.(check int)
      "load accepted no non-finite candidate"
      0
      (List.length candidates)
;;

let test_non_finite_current_signal_is_rejected () =
  with_temp_base "board-attention-candidate-signal-finite" @@ fun base_path ->
  let base = candidate (signal "post-signal-finite") in
  let at_signal value =
    (* [candidate] derives candidate_id by serializing the signal, which yojson 3
       refuses to do for a non-finite float. Hash a finite placeholder and inject
       the value afterwards: the stored record, not the id, is under test. *)
    let placeholder = { (signal "post-signal-finite") with updated_at = Some 0.0 } in
    let candidate = candidate placeholder in
    let source = { candidate.signal with updated_at = Some value } in
    { candidate with signal = source }
  in
  let locations =
    [ ( "signal.updated_at"
      , Some
          "invalid Board attention candidate: candidate.signal.updated_at must \
           be finite"
      , at_signal )
    ]
  in
  let non_finite_values =
    [ "NaN", Float.nan
    ; "+Infinity", Float.infinity
    ; "-Infinity", Float.neg_infinity
    ]
  in
  List.iter
    (fun (location, expected_detail, make_candidate) ->
       List.iter
         (fun (number, value) ->
            expect_record_error
              ?expected_detail
              ~base_path
              (number ^ " at " ^ location)
              (make_candidate value))
         non_finite_values)
    locations;
  Alcotest.(check int)
    "non-finite signal fixtures left no durable row"
    0
    (ok
       "load after rejected request fixtures"
       (A.load_candidates ~base_path ~keeper_name:base.keeper_name)
     |> List.length)
;;

let test_finite_numeric_boundary_is_persisted () =
  with_temp_base "board-attention-candidate-finite-boundary" @@ fun base_path ->
  let signal =
    { (signal "post-finite-boundary") with
      updated_at = Some Float.max_float
    }
  in
  let original = candidate signal in
  let persisted = record ~base_path original in
  Alcotest.(check bool)
    "largest finite magnitudes round-trip"
    true
    (load_one ~base_path = persisted)
;;

let test_record_dedupes_exact_identity_and_rejects_conflict () =
  with_temp_base "board-attention-candidate-record" @@ fun base_path ->
  let original = candidate (signal "post-record") in
  let persisted = record ~base_path original in
  (match A.record ~base_path original with
   | A.Duplicate duplicate ->
     Alcotest.(check bool) "exact duplicate" true (duplicate = persisted)
   | A.Recorded _ | A.Record_error _ -> Alcotest.fail "exact duplicate was not deduped");
  (* #28607 regression: the backlog scanner re-synthesizes the same post's
     [Board_post_created] signal with a moved [updated_at]/[content] every
     cycle. Under the typed event identity (keeper, kind, post_id) that
     re-mint must converge to the already-persisted candidate instead of
     minting a fresh one (68 candidates = 68 model judgments for one post). *)
  (* Both volatile axes drift on a real re-scan: a comment bumps the post's
     updated_at, and edits change content. The fixture must move both or a
     hash that quietly re-admits one of them survives this test. *)
  let rescanned =
    candidate
      (signal ~content:"different evidence" ~updated_at:99.5 "post-record")
  in
  (match A.record ~base_path rescanned with
   | A.Duplicate duplicate ->
     Alcotest.(check bool) "re-scan converges to original" true (duplicate = persisted)
   | A.Recorded _ -> Alcotest.fail "re-scanned post minted a second candidate"
   | A.Record_error _ -> Alcotest.fail "re-scanned post was rejected");
  let conflicting =
    { original with signal = signal "post-other" }
  in
  (match A.record ~base_path conflicting with
   | A.Record_error _ -> ()
   | A.Recorded _ | A.Duplicate _ -> Alcotest.fail "identity conflict was accepted");
  Alcotest.(check bool) "conflict preserved original" true (load_one ~base_path = original)
;;

(* A rejected record is still evidence of an obligation. Valid candidates
   remain usable, while writes preserve the original bytes even when ordinary
   decoded-row compaction would otherwise run. *)
let test_unreadable_row_does_not_hide_the_rest () =
  with_temp_base "board-attention-candidate-partial-read" @@ fun base_path ->
  let persisted = record ~base_path (candidate (signal "post-partial")) in
  let path =
    Filename.concat
      (Filename.concat
         (Filename.concat base_path ".masc")
         "board_attention_candidates")
      "alpha.jsonl"
  in
  let good = In_channel.with_open_bin path In_channel.input_all in
  let unsupported =
    match A.candidate_to_json persisted with
    | `Assoc fields -> `Assoc (("schema_version", `Int (-1)) :: List.remove_assoc "schema_version" fields)
    | _ -> Alcotest.fail "candidate fixture is not an object"
  in
  let rejected = "{not-json}\n" ^ Yojson.Safe.to_string unsupported ^ "\n" in
  let original = rejected ^ String.concat "" (List.init 5 (fun _ -> good)) in
  replace_ledger_bytes path original;
  let loaded, rejections = ok "read rejected evidence"
      (A.load_candidates_with_rejections ~base_path ~keeper_name:"alpha") in
  Alcotest.(check bool) "readable candidate survives" true (loaded = [ persisted ]);
  Alcotest.(check int) "both rejected rows remain visible" 2 (List.length rejections);
  let second = record ~base_path (candidate (signal "post-partial-second")) in
  let third = record ~base_path (candidate (signal "post-partial-third")) in
  let after = In_channel.with_open_bin path In_channel.input_all in
  Alcotest.(check bool) "writes preserve every original byte" true
    (String.starts_with ~prefix:original after);
  let loaded, rejections = ok "reload rejected evidence after writes"
      (A.load_candidates_with_rejections ~base_path ~keeper_name:"alpha") in
  Alcotest.(check bool) "new valid candidates remain usable" true
    (loaded = [ persisted; second; third ]);
  Alcotest.(check int) "writes do not erase rejected obligations" 2
    (List.length rejections)
;;

let test_record_requests_worker_without_invoking_judgment () =
  Eio_main.run @@ fun _env ->
  Eio.Switch.run @@ fun sw ->
  with_temp_base "board-attention-candidate-wake" @@ fun base_path ->
  let registration =
    ok "register worker" (Wake.register ~sw ~base_path ~keeper_name:"alpha")
  in
  let original = candidate (signal "post-wake") in
  let accepted =
    Domain.spawn (fun () -> A.record_and_wake ~base_path original)
    |> Domain.join
    |> ok "record and wake"
  in
  (match accepted with
   | { A.persistence = A.Candidate_recorded
     ; wake = A.Judgment_worker_requested Wake.Signaled
     ; candidate = persisted
     } ->
     (match persisted.status with
      | A.Pending { last_delivery_failure = None } -> ()
      | A.Pending { last_delivery_failure = Some _ }
      | A.Judged _
      | A.Consumed _
      | A.Quarantine _ ->
        Alcotest.fail "producer performed judgment work")
   | _ -> Alcotest.fail "candidate returned the wrong worker-wake acceptance");
  match Wake.await registration with
  | Wake.Wake -> ()
  | Wake.Registration_closed -> Alcotest.fail "worker registration closed"
;;

let test_not_relevant_delivery_is_idempotent () =
  with_temp_base "board-attention-candidate-not-relevant" @@ fun base_path ->
  let persisted = record ~base_path (candidate (signal "post-not-relevant")) in
  let verdict = judgment J.Not_relevant in
  ignore
    (ok "record judgment" (A.record_judgment ~base_path persisted verdict)
      : A.candidate);
  (match
     A.record_judgment
       ~base_path
       persisted
       (judgment J.Relevant)
   with
   | Error _ -> ()
   | Ok _ -> Alcotest.fail "conflicting durable judgment was accepted");
  let consumed =
    delivered
      "apply judgment"
      (A.apply_judgment_and_deliver
         ~base_path
         ~keeper_name:persisted.keeper_name
         ~candidate_id:persisted.candidate_id
         ~judgment:verdict)
  in
  (match consumed.status with
   | A.Consumed { delivery = A.Not_relevant; _ } -> ()
   | A.Pending _ | A.Judged _ | A.Consumed _ | A.Quarantine _ ->
     Alcotest.fail "not-relevant judgment did not reach Consumed");
  let replayed =
    delivered
      "replay judgment"
      (A.apply_judgment_and_deliver
         ~base_path
         ~keeper_name:persisted.keeper_name
         ~candidate_id:persisted.candidate_id
         ~judgment:verdict)
  in
  Alcotest.(check bool) "terminal replay is idempotent" true (replayed = consumed);
  match
    A.apply_judgment_and_deliver
      ~base_path
      ~keeper_name:persisted.keeper_name
      ~candidate_id:persisted.candidate_id
      ~judgment:(judgment J.Relevant)
  with
  | Error _ -> ()
  | Ok _ -> Alcotest.fail "conflicting terminal judgment was accepted"
;;

let test_relevant_delivery_uses_exact_candidate_identity () =
  with_temp_base "board-attention-candidate-relevant" @@ fun base_path ->
  let persisted = record ~base_path (candidate (signal "post-relevant")) in
  let consumed =
    delivered
      "apply relevant judgment"
      (A.apply_judgment_and_deliver
         ~base_path
         ~keeper_name:persisted.keeper_name
         ~candidate_id:persisted.candidate_id
         ~judgment:(judgment J.Relevant))
  in
  (match consumed.status with
   | A.Consumed { delivery = A.Enqueued_to_keeper_lane; _ } -> ()
   | A.Pending _ | A.Judged _ | A.Consumed _ | A.Quarantine _ ->
     Alcotest.fail "relevant judgment consumed without durable enqueue");
  match
    Event_queue_persistence.load
      ~base_path
      ~keeper_name:persisted.keeper_name
    |> Event_queue.to_list
  with
  | [ { payload = Event_queue.Board_attention attention; _ } ] ->
    Alcotest.(check string)
      "exact candidate delivery identity"
      persisted.candidate_id
      attention.candidate_id
  | _ -> Alcotest.fail "relevant judgment did not enqueue one Board_attention event"
;;

let ledger_rows ~base_path =
  In_channel.with_open_bin (ledger_path ~base_path) In_channel.input_all
  |> String.split_on_char '\n'
  |> List.filter (fun line -> not (String.equal (String.trim line) ""))
;;

(* RFC main-domain-scheduler-latency §8 P4a: an update appends the rows it
   changes after the store's end. The bytes already on disk stay in place. *)
let test_update_appends_after_existing_rows () =
  with_temp_base "board-attention-candidate-append" @@ fun base_path ->
  let first = record ~base_path (candidate (signal "append-first")) in
  let before = In_channel.with_open_bin (ledger_path ~base_path) In_channel.input_all in
  let second = record ~base_path (candidate (signal "append-second")) in
  let after = In_channel.with_open_bin (ledger_path ~base_path) In_channel.input_all in
  let before_length = String.length before in
  Alcotest.(check bool)
    "second write kept the first row's bytes in place"
    true
    (String.length after > before_length
     && String.equal (String.sub after 0 before_length) before);
  Alcotest.(check int) "two rows on disk" 2 (List.length (ledger_rows ~base_path));
  Alcotest.(check bool)
    "reader answers in first-index order"
    true
    (ok "load" (A.load_candidates ~base_path ~keeper_name:"alpha") = [ first; second ])
;;

(* Dead rows stay bounded: once the decoded rows exceed twice the live set,
   the next write rewrites the store as the latest set. The reader's answer
   is the same before and after the rewrite. *)
let test_write_compacts_when_dead_rows_exceed_the_bound () =
  with_temp_base "board-attention-candidate-compaction" @@ fun base_path ->
  let first = record ~base_path (candidate (signal "compact-first")) in
  (* Five rows for one id: one live, four dead. Written behind the cache so
     the next access must notice the store changed. *)
  write_ledger_rows ~base_path (List.init 5 (fun _ -> A.candidate_to_json first));
  Alcotest.(check bool)
    "reader sees the replaced store"
    true
    (ok "load" (A.load_candidates ~base_path ~keeper_name:"alpha") = [ first ]);
  let second = record ~base_path (candidate (signal "compact-second")) in
  Alcotest.(check int)
    "six decoded rows for two live exceed the bound, so the write rewrote the store"
    2
    (List.length (ledger_rows ~base_path));
  Alcotest.(check bool)
    "reader answers the latest set in first-index order"
    true
    (ok "load" (A.load_candidates ~base_path ~keeper_name:"alpha") = [ first; second ]);
  let third = record ~base_path (candidate (signal "compact-third")) in
  Alcotest.(check int)
    "three decoded rows for three live are within the bound, so the write appended"
    3
    (List.length (ledger_rows ~base_path));
  Alcotest.(check bool)
    "reader after the append"
    true
    (ok "load" (A.load_candidates ~base_path ~keeper_name:"alpha")
     = [ first; second; third ])
;;

(* A store replaced behind the cache (another process, or a test fixture) is
   read again in full; the cached cursor no longer names the file's end. *)
let test_replaced_store_is_reread_and_appended_after () =
  with_temp_base "board-attention-candidate-replaced" @@ fun base_path ->
  let original = record ~base_path (candidate (signal "replaced-original")) in
  Alcotest.(check bool)
    "cached read"
    true
    (ok "load" (A.load_candidates ~base_path ~keeper_name:"alpha") = [ original ]);
  let replacement_a = candidate (signal "replaced-a") in
  let replacement_b = candidate (signal "replaced-b") in
  write_ledger_rows
    ~base_path
    [ A.candidate_to_json replacement_a; A.candidate_to_json replacement_b ];
  Alcotest.(check bool)
    "reader sees the replacement, not the cache"
    true
    (ok "load" (A.load_candidates ~base_path ~keeper_name:"alpha")
     = [ replacement_a; replacement_b ]);
  let appended = record ~base_path (candidate (signal "replaced-appended")) in
  Alcotest.(check bool)
    "write appended after the replacement"
    true
    (ok "load" (A.load_candidates ~base_path ~keeper_name:"alpha")
     = [ replacement_a; replacement_b; appended ]);
  Alcotest.(check int) "three rows on disk" 3 (List.length (ledger_rows ~base_path))
;;

(* #33322. The ledger lock is held across the store transaction, and from an
   Eio fiber that transaction runs its Unix I/O in a systhread, so the holder
   yields while locked. A second fiber on the same domain that reads or writes
   the same ledger meanwhile must wait for it. With a Stdlib mutex the second
   fiber re-locked the domain's own mutex and got
   [Sys_error "Mutex.lock: Resource deadlock avoided"]; on 2026-09-05 four
   keepers each lost a turn to that in the first five seconds after boot. *)
let test_fibers_on_one_domain_share_the_ledger_lock () =
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  Eio.Switch.on_release sw Fs_compat.clear_fs;
  with_temp_base "board-attention-candidate-fibers" @@ fun base_path ->
  let first = record ~base_path (candidate (signal "fibers-first")) in
  let read_answers = ref [] in
  Eio.Fiber.all
    [ (fun () ->
        List.iter
          (fun i ->
             ignore
               (record ~base_path (candidate (signal (Printf.sprintf "fibers-write-%d" i)))))
          [ 1; 2; 3 ])
    ; (fun () ->
        List.iter
          (fun _ ->
             read_answers
             := ok "load while a writer holds the ledger"
                  (A.load_candidates ~base_path ~keeper_name:"alpha")
                :: !read_answers;
             Eio.Fiber.yield ())
          [ 1; 2; 3 ])
    ];
  let final = ok "load" (A.load_candidates ~base_path ~keeper_name:"alpha") in
  Alcotest.(check int) "every write landed" 4 (List.length final);
  Alcotest.(check bool)
    "the first candidate is still first"
    true
    (match final with
     | head :: _ -> head = first
     | [] -> false);
  Alcotest.(check int) "every read answered" 3 (List.length !read_answers);
  Alcotest.(check bool)
    "every read answered candidates that are in the final ledger"
    true
    (List.for_all
       (fun answer -> List.for_all (fun c -> List.mem c final) answer)
       !read_answers)
;;

let () =
  Alcotest.run
    "keeper_board_attention_candidate"
    [ ( "durable candidate"
      , [ Alcotest.test_case
            "an unreadable row does not hide the rest"
            `Quick
            test_unreadable_row_does_not_hide_the_rest
        ; Alcotest.test_case
            "codec and context identity are strict"
            `Quick
            test_codec_and_context_identity_are_strict
        ; Alcotest.test_case
            "vote signal codec round trips without widening other rows"
            `Quick
            test_vote_signal_codec_round_trips_without_widening_other_rows
        ; Alcotest.test_case
            "status view preserves resumability and quarantine"
            `Quick
            test_status_view_preserves_resumability_and_quarantine
        ; Alcotest.test_case
            "judgment requests project only current signal and keeper role"
            `Quick
            test_judgment_requests_project_only_current_signal_and_keeper_role
        ; Alcotest.test_case
            "old relevant comment cannot override current unrelated signal"
            `Quick
            test_old_relevant_comment_cannot_override_current_unrelated_signal
        ; Alcotest.test_case
            "edit candidates preserve revision identity"
            `Quick
            test_edit_candidates_preserve_revision_identity
        ; Alcotest.test_case
            "distinct comment ids with the same body are distinct candidates"
            `Quick
            test_distinct_comment_ids_with_the_same_body_are_distinct_candidates
        ; Alcotest.test_case
            "pending row has no Board thread history"
            `Quick
            test_pending_row_has_no_board_thread_history
        ; Alcotest.test_case
            "codec rejects malformed comment identity"
            `Quick
            test_codec_rejects_malformed_comment_identity
        ; Alcotest.test_case
            "judgment write invariant rejects blank provenance"
            `Quick
            test_judgment_write_invariant_rejects_blank_provenance
        ; Alcotest.test_case
            "direct judgment decoder enforces invariant"
            `Quick
            test_direct_judgment_decoder_enforces_invariant
        ; Alcotest.test_case
            "a cli-slot judgment round trips without a receipt"
            `Quick
            test_cli_lane_slot_judgment_round_trips_without_a_receipt
        ; Alcotest.test_case
            "a vendor judgment round trips with its provenance"
            `Quick
            test_vendor_judgment_round_trips_with_its_provenance
        ; Alcotest.test_case
            "non-finite lifecycle times are rejected"
            `Quick
            test_non_finite_lifecycle_times_are_rejected
        ; Alcotest.test_case
            "non-finite current signal is rejected"
            `Quick
            test_non_finite_current_signal_is_rejected
        ; Alcotest.test_case
            "finite numeric boundary is persisted"
            `Quick
            test_finite_numeric_boundary_is_persisted
        ; Alcotest.test_case
            "record dedupes exact identity"
            `Quick
            test_record_dedupes_exact_identity_and_rejects_conflict
        ; Alcotest.test_case
            "record requests worker without judgment"
            `Quick
            test_record_requests_worker_without_invoking_judgment
        ; Alcotest.test_case
            "not relevant delivery is idempotent"
            `Quick
            test_not_relevant_delivery_is_idempotent
        ; Alcotest.test_case
            "relevant delivery uses exact identity"
            `Quick
            test_relevant_delivery_uses_exact_candidate_identity
        ; Alcotest.test_case
            "update appends after existing rows"
            `Quick
            test_update_appends_after_existing_rows
        ; Alcotest.test_case
            "write compacts when dead rows exceed the bound"
            `Quick
            test_write_compacts_when_dead_rows_exceed_the_bound
        ; Alcotest.test_case
            "replaced store is reread and appended after"
            `Quick
            test_replaced_store_is_reread_and_appended_after
        ; Alcotest.test_case
            "fibers on one domain share the ledger lock"
            `Quick
            test_fibers_on_one_domain_share_the_ledger_lock
        ] )
    ]
;;

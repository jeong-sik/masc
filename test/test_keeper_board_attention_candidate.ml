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

let post_id_exn value =
  match Masc.Board.Post_id.of_string value with
  | Ok value -> value
  | Error _ -> Alcotest.fail ("invalid Board post id fixture: " ^ value)
;;

let agent_id_exn value =
  match Masc.Board.Agent_id.of_string value with
  | Ok value -> value
  | Error _ -> Alcotest.fail ("invalid Board agent id fixture: " ^ value)
;;

let comment_id_exn value =
  match Masc.Board.Comment_id.of_string value with
  | Ok value -> value
  | Error _ -> Alcotest.fail ("invalid Board comment id fixture: " ^ value)
;;

let post_of_signal (signal : Masc.Board_dispatch.board_signal) : Masc.Board.post =
  { id = post_id_exn signal.post_id
  ; author = agent_id_exn signal.author
  ; title = signal.title
  ; body = signal.content
  ; post_kind = Masc.Board.Human_post
  ; meta_json = None
  ; visibility = Masc.Board.Public
  ; created_at = 1.0
  ; updated_at = Option.value signal.updated_at ~default:1.0
  ; expires_at = 3601.0
  ; votes_up = 0
  ; votes_down = 0
  ; reply_count = 0
  ; pinned = false
  ; hearth = signal.hearth
  ; thread_id = None
  ; origin = None
  }
;;

let comment_of_signal
      (signal : Masc.Board_dispatch.board_signal)
  : Masc.Board.comment
  =
  (* A comment id must have the shape [Comment_id.generate] mints; derive one
     from the post id so the fixture stays deterministic per post. *)
  { id = comment_id_exn (Printf.sprintf "c-%032x" (Hashtbl.hash signal.post_id))
  ; post_id = post_id_exn signal.post_id
  ; parent_id = None
  ; author = agent_id_exn "comment-author"
  ; content = "Canonical Board comment"
  ; created_at = 2.0
  ; expires_at = 3602.0
  ; votes_up = 0
  ; votes_down = 0
  }
;;

let keeper_context ?(mention_keeper_ids = [ "alpha" ]) () =
  `Assoc
    [ "lane_keeper_name", `String "alpha"
    ; "keeper_record_id", `Null
    ; "keeper_runtime_uid", `Null
    ; "instructions", `String "continue"
    ; "current_task_id", `Null
    ; ( "mention_keeper_ids"
      , `List (List.map (fun id -> `String id) mention_keeper_ids) )
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
  ; judgment_request =
      `Assoc
        [ "candidate_id", `String candidate_id
        ; "signal", A.signal_to_yojson signal
        ; "post", Masc.Board.post_to_yojson (post_of_signal signal)
        ; ( "comments"
          , `List
              [ Masc.Board.comment_to_yojson (comment_of_signal signal) ] )
        ; "keeper_context", context
        ]
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
    quarantine_state ~phase:(A.Requeued { requeued_at = 4.0 }) pending
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

(* #29457: a vote signal round-trips through the candidate codec with its
   payload under a [vote] key that only vote rows carry, so the rows written
   before votes were a signal (exactly eight [signal] keys) still decode. *)
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
    [ "author"; "content"; "hearth"; "kind"; "post_id"; "reaction"; "title"; "updated_at"; "vote" ]
    (signal_keys (A.signal_to_yojson vote_signal));
  Alcotest.(check (list string))
    "post row keeps the eight pre-vote keys"
    [ "author"; "content"; "hearth"; "kind"; "post_id"; "reaction"; "title"; "updated_at" ]
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
      ~context:(keeper_context ~mention_keeper_ids:[ "alpha"; "peer" ] ())
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
              then name, `Int 2
              else name, value)
           fields)
    | _ -> Alcotest.fail "candidate codec did not produce an object"
  in
  (match A.candidate_of_json old_schema with
   | Error _ -> ()
   | Ok _ -> Alcotest.fail "candidate schema v2 was accepted");
  let left = ok "left context" (A.Context_key.of_candidate original) in
  let reordered =
    candidate
      ~context:
        (match keeper_context ~mention_keeper_ids:[ "alpha"; "peer" ] () with
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
      ~context:(keeper_context ~mention_keeper_ids:[ "peer"; "alpha" ] ())
      (signal "post-list-order")
    |> A.Context_key.of_candidate
    |> ok "changed list context"
  in
  Alcotest.(check bool)
    "list order remains context identity"
    false
    (A.Context_key.equal left changed_list);
  (match
     A.Context_key.of_candidate
       { original with
         judgment_request =
           `Assoc
             [ "keeper_context", `Assoc []
             ; "keeper_context", `Assoc []
             ]
       }
   with
   | Error _ -> ()
   | Ok _ -> Alcotest.fail "duplicate keeper_context authority was accepted")
;;

let legacy_exact_attempt_judgment = function
  | `Assoc fields ->
    let required name =
      match List.assoc_opt name fields with
      | Some value -> value
      | None -> Alcotest.fail ("new judgment is missing " ^ name)
    in
    let source_fields =
      match required "source" with
      | `Assoc source_fields -> source_fields
      | _ -> Alcotest.fail "new judgment source is not an object"
    in
    let source_required name =
      match List.assoc_opt name source_fields with
      | Some value -> value
      | None -> Alcotest.fail ("exact-attempt source is missing " ^ name)
    in
    `Assoc
      [ "verdict", required "verdict"
      ; "slot_id", required "slot_id"
      ; "call_id", source_required "call_id"
      ; "plan_fingerprint", source_required "plan_fingerprint"
      ; "request_body_sha256", source_required "request_body_sha256"
      ; "judged_at", required "judged_at"
      ]
  | _ -> Alcotest.fail "new judgment is not an object"
;;

let test_legacy_exact_attempt_judgment_decodes_without_rewriting_the_writer () =
  let rewrite_field key rewrite = function
    | `Assoc fields ->
      `Assoc
        (List.map
           (fun (field, value) ->
              if String.equal field key
              then field, rewrite value
              else field, value)
           fields)
    | _ -> Alcotest.fail ("expected object while rewriting field " ^ key)
  in
  let original =
    { (candidate (signal "post-legacy-judgment")) with
      status =
        A.Judged
          { judgment = judgment J.Relevant
          ; last_delivery_failure = None
          }
    }
  in
  let legacy =
    A.candidate_to_json original
    |> rewrite_field "status" (fun status ->
      rewrite_field "judgment" legacy_exact_attempt_judgment status)
  in
  Alcotest.(check bool)
    "legacy durable judgment"
    true
    (ok "decode legacy judgment" (A.candidate_of_json legacy) = original);
  match A.candidate_to_json original with
  | `Assoc fields ->
    (match List.assoc_opt "status" fields with
     | Some (`Assoc status_fields) ->
       (match List.assoc_opt "judgment" status_fields with
        | Some (`Assoc judgment_fields) ->
          Alcotest.(check bool)
            "writer emits source"
            true
            (List.mem_assoc "source" judgment_fields)
        | _ -> Alcotest.fail "written status has no judgment object")
     | _ -> Alcotest.fail "written candidate has no status object")
  | _ -> Alcotest.fail "written candidate is not an object"
;;

let rewrite_assoc_field key rewrite = function
  | `Assoc fields ->
    `Assoc
      (List.map
         (fun (field, value) ->
            if String.equal field key
            then field, rewrite value
            else field, value)
         fields)
  | _ -> Alcotest.fail ("expected object while rewriting field " ^ key)
;;

let add_legacy_extra = function
  | `Assoc fields -> `Assoc (("legacy_extra", `String "must-not-survive") :: fields)
  | _ -> Alcotest.fail "expected Board object fixture"
;;

let set_assoc_field key value = function
  | `Assoc fields ->
    if List.exists (fun (field, _) -> String.equal field key) fields
    then
      `Assoc
        (List.map
           (fun (field, current) ->
              if String.equal field key then field, value else field, current)
           fields)
    else `Assoc (fields @ [ key, value ])
  | _ -> Alcotest.fail ("expected object while setting field " ^ key)
;;

let append_assoc_field key value = function
  | `Assoc fields -> `Assoc (fields @ [ key, value ])
  | _ -> Alcotest.fail ("expected object while appending field " ^ key)
;;

let insert_assoc_field_after anchor key value = function
  | `Assoc fields ->
    let rec insert reversed = function
      | [] -> Alcotest.fail ("missing object field " ^ anchor)
      | ((name, _) as field) :: rest ->
        if String.equal name anchor
        then `Assoc (List.rev_append reversed (field :: (key, value) :: rest))
        else insert (field :: reversed) rest
    in
    insert [] fields
  | _ -> Alcotest.fail ("expected object while inserting field " ^ key)
;;

let rewrite_candidate_keeper_context rewrite candidate =
  A.candidate_to_json candidate
  |> rewrite_assoc_field "judgment_request" (fun request ->
    rewrite_assoc_field "keeper_context" rewrite request)
;;

let ledger_path ~base_path =
  Filename.concat
    (Filename.concat
       (Common.masc_dir_from_base_path ~base_path)
       "board_attention_candidates")
    "alpha.jsonl"
;;

let write_ledger_rows ~base_path rows =
  Out_channel.with_open_bin (ledger_path ~base_path) (fun channel ->
    List.iter
      (fun row ->
         output_string channel (Yojson.Safe.to_string row);
         output_char channel '\n')
      rows)
;;

let rewrite_first_comment rewrite = function
  | `List (comment :: rest) -> `List (rewrite comment :: rest)
  | `List [] -> Alcotest.fail "expected one Board comment fixture"
  | _ -> Alcotest.fail "expected comments array"
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

let test_singleton_request_is_canonical_and_identity_bound () =
  let original = candidate (signal "post-canonical-request") in
  ignore
    (ok
       "canonical singleton request"
       (A.singleton_judgment_request original)
      : Yojson.Safe.t);
  let noisy_request =
    original.judgment_request
    |> rewrite_assoc_field "post" add_legacy_extra
    |> rewrite_assoc_field "comments" (function
      | `List comments -> `List (List.map add_legacy_extra comments)
      | _ -> Alcotest.fail "expected comments array")
  in
  (match
     A.singleton_judgment_request
       { original with judgment_request = noisy_request }
   with
   | Error _ -> ()
   | Ok _ -> Alcotest.fail "unknown nested Board fields were accepted");
  let mismatched_post =
    original.judgment_request
    |> rewrite_assoc_field "post" (rewrite_assoc_field "id" (fun _ ->
      `String "different-post"))
  in
  (match
     A.singleton_judgment_request
       { original with judgment_request = mismatched_post }
   with
   | Error _ -> ()
   | Ok _ -> Alcotest.fail "mismatched Board post identity was accepted");
  let mismatched_comment =
    original.judgment_request
    |> rewrite_assoc_field "comments" (function
      | `List (comment :: rest) ->
        `List
          (rewrite_assoc_field
             "post_id"
             (fun _ -> `String "different-post")
             comment
           :: rest)
      | `List [] -> Alcotest.fail "expected one Board comment fixture"
      | _ -> Alcotest.fail "expected comments array")
  in
  match
    A.singleton_judgment_request
      { original with judgment_request = mismatched_comment }
  with
  | Error _ -> ()
  | Ok _ -> Alcotest.fail "mismatched Board comment identity was accepted"
;;

let test_record_rejects_malformed_without_poisoning_ledger () =
  with_temp_base "board-attention-candidate-record-validation" @@ fun base_path ->
  let valid = candidate (signal "post-record-validation") in
  let malformed_request =
    valid.judgment_request
    |> rewrite_assoc_field "post" (rewrite_assoc_field "id" (fun _ ->
      `String "different-post"))
  in
  (match
     A.record
       ~base_path
       { valid with judgment_request = malformed_request }
   with
   | A.Record_error _ -> ()
   | A.Recorded _ | A.Duplicate _ ->
     Alcotest.fail "malformed in-memory candidate was recorded");
  Alcotest.(check int)
    "failed validation did not poison the ledger"
    0
    (ok
       "load ledger after rejected record"
       (A.load_candidates ~base_path ~keeper_name:valid.keeper_name)
     |> List.length);
  let noisy_request =
    valid.judgment_request
    |> rewrite_assoc_field "post" add_legacy_extra
    |> rewrite_assoc_field "comments" (function
      | `List comments -> `List (List.map add_legacy_extra comments)
      | _ -> Alcotest.fail "expected comments array")
  in
  (match A.record ~base_path { valid with judgment_request = noisy_request } with
   | A.Record_error _ -> ()
   | A.Recorded _ | A.Duplicate _ ->
     Alcotest.fail "unknown nested Board fields were canonicalized and recorded");
  Alcotest.(check int)
    "rejected old JSON left the ledger empty"
    0
    (ok
       "load ledger after rejected old JSON"
       (A.load_candidates ~base_path ~keeper_name:valid.keeper_name)
     |> List.length);
  let persisted = record ~base_path valid in
  Alcotest.(check bool)
    "valid current request is the only durable row"
    true
    (load_one ~base_path = persisted)
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
        Alcotest.fail "a cli judgment decoded as an exact attempt"));
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
      status = A.Pending { last_delivery_failure = Some infinite_failure }
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
  Out_channel.with_open_bin ledger_path (fun channel ->
    output_string channel (non_finite_row ^ "\n"));
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

let test_non_finite_complete_request_evidence_is_rejected () =
  with_temp_base "board-attention-candidate-request-finite" @@ fun base_path ->
  let base = candidate (signal "post-request-finite") in
  let at_signal value =
    (* [candidate] derives candidate_id by serializing the signal, which yojson 3
       refuses to do for a non-finite float. Hash a finite placeholder and inject
       the value afterwards: the stored record, not the id, is under test. *)
    let placeholder =
      { (signal "post-request-finite") with updated_at = Some 0.0 }
    in
    let candidate = candidate placeholder in
    let candidate =
      { candidate with
        signal = { candidate.signal with updated_at = Some value }
      }
    in
    { candidate with
      judgment_request =
        candidate.judgment_request
        |> rewrite_assoc_field
             "post"
             (rewrite_assoc_field "updated_at" (fun _ -> `Float 42.0))
    }
  in
  let at_post value =
    { base with
      judgment_request =
        base.judgment_request
        |> rewrite_assoc_field
             "post"
             (rewrite_assoc_field "created_at" (fun _ -> `Float value))
    }
  in
  let at_comment value =
    { base with
      judgment_request =
        base.judgment_request
        |> rewrite_assoc_field
             "comments"
             (rewrite_first_comment
                (rewrite_assoc_field "created_at" (fun _ -> `Float value)))
    }
  in
  let at_nested_evidence value =
    let nested =
      `Assoc
        [ ( "evidence"
          , `List [ `Assoc [ "confidence", `Float value ] ] )
        ]
    in
    { base with
      judgment_request =
        base.judgment_request
        |> rewrite_assoc_field "post" (set_assoc_field "meta" nested)
    }
  in
  let locations =
    [ (* signal.updated_at is a typed field, so the record's own finiteness
         check answers before the JSON canonicalizer walks the request, and it
         names the field rather than the enclosing object. The untyped
         locations below keep the canonicalizer's generic message, which is why
         they pin no detail. *)
      ( "signal.updated_at"
      , Some
          "invalid Board attention candidate: candidate.signal.updated_at must \
           be finite"
      , at_signal )
    ; "post.created_at", None, at_post
    ; "comment.created_at", None, at_comment
    ; "nested post evidence", None, at_nested_evidence
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
    "non-finite request fixtures left no durable row"
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
  let nested_boundary =
    `Assoc
      [ ( "evidence"
        , `List
            [ `Assoc
                [ "positive", `Float Float.max_float
                ; "negative", `Float (-. Float.max_float)
                ]
            ] )
      ]
  in
  let judgment_request =
    original.judgment_request
    |> rewrite_assoc_field
         "post"
         (fun post ->
            post
            |> rewrite_assoc_field
                 "created_at"
                 (fun _ -> `Float (-. Float.max_float))
            |> set_assoc_field "meta" nested_boundary)
    |> rewrite_assoc_field
         "comments"
         (rewrite_first_comment
            (rewrite_assoc_field
               "created_at"
               (fun _ -> `Float Float.max_float)))
  in
  let original = { original with judgment_request } in
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

(* One unreadable row used to fail the whole read, and the write path reads
   before it writes, so compaction could never remove it. Measured 2026-08-28:
   17 of 575 rows carried a field a hard cut had removed and stopped all 10
   keeper ledgers, 402 WARN/day. The reader must keep the rows it can parse and
   let the next write compact the rest away. *)
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
  Alcotest.(check bool) "fixture wrote a row" true (String.length good > 0);
  (* A row the current decoder refuses, ahead of the good one — the shape a
     removed field leaves behind. *)
  Out_channel.with_open_bin path (fun oc ->
    Out_channel.output_string oc "{\"schema_version\":5,\"unreadable\":true}\n";
    Out_channel.output_string oc good);
  (match A.load_candidates ~base_path ~keeper_name:"alpha" with
   | Ok [ loaded ] ->
     Alcotest.(check bool) "readable row survives" true (loaded = persisted)
   | Ok candidates ->
     Alcotest.failf "expected the one readable candidate, got %d" (List.length candidates)
   | Error detail -> Alcotest.failf "one bad row failed the whole read: %s" detail);
  (* The next write compacts the file, so the bad row does not come back. *)
  let _ = record ~base_path (candidate (signal "post-partial-second")) in
  let after = In_channel.with_open_bin path In_channel.input_all in
  let contains haystack needle =
    let hn = String.length haystack and nn = String.length needle in
    let rec scan i = i + nn <= hn && (String.sub haystack i nn = needle || scan (i + 1)) in
    scan 0
  in
  Alcotest.(check bool)
    "next write drops the unreadable row"
    false
    (contains after "unreadable")
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
            "legacy exact-attempt judgment remains readable"
            `Quick
            test_legacy_exact_attempt_judgment_decodes_without_rewriting_the_writer
        ; Alcotest.test_case
            "status view preserves resumability and quarantine"
            `Quick
            test_status_view_preserves_resumability_and_quarantine
        ; Alcotest.test_case
            "singleton request is canonical and identity bound"
            `Quick
            test_singleton_request_is_canonical_and_identity_bound
        ; Alcotest.test_case
            "record rejects malformed input without poisoning ledger"
            `Quick
            test_record_rejects_malformed_without_poisoning_ledger
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
            "non-finite lifecycle times are rejected"
            `Quick
            test_non_finite_lifecycle_times_are_rejected
        ; Alcotest.test_case
            "non-finite complete request evidence is rejected"
            `Quick
            test_non_finite_complete_request_evidence_is_rejected
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
        ] )
    ]
;;

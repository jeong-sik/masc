module A = Masc.Keeper_board_attention_candidate

let rec remove_tree path =
  if Sys.file_exists path then
    if Sys.is_directory path
    then begin
      Sys.readdir path
      |> Array.iter (fun name -> remove_tree (Filename.concat path name));
      Unix.rmdir path
    end
    else Sys.remove path

let temp_base_path prefix =
  Filename.concat
    (Filename.get_temp_dir_name ())
    (Printf.sprintf "%s-%d-%d" prefix (Unix.getpid ()) (Random.bits ()))

let with_temp_base name f =
  let base_path = temp_base_path name in
  match f base_path with
  | result ->
    (try remove_tree base_path with _ -> ());
    result
  | exception exn ->
    (try remove_tree base_path with _ -> ());
    raise exn

let signal ?(kind = Masc.Board_dispatch.Board_post_created)
    ?(post_id = "post-1") ?(updated_at = Some 42.0)
    ?(content = "goal-adjacent board text") () :
    Masc.Board_dispatch.board_signal =
  {
    kind;
    post_id;
    author = "external-author";
    title = "Board update";
    content;
    hearth = Some "hearth-1";
    updated_at;
  }

let expect_recorded = function
  | `Recorded -> ()
  | `Duplicate _ -> Alcotest.fail "expected first record to append"
  | `Error detail -> Alcotest.failf "record failed: %s" detail

let test_candidate_roundtrip_and_authority () =
  let candidate =
    A.of_board_signal
      ~keeper_name:"sangsu"
      ~recorded_at:100.0
      (signal ())
  in
  Alcotest.(check string)
    "attention authority"
    "llm_judge_required"
    (A.attention_authority_to_string candidate.A.attention_authority);
  Alcotest.(check string)
    "wake authority"
    "no_direct_wake"
    (A.wake_authority_to_string candidate.A.wake_authority);
  match A.candidate_of_json (A.candidate_to_json candidate) with
  | Ok decoded -> Alcotest.(check bool) "roundtrip" true (decoded = candidate)
  | Error detail -> Alcotest.failf "decode failed: %s" detail

let test_record_dedupes_by_keeper_signal_identity () =
  with_temp_base "keeper-board-attention-candidate" @@ fun base_path ->
  let first =
    A.of_board_signal ~keeper_name:"sangsu" ~recorded_at:100.0 (signal ())
  in
  let duplicate =
    A.of_board_signal ~keeper_name:"sangsu" ~recorded_at:101.0 (signal ())
  in
  Alcotest.(check string)
    "same signal identity produces stable candidate id"
    first.A.candidate_id
    duplicate.A.candidate_id;
  expect_recorded (A.record ~base_path first);
  (match A.record ~base_path duplicate with
   | `Duplicate existing ->
     Alcotest.(check string)
       "duplicate returns existing candidate"
       first.A.candidate_id
       existing.A.candidate_id
   | `Recorded -> Alcotest.fail "duplicate appended"
   | `Error detail -> Alcotest.failf "duplicate record failed: %s" detail);
  match A.load_candidates ~base_path ~keeper_name:"sangsu" with
  | [ loaded ] ->
    Alcotest.(check string) "loaded id" first.A.candidate_id loaded.A.candidate_id
  | loaded ->
    Alcotest.failf "expected one loaded candidate, got %d" (List.length loaded)

let test_distinct_signal_identity_changes_candidate_id () =
  let a =
    A.of_board_signal ~keeper_name:"sangsu" ~recorded_at:100.0
      (signal ~post_id:"post-1" ())
  in
  let b =
    A.of_board_signal ~keeper_name:"sangsu" ~recorded_at:100.0
      (signal ~post_id:"post-2" ())
  in
  Alcotest.(check bool)
    "distinct post id changes candidate id"
    true
    (not (String.equal a.A.candidate_id b.A.candidate_id))

let test_distinct_payload_on_same_post_changes_candidate_id () =
  let a =
    A.of_board_signal ~keeper_name:"sangsu" ~recorded_at:100.0
      (signal ~post_id:"post-1" ~content:"first comment" ())
  in
  let b =
    A.of_board_signal ~keeper_name:"sangsu" ~recorded_at:100.0
      (signal ~post_id:"post-1" ~content:"second comment" ())
  in
  Alcotest.(check bool)
    "distinct payload changes candidate id"
    true
    (not (String.equal a.A.candidate_id b.A.candidate_id))

let () =
  Alcotest.run
    "keeper_board_attention_candidate"
    [
      ( "candidate"
      , [ Alcotest.test_case
            "roundtrip and authority labels"
            `Quick
            test_candidate_roundtrip_and_authority
        ; Alcotest.test_case
            "record dedupes by keeper signal identity"
            `Quick
            test_record_dedupes_by_keeper_signal_identity
        ; Alcotest.test_case
            "distinct signal identity changes candidate id"
            `Quick
            test_distinct_signal_identity_changes_candidate_id
        ; Alcotest.test_case
            "distinct payload on same post changes candidate id"
            `Quick
            test_distinct_payload_on_same_post_changes_candidate_id
        ] );
    ]

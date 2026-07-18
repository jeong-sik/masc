open Alcotest
module A = Fusion_run_authority
let fresh_base () =
  let path = Filename.temp_file "fusion-authority-" "" in
  Sys.remove path;
  Unix.mkdir path 0o700;
  path
;;
let success answer = A.Succeeded answer
let failure ~code detail = A.Failed { code; detail }
let run_file directory keeper run_id =
  let key = Printf.sprintf "%d:%s%d:%s" (String.length keeper) keeper (String.length run_id) run_id in
  let digest = Digestif.SHA256.(digest_string key |> to_hex) in
  Filename.concat directory (digest ^ ".jsonl")
;;
let test_exact_lifecycle_and_validation () =
  let base_path = fresh_base () in
  let store = A.create ~directory:(Filename.concat base_path "runs") in
  (match A.register store ~keeper:"" ~run_id:"r" ~preset:"p" ~started_at:1. with
   | Error A.Empty_keeper -> ()
   | _ -> fail "empty keeper identity was accepted");
  (match A.register store ~keeper:"k" ~run_id:"" ~preset:"p" ~started_at:1. with
   | Error A.Empty_run_id -> ()
   | _ -> fail "empty run identity was accepted");
  (match A.register store ~keeper:"k" ~run_id:"r" ~preset:"p" ~started_at:Float.nan with
   | Error (A.Invalid_started_at _) -> ()
   | _ -> fail "non-finite start time was accepted");
  (match A.register store ~keeper:"k" ~run_id:"r" ~preset:"p" ~started_at:1. with
   | Ok A.Registered -> ()
   | _ -> fail "first registration must be durable");
  let restarted = A.create ~directory:(Filename.concat base_path "runs") in
  (match A.register restarted ~keeper:"k" ~run_id:"r" ~preset:"p" ~started_at:1. with
   | Ok A.Already_running -> ()
   | _ -> fail "exact registration retry must be idempotent");
  let winner = success "answer" in
  (match A.claim_terminal store ~keeper:"k" ~run_id:"r" winner with
   | Ok A.First_committed -> ()
   | _ -> fail "first terminal must commit");
  (match A.register store ~keeper:"k" ~run_id:"r" ~preset:"p" ~started_at:1. with
   | Ok (A.Already_settled terminal) ->
     check bool "settled retry returns winner" true (A.equal_terminal winner terminal)
   | _ -> fail "settled registration retry could start another run");
  (match A.claim_terminal restarted ~keeper:"k" ~run_id:"r" winner with
   | Ok A.Already_same -> ()
   | _ -> fail "restart must retain the winner");
  (match
     A.claim_terminal store ~keeper:"k" ~run_id:"r"
       (failure ~code:"judge_failed" "detail")
   with
   | Ok (A.Conflict terminal) ->
     check bool "conflict returns exact winner" true (A.equal_terminal winner terminal)
   | _ -> fail "different terminal must conflict");
  let reject terminal expected =
    match A.claim_terminal store ~keeper:"k" ~run_id:"other" terminal, expected with
    | Error A.Empty_success_answer, `Answer
    | Error A.Empty_failure_code, `Code
    | Error A.Empty_failure_detail, `Detail
    | Error A.Empty_cancellation_detail, `Cancel -> ()
    | _ -> fail "terminal validation returned the wrong result"
  in
  reject (success "") `Answer;
  reject (failure ~code:"" "detail") `Code;
  reject (failure ~code:"code" "") `Detail;
  reject (A.Cancelled "") `Cancel;
  match A.claim_terminal store ~keeper:"k" ~run_id:"missing" (A.Cancelled "shutdown") with
  | Error A.Orphan_terminal -> ()
  | _ -> fail "terminal without durable registration must be rejected"
;;
let test_corruption_is_per_run_and_semantic () =
  let base_path = fresh_base () in
  let directory = Filename.concat base_path "runs" in
  let store = A.create ~directory in
  let register run_id =
    match A.register store ~keeper:"k" ~run_id ~preset:"p" ~started_at:1. with
    | Ok A.Registered -> ()
    | _ -> fail (run_id ^ " registration failed")
  in
  register "bad";
  let bad_path = run_file directory "k" "bad" in
  let registered = Fs_compat.load_file bad_path in
  Fs_compat.save_file bad_path (String.sub registered 0 (String.length registered - 1));
  (match A.claim_terminal store ~keeper:"k" ~run_id:"bad" (success "answer") with
   | Error A.Partial_tail -> ()
   | _ -> fail "partial tail must fail explicitly");
  register "peer";
  (match A.claim_terminal store ~keeper:"k" ~run_id:"peer" (success "peer answer") with
   | Ok A.First_committed -> ()
   | _ -> fail "corrupt peer must not block an unrelated run");
  let versioned =
    match Yojson.Safe.from_string registered with
    | `Assoc fields -> `Assoc (("schema_version", `Int 2) :: List.remove_assoc "schema_version" fields)
    | _ -> fail "registered record was not an object"
  in
  Fs_compat.save_file bad_path (Yojson.Safe.to_string versioned ^ "\n");
  (match A.claim_terminal store ~keeper:"k" ~run_id:"bad" (success "answer") with
   | Error (A.Unsupported_schema_version { found = 2; _ }) -> ()
   | _ -> fail "unsupported schema version must fail explicitly");
  register "order";
  (match A.claim_terminal store ~keeper:"k" ~run_id:"order" (success "ordered") with
   | Ok A.First_committed -> ()
   | _ -> fail "ordered terminal did not commit");
  let order_path = run_file directory "k" "order" in
  (match String.split_on_char '\n' (Fs_compat.load_file order_path) with
   | [ registration; terminal; "" ] ->
     Fs_compat.save_file order_path (terminal ^ "\n");
     (match A.claim_terminal store ~keeper:"k" ~run_id:"order" (success "ordered") with
      | Error A.Orphan_terminal -> ()
      | _ -> fail "orphan terminal must fail explicitly");
     Fs_compat.save_file order_path (terminal ^ "\n" ^ registration ^ "\n");
     (match A.claim_terminal store ~keeper:"k" ~run_id:"order" (success "ordered") with
      | Error A.Reversed_records -> ()
      | _ -> fail "reversed records must fail explicitly")
   | _ -> fail "expected exact register/terminal JSONL pair");
  let foreign_path = run_file directory "k" "foreign" in
  Fs_compat.save_file foreign_path
    (Fs_compat.load_file (run_file directory "k" "peer"));
  match A.claim_terminal store ~keeper:"k" ~run_id:"foreign" (success "foreign") with
  | Error (A.Identity_mismatch _) -> ()
  | _ -> fail "hashed path must still verify persisted identity"
;;
let () =
  run "fusion_run_authority"
    [ ( "authority"
      , [ test_case "exact lifecycle and validation" `Quick
            test_exact_lifecycle_and_validation
        ; test_case "per-run corruption and semantic validation" `Quick
            test_corruption_is_per_run_and_semantic
        ] )
    ]
;;

(* Prompt composition and strict verdict parsing for the canary LLM judge
   (lib/keeper_canary/keeper_canary_judge.ml, masc task-11, M1 PR2).
   The provider call itself lives in bin/ and is exercised by live runs;
   everything here is the pure contract both sides of that call rely on. *)

let facts3 = Keeper_canary_facts.generate ~seed:"judge-test-seed" ~count:3

let categories fs = List.map (fun (f : Keeper_canary_facts.fact) -> f.category) fs

let reply_json ?(rationale = "all three values appear verbatim") entries =
  `Assoc
    [ ( "per_fact"
      , `List
          (List.map
             (fun (c, r) -> `Assoc [ ("category", `String c); ("recalled", `Bool r) ])
             entries) )
    ; ("rationale", `String rationale)
    ]
  |> Yojson.Safe.to_string

let parse ?(facts = facts3) reply =
  Keeper_canary_judge.parse_reply ~judge_runtime:"rt.judge-test" ~facts reply

let expect_error name reply pattern =
  match parse reply with
  | Ok _ -> Alcotest.failf "%s: expected Error, got Ok" name
  | Error msg ->
    Alcotest.(check bool)
      (Printf.sprintf "%s: error mentions %s (got: %s)" name pattern msg)
      true
      (Astring.String.is_infix ~affix:pattern msg)

let test_compose_prompt_carries_facts_and_reply () =
  let prompt =
    Keeper_canary_judge.compose_prompt ~facts:facts3 ~recall_reply:"REPLY-MARKER-77"
  in
  List.iter
    (fun (f : Keeper_canary_facts.fact) ->
      Alcotest.(check bool)
        (f.category ^ " category in prompt")
        true
        (Astring.String.is_infix ~affix:f.category prompt);
      Alcotest.(check bool)
        (f.category ^ " value in prompt")
        true
        (Astring.String.is_infix ~affix:f.value prompt))
    facts3;
  Alcotest.(check bool)
    "recall reply embedded"
    true
    (Astring.String.is_infix ~affix:"REPLY-MARKER-77" prompt);
  Alcotest.(check bool)
    "JSON contract stated"
    true
    (Astring.String.is_infix ~affix:"per_fact" prompt)

let test_parse_valid_all_recalled () =
  let entries = List.map (fun c -> (c, true)) (categories facts3) in
  match parse (reply_json entries) with
  | Error msg -> Alcotest.failf "expected Ok, got: %s" msg
  | Ok j ->
    Alcotest.(check string) "judge_runtime" "rt.judge-test" j.judge_runtime;
    Alcotest.(check int) "recalled_count" 3 j.recalled_count;
    Alcotest.(check bool) "all_recalled" true j.all_recalled;
    Alcotest.(check (list string))
      "per_fact in fact order"
      (categories facts3)
      (List.map (fun (e : Keeper_canary_judge.per_fact) -> e.category) j.per_fact)

let test_parse_partial_not_all_recalled () =
  let entries =
    List.mapi (fun i c -> (c, i <> 1)) (categories facts3)
  in
  match parse (reply_json entries) with
  | Error msg -> Alcotest.failf "expected Ok, got: %s" msg
  | Ok j ->
    Alcotest.(check int) "recalled_count" 2 j.recalled_count;
    Alcotest.(check bool) "all_recalled" false j.all_recalled

let test_parse_reorders_to_fact_order () =
  let entries = List.rev_map (fun c -> (c, true)) (categories facts3) in
  match parse (reply_json entries) with
  | Error msg -> Alcotest.failf "expected Ok, got: %s" msg
  | Ok j ->
    Alcotest.(check (list string))
      "normalized order"
      (categories facts3)
      (List.map (fun (e : Keeper_canary_judge.per_fact) -> e.category) j.per_fact)

let test_parse_accepts_json_fence () =
  let entries = List.map (fun c -> (c, true)) (categories facts3) in
  let fenced = "```json\n" ^ reply_json entries ^ "\n```" in
  match parse fenced with
  | Error msg -> Alcotest.failf "expected Ok, got: %s" msg
  | Ok j -> Alcotest.(check bool) "all_recalled" true j.all_recalled

let test_parse_accepts_bare_fence () =
  let entries = List.map (fun c -> (c, true)) (categories facts3) in
  let fenced = "```\n" ^ reply_json entries ^ "\n```" in
  match parse fenced with
  | Error msg -> Alcotest.failf "expected Ok, got: %s" msg
  | Ok j -> Alcotest.(check int) "recalled_count" 3 j.recalled_count

let test_parse_rejects_missing_category () =
  let entries =
    match List.map (fun c -> (c, true)) (categories facts3) with
    | _ :: rest -> rest
    | [] -> assert false
  in
  expect_error "missing category" (reply_json entries) "missing category"

let test_parse_rejects_unexpected_category () =
  let entries = ("not_a_real_category", true) :: List.map (fun c -> (c, true)) (categories facts3) in
  expect_error "unexpected category" (reply_json entries) "unexpected category"

let test_parse_rejects_duplicate_category () =
  let entries =
    match categories facts3 with
    | first :: _ -> (first, true) :: List.map (fun c -> (c, true)) (categories facts3)
    | [] -> assert false
  in
  expect_error "duplicate category" (reply_json entries) "duplicate category"

let test_parse_rejects_non_bool_recalled () =
  let broken =
    `Assoc
      [ ( "per_fact"
        , `List
            (List.map
               (fun c ->
                 `Assoc [ ("category", `String c); ("recalled", `String "yes") ])
               (categories facts3)) )
      ; ("rationale", `String "r")
      ]
    |> Yojson.Safe.to_string
  in
  expect_error "non-bool recalled" broken "not a boolean"

let test_parse_rejects_missing_rationale () =
  let broken =
    `Assoc
      [ ( "per_fact"
        , `List
            (List.map
               (fun c -> `Assoc [ ("category", `String c); ("recalled", `Bool true) ])
               (categories facts3)) )
      ]
    |> Yojson.Safe.to_string
  in
  expect_error "missing rationale" broken "missing field: rationale"

let test_parse_rejects_blank_rationale () =
  let entries = List.map (fun c -> (c, true)) (categories facts3) in
  expect_error "blank rationale" (reply_json ~rationale:"   " entries) "rationale is empty"

let test_parse_rejects_extra_top_level_key () =
  let entries = List.map (fun c -> (c, true)) (categories facts3) in
  let with_extra =
    match Yojson.Safe.from_string (reply_json entries) with
    | `Assoc kvs -> Yojson.Safe.to_string (`Assoc (kvs @ [ ("verdict", `String "PASS") ]))
    | _ -> assert false
  in
  expect_error "extra top-level key" with_extra "unexpected key verdict"

let test_parse_rejects_extra_entry_key () =
  let broken =
    `Assoc
      [ ( "per_fact"
        , `List
            (List.map
               (fun c ->
                 `Assoc
                   [ ("category", `String c)
                   ; ("recalled", `Bool true)
                   ; ("confidence", `Float 0.9)
                   ])
               (categories facts3)) )
      ; ("rationale", `String "r")
      ]
    |> Yojson.Safe.to_string
  in
  expect_error "extra entry key" broken "unexpected key confidence"

let test_parse_rejects_non_json () =
  expect_error "prose reply" "The assistant recalled everything correctly." "invalid JSON"

let test_parse_rejects_non_object () =
  expect_error "list reply" "[1, 2, 3]" "not a JSON object"

let test_parse_empty_facts_never_all_recalled () =
  (* Zero facts means there was nothing to prove: an empty per_fact list
     parses, but it must not read as a passing judgment. *)
  match parse ~facts:[] (reply_json ~rationale:"nothing to check" []) with
  | Error msg -> Alcotest.failf "expected Ok, got: %s" msg
  | Ok j ->
    Alcotest.(check int) "recalled_count" 0 j.recalled_count;
    Alcotest.(check bool) "all_recalled stays false" false j.all_recalled

let test_judgment_to_yojson_shape () =
  let entries = List.map (fun c -> (c, true)) (categories facts3) in
  match parse (reply_json entries) with
  | Error msg -> Alcotest.failf "expected Ok, got: %s" msg
  | Ok j ->
    (match Keeper_canary_judge.judgment_to_yojson j with
     | `Assoc kvs ->
       List.iter
         (fun key ->
           Alcotest.(check bool)
             (key ^ " present")
             true
             (List.mem_assoc key kvs))
         [ "judge_runtime"; "per_fact"; "recalled_count"; "all_recalled"; "rationale" ];
       (match List.assoc "per_fact" kvs with
        | `List rows -> Alcotest.(check int) "per_fact rows" 3 (List.length rows)
        | _ -> Alcotest.fail "per_fact is not a list")
     | _ -> Alcotest.fail "judgment_to_yojson is not an object")

let () =
  Alcotest.run
    "keeper_canary_judge"
    [ ( "compose"
      , [ Alcotest.test_case "prompt carries facts, reply, contract" `Quick
            test_compose_prompt_carries_facts_and_reply
        ] )
    ; ( "parse-accept"
      , [ Alcotest.test_case "valid all recalled" `Quick test_parse_valid_all_recalled
        ; Alcotest.test_case "partial recall" `Quick test_parse_partial_not_all_recalled
        ; Alcotest.test_case "reorders to fact order" `Quick test_parse_reorders_to_fact_order
        ; Alcotest.test_case "json fence" `Quick test_parse_accepts_json_fence
        ; Alcotest.test_case "bare fence" `Quick test_parse_accepts_bare_fence
        ; Alcotest.test_case "empty facts never pass" `Quick
            test_parse_empty_facts_never_all_recalled
        ] )
    ; ( "parse-reject"
      , [ Alcotest.test_case "missing category" `Quick test_parse_rejects_missing_category
        ; Alcotest.test_case "unexpected category" `Quick
            test_parse_rejects_unexpected_category
        ; Alcotest.test_case "duplicate category" `Quick
            test_parse_rejects_duplicate_category
        ; Alcotest.test_case "non-bool recalled" `Quick test_parse_rejects_non_bool_recalled
        ; Alcotest.test_case "missing rationale" `Quick test_parse_rejects_missing_rationale
        ; Alcotest.test_case "blank rationale" `Quick test_parse_rejects_blank_rationale
        ; Alcotest.test_case "extra top-level key" `Quick
            test_parse_rejects_extra_top_level_key
        ; Alcotest.test_case "extra entry key" `Quick test_parse_rejects_extra_entry_key
        ; Alcotest.test_case "non-json" `Quick test_parse_rejects_non_json
        ; Alcotest.test_case "non-object" `Quick test_parse_rejects_non_object
        ] )
    ; ( "serialize"
      , [ Alcotest.test_case "judgment json shape" `Quick test_judgment_to_yojson_shape ] )
    ]

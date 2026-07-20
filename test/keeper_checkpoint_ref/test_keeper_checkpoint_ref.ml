let result_ok = function
  | Ok value -> value
  | Error _ -> Alcotest.fail "checkpoint identity construction failed"
;;

let trace_id =
  match Keeper_id.Trace_id.of_string "trace-1" with
  | Ok value -> value
  | Error detail -> Alcotest.fail detail
;;

let create bytes =
  Keeper_checkpoint_ref.create
    ~trace_id
    ~generation:2
    ~turn_count:7
    ~canonical_checkpoint_bytes:bytes
  |> result_ok
;;

let test_exact_bytes_identity () =
  let first = create {|{"messages":["before"]}|} in
  let same = create {|{"messages":["before"]}|} in
  let changed = create {|{ "messages": ["before"] }|} in
  Alcotest.(check bool) "same exact bytes" true (Keeper_checkpoint_ref.equal first same);
  Alcotest.(check bool) "re-encoded bytes differ" false (Keeper_checkpoint_ref.equal first changed);
  Alcotest.(check string) "typed trace" "trace-1" (Keeper_id.Trace_id.to_string first.trace_id);
  Alcotest.(check int) "generation" 2 first.generation;
  Alcotest.(check int) "turn count" 7 first.turn_count
;;

let test_typed_rejections () =
  let make generation turn_count =
    Keeper_checkpoint_ref.create
      ~trace_id
      ~generation
      ~turn_count
      ~canonical_checkpoint_bytes:"{}"
  in
  Alcotest.(check bool)
    "negative generation"
    true
    (match make (-1) 0 with
     | Error (Keeper_checkpoint_ref.Negative_generation (-1)) -> true
     | Ok _ | Error _ -> false);
  Alcotest.(check bool)
    "negative turn"
    true
    (match make 0 (-2) with
     | Error (Keeper_checkpoint_ref.Negative_turn_count (-2)) -> true
     | Ok _ | Error _ -> false)
;;

let test_persisted_roundtrip_is_canonical () =
  let expected = create {|{"messages":["before"]}|} in
  let restore sha256 =
    Keeper_checkpoint_ref.of_persisted
      ~trace_id
      ~generation:expected.generation
      ~turn_count:expected.turn_count
      ~sha256
  in
  (match restore expected.sha256 with
   | Ok restored ->
     Alcotest.(check bool)
       "restored identity"
       true
       (Keeper_checkpoint_ref.equal expected restored)
   | Error _ -> Alcotest.fail "canonical persisted identity was rejected");
  List.iter
    (fun sha256 ->
       match restore sha256 with
       | Error (Keeper_checkpoint_ref.Invalid_sha256 _) -> ()
       | Ok _ | Error _ -> Alcotest.fail "non-canonical digest was accepted")
    [ String.uppercase_ascii expected.sha256; String.sub expected.sha256 0 62; " " ^ expected.sha256 ]
;;

let test_json_roundtrip_is_exact () =
  let expected = create {|{"messages":["before"]}|} in
  let json = Keeper_checkpoint_ref.to_yojson expected in
  let restored = Keeper_checkpoint_ref.of_yojson json |> result_ok in
  Alcotest.(check bool)
    "json identity"
    true
    (Keeper_checkpoint_ref.equal expected restored);
  let reordered =
    `Assoc
      [ "sha256", `String expected.sha256
      ; "turn_count", `Int expected.turn_count
      ; "trace_id", `String (Keeper_id.Trace_id.to_string expected.trace_id)
      ; "generation", `Int expected.generation
      ]
  in
  let reordered = Keeper_checkpoint_ref.of_yojson reordered |> result_ok in
  Alcotest.(check bool)
    "object field order is not identity"
    true
    (Keeper_checkpoint_ref.equal expected reordered);
  match json with
  | `Assoc fields ->
    (match Keeper_checkpoint_ref.of_yojson (`Assoc (("extra", `Bool true) :: fields)) with
     | Error _ -> ()
     | Ok _ -> Alcotest.fail "unknown checkpoint identity field was accepted")
  | _ -> Alcotest.fail "checkpoint identity encoder returned a non-object"
;;

let () =
  Alcotest.run
    "keeper checkpoint ref"
    [ ( "identity"
      , [ Alcotest.test_case "exact bytes" `Quick test_exact_bytes_identity
        ; Alcotest.test_case "typed rejections" `Quick test_typed_rejections
        ; Alcotest.test_case
            "persisted canonical roundtrip"
            `Quick
            test_persisted_roundtrip_is_canonical
        ; Alcotest.test_case "json roundtrip" `Quick test_json_roundtrip_is_exact
        ] )
    ]

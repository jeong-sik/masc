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
  Alcotest.(check int) "turn count" 7 first.turn_count
;;

let test_typed_rejections () =
  let make turn_count =
    Keeper_checkpoint_ref.create
      ~trace_id
      ~turn_count
      ~canonical_checkpoint_bytes:"{}"
  in
  Alcotest.(check bool)
    "negative turn"
    true
    (match make (-2) with
     | Error (Keeper_checkpoint_ref.Negative_turn_count (-2)) -> true
     | Ok _ | Error _ -> false)
;;

let test_persisted_roundtrip_is_canonical () =
  let expected = create {|{"messages":["before"]}|} in
  let restore sha256 =
    Keeper_checkpoint_ref.of_persisted
      ~trace_id
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

(* The digest is fed in bounded slices. Sizes cover the empty string, one
   byte, and a 4 MiB string and one byte either side of it: an exact multiple
   of any power-of-two slice up to 4 MiB, and a short last slice both ways. The
   bytes vary by position, so a slice fed twice, skipped or out of order
   changes the digest. *)
let test_sliced_digest_equals_one_shot_digest () =
  let four_mib = 1 lsl 22 in
  List.iter
    (fun size ->
       let bytes = String.init size (fun index -> Char.chr ((index * 31 + 7) land 255)) in
       Alcotest.(check string)
         (Printf.sprintf "%d bytes" size)
         Digestif.SHA256.(to_hex (digest_string bytes))
         (Keeper_checkpoint_ref.sha256_of_canonical_bytes bytes);
       Alcotest.(check string)
         (Printf.sprintf "a reference over %d bytes carries that digest" size)
         (Keeper_checkpoint_ref.sha256_of_canonical_bytes bytes)
         (create bytes).sha256)
    [ 0; 1; four_mib - 1; four_mib; four_mib + 1 ]
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
        ; Alcotest.test_case
            "sliced digest equals the one-shot digest"
            `Quick
            test_sliced_digest_equals_one_shot_digest
        ] )
    ]

(* Domain_budget keeps the server's domains within
   Domain.recommended_domain_count () - 1 (RFC-0474 L1). *)

let plan ~recommended ~fixed ~override =
  match Domain_budget.plan ~recommended ~fixed ~override with
  | Ok plan -> plan
  | Error error -> Alcotest.failf "refused: %s" (Domain_budget.error_to_string error)

let check_plan name ~shared ~codec (plan : Domain_budget.plan) =
  Alcotest.(check int) (name ^ ": shared pool") shared plan.Domain_budget.shared_pool;
  Alcotest.(check int) (name ^ ": execution codec") codec plan.Domain_budget.execution_codec

let test_sixteen_cores () =
  let p = plan ~recommended:16 ~fixed:3 ~override:None in
  check_plan "16 cores" ~shared:10 ~codec:2 p;
  Alcotest.(check int) "total is the limit" 15 (Domain_budget.total p);
  Alcotest.(check bool) "within limit" true (Domain_budget.within_limit p);
  let serving = plan ~recommended:16 ~fixed:4 ~override:None in
  check_plan "serving domain on" ~shared:9 ~codec:2 serving

let test_override () =
  check_plan "override 6" ~shared:6 ~codec:2 (plan ~recommended:16 ~fixed:3 ~override:(Some 6));
  check_plan "override at the limit" ~shared:10 ~codec:2
    (plan ~recommended:16 ~fixed:3 ~override:(Some 10));
  match Domain_budget.plan ~recommended:16 ~fixed:3 ~override:(Some 11) with
  | Ok _ -> Alcotest.fail "an override above the limit was accepted"
  | Error (Domain_budget.Override_exceeds_limit { override; limit; fixed; execution_codec }) ->
    Alcotest.(check (list int)) "error fields" [ 11; 15; 3; 2 ] [ override; limit; fixed; execution_codec ]

let test_small_host () =
  let p = plan ~recommended:4 ~fixed:3 ~override:None in
  check_plan "4 cores" ~shared:1 ~codec:1 p;
  Alcotest.(check bool) "over the limit is reported" false (Domain_budget.within_limit p);
  check_plan "override 1 on 4 cores" ~shared:1 ~codec:1 (plan ~recommended:4 ~fixed:3 ~override:(Some 1));
  check_plan "one core" ~shared:1 ~codec:1 (plan ~recommended:1 ~fixed:3 ~override:None)

let test_codec_shrinks_before_shared_pool () =
  (* limit 6, fixed 3: three left, two for the codec would leave one. *)
  check_plan "7 cores" ~shared:1 ~codec:2 (plan ~recommended:7 ~fixed:3 ~override:None);
  (* limit 5, fixed 3: two left, the codec takes one so the pool keeps one. *)
  check_plan "6 cores" ~shared:1 ~codec:1 (plan ~recommended:6 ~fixed:3 ~override:None)

let () =
  Alcotest.run "domain_budget"
    [ ( "plan",
        [ Alcotest.test_case "16 cores" `Quick test_sixteen_cores;
          Alcotest.test_case "override" `Quick test_override;
          Alcotest.test_case "small host" `Quick test_small_host;
          Alcotest.test_case "codec shrinks first" `Quick test_codec_shrinks_before_shared_pool ] ) ]

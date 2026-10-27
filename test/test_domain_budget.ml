(* Domain_budget keeps the server's domains within
   Domain.recommended_domain_count () - 1 (RFC-0474 L1), the read pool
   included (RFC-0204 L3). *)

let plan ~recommended ~fixed ~override =
  match Domain_budget.plan ~recommended ~fixed ~override with
  | Ok plan -> plan
  | Error error -> Alcotest.failf "refused: %s" (Domain_budget.error_to_string error)

let check_plan name ~shared ~read ~codec (plan : Domain_budget.plan) =
  Alcotest.(check int) (name ^ ": shared pool") shared plan.Domain_budget.shared_pool;
  Alcotest.(check int) (name ^ ": read pool") read plan.Domain_budget.read_pool;
  Alcotest.(check int) (name ^ ": execution codec") codec plan.Domain_budget.execution_codec

let test_sixteen_cores () =
  let p = plan ~recommended:16 ~fixed:3 ~override:None in
  check_plan "16 cores" ~shared:8 ~read:2 ~codec:2 p;
  Alcotest.(check int) "total is the limit" 15 (Domain_budget.total p);
  Alcotest.(check bool) "within limit" true (Domain_budget.within_limit p);
  let serving = plan ~recommended:16 ~fixed:4 ~override:None in
  check_plan "serving domain on" ~shared:7 ~read:2 ~codec:2 serving

let test_override () =
  check_plan "override 6" ~shared:6 ~read:2 ~codec:2
    (plan ~recommended:16 ~fixed:3 ~override:(Some 6));
  check_plan "override at the limit" ~shared:8 ~read:2 ~codec:2
    (plan ~recommended:16 ~fixed:3 ~override:(Some 8));
  match Domain_budget.plan ~recommended:16 ~fixed:3 ~override:(Some 9) with
  | Ok _ -> Alcotest.fail "an override above the limit was accepted"
  | Error (Domain_budget.Override_exceeds_limit { override; limit; fixed; read_pool; execution_codec })
    ->
    Alcotest.(check (list int)) "error fields" [ 9; 15; 3; 2; 2 ]
      [ override; limit; fixed; read_pool; execution_codec ]

let test_small_host () =
  let p = plan ~recommended:4 ~fixed:3 ~override:None in
  check_plan "4 cores" ~shared:1 ~read:1 ~codec:1 p;
  Alcotest.(check bool) "over the limit is reported" false (Domain_budget.within_limit p);
  check_plan "override 1 on 4 cores" ~shared:1 ~read:1 ~codec:1
    (plan ~recommended:4 ~fixed:3 ~override:(Some 1));
  check_plan "one core" ~shared:1 ~read:1 ~codec:1 (plan ~recommended:1 ~fixed:3 ~override:None)

let test_codec_shrinks_before_the_read_pool () =
  (* limit 8, fixed 3: five left, enough for codec 2, read 2 and one shared. *)
  check_plan "9 cores" ~shared:1 ~read:2 ~codec:2 (plan ~recommended:9 ~fixed:3 ~override:None);
  (* limit 7, fixed 3: four left, the codec gives up its second domain first. *)
  check_plan "8 cores" ~shared:1 ~read:2 ~codec:1 (plan ~recommended:8 ~fixed:3 ~override:None);
  (* limit 6, fixed 3: three left, the read pool gives up its second next. *)
  check_plan "7 cores" ~shared:1 ~read:1 ~codec:1 (plan ~recommended:7 ~fixed:3 ~override:None)

let () =
  Alcotest.run "domain_budget"
    [ ( "plan",
        [ Alcotest.test_case "16 cores" `Quick test_sixteen_cores;
          Alcotest.test_case "override" `Quick test_override;
          Alcotest.test_case "small host" `Quick test_small_host;
          Alcotest.test_case "codec shrinks before the read pool" `Quick
            test_codec_shrinks_before_the_read_pool ] ) ]

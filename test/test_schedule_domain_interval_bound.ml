(** Pin the minimum recurrence interval bound in {!Schedule_domain}. A schedule
    whose [interval_sec] is below the bound used to be accepted and then fired
    without limit (#29365). *)

open Alcotest

let check_ok label interval_sec =
  match Schedule_domain.validate_recurrence (Schedule_domain.Interval { interval_sec }) with
  | Ok _ -> ()
  | Error err -> failf "%s: expected Ok, got Error %s" label err
;;

let check_error label interval_sec =
  match Schedule_domain.validate_recurrence (Schedule_domain.Interval { interval_sec }) with
  | Ok _ -> failf "%s: expected Error, got Ok" label
  | Error _ -> ()
;;

let test_positive_below_bound_rejected () =
  check_error "interval 1s is below the 60s bound" 1
;;

let test_boundary_accepted () =
  check_ok "interval 60s is at the bound" 60
;;

let test_above_bound_accepted () =
  check_ok "interval 3600s is above the bound" 3600
;;

let test_zero_rejected () =
  check_error "interval 0 is rejected" 0
;;

let test_negative_rejected () =
  check_error "interval -5 is rejected" (-5)
;;

let () =
  run
    "schedule_domain_interval_bound"
    [
      ( "minimum interval bound",
        [
          test_case "1s rejected" `Quick test_positive_below_bound_rejected;
          test_case "60s accepted" `Quick test_boundary_accepted;
          test_case "3600s accepted" `Quick test_above_bound_accepted;
        ] );
      ( "positivity",
        [
          test_case "0 rejected" `Quick test_zero_rejected;
          test_case "negative rejected" `Quick test_negative_rejected;
        ] );
    ]
;;

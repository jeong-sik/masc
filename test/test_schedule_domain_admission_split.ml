(** Pin the admission-bound split in {!Schedule_domain} (#29365, review
    5224937258 on #36848).

    [validate_recurrence] is shared by the JSON decoder, so it may enforce only
    structural validity — [Schedule_store] loads legacy records through it and
    a fail-fast Result fold would corrupt the whole ledger if the decoder
    rejected a pre-bound interval. The minimum-interval bound therefore lives
    in [check_admission], applied by [create_request] only.

    Five properties:

    1. The decoder accepts pre-bound intervals (> 0, < 60).
    2. The decoder still rejects non-positive intervals.
    3. [check_admission] rejects intervals below the bound.
    4. [check_admission] accepts the boundary value.
    5. [create_request] rejects a below-bound interval at admission. *)

open Alcotest

let interval interval_sec = Schedule_domain.Interval { interval_sec }

let check_decoder_ok label interval_sec =
  match Schedule_domain.validate_recurrence (interval interval_sec) with
  | Ok _ -> ()
  | Error err -> failf "%s: expected Ok, got Error %s" label err
;;

let check_decoder_error label interval_sec =
  match Schedule_domain.validate_recurrence (interval interval_sec) with
  | Ok _ -> failf "%s: expected Error, got Ok" label
  | Error _ -> ()
;;

let check_admission_ok label interval_sec =
  match Schedule_domain.check_admission (interval interval_sec) with
  | Ok _ -> ()
  | Error err -> failf "%s: expected Ok, got Error %s" label err
;;

let check_admission_error label interval_sec =
  match Schedule_domain.check_admission (interval interval_sec) with
  | Ok _ -> failf "%s: expected Error, got Ok" label
  | Error _ -> ()
;;

(* --- 1. The decoder keeps legacy records readable ------------------ *)

let test_decoder_accepts_prebound_interval () =
  check_decoder_ok "decoder accepts 1s (legacy record)" 1;
  check_decoder_ok "decoder accepts 59s (legacy record)" 59
;;

(* --- 2. Structural validity stays with the decoder ----------------- *)

let test_decoder_rejects_nonpositive () =
  check_decoder_error "decoder rejects 0" 0;
  check_decoder_error "decoder rejects -5" (-5)
;;

(* --- 3/4. The admission bound lives in check_admission ------------- *)

let test_admission_rejects_below_bound () =
  check_admission_error "admission rejects 1s" 1;
  check_admission_error "admission rejects 59s" 59
;;

let test_admission_accepts_boundary () =
  check_admission_ok "admission accepts 60s" 60;
  check_admission_ok "admission accepts 3600s" 3600
;;

(* --- 5. create_request applies the bound --------------------------- *)

let test_create_request_applies_bound () =
  let requested_by =
    { Schedule_domain.id = "k1"
    ; kind = Schedule_domain.Automated_actor
    ; display_name = None
    }
  in
  let scheduled_by = requested_by in
  let payload = `Assoc [] in
  let source = Schedule_domain.Automated_request in
  let result =
    Schedule_domain.create_request
      ~schedule_id:"sched-bound-check"
      ~requested_by
      ~scheduled_by
      ~requested_at:1789570000.0
      ~due_at:1789570060.0
      ~payload
      ~source
      ~recurrence:(interval 30)
      ()
  in
  match result with
  | Ok _ -> failf "create_request accepted a below-bound interval"
  | Error _ -> ()
;;

let () =
  run
    "schedule_domain_admission_split"
    [
      ( "decoder keeps legacy records readable",
        [ test_case "prebound intervals pass" `Quick test_decoder_accepts_prebound_interval ] );
      ( "decoder structural validity",
        [ test_case "non-positive rejected" `Quick test_decoder_rejects_nonpositive ] );
      ( "admission bound",
        [
          test_case "below bound rejected" `Quick test_admission_rejects_below_bound;
          test_case "boundary accepted" `Quick test_admission_accepts_boundary;
        ] );
      ( "create_request",
        [ test_case "below-bound interval rejected" `Quick test_create_request_applies_bound ] );
    ]
;;

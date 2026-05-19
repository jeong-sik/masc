(** RFC-0144 — Parse_outcome unit tests.

    Covers:
    1. Ok path (successful parse).
    2. Error (`Other exn) path (Failure / Invalid_argument).
    3. Yojson-shaped exception classification via [of_exn] (using a
       custom exception with the same [Printexc.exn_slot_name] would
       require Obj.magic; instead we test the negative case + provide a
       Failure case for the structural contract).
    4. Cancellation re-raise (Eio.Cancel.Cancelled is *not* absorbed). *)

open Alcotest

let test_ok () =
  let r = Parse_outcome.parse_safe int_of_string "42" in
  match r with
  | Ok 42 -> ()
  | Ok n -> failf "expected Ok 42, got Ok %d" n
  | Error _ -> fail "expected Ok 42, got Error"

let test_error_other () =
  let r = Parse_outcome.parse_safe int_of_string "not-a-number" in
  match r with
  | Ok n -> failf "expected Error, got Ok %d" n
  | Error (`Other (Failure _)) -> ()
  | Error (`Other _) -> ()
  | Error (`Json_parse_error _) ->
      fail "expected `Other, got `Json_parse_error"

let test_of_exn_other () =
  match Parse_outcome.of_exn (Failure "boom") with
  | `Other (Failure msg) -> check string "Failure msg preserved" "boom" msg
  | `Other _ -> fail "expected Failure constructor preserved"
  | `Json_parse_error _ -> fail "Failure must classify as `Other"

let test_bind () =
  let r =
    Parse_outcome.bind (Parse_outcome.parse_safe int_of_string "10")
      (fun n -> Ok (n * 2))
  in
  check int "bind multiplies" 20 (match r with Ok v -> v | Error _ -> -1)

let test_map () =
  let r = Parse_outcome.map (fun n -> n + 1)
    (Parse_outcome.parse_safe int_of_string "7")
  in
  check int "map increments" 8 (match r with Ok v -> v | Error _ -> -1)

let test_to_option () =
  check (option int) "Ok -> Some"
    (Some 5) (Parse_outcome.to_option (Ok 5));
  check (option int) "Error -> None"
    None (Parse_outcome.to_option (Error (`Other (Failure "x"))))

(* RFC-0144 §Design — cancellation MUST re-raise. We drive an Eio
   fiber and cancel it from a sibling; inside the cancelled context
   the parser raises Cancelled which parse_safe must propagate. *)
let test_cancellation_reraises () =
  let cancelled_propagated = ref false in
  (try
     Eio_main.run @@ fun _env ->
     Eio.Cancel.sub (fun cc ->
       (* Cancel the local context, then attempt a parse that calls
          Cancel.check. Cancel.check raises Cancelled — parse_safe
          must re-raise, not absorb it into [`Other]. *)
       Eio.Cancel.cancel cc (Failure "trigger-cancel");
       let _ : (int, Parse_outcome.error) result =
         Parse_outcome.parse_safe
           (fun s ->
              Eio.Cancel.check cc;
              int_of_string s)
           "1"
       in
       ())
   with
   | Eio.Cancel.Cancelled _ -> cancelled_propagated := true);
  check bool "Cancellation re-raised, not absorbed into Error"
    true !cancelled_propagated

let () =
  Alcotest.run "parse_outcome"
    [
      ( "basic",
        [
          test_case "Ok path" `Quick test_ok;
          test_case "Error `Other path" `Quick test_error_other;
          test_case "of_exn classifies Failure as `Other" `Quick test_of_exn_other;
          test_case "bind" `Quick test_bind;
          test_case "map" `Quick test_map;
          test_case "to_option" `Quick test_to_option;
        ] );
      ( "cancellation",
        [
          test_case "Cancelled re-raised, not absorbed" `Quick
            test_cancellation_reraises;
        ] );
    ]

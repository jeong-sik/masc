open Alcotest

module Uid = Keeper_id.Uid
module Keeper_name = Keeper_id.Keeper_name
module Trace_id = Keeper_id.Trace_id

let expect_valid parse to_string label value =
  match parse value with
  | Ok parsed -> check string label value (to_string parsed)
  | Error error -> failf "%s rejected valid value %S: %s" label value error
;;

let expect_invalid parse label value =
  match parse value with
  | Error _ -> ()
  | Ok _ -> failf "%s accepted invalid value %S" label value
;;

let test_keeper_name_portable_grammar () =
  expect_valid
    Keeper_name.of_string
    Keeper_name.to_string
    "dotted keeper name"
    "owner.with.internal.dots";
  expect_invalid Keeper_name.of_string "reserved current-directory component" ".";
  expect_invalid Keeper_name.of_string "reserved parent-directory component" "..";
  expect_invalid Keeper_name.of_string "path separator" "owner/escape"
;;

let test_trace_id_keeps_bounded_non_dotted_grammar () =
  expect_valid Trace_id.of_string Trace_id.to_string "trace id" "trace-01";
  expect_invalid Trace_id.of_string "dotted trace id" "trace.with.dot";
  expect_invalid Trace_id.of_string "overlong trace id" (String.make 65 't')
;;

let test_generate_format () =
  let uid = Uid.generate () in
  let s = Uid.to_string uid in
  check bool "starts with keeper-" true (String.length s > 7);
  check bool "prefix is keeper-"
    true
    (String.sub s 0 7 = "keeper-");
  let uuid_part = String.sub s 7 (String.length s - 7) in
  check int "uuid part is 36 chars" 36 (String.length uuid_part);
  check bool "uuid has 4 dashes" true (
    let count = ref 0 in
    String.iter (fun c -> if c = '-' then incr count) uuid_part;
    !count = 4)

let test_generate_unique () =
  let uids = List.init 100 (fun _ -> Uid.generate ()) in
  let strings = List.map Uid.to_string uids in
  let rec all_unique = function
    | [] | [ _ ] -> true
    | x :: rest ->
      not (List.mem x rest) && all_unique rest
  in
  check bool "100 generated UIDs are all unique" true (all_unique strings)

let test_of_string_valid () =
  let uid = Uid.generate () in
  let s = Uid.to_string uid in
  match Uid.of_string s with
  | Ok uid' -> check bool "round-trip equal" true (Uid.equal uid uid')
  | Error e -> fail (Printf.sprintf "valid uid rejected: %s" e)

let test_of_string_invalid () =
  let cases =
    [ ("", "empty string")
    ; ("keeper-", "missing uuid")
    ; ("keeper-not-a-uuid", "bad uuid format")
    ; ("agent-12345678-1234-1234-1234-123456789abc", "wrong prefix")
    ]
  in
  List.iter (fun (input, label) ->
    match Uid.of_string input with
    | Ok _ -> fail (Printf.sprintf "%s should be rejected" label)
    | Error _ -> ()
  ) cases

let test_equal () =
  let a = Uid.generate () in
  let b = Uid.generate () in
  check bool "different UIDs not equal" false (Uid.equal a b);
  check bool "same UID equal" true (Uid.equal a a)

let () =
  run "Keeper ID"
    [
      ( "Uid",
        [
          test_case "generate format" `Quick test_generate_format;
          test_case "generate unique" `Quick test_generate_unique;
          test_case "of_string valid" `Quick test_of_string_valid;
          test_case "of_string invalid" `Quick test_of_string_invalid;
          test_case "equal" `Quick test_equal;
        ] );
      ( "Keeper_name",
        [ test_case
            "portable grammar and reserved path components"
            `Quick
            test_keeper_name_portable_grammar
        ] );
      ( "Trace_id",
        [ test_case
            "bounded non-dotted grammar remains independent"
            `Quick
            test_trace_id_keeps_bounded_non_dotted_grammar
        ] );
    ]

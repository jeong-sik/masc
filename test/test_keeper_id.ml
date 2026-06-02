open Alcotest

module Uid = Masc_mcp.Keeper_id.Uid

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
    ]

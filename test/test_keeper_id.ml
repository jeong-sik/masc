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

(* The name becomes a directory. #24343 is a name longer than a filesystem
   component can be, and the grammar alone does not stop one: [A-Za-z0-9._-]+
   matches any length. *)
let test_keeper_name_is_bounded () =
  let at_limit = String.make Keeper_name.max_length 'a' in
  expect_valid
    Keeper_name.of_string
    Keeper_name.to_string
    "a name exactly at the limit"
    at_limit;
  expect_invalid
    Keeper_name.of_string
    "a name one byte past the limit"
    (String.make (Keeper_name.max_length + 1) 'a');
  (* POSIX NAME_MAX, the constraint the bound exists for. *)
  expect_invalid Keeper_name.of_string "a name past NAME_MAX" (String.make 255 'a')
;;

let contains ~sub text =
  let n = String.length sub and m = String.length text in
  let rec at i = i + n <= m && (String.equal (String.sub text i n) sub || at (i + 1)) in
  at 0
;;

(* #36487: a capital letter is refused, not lowered. The refusal names the
   field, the byte and the fix, and the operator-facing message of
   [Keeper_config] carries the same reason. *)
let test_keeper_name_refuses_capitals () =
  List.iter
    (fun (value, byte) ->
       match Keeper_name.of_string value with
       | Ok _ -> failf "capital letter accepted in %S" value
       | Error reason ->
         List.iter
           (fun sub ->
              check bool (Printf.sprintf "%S refusal says %S (%s)" value sub reason) true
                (contains ~sub reason))
           [ "keeper_name"; "lowercase"; Printf.sprintf "byte %d" byte ];
         check bool (value ^ " refused by validate_name") false
           (Masc.Keeper_config.validate_name value);
         check bool (value ^ " operator message says lowercase") true
           (contains ~sub:"lowercase" (Masc.Keeper_config.invalid_name_error value)))
    [ "Foo", 0; "fOO", 1; "YUNA", 0; "owner.With.dots", 6; "TOOL_USAGE", 0 ]
;;

let test_keeper_name_accepts_lowercase () =
  List.iter
    (fun value ->
       expect_valid Keeper_name.of_string Keeper_name.to_string "lowercase name" value;
       check bool (value ^ " accepted by validate_name") true
         (Masc.Keeper_config.validate_name value))
    [ "foo"; "yuna"; "masc-pro-builder"; "owner.with.internal.dots"; "k_1-2.3" ]
;;

(* [Foo] and [foo] are one directory on APFS as installed, one container
   name and one Board key. Of the spellings that differ only in case, the
   name type admits exactly one, so the two cannot both exist. *)
let test_case_variants_cannot_coexist () =
  let accepted spellings =
    List.filter (fun value -> Result.is_ok (Keeper_name.of_string value)) spellings
  in
  check (list string) "one spelling of foo" [ "foo" ] (accepted [ "Foo"; "foo"; "FOO"; "fOo" ]);
  check (list string) "one spelling of yuna" [ "yuna" ] (accepted [ "Yuna"; "YUNA"; "yuna" ])
;;

(* #53072: the Librarian minted the owner through
   [Keeper_identity.Keeper_id.of_string], which lowers, and refused the owner
   when the minted id differed from the name it was given. That check, and
   the input speaker decode that does the same, holds for every name the
   type accepts. *)
let test_owner_check_holds_for_every_valid_name () =
  List.iter
    (fun value ->
       match Keeper_name.of_string value with
       | Error reason -> failf "fixture %S is not a Keeper name: %s" value reason
       | Ok name ->
         let raw = Keeper_name.to_string name in
         (match Masc.Keeper_identity.Keeper_id.of_string raw with
          | Some id ->
            check string (raw ^ " owner id is the name") raw
              (Masc.Keeper_identity.Keeper_id.to_string id)
          | None -> failf "Keeper name %S minted no owner id" raw))
    [ "yuna"; "foo"; "masc-pro-builder"; "owner.with.internal.dots"; "k_1-2.3" ];
  expect_invalid Keeper_name.of_string "the #53072 name" "Yuna"
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
        ; test_case "bounded as a filesystem component" `Quick
            test_keeper_name_is_bounded
        ; test_case "a capital letter is refused" `Quick
            test_keeper_name_refuses_capitals
        ; test_case "a lowercase name is accepted" `Quick
            test_keeper_name_accepts_lowercase
        ; test_case "names differing only in case cannot coexist" `Quick
            test_case_variants_cannot_coexist
        ; test_case "the Librarian owner check holds for a valid name" `Quick
            test_owner_check_holds_for_every_valid_name
        ] );
      ( "Trace_id",
        [ test_case
            "bounded non-dotted grammar remains independent"
            `Quick
            test_trace_id_keeps_bounded_non_dotted_grammar
        ] );
    ]

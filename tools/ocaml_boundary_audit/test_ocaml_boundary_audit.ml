open Ocaml_boundary_audit

let sites source =
  match audit_source ~path:"lib/sample.ml" ~pure:false source with
  | Ok sites -> sites
  | Error message -> Alcotest.fail message
;;

let pure_sites source =
  match audit_source ~path:"lib/pure_sample.ml" ~pure:true source with
  | Ok sites -> sites
  | Error message -> Alcotest.fail message
;;

let count category (sites : site list) =
  List.length
    (List.filter (fun (site : site) -> site.category = category) sites)
;;

let test_semantic_calls_ignore_text () =
  let source =
    {|
let decode optional result =
  let _comment_like = "Option.get Result.get_ok" in
  let _ = Option.get optional in
  let _ = Result.get_ok result in
  let _ = Result.to_option result in
  Option.value optional ~default:0
|}
  in
  let findings = sites source in
  Alcotest.(check int) "partial extraction" 2 (count Partial_extraction findings);
  Alcotest.(check int) "failure erasure" 1 (count Failure_erasure findings);
  Alcotest.(check int) "implicit default" 1 (count Implicit_default findings)
;;

let test_catch_all_exception_only () =
  let source =
    {|
let specific f = try f () with Failure _ -> ()
let guarded f = try f () with exn when recoverable exn -> ignore exn
let broad f = try f () with exn -> ignore exn
let ordinary value = match value with _ -> ()
let broad_match f = match f () with value -> value | exception _ -> 0
|}
  in
  Alcotest.(check int)
    "two broad exception handlers"
    2
    (count Catch_all_exception (sites source))
;;

let test_pure_module_effects () =
  let source =
    {|
let calendar timestamp = Unix.gmtime timestamp
let read_env () = Sys.getenv_opt "TOKEN"
let sleep clock = Eio.Time.sleep clock 0.1
|}
  in
  let findings = pure_sites source in
  Alcotest.(check int)
    "gmtime remains a pure conversion; environment and sleep are effects"
    2
    (count Effect_in_pure_module findings)
;;

let test_scope_bucket_is_stable () =
  let source =
    {|
module Decode = struct
  let status value = Option.get value
end
|}
  in
  match sites source with
  | [ site ] -> Alcotest.(check string) "scope" "module:Decode/status" site.scope
  | findings ->
    Alcotest.failf "expected one finding, got %d" (List.length findings)
;;

let test_downward_comparison () =
  let baseline =
    sites "let decode value = Option.get value; Option.get value"
    |> entries_of_sites
  in
  let reduced = sites "let decode value = Option.get value" |> entries_of_sites in
  let increased =
    sites
      "let decode value = Option.get value; Option.get value; Option.get value"
    |> entries_of_sites
  in
  let reduction = compare ~baseline ~current:reduced in
  let increase = compare ~baseline ~current:increased in
  Alcotest.(check int) "one reduced bucket" 1 (List.length reduction.reductions);
  Alcotest.(check int) "no increase" 0 (List.length reduction.increases);
  Alcotest.(check int) "one increased bucket" 1 (List.length increase.increases)
;;

let test_parse_failure_is_explicit () =
  match audit_source ~path:"broken.ml" ~pure:false "let =" with
  | Ok _ -> Alcotest.fail "invalid OCaml unexpectedly parsed"
  | Error message ->
    Alcotest.(check bool)
      "location-bearing error"
      true
      (String.length message > 0)
;;

let test_baseline_round_trip () =
  let path = Filename.temp_file "ocaml-boundary-test-" ".tsv" in
  Fun.protect
    ~finally:(fun () ->
      if Sys.file_exists path then Sys.remove path)
    (fun () ->
       let expected =
         sites "let decode value = Option.get value" |> entries_of_sites
       in
       (match write_baseline path expected with
        | Ok () -> ()
        | Error message -> Alcotest.fail message);
       match read_baseline path with
       | Error message -> Alcotest.fail message
       | Ok actual ->
         Alcotest.(check bool) "round trip" true (expected = actual))
;;

let () =
  Alcotest.run
    "ocaml-boundary-audit"
    [ ( "ast"
      , [ Alcotest.test_case "semantic calls" `Quick test_semantic_calls_ignore_text
        ; Alcotest.test_case "catch all" `Quick test_catch_all_exception_only
        ; Alcotest.test_case "pure effects" `Quick test_pure_module_effects
        ; Alcotest.test_case "scope" `Quick test_scope_bucket_is_stable
        ; Alcotest.test_case "parse failure" `Quick test_parse_failure_is_explicit
        ] )
    ; ( "ratchet"
      , [ Alcotest.test_case "downward" `Quick test_downward_comparison
        ; Alcotest.test_case "baseline round trip" `Quick test_baseline_round_trip
        ] )
    ]
;;

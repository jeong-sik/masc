open Alcotest
module Cookies = Masc.Browser_cookies
let cookie ?(extra = []) name value =
  `Assoc ([ "name", `String name; "value", `String value; "path", `String "/"; "domain", `String "example.test"
          ; "secure", `Bool true; "httpOnly", `Bool true; "sameSite", `String "Lax"; "expiry", `Int 1792700000 ] @ extra)
let ok = function Ok json -> json | Error detail -> fail detail
let member key json = Yojson.Safe.Util.member key json
let rows json = Yojson.Safe.Util.to_list (member "cookies" json)

let test_no_value_survives () =
  let secret = "VERYSECRETSESSION" in
  let result = ok (Cookies.of_driver (`List [ cookie "sid" secret
    ~extra:[ "value2", `String secret; "comment", `String secret ] ])) in
  let text = Yojson.Safe.to_string result in
  check bool "the value is not in the output" false
    (try ignore (Str.search_forward (Str.regexp_string secret) text 0); true with Not_found -> false);
  match rows result with
  | [ row ] ->
    check (list string) "only the scoping attributes are kept"
      [ "name"; "path"; "domain"; "secure"; "httpOnly"; "sameSite"; "expiry" ]
      (List.map fst (Yojson.Safe.Util.to_assoc row));
    check string "name" "sid" (Yojson.Safe.Util.to_string (member "name" row));
    check bool "values withheld says so" true (member "valuesWithheld" result = `Bool true)
  | _ -> fail "one cookie expected"

let test_the_list_is_bounded_and_counted () =
  let many = List.init (Cookies.cookies_limit + 5) (fun index -> cookie (Printf.sprintf "c%d" index) "v") in
  let result = ok (Cookies.of_driver (`List many)) in
  check int "no more than the limit" Cookies.cookies_limit (List.length (rows result));
  check int "the total is the real count" (Cookies.cookies_limit + 5) (Yojson.Safe.Util.to_int (member "total" result))

let test_an_empty_list_is_an_empty_answer () =
  let result = ok (Cookies.of_driver (`List [])) in
  check int "none" 0 (List.length (rows result));
  check int "total zero" 0 (Yojson.Safe.Util.to_int (member "total" result))

let test_malformed_replies_are_errors () =
  List.iter (fun (label, json) ->
    check bool (label ^ " is refused") true (Result.is_error (Cookies.of_driver json)))
    [ "a non-list", `Assoc []; "a cookie that is not an object", `List [ `String "x" ]
    ; "a cookie with no name", `List [ `Assoc [ "value", `String "v" ] ]
    ; "a cookie with a numeric name", `List [ `Assoc [ "name", `Int 1 ] ] ]

let test_the_verb_and_the_table () =
  let verb = Browser_lane.Page_cookies { tab_id = 3 } in
  check string "wire name" "page.cookies" (Browser_lane.verb_to_string verb);
  check bool "automation only" true
    (Browser_lane.verb_allowed_on_automation verb && not (Browser_lane.verb_allowed_on_stagehand verb)
     && not (Browser_lane.verb_allowed_on_live verb));
  (match Masc.Browser_addon_wire.verb_of_json ~route:Browser_lane.Automation_route (Browser_lane.verb_json verb) with
   | Ok parsed -> check bool "the Add-on wire parses it back" true (parsed = verb)
   | Error detail -> fail detail);
  let module Cap = Masc.Browser_capabilities in
  let reaches backend = match Cap.support backend Cap.Read_storage with
    | Cap.Available _ | Cap.Conditional _ -> true | Cap.Unsupported _ -> false in
  check bool "the owned Firefox reads cookies" true (reaches Cap.Owned_gecko);
  List.iter (fun (label, backend) -> check bool (label ^ " does not") false (reaches backend))
    [ "live BiDi", Cap.Connected Browser_lane.Webdriver_bidi; "the extension", Cap.Connected Browser_lane.Web_extension
    ; "Stagehand", Cap.Owned_chromium; "Safari", Cap.Safari_unavailable ];
  check bool "writing storage is still not offered" false
    (match Cap.support Cap.Owned_gecko Cap.Write_storage with Cap.Unsupported _ -> false | Cap.Available _ | Cap.Conditional _ -> true)

let () = run "browser cookies" [ "cookies", [
  test_case "no value survives" `Quick test_no_value_survives;
  test_case "the list is bounded and counted" `Quick test_the_list_is_bounded_and_counted;
  test_case "an empty list is an empty answer" `Quick test_an_empty_list_is_an_empty_answer;
  test_case "malformed replies are errors" `Quick test_malformed_replies_are_errors;
  test_case "the verb and the table" `Quick test_the_verb_and_the_table ] ]

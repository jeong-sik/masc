open Alcotest
module Network = Masc.Browser_network
let obj fields = `Assoc fields
let header name value = obj [ "name", `String name; "value", obj [ "type", `String "string"; "value", `String value ] ]
let request ?(id = "1-a") ?(url = "https://example.test/page") ?(headers = [ header "Accept" "*/*" ]) () =
  obj [ "request", `String id; "method", `String "GET"; "url", `String url; "headers", `List headers ]
let before ?(context = "tab-a") ?(redirects = 0) ?(timestamp = 10) req =
  obj [ "context", `String context; "redirectCount", `Int redirects; "timestamp", `Int timestamp; "request", req ]
let completed ?(context = "tab-a") ?(status = 200) ?(response_headers = [ header "Content-Type" "text/html" ]) req =
  obj [ "context", `String context; "redirectCount", `Int 0; "timestamp", `Int 20; "request", req
      ; "response", obj [ "status", `Int status; "mimeType", `String "text/html"; "bytesReceived", `Int 173
                        ; "headers", `List response_headers ] ]
let failed ?(context = "tab-a") req =
  obj [ "context", `String context; "redirectCount", `Int 0; "timestamp", `Int 30; "request", req
      ; "errorText", `String "NS_ERROR_NET_RESET" ]
let record log ~method_ params = match Network.event log ~method_ params with Ok () -> () | Error detail -> fail detail
let member key json = Yojson.Safe.Util.member key json
let requests log ~context = Yojson.Safe.Util.to_list (member "requests" (Network.to_json log ~context))

let test_a_request_goes_from_pending_to_completed () =
  let log = Network.create () in
  let req = request () in
  record log ~method_:"network.beforeRequestSent" (before req);
  (match requests log ~context:"tab-a" with
   | [ row ] -> check string "pending first" "pending" (Yojson.Safe.Util.to_string (member "state" row))
   | _ -> fail "one request expected");
  record log ~method_:"network.responseCompleted" (completed req);
  match requests log ~context:"tab-a" with
  | [ row ] ->
    check string "then completed" "completed" (Yojson.Safe.Util.to_string (member "state" row));
    check int "status" 200 (Yojson.Safe.Util.to_int (member "status" row));
    check int "bytes" 173 (Yojson.Safe.Util.to_int (member "bytesReceived" row));
    check string "mime" "text/html" (Yojson.Safe.Util.to_string (member "mimeType" row))
  | _ -> fail "the completed request was not updated in place"

let test_a_failed_request_keeps_its_reason () =
  let log = Network.create () in
  let req = request () in
  record log ~method_:"network.beforeRequestSent" (before req);
  record log ~method_:"network.fetchError" (failed req);
  match requests log ~context:"tab-a" with
  | [ row ] ->
    check string "failed" "failed" (Yojson.Safe.Util.to_string (member "state" row));
    check string "reason" "NS_ERROR_NET_RESET" (Yojson.Safe.Util.to_string (member "error" row))
  | _ -> fail "one request expected"

let test_a_request_seen_only_at_its_end_is_still_listed () =
  let log = Network.create () in
  record log ~method_:"network.responseCompleted" (completed (request ~id:"late" ()));
  check int "listed, not dropped" 1 (List.length (requests log ~context:"tab-a"))

let test_a_redirect_is_its_own_row () =
  let log = Network.create () in
  let req = request () in
  record log ~method_:"network.beforeRequestSent" (before ~redirects:0 req);
  record log ~method_:"network.beforeRequestSent" (before ~redirects:1 req);
  check int "two rows" 2 (List.length (requests log ~context:"tab-a"))

let test_no_secret_value_leaves_the_model () =
  let log = Network.create () in
  let secrets = [ "SECRETQUERY"; "BEARERTOKEN"; "SESSIONCOOKIE"; "RESPTOKEN"; "userpass" ] in
  let req = request ~url:"https://userpass@example.test/a/b?token=SECRETQUERY&x=1#frag"
      ~headers:[ header "Authorization" "BEARERTOKEN"; header "Cookie" "SESSIONCOOKIE" ] () in
  record log ~method_:"network.beforeRequestSent" (before req);
  record log ~method_:"network.responseCompleted"
    (completed ~response_headers:[ header "Set-Cookie" "SESSIONCOOKIE"; header "X-Token" "RESPTOKEN" ] req);
  let text = Yojson.Safe.to_string (Network.to_json log ~context:"tab-a") in
  List.iter (fun secret ->
    check bool (secret ^ " is not in the output") false
      (try ignore (Str.search_forward (Str.regexp_string secret) text 0); true with Not_found -> false))
    secrets;
  let row = List.hd (requests log ~context:"tab-a") in
  check string "the address keeps host and path, names the query, hides its values and the fragment"
    "https://example.test/a/b?token=REDACTED&x=REDACTED" (Yojson.Safe.Util.to_string (member "url" row));
  let names key = Yojson.Safe.Util.(row |> member key |> member "names" |> to_list |> List.map to_string) in
  check (list string) "request header names are kept" [ "Authorization"; "Cookie" ] (names "requestHeaders");
  check (list string) "response header names are kept" [ "Set-Cookie"; "X-Token" ] (names "responseHeaders")

let test_redact_url () =
  check bool "a relative address has no host" true (Network.redact_url "/only/a/path" = None);
  check bool "a port is kept" true
    (Network.redact_url "http://127.0.0.1:8080/x" = Some ("http://127.0.0.1:8080/x", false));
  let long = "https://example.test/" ^ String.make (Network.path_bytes_limit + 50) 'a' in
  match Network.redact_url long with
  | Some (kept, cut) ->
    check bool "a long path is cut and flagged" true (cut && String.length kept < String.length long)
  | None -> fail "a long address was refused"

let test_the_oldest_requests_drop_and_are_counted () =
  let log = Network.create () in
  let total = Network.requests_per_context + 5 in
  for index = 1 to total do
    record log ~method_:"network.beforeRequestSent" (before (request ~id:(string_of_int index) ()))
  done;
  check int "the limit is kept" Network.requests_per_context (List.length (requests log ~context:"tab-a"));
  check int "the rest are counted" 5 (Yojson.Safe.Util.to_int (member "dropped" (Network.to_json log ~context:"tab-a")))

let test_tabs_are_separate () =
  let log = Network.create () in
  record log ~method_:"network.beforeRequestSent" (before ~context:"tab-a" (request ~id:"a" ()));
  record log ~method_:"network.beforeRequestSent" (before ~context:"tab-b" (request ~id:"b" ()));
  check int "tab a" 1 (List.length (requests log ~context:"tab-a"));
  check int "tab b" 1 (List.length (requests log ~context:"tab-b"));
  check int "tab c" 0 (List.length (requests log ~context:"tab-c"))

let test_malformed_events_are_errors () =
  let log = Network.create () in
  let bad = [
    "an unsubscribed method", "network.authRequired", before (request ());
    "no context", "network.beforeRequestSent", obj [ "request", request (); "timestamp", `Int 1 ];
    "no request", "network.beforeRequestSent", obj [ "context", `String "t"; "timestamp", `Int 1 ];
    "an address with no host", "network.beforeRequestSent", before (request ~url:"/relative" ());
    "headers that are not a list", "network.beforeRequestSent",
      before (obj [ "request", `String "x"; "method", `String "GET"; "url", `String "https://e.test/"; "headers", `String "h" ]);
    "a completed response with no status", "network.responseCompleted",
      obj [ "context", `String "t"; "timestamp", `Int 1; "request", request ()
          ; "response", obj [ "mimeType", `String "m"; "bytesReceived", `Int 1 ] ] ] in
  List.iter (fun (label, method_, params) ->
    check bool (label ^ " is refused") true (Result.is_error (Network.event log ~method_ params))) bad;
  check int "nothing was recorded" 0 (List.length (requests log ~context:"t"))

let test_the_verb_and_the_table () =
  let verb = Browser_lane.Page_network { tab_id = 3 } in
  check string "wire name" "page.network" (Browser_lane.verb_to_string verb);
  check bool "automation only" true
    (Browser_lane.verb_allowed_on_automation verb && not (Browser_lane.verb_allowed_on_stagehand verb)
     && not (Browser_lane.verb_allowed_on_live verb));
  (match Masc.Browser_addon_wire.verb_of_json ~route:Browser_lane.Automation_route (Browser_lane.verb_json verb) with
   | Ok parsed -> check bool "the Add-on wire parses it back" true (parsed = verb)
   | Error detail -> fail detail);
  let module Cap = Masc.Browser_capabilities in
  let reaches backend = match Cap.support backend Cap.Read_network with
    | Cap.Available _ | Cap.Conditional _ -> true | Cap.Unsupported _ -> false in
  check bool "the owned Firefox reads the network" true (reaches Cap.Owned_gecko);
  List.iter (fun (label, backend) -> check bool (label ^ " does not") false (reaches backend))
    [ "live BiDi", Cap.Connected Browser_lane.Webdriver_bidi; "the extension", Cap.Connected Browser_lane.Web_extension
    ; "Stagehand", Cap.Owned_chromium; "Safari", Cap.Safari_unavailable ]

let () = run "browser network" [ "network", [
  test_case "pending to completed" `Quick test_a_request_goes_from_pending_to_completed;
  test_case "a failed request keeps its reason" `Quick test_a_failed_request_keeps_its_reason;
  test_case "a request seen only at its end is listed" `Quick test_a_request_seen_only_at_its_end_is_still_listed;
  test_case "a redirect is its own row" `Quick test_a_redirect_is_its_own_row;
  test_case "no secret value leaves the model" `Quick test_no_secret_value_leaves_the_model;
  test_case "the address is redacted" `Quick test_redact_url;
  test_case "the oldest drop and are counted" `Quick test_the_oldest_requests_drop_and_are_counted;
  test_case "tabs are separate" `Quick test_tabs_are_separate;
  test_case "malformed events are errors" `Quick test_malformed_events_are_errors;
  test_case "the verb and the table" `Quick test_the_verb_and_the_table ] ]

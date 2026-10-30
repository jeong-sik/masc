(* The Chromium the Stagehand lane starts: its command line, the port file
   it answers with. Process ownership belongs to the native guardian. *)
open Alcotest
module P = Masc.Browser_chromium_process

let chrome = "/Applications/Google Chrome for Testing.app/Contents/MacOS/Google Chrome for Testing"
let profile = "/ws/.masc/browser-lane/stagehand-profile"
let extension_id = String.make 32 'h'

let test_argv () =
  let argv = P.argv ~chrome ~profile:(P.Private_profile profile) ~extension_id ~headless:true in
  check string "the executable comes first" chrome (List.hd argv);
  check bool "headless" true (List.mem "--headless=new" argv);
  check bool "the port is Chrome's choice" true (List.mem "--remote-debugging-port=0" argv);
  check bool "CDP may load the extension" true (List.mem "--enable-unsafe-extension-debugging" argv);
  check bool "only the extension's origin is allowed" true
    (List.mem ("--remote-allow-origins=chrome-extension://" ^ extension_id) argv);
  check bool "no origin wildcard" false (List.exists (String.equal "--remote-allow-origins=*") argv);
  check bool "the profile" true (List.mem ("--user-data-dir=" ^ profile) argv);
  check bool "headed when asked" false
    (List.mem "--headless=new" (P.argv ~chrome ~profile:(P.Private_profile profile) ~extension_id ~headless:false));
  check bool "background tabs keep their timers" true (List.mem "--disable-background-timer-throttling" argv);
  check bool "a server profile asks macOS for no Keychain" true (List.mem "--use-mock-keychain" argv);
  let operator = P.argv ~chrome ~profile:(P.Operator_profile "/Users/me/chrome-work") ~extension_id ~headless:true in
  check bool "an operator's profile keeps its own password store" false
    (List.exists (fun flag -> List.mem flag operator) [ "--use-mock-keychain"; "--password-store=basic" ]);
  check bool "the operator's profile" true (List.mem "--user-data-dir=/Users/me/chrome-work" operator)
;;

let test_devtools_endpoint () =
  check (result (pair int string) string) "port and path"
    (Ok (51148, "/devtools/browser/0b1c"))
    (P.devtools_endpoint_of_string "51148\n/devtools/browser/0b1c\n");
  List.iter (fun (why, text) -> check bool why true (Result.is_error (P.devtools_endpoint_of_string text)))
    [ "mid-write, one line", "51148";
      "no port", "\n/devtools/browser/x";
      "a port out of range", "70000\n/devtools/browser/x";
      "a relative path", "51148\ndevtools/browser/x" ];
  check string "loopback URL" "ws://127.0.0.1:51148/devtools/browser/0b1c"
    (P.browser_ws_url ~port:51148 ~path:"/devtools/browser/0b1c")
;;

let () =
  run "browser_chromium_process" [
    "launch", [
      test_case "command line" `Quick test_argv;
      test_case "DevToolsActivePort" `Quick test_devtools_endpoint;
    ];
  ]
;;

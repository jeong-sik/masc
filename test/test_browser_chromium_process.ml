(* The Chromium the Stagehand lane starts: its command line, the port file
   it answers with, and which process a later server may stop. *)
open Alcotest
module P = Masc.Browser_chromium_process

let chrome = "/Applications/Google Chrome for Testing.app/Contents/MacOS/Google Chrome for Testing"
let profile = "/ws/.masc/browser-lane/stagehand-profile"
let extension_id = String.make 32 'h'

let test_argv () =
  let argv = P.argv ~chrome ~profile ~extension_id ~headless:true in
  check string "the executable comes first" chrome (List.hd argv);
  check bool "headless" true (List.mem "--headless=new" argv);
  check bool "the port is Chrome's choice" true (List.mem "--remote-debugging-port=0" argv);
  check bool "CDP may load the extension" true (List.mem "--enable-unsafe-extension-debugging" argv);
  check bool "only the extension's origin is allowed" true
    (List.mem ("--remote-allow-origins=chrome-extension://" ^ extension_id) argv);
  check bool "no origin wildcard" false (List.exists (String.equal "--remote-allow-origins=*") argv);
  check bool "the profile" true (List.mem ("--user-data-dir=" ^ profile) argv);
  check bool "headed when asked" false
    (List.mem "--headless=new" (P.argv ~chrome ~profile ~extension_id ~headless:false))
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

let leftover = testable (fun fmt -> function
  | P.Stop_recorded_browser pid -> Format.fprintf fmt "stop %d" pid
  | P.Not_the_recorded_browser -> Format.pp_print_string fmt "keep") ( = )

(* A pid is stopped only while it still runs the recorded executable on the
   recorded profile: the system may have handed the pid to anything since. *)
let test_leftover () =
  let owner = { P.pid = 4242; chrome; profile } in
  (match P.owner_of_string (P.owner_to_string owner) with
   | Ok read -> check bool "the record round-trips" true (read = owner)
   | Error detail -> fail detail);
  let running = String.concat " " (P.argv ~chrome ~profile ~extension_id ~headless:true) in
  check leftover "the recorded browser" (P.Stop_recorded_browser 4242) (P.leftover owner ~command:(Some running));
  check leftover "another profile" P.Not_the_recorded_browser
    (P.leftover owner ~command:(Some (chrome ^ " --user-data-dir=/elsewhere")));
  check leftover "another program" P.Not_the_recorded_browser
    (P.leftover owner ~command:(Some ("/usr/bin/python3 --user-data-dir=" ^ profile)));
  check leftover "no such process" P.Not_the_recorded_browser (P.leftover owner ~command:None);
  check bool "a relative profile is not a record" true
    (Result.is_error (P.owner_of_string {|{"pid":1,"chrome":"/c","profile":"p"}|}))
;;

let () =
  run "browser_chromium_process" [
    "launch", [
      test_case "command line" `Quick test_argv;
      test_case "DevToolsActivePort" `Quick test_devtools_endpoint;
    ];
    "ownership", [ test_case "a later server stops only the recorded browser" `Quick test_leftover ];
  ]
;;

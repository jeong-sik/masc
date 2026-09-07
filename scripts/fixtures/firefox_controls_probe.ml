let read_all channel =
  let buffer = Buffer.create 1024 in
  (try while true do Buffer.add_channel buffer channel 1024 done with End_of_file -> ());
  Buffer.contents buffer
let endpoint = Sys.getenv "MASC_PROBE_DRIVER_URL"
let fixture_url = Sys.getenv "MASC_PROBE_FIXTURE_URL"
let remote_session = ref None
let request ~method_ ~path ~body =
  let method_name = match method_ with `GET -> "GET" | `POST -> "POST" | `DELETE -> "DELETE" in
  let args = ["curl";"--silent";"--show-error";"--max-time";"45";"--request";method_name;
    "--header";"Content-Type: application/json";"--write-out";"\n%{http_code}";endpoint ^ path]
    @ (match body with None -> [] | Some json -> ["--data-binary";Yojson.Safe.to_string json]) in
  let channel = Unix.open_process_args_in "curl" (Array.of_list args) in
  let output = read_all channel in
  match Unix.close_process_in channel with
  | Unix.WEXITED 0 ->
    let split = String.rindex output '\n' in
    let result = Driver.decode_response ~status:(int_of_string (String.sub output (split+1) (String.length output-split-1)))
      (String.sub output 0 split) in
    (match method_,path,result with
     | `POST,"/session",Ok (`Assoc fields) -> (match List.assoc_opt "sessionId" fields with Some (`String id) -> remote_session := Some id | _ -> ())
     | _ -> ());
    result
  | _ -> Error (Driver.Transport "curl failed")
let member = Yojson.Safe.Util.member
let integer json = Yojson.Safe.Util.to_int json
let string json = Yojson.Safe.Util.to_string json
let success = function
  | Browser_lane.Answered json -> member "data" json
  | Browser_lane.Refused message | Browser_lane.Rejected_before_effect message -> failwith message
  | _ -> failwith "no browser answer"
let check message condition = if not condition then failwith message else Printf.printf "PASS %s\n%!" message
let () = Eio_main.run (fun _ ->
  let driver = Driver.create ~request in
  let run verb = Driver.execute driver verb in
  let close () = match Driver.close driver with
    | Ok () -> ()
    | Error error -> failwith ("fixture cleanup failed: " ^ Driver.error_message error) in
  let open_session () =
    let response = success (run (Browser_lane.Session_open {headless=Some true})) in
    check "probe owns a newly opened session"
      (member "opened" response = `Bool true && member "reused" response = `Bool false) in
  Fun.protect ~finally:close (fun () ->
    open_session ();
    let open_tab suffix = success (run (Browser_lane.Page_act (Browser_action.Open_tab (fixture_url ^ suffix)))) |> member "tabId" |> integer in
    let first = open_tab "/first" in
    let act id interaction =
      let response = success (run (Browser_lane.Page_act (Browser_action.On_tab {tab_id=id;interaction}))) in
      let confirmation = match interaction with Browser_action.Close_tab -> "closed" | _ -> "performed" in
      check "native action confirms its target tab"
        (member "tabId" response = `Int id && member confirmation response = `Bool true) in
    let elements id = success (run (Browser_lane.Page_elements {tab_id=Some id})) in
    let observation = elements first in
    check "element observation names its tab" (integer (member "tabId" observation)=first);
    let controls = member "elements" observation |> Yojson.Safe.Util.to_list in
    let control name = List.find (fun item -> member "name" item = `String name) controls in
    let selector name = control name |> member "selector" |> string in
    check "password values are absent" (member "value" (control "password") = `Null);
    let options = member "options" (control "country") |> Yojson.Safe.Util.to_list in
    check "opaque option values are observable" (List.exists (fun item -> member "value" item = `String "opaque-02") options);
    act first (Browser_action.Fill {selector=selector "name";text="한글 Firefox 🙂"});
    act first (Browser_action.Select {selector=selector "country";value="opaque-02"});
    act first (Browser_action.Click (selector "submit"));
    let read id = success (run (Browser_lane.Page_read {tab_id=Some id;max_chars=None})) in
    let text = member "text" (read first) |> string in
    check "native fill select and click changed page" (String.starts_with ~prefix:"Firefox fixture" text && String.contains text '1');
    let current = elements first |> member "elements" |> Yojson.Safe.Util.to_list in
    check "live DOM value reflects native fill" (List.exists (fun item -> member "value" item = `String "한글 Firefox 🙂") current);
    act first (Browser_action.Press {selector=selector "name";key=Browser_action.Enter});
    let second = open_tab "/second" in
    act first (Browser_action.Click (selector "submit"));
    check "second tab remains independently readable" (member "url" (read second) = `String (fixture_url ^ "/second"));
    let rejected = run (Browser_lane.Page_act (Browser_action.On_tab {tab_id=first;interaction=Browser_action.Click "input"})) in
    check "ambiguous selector rejected before effect" (match rejected with Browser_lane.Rejected_before_effect _ -> true | _ -> false);
    act first (Browser_action.Scroll {x=0;y=400});
    let navigated = success (run (Browser_lane.Page_goto {url=fixture_url ^ "/next";tab_id=Some second})) in
    check "targeted navigation reaches the requested URL"
      (member "url" navigated = `String (fixture_url ^ "/next"));
    act second Browser_action.Back;
    check "native back returns to previous URL" (member "url" (read second) = `String (fixture_url ^ "/second"));
    act second Browser_action.Forward;
    check "native forward restores URL" (member "url" (read second) = `String (fixture_url ^ "/next"));
    act second Browser_action.Reload;
    act first (Browser_action.Scroll {x=0;y=(-400)});
    check "screenshot target is the first fixture page"
      (member "url" (read first) = `String (fixture_url ^ "/first"));
    (* Capture the resulting real Firefox viewport using the same native transport. *)
    let screenshot = success (run (Browser_lane.Page_screenshot {tab_id=first})) in
    check "native screenshot carries the selected tab" (member "tabId" screenshot = `Int first);
    let png = member "base64" screenshot |> string in
    let oc=open_out (Sys.getenv "MASC_PROBE_SCREENSHOT_BASE64") in
    output_string oc png; close_out oc;
    act first Browser_action.Close_tab;
    check "closed tab cannot be clicked" (match run (Browser_lane.Page_act (Browser_action.On_tab {tab_id=first;interaction=Browser_action.Click "button"})) with Browser_lane.Rejected_before_effect _ -> true | _ -> false);
    let closed = success (run Browser_lane.Session_close) in
    check "session close is confirmed" (member "closed" closed = `Bool true);
    open_session ();
    let fresh = open_tab "/fresh" in
    check "reopened sessions never reuse tab IDs" (fresh > second);
    check "old session target rejected" (match run (Browser_lane.Page_act (Browser_action.On_tab {tab_id=second;interaction=Browser_action.Click "button"})) with Browser_lane.Rejected_before_effect _ -> true | _ -> false)))

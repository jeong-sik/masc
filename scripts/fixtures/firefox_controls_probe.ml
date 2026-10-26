let read_all channel =
  let buffer = Buffer.create 1024 in
  (try while true do Buffer.add_channel buffer channel 1024 done with End_of_file -> ());
  Buffer.contents buffer
let endpoint = Sys.getenv "MASC_PROBE_DRIVER_URL"
let fixture_url = Sys.getenv "MASC_PROBE_FIXTURE_URL"
let remote_session = ref None
let request ~method_ ~path ~body =
  Eio_unix.run_in_systhread (fun () ->
  let method_name = match method_ with `GET -> "GET" | `POST -> "POST" | `DELETE -> "DELETE" | `PUT -> "PUT" | `PATCH -> "PATCH" | `HEAD -> "HEAD" in
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
  | _ -> Error (Driver.Transport "curl failed"))
let member = Yojson.Safe.Util.member
let integer json = Yojson.Safe.Util.to_int json
let string json = Yojson.Safe.Util.to_string json
let success = function
  | Browser_lane.Answered json -> member "data" json
  | Browser_lane.Refused message | Browser_lane.Rejected_before_effect message -> failwith message
  | _ -> failwith "no browser answer"
let contains text expected =
  let rec search i =
    i + String.length expected <= String.length text
    && (String.sub text i (String.length expected) = expected || search (i + 1)) in
  search 0
let check message condition = if not condition then failwith message else Printf.printf "PASS %s\n%!" message
let () = Eio_main.run (fun env -> Eio.Switch.run (fun sw ->
  let root = Sys.getenv "MASC_PROBE_DOWNLOAD_ROOT" in
  let driver = Driver.create ~request
      ~start_downloads:(Browser_bidi_downloads.start ~sw ~env ~root
        ~publish:publish_download) () in
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
      let response = success (run (Browser_lane.Page_act (Browser_action.On_tab {tab_id=id;frame_path=[];interaction}))) in
      let confirmation = match interaction with Browser_action.Close_tab -> "closed" | _ -> "performed" in
      check "native action confirms its target tab"
        (member "tabId" response = `Int id && member confirmation response = `Bool true) in
    (* Page input is BrowserInteract; BrowserAct keeps tabs, history, dialogs and upload. *)
    let interact_in id ?(frame_path=[]) ?expected_url action =
      run (Browser_lane.Page_interact {frame_path;tab_id=id;expected_url;action}) in
    let interact_raw id ?expected_url action = interact_in id ?expected_url action in
    let input id ?expected_url action =
      let response = success (interact_raw id ?expected_url action) in
      check "page input confirms its target tab" (member "tabId" response = `Int id) in
    (* A click that opens a JavaScript dialog can report an error after the page
       took the click, so the dialog itself is the evidence. *)
    let click_opening_dialog id selector = ignore (interact_raw id (Browser_lane.Click selector)) in
    let elements id = success (run (Browser_lane.Page_elements {tab_id=Some id;filter={within=None;selector=None}})) in
    let observation = elements first in
    check "element observation names its tab" (integer (member "tabId" observation)=first);
    let controls = member "elements" observation |> Yojson.Safe.Util.to_list in
    let control name = List.find (fun item -> member "name" item = `String name) controls in
    let selector name = control name |> member "selector" |> string in
    check "password values are absent" (member "value" (control "password") = `Null);
    let options = member "options" (control "country") |> Yojson.Safe.Util.to_list in
    check "opaque option values are observable" (List.exists (fun item -> member "value" item = `String "opaque-02") options);
    input first (Browser_lane.Fill {selector=selector "name";text="한글 Firefox 🙂"});
    input first (Browser_lane.Select_option {selector=selector "country";selection=Browser_lane.Single_option "opaque-02"});
    input first (Browser_lane.Click (selector "submit"));
    let read id = success (run (Browser_lane.Page_read {tab_id=Some id;max_chars=None})) in
    let text = member "text" (read first) |> string in
    check "native fill select and click changed page" (contains text "1 submissions: 한글 Firefox 🙂 / opaque-02");
    let current = elements first |> member "elements" |> Yojson.Safe.Util.to_list in
    check "live DOM value reflects native fill" (List.exists (fun item -> member "value" item = `String "한글 Firefox 🙂") current);
    let document_id = success (run (Browser_lane.Page_scene {tab_id=first;max_chars=1000;view=Browser_lane.Content;scope=None}))
      |> member "documentId" |> string in
    let enter = match Browser_lane.Keyboard.of_wire ~key:"Enter" ~modifiers:[] with Ok key -> key | Error error -> failwith error in
    input first (Browser_lane.Click (selector "name"));
    input first ~expected_url:(fixture_url ^ "/first") (Browser_lane.Press_key {document_id;key=enter});
    check "native Enter submits the filled form" (contains (member "text" (read first) |> string) "2 submissions: 한글 Firefox 🙂 / opaque-02");
    let second = open_tab "/second" in
    input first (Browser_lane.Click (selector "submit"));
    check "second tab remains independently readable" (member "url" (read second) = `String (fixture_url ^ "/second"));
    (* Web storage names ride on the cookie read; values never do. *)
    ignore (read first);
    let remote = match !remote_session with Some id -> id | None -> failwith "no owned session" in
    (match request ~method_:`POST ~path:("/session/" ^ remote ^ "/execute/sync")
       ~body:(Some (`Assoc ["script",`String "localStorage.setItem('probe-key','probe-secret-value'); sessionStorage.setItem('probe-session-key','x'); return true;";"args",`List []])) with
     | Ok _ -> () | Error error -> failwith (Driver.error_message error));
    let cookie_read = success (run (Browser_lane.Page_cookies {tab_id=first})) in
    let storage = member "storage" cookie_read in
    check "localStorage key names are listed" (member "keys" (member "localStorage" storage) = `List [`String "probe-key"]);
    check "sessionStorage key names are listed" (member "keys" (member "sessionStorage" storage) = `List [`String "probe-session-key"]);
    check "IndexedDB names are read or reported" (member "count" (member "indexedDb" storage) <> `Null || member "unsupported" (member "indexedDb" storage) <> `Null);
    check "no storage value reaches the reply" (not (contains (Yojson.Safe.to_string cookie_read) "probe-secret-value"));
    (* A cookie is written for the tab's own host, read back by name only, then removed. *)
    let cookie_names () = success (run (Browser_lane.Page_cookies {tab_id=first})) |> member "cookies"
      |> Yojson.Safe.Util.to_list |> List.map (fun c -> member "name" c |> string) in
    act first (Browser_action.Set_cookie {name="probe-cookie";value="probe-cookie-secret";path="/";secure=false;
      http_only=false;same_site=Some Browser_action.Lax;max_age_sec=Some 600});
    check "the written cookie is listed by name" (List.mem "probe-cookie" (cookie_names ()));
    check "the written cookie's value never reaches a read"
      (not (contains (Yojson.Safe.to_string (success (run (Browser_lane.Page_cookies {tab_id=first})))) "probe-cookie-secret"));
    let page_cookie = request ~method_:`POST ~path:("/session/" ^ remote ^ "/execute/sync")
      ~body:(Some (`Assoc ["script",`String "return document.cookie;";"args",`List []])) in
    (match page_cookie with
     | Ok value -> check "the page itself sees the cookie value" (contains (Yojson.Safe.to_string value) "probe-cookie=probe-cookie-secret")
     | Error error -> failwith (Driver.error_message error));
    act first (Browser_action.Delete_cookie "probe-cookie");
    check "the deleted cookie is gone" (not (List.mem "probe-cookie" (cookie_names ())));
    (* Location, language and time zone are emulated over the session's BiDi connection and cleared to the tab's own. *)
    let page_value path script =
      match request ~method_:`POST ~path:("/session/" ^ remote ^ path)
          ~body:(Some (`Assoc ["script",`String script;"args",`List []])) with
      | Ok value -> value | Error error -> failwith (Driver.error_message error) in
    let identity () = page_value "/execute/sync" "return [navigator.language, Intl.DateTimeFormat().resolvedOptions().timeZone];" in
    let original = identity () in
    act first (Browser_action.Set_emulation {geolocation=Some {latitude=37.5;longitude=127.;accuracy_m=25.};
      locale=Some "ko-KR";timezone=Some "Asia/Seoul"});
    check "the page reports the emulated language and time zone" (identity () = `List [`String "ko-KR";`String "Asia/Seoul"]);
    check "the page reports the emulated location, with its permission granted"
      (page_value "/execute/async" "const done = arguments[arguments.length - 1]; navigator.geolocation.getCurrentPosition(function(p){ done([p.coords.latitude, p.coords.longitude]); }, function(e){ done('error ' + e.code); }, {timeout: 5000});"
       = `List [`Float 37.5;`Int 127]);
    act first Browser_action.Clear_emulation;
    check "clearing gives the tab its own language and time zone back" (identity () = original);
    (* The fixture also answers on localhost, a host of its own for a block. *)
    let port = String.sub fixture_url (String.rindex fixture_url ':') (String.length fixture_url - String.rindex fixture_url ':') in
    let load ?(cache="no-store") url =
      match request ~method_:`POST ~path:("/session/" ^ remote ^ "/execute/async")
          ~body:(Some (`Assoc ["script",`String "const done = arguments[arguments.length - 1]; fetch(arguments[0], {mode: 'no-cors', cache: arguments[1]}).then(function(){ done('loaded'); }, function(){ done('failed'); });";
            "args",`List [`String url;`String cache]])) with
      | Ok value -> value | Error error -> failwith (Driver.error_message error) in
    let fetch host = load ("http://" ^ host ^ port ^ "/second") in
    check "another host loads before a block" (fetch "localhost" = `String "loaded");
    act first (Browser_action.Block_requests ["localhost"]);
    check "a request to the blocked host fails" (fetch "localhost" = `String "failed");
    check "a request to another host still loads" (fetch "127.0.0.1" = `String "loaded");
    act first Browser_action.Unblock_requests;
    check "the host loads again once unblocked" (fetch "localhost" = `String "loaded");
    (* A response the browser cached before the block must not reach the page from its cache. *)
    let cached () = load ~cache:"default" ("http://localhost" ^ port ^ "/cached") in
    let network_hits () =
      match request ~method_:`POST ~path:("/session/" ^ remote ^ "/execute/async")
          ~body:(Some (`Assoc ["script",`String "const done = arguments[arguments.length - 1]; fetch('/cached-hits', {cache: 'no-store'}).then(function(r){ return r.text(); }).then(done, function(){ done('failed'); });";
            "args",`List []])) with
      | Ok value -> value | Error error -> failwith (Driver.error_message error) in
    check "the cacheable response loads" (cached () = `String "loaded");
    check "loading it again is answered from the cache" (cached () = `String "loaded" && network_hits () = `String "1");
    act first (Browser_action.Block_requests ["localhost"]);
    check "a response cached before the block fails too" (cached () = `String "failed");
    act first Browser_action.Unblock_requests;
    check "the cached host loads again once unblocked" (cached () = `String "loaded");
    let window_tab = success (run (Browser_lane.Page_act (Browser_action.Open_window (fixture_url ^ "/second")))) |> member "tabId" |> integer in
    check "open_window returns a tab that reads as its own page" (member "url" (read window_tab) = `String (fixture_url ^ "/second"));
    check "the window's tab id is new" (window_tab <> first && window_tab <> second);
    act window_tab Browser_action.Close_tab;
    let resize size = success (interact_raw first ~expected_url:(fixture_url ^ "/first") (Browser_lane.Set_viewport size)) in
    let sized = resize (Browser_lane.Fit {width=800;height=600}) in
    check "the resized page reports the asked viewport" (member "innerWidth" sized = `Int 800 && member "innerHeight" sized = `Int 600);
    (match interact_raw first ~expected_url:(fixture_url ^ "/first") (Browser_lane.Set_viewport (Browser_lane.Fit {width=300;height=100})) with
     | Browser_lane.Refused _ -> check "a viewport below the smallest window is refused with the size kept" true
     | _ -> failwith "a viewport below the smallest window was accepted");
    let restored = resize Browser_lane.Browser_default in
    check "the window's first size returns" (member "innerWidth" restored <> `Int 800);
    let rejected = interact_raw first (Browser_lane.Click "input") in
    check "ambiguous selector rejected before effect" (match rejected with Browser_lane.Rejected_before_effect _ -> true | _ -> false);
    input first (Browser_lane.Scroll {x=0;y=400});
    let navigated = success (run (Browser_lane.Page_goto {url=fixture_url ^ "/next";tab_id=Some second})) in
    check "targeted navigation reaches the requested URL"
      (member "url" navigated = `String (fixture_url ^ "/next"));
    act second Browser_action.Back;
    check "native back returns to previous URL" (member "url" (read second) = `String (fixture_url ^ "/second"));
    act second Browser_action.Forward;
    check "native forward restores URL" (member "url" (read second) = `String (fixture_url ^ "/next"));
    act second Browser_action.Reload;
    input first (Browser_lane.Scroll {x=0;y=(-400)});
    check "screenshot target is the first fixture page"
      (member "url" (read first) = `String (fixture_url ^ "/first"));
    check "another tab is selected before screenshot"
      (member "url" (read second) = `String (fixture_url ^ "/next"));
    (* The requested screenshot must switch away from the currently selected tab. *)
    let screenshot = success (run (Browser_lane.Page_capture {tab_id=first;options=None})) in
    check "native screenshot carries the selected tab" (member "tabId" screenshot = `Int first);
    check "native screenshot switches to the requested page"
      (member "url" screenshot = `String (fixture_url ^ "/first"));
    let png = member "data" screenshot |> string in
    let oc=open_out (Sys.getenv "MASC_PROBE_SCREENSHOT_BASE64") in
    output_string oc png; close_out oc;
    let context id frame_path mode = success (run (Browser_lane.Page_context {tab_id=id;frame_path;mode})) in
    let frames = context first [] `Frames |> member "frames" |> Yojson.Safe.Util.to_list in
    check "iframe discovery returns a selectable frame" (List.length frames = 1);
    let outer = member "selector" (List.hd frames) |> string in
    let nested = context first [outer] `Frames |> member "frames" |> Yojson.Safe.Util.to_list in
    let inner = member "selector" (List.hd nested) |> string in
    let frame_path = [outer;inner] in
    let frame_input action = success (interact_in first ~frame_path action) in
    check "nested cross-origin frame controls are readable"
      (context first frame_path (`Elements Browser_lane.unfiltered_elements) |> member "elements" |> Yojson.Safe.Util.to_list |> List.length = 2);
    check "nested fill executed" (member "tabId" (frame_input (Browser_lane.Fill {selector="#nested-input";text="프레임 입력"})) = `Int first);
    check "nested click executed" (member "tabId" (frame_input (Browser_lane.Click "#nested-apply")) = `Int first);
    check "nested frame contains submitted input" (contains (context first frame_path (`Text 1000) |> member "text" |> string) "프레임 입력");
    (* A call without framePath must not inherit the previous frame. *)
    let interact action expected_url = interact_raw first ?expected_url action in
    let mixed = success (interact (Browser_lane.Fill
      {selector=selector "name";text="Mixed browser controls"}) (Some (fixture_url ^ "/first"))) in
    check "BrowserInteract resets native frame context and names its tab"
      (member "tabId" mixed = `Int first);
    let rejected = interact (Browser_lane.Fill
      {selector=selector "name";text="unexpected overwrite"}) (Some (fixture_url ^ "/wrong")) in
    check "BrowserInteract rejects stale URL before overwriting input"
      (match rejected with Browser_lane.Rejected_before_effect _ -> true | _ -> false);
    let submitted = success (interact (Browser_lane.Click (selector "submit")) None) in
    check "BrowserInteract returns the observed task tab" (member "tabId" submitted = `Int first);
    check "native and DOM interactions share the correct page without stale overwrite"
      (contains (member "text" (read first) |> string) "Mixed browser controls");
    check "top-level read resets the frame context" (contains (member "text" (read first) |> string) "Firefox fixture");
    (match interact_in first ~frame_path:["#missing"] (Browser_lane.Click "button") with
     | Browser_lane.Rejected_before_effect _ -> check "missing frame rejected before effect" true
     | _ -> failwith "missing frame action accepted");
    click_opening_dialog first "button[aria-label=alert]";
    check "alert text remains available" (member "text" (context first [] `Dialog) = `String "Firefox alert");
    act first (Browser_action.Accept_dialog None);
    check "accepted alert closes" (member "open" (context first [] `Dialog) = `Bool false);
    click_opening_dialog first "button[aria-label=confirm]";
    act first Browser_action.Dismiss_dialog;
    check "dismiss reaches the page as false" (contains (member "text" (read first) |> string) "false");
    click_opening_dialog first "button[aria-label=prompt]";
    act first (Browser_action.Accept_dialog (Some "대화상자 입력"));
    check "prompt input reaches the page" (contains (member "text" (read first) |> string) "대화상자 입력");
    let load_dialog = success (run (Browser_lane.Page_act (Browser_action.Open_tab (fixture_url ^ "/load-dialog")))) in
    let load_tab = member "tabId" load_dialog |> integer in
    check "load-time dialog retains its new tab id" (member "navigation" load_dialog = `String "blocked_by_dialog");
    check "load-time prompt can be inspected by returned id" (member "text" (context load_tab [] `Dialog) = `String "Load-time dialog");
    (match run Browser_lane.Tabs_list with
     | Browser_lane.Refused detail -> check "blocked tab scan reports its exact id" (contains detail ("tabId=" ^ string_of_int load_tab))
     | _ -> failwith "expected blocked page observation");
    act load_tab (Browser_action.Accept_dialog None);
    check "load-time dialog recovery leaves page readable" (contains (member "text" (read load_tab) |> string) "Firefox fixture");
    act load_tab Browser_action.Close_tab;
    let upload = open_tab "/upload" in
    let source_path = Sys.getenv "MASC_PROBE_UPLOAD_PATH" in
    let read_upload () =
      let ic=open_in_bin source_path in
      Fun.protect ~finally:(fun () -> close_in ic) (fun () -> Ok (read_all ic)) in
    let staged_paths = ref [] in
    (match Browser_lane.Upload_lease.with_staged_files
      ~files:[Filename.basename source_path,read_upload] (fun paths ->
        staged_paths := paths;
        check "upload uses a private snapshot instead of caller source" (List.hd paths <> source_path);
        act upload (Browser_action.Upload {target=Browser_action.File_input "#upload";paths})) with
     | Ok () -> ()
     | Error (Browser_lane.Upload_lease.Read_failed error
             | Browser_lane.Upload_lease.Snapshot_failed error) -> failwith error);
    check "selected snapshots survive staging callback return" (List.for_all Sys.file_exists !staged_paths);
    let session_id = match !remote_session with Some id -> id | None -> failwith "no owned session" in
    let result = request ~method_:`POST ~path:("/session/" ^ session_id ^ "/execute/async")
      ~body:(Some (`Assoc ["script",`String "const done=arguments[arguments.length-1]; document.querySelector('#upload').files[0].text().then(text=>done({text}),error=>done({error:String(error)}));";"args",`List []])) in
    (match result with
     | Ok data -> check "later File text read preserves staged bytes" (member "text" data = `String "Firefox upload 한글\n")
     | Error error -> failwith (Driver.error_message error));
    input upload (Browser_lane.Click "#send-upload");
    check "real multipart upload preserves file bytes" (contains (member "text" (read upload) |> string) "Upload verified");
    let downloads_tab = open_tab "/downloads" in
    let download_rows () = success (run (Browser_lane.Page_downloads {tab_id=downloads_tab})) |> member "downloads" |> Yojson.Safe.Util.to_list in
    let await_downloads count =
      Eio.Time.with_timeout_exn (Eio.Stdenv.clock env) 20. (fun () ->
        let rec wait () =
          let rows = download_rows () in
          if List.length rows = count && List.for_all (fun row -> member "status" row = `String "completed") rows then rows
          else (Eio.Time.sleep (Eio.Stdenv.clock env) 0.05; wait ()) in wait ()) in
    input downloads_tab (Browser_lane.Click "#download-link");
    check "download 1 reached terminal completion" (List.length (await_downloads 1) = 1);
    input downloads_tab (Browser_lane.Click "#download-link");
    check "download 2 reached terminal completion" (List.length (await_downloads 2) = 2);
    input downloads_tab (Browser_lane.Click "#download-attribute");
    check "download 3 reached terminal completion" (List.length (await_downloads 3) = 3);
    let frame_download_receipt = success (interact_in downloads_tab ~frame_path:["#download-frame"]
      (Browser_lane.Click "#frame-download")) in
    check "frame download click confirms its tab"
      (member "tabId" frame_download_receipt = `Int downloads_tab);
    let rows = await_downloads 4 in
    check "distinct UUIDs correlate identical URLs and null navigation" (List.length (List.sort_uniq String.compare
      (List.map (fun row -> member "downloadId" row |> string) rows)) = 4);
    check "iframe downloads belong to their observed top-level tab" (List.length rows = 4);
    check "another tab cannot see these downloads"
      (success (run (Browser_lane.Page_downloads {tab_id=second})) |> member "downloads" = `List []);
    List.iter (fun row ->
      let path = member "path" row |> string in
      let bytes = In_channel.with_open_bin path In_channel.input_all in
      check "completed native download contains exact binary bytes"
        (bytes = String.init 40960 (fun i -> Char.chr (i mod 256)));
      check "download publication returned metadata" (member "artifact" row <> `Null)) rows;
    let evidence = success (run (Browser_lane.Page_downloads {tab_id=downloads_tab})) in
    Out_channel.with_open_bin (Sys.getenv "MASC_PROBE_DOWNLOAD_RESULT") (fun oc ->
      output_string oc (Yojson.Safe.pretty_to_string evidence));
    act downloads_tab Browser_action.Close_tab;
    check "completed downloads remain readable after their tab closes" (List.length (download_rows ()) = 4);
    act upload Browser_action.Close_tab;
    check "closing one tab retains session-owned files" (List.for_all Sys.file_exists !staged_paths);
    act first Browser_action.Close_tab;
    check "closed tab cannot be reloaded" (match run (Browser_lane.Page_act (Browser_action.On_tab {tab_id=first;frame_path=[];interaction=Browser_action.Reload})) with Browser_lane.Rejected_before_effect _ -> true | _ -> false);
    let closed = success (run Browser_lane.Session_close) in
    check "session close is confirmed" (member "closed" closed = `Bool true);
    check "confirmed session teardown removes private snapshots" (List.for_all (fun path -> not (Sys.file_exists path)) !staged_paths);
    check "session cleanup never deletes caller source file" (Sys.file_exists source_path);
    open_session ();
    let fresh = open_tab "/fresh" in
    check "reopened sessions never reuse tab IDs" (fresh > second);
    check "old session target rejected" (match run (Browser_lane.Page_act (Browser_action.On_tab {tab_id=second;frame_path=[];interaction=Browser_action.Reload})) with Browser_lane.Rejected_before_effect _ -> true | _ -> false))))

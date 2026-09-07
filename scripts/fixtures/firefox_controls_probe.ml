let read_all channel =
  let buffer = Buffer.create 1024 in
  (try while true do Buffer.add_channel buffer channel 1024 done with End_of_file -> ());
  Buffer.contents buffer
let endpoint = Sys.getenv "MASC_PROBE_DRIVER_URL"
let fixture_url = Sys.getenv "MASC_PROBE_FIXTURE_URL"
let remote_session = ref None
let request ~method_ ~path ~body =
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
  | _ -> Error (Driver.Transport "curl failed")
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
        ~publish:publish_download) in
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
    check "native fill select and click changed page" (contains text "1 submissions: 한글 Firefox 🙂 / opaque-02");
    let current = elements first |> member "elements" |> Yojson.Safe.Util.to_list in
    check "live DOM value reflects native fill" (List.exists (fun item -> member "value" item = `String "한글 Firefox 🙂") current);
    act first (Browser_action.Press {selector=selector "name";key=Browser_action.Enter});
    check "native Enter submits the filled form" (contains (member "text" (read first) |> string) "2 submissions: 한글 Firefox 🙂 / opaque-02");
    let second = open_tab "/second" in
    act first (Browser_action.Click (selector "submit"));
    check "second tab remains independently readable" (member "url" (read second) = `String (fixture_url ^ "/second"));
    let rejected = run (Browser_lane.Page_act (Browser_action.On_tab {tab_id=first;frame_path=[];interaction=Browser_action.Click "input"})) in
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
    check "another tab is selected before screenshot"
      (member "url" (read second) = `String (fixture_url ^ "/next"));
    (* The requested screenshot must switch away from the currently selected tab. *)
    let screenshot = success (run (Browser_lane.Page_screenshot {tab_id=first})) in
    check "native screenshot carries the selected tab" (member "tabId" screenshot = `Int first);
    check "native screenshot switches to the requested page"
      (member "url" screenshot = `String (fixture_url ^ "/first"));
    let png = member "base64" screenshot |> string in
    let oc=open_out (Sys.getenv "MASC_PROBE_SCREENSHOT_BASE64") in
    output_string oc png; close_out oc;
    let context id frame_path mode = success (run (Browser_lane.Page_context {tab_id=id;frame_path;mode})) in
    let frames = context first [] `Frames |> member "frames" |> Yojson.Safe.Util.to_list in
    check "iframe discovery returns a selectable frame" (List.length frames = 1);
    let outer = member "selector" (List.hd frames) |> string in
    let nested = context first [outer] `Frames |> member "frames" |> Yojson.Safe.Util.to_list in
    let inner = member "selector" (List.hd nested) |> string in
    let frame_path = [outer;inner] in
    let frame_act interaction = success (run (Browser_lane.Page_act (Browser_action.On_tab {tab_id=first;frame_path;interaction}))) in
    check "nested cross-origin frame controls are readable"
      (context first frame_path `Elements |> member "elements" |> Yojson.Safe.Util.to_list |> List.length = 2);
    check "nested fill executed" (member "performed" (frame_act (Browser_action.Fill {selector="#nested-input";text="프레임 입력"})) = `Bool true);
    check "nested click executed" (member "performed" (frame_act (Browser_action.Click "#nested-apply")) = `Bool true);
    check "nested frame contains submitted input" (contains (context first frame_path (`Text 1000) |> member "text" |> string) "프레임 입력");
    check "top-level read resets the frame context" (contains (member "text" (read first) |> string) "Firefox fixture");
    (match run (Browser_lane.Page_act (Browser_action.On_tab {tab_id=first;frame_path=["#missing"];interaction=Browser_action.Click "button"})) with
     | Browser_lane.Rejected_before_effect _ -> check "missing frame rejected before effect" true
     | _ -> failwith "missing frame action accepted");
    act first (Browser_action.Click "button[aria-label=alert]");
    check "alert text remains available" (member "text" (context first [] `Dialog) = `String "Firefox alert");
    act first (Browser_action.Accept_dialog None);
    check "accepted alert closes" (member "open" (context first [] `Dialog) = `Bool false);
    act first (Browser_action.Click "button[aria-label=confirm]");
    act first Browser_action.Dismiss_dialog;
    check "dismiss reaches the page as false" (contains (member "text" (read first) |> string) "false");
    act first (Browser_action.Click "button[aria-label=prompt]");
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
    act upload (Browser_action.Upload {selector="#upload";paths=[Sys.getenv "MASC_PROBE_UPLOAD_PATH"]});
    act upload (Browser_action.Click "#send-upload");
    check "real multipart upload preserves file bytes" (contains (member "text" (read upload) |> string) "Upload verified");
    let downloads_tab = open_tab "/downloads" in
    let download_rows () = success (run (Browser_lane.Page_downloads {tab_id=downloads_tab})) |> member "downloads" |> Yojson.Safe.Util.to_list in
    let await_downloads count =
      Eio.Time.with_timeout_exn (Eio.Stdenv.clock env) 20. (fun () ->
        let rec wait () =
          let rows = download_rows () in
          if List.length rows = count && List.for_all (fun row -> member "status" row = `String "completed") rows then rows
          else (Eio.Time.sleep (Eio.Stdenv.clock env) 0.05; wait ()) in wait ()) in
    act downloads_tab (Browser_action.Click "#download-link");
    ignore (await_downloads 1);
    act downloads_tab (Browser_action.Click "#download-link");
    ignore (await_downloads 2);
    act downloads_tab (Browser_action.Click "#download-attribute");
    ignore (await_downloads 3);
    ignore (success (run (Browser_lane.Page_act (Browser_action.On_tab {
      tab_id=downloads_tab;frame_path=["#download-frame"];interaction=Browser_action.Click "#frame-download"}))));
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
    act first Browser_action.Close_tab;
    check "closed tab cannot be clicked" (match run (Browser_lane.Page_act (Browser_action.On_tab {tab_id=first;frame_path=[];interaction=Browser_action.Click "button"})) with Browser_lane.Rejected_before_effect _ -> true | _ -> false);
    let closed = success (run Browser_lane.Session_close) in
    check "session close is confirmed" (member "closed" closed = `Bool true);
    open_session ();
    let fresh = open_tab "/fresh" in
    check "reopened sessions never reuse tab IDs" (fresh > second);
    check "old session target rejected" (match run (Browser_lane.Page_act (Browser_action.On_tab {tab_id=second;frame_path=[];interaction=Browser_action.Click "button"})) with Browser_lane.Rejected_before_effect _ -> true | _ -> false))))

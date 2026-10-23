(* Drives a real ego lite's input through the browser Add-on worker's ego
   connection: input_probe.exe <absolute path of ego-browser> <fixture base URL>.
   It opens fixture.html in a task space named [space], sends each input
   through the owner as the server would issue it, reads the page's own event
   log, retires, and then lists the spaces left with that name. *)
module Ego = Masc.Browser_addon_live_ego
module Owner = Masc.Browser_addon_owner
module W = Masc.Browser_addon_wire
module B = Browser_lane
let command = Sys.argv.(1)
let base = Sys.argv.(2)
let space = "masc ego input probe"
let excerpt_bytes = 300
let fixture = base ^ "/fixture.html"
let json_text json =
  let t = Yojson.Safe.to_string json in
  if String.length t > excerpt_bytes then String.sub t 0 excerpt_bytes ^ "..." else t
let text = function
  | W.Issue_result (Ok (B.Answered json)) -> json_text json
  | W.Issue_result (Ok B.Timed_out) -> "timed out"
  | W.Issue_result (Ok (B.Refused d | B.Rejected_before_effect d)) -> "refused: " ^ d
  | W.Issue_result (Ok B.Lane_absent) -> "lane absent"
  | W.Issue_result (Error _) -> "refused by the lane table before reaching ego"
  | W.Snapshot_result _ | Model_reply _ | Download_reply _ | Poll_result _ | Receipt | Service_refusal _ -> "other reply"
let data = function
  | W.Issue_result (Ok (B.Answered json)) -> Yojson.Safe.Util.member "data" json
  | _ -> `Null
let () =
  Eio_main.run (fun env ->
    Time_compat.set_clock (Eio.Stdenv.clock env);
    let owner = match Owner.create ~incarnation:"0b000000-0000-4000-8000-000000000096" with Ok o -> o | Error e -> failwith e in
    let dispatch command = Owner.dispatch owner {W.incarnation=Owner.incarnation owner;command} in
    let work () =
      let client = match B.connected_clients () with [c] -> c | _ -> failwith "one client" in
      Printf.printf "client %s %s %s %s\n%!" (B.browser_name client.browser)
        (B.live_transport_to_string client.transport) client.version client.engine_version;
      let issue verb = dispatch (W.Issue {route=B.Live_route (Some client.client_id);verb;
        actor=Some "keeper/probe";timeout_sec=B.reply_timeout_sec verb;only_if_idle=false}) in
      let step name verb =
        let t0 = Unix.gettimeofday () in
        let reply = issue verb in
        Printf.printf "%-24s %.2fs %s\n%!" name (Unix.gettimeofday () -. t0) (text reply);
        reply in
      let quiet name verb = ignore (step name verb) in
      ignore (step "tabs.list" B.Tabs_list);
      let opened = step "open_tab fixture" (B.Page_act (B.Action.Open_tab fixture)) in
      let tab = Yojson.Safe.Util.(data opened |> member "tabId" |> to_int) in
      let input ?(url=fixture) name action =
        quiet name (B.Page_interact {tab_id=tab;expected_url=Some url;frame_path=[];action}) in
      let scene = data (issue (B.Page_scene {tab_id=tab;max_chars=4000;view=B.Content;scope=None})) in
      let open Yojson.Safe.Util in
      let viewport_json = scene |> member "viewport" in
      let number key = match viewport_json |> member key with `Int n -> float_of_int n | `Float f -> f | _ -> failwith key in
      let viewport : B.Pointer.viewport = {document_id = scene |> member "documentId" |> to_string;
        width = number "width"; height = number "height"; scroll_x = number "scrollX"; scroll_y = number "scrollY"} in
      Printf.printf "viewport %s\n%!" (Yojson.Safe.to_string (B.Pointer.viewport_to_json viewport));
      (* The centre of an element the fixture places at a fixed CSS position. *)
      let at x y = {B.Pointer.x = x /. viewport.width; y = y /. viewport.height} in
      input "click #send" (B.Click "#send");
      input "click_at #ctx secondary" (B.Click_at {point=at 261. 41.;viewport;button=B.Pointer.Secondary});
      input "double_click #dbl" (B.Double_click (B.Selector "#dbl"));
      input "hover #hov" (B.Hover (B.Selector "#hov"));
      input "fill #name" (B.Fill {selector="#name";text="héllo"});
      input "click #name (focus)" (B.Click "#name");
      input "type_text" (B.Type_text {document_id=viewport.document_id;text=" world"});
      (match B.Keyboard.of_wire ~key:"Enter" ~modifiers:[] with
       | Ok key -> input "press_key Enter" (B.Press_key {document_id=viewport.document_id;key})
       | Error detail -> failwith detail);
      input "select_option #month 10" (B.Select_option {selector="#month";value="10"});
      input "scroll_at #pane 0,120" (B.Scroll_at {point=at 120. 230.;viewport;x=0;y=120});
      Unix.sleepf 0.5;
      input "click #missing" (B.Click "#missing");
      input "click_at stale document" (B.Click_at {point=at 80. 41.;viewport={viewport with document_id="stale"};button=B.Pointer.Primary});
      input "drag (not served)" (B.Drag {from=at 80. 41.;to_=at 261. 41.;viewport;via=[];duration_ms=0});
      let log = data (issue (B.Page_read {tab_id=Some tab;max_chars=Some 2000})) |> member "text" |> to_string in
      let lines = String.split_on_char '\n' log in
      let events = List.filter (fun line -> List.exists (fun prefix -> String.starts_with ~prefix line)
        ["click ";"contextmenu ";"dblclick ";"mouseenter ";"keydown ";"submit ";"change ";"scroll "]) lines in
      Printf.printf "page event log (%d lines):\n%s\n%!" (List.length events) (String.concat "\n" (List.map (fun l -> "  " ^ l) events));
      let link = List.find_map (fun node ->
          if (node |> member "tag") = `String "a" && (node |> member "text") = `String "next"
          then Some (node |> member "nodeId" |> to_string) else None) (scene |> member "nodes" |> to_list) in
      (match link with
       | Some node_id -> input "follow_link (scene node)" (B.Follow_link {document_id=viewport.document_id;node_id})
       | None -> print_endline "follow_link: the scene listed no link node");
      ignore (step "page.read after the link" (B.Page_read {tab_id=Some tab;max_chars=Some 80}));
      ignore (step "close_tab" (B.Page_act (B.Action.On_tab {tab_id=tab;frame_path=[];interaction=B.Action.Close_tab})));
      Printf.printf "retire %s\n%!" (match dispatch W.Retire with W.Receipt -> "receipt" | _ -> "not a receipt");
      Printf.printf "clients left %d\n%!" (List.length (B.connected_clients ())) in
    (match Ego.run ~env ~owner {command; space} work with
     | () -> print_endline "run returned"
     | exception (Invalid_argument d | Sys_error d | Failure d) -> print_endline ("run failed: " ^ d));
    match Ego.run_command ~env ~timeout_s:30. ~command ["nodejs"]
            ~stdin:(Printf.sprintf "const spaces = await listTaskSpaces();\nconsole.log('spaces left with this name: ' + spaces.filter(s => s.name === %S).length);" space) with
    | Ok output -> print_string output
    | Error f -> print_endline (Masc.Browser_ego_peer.run_failure_message f))

(* Drives a real ego lite through the browser Add-on worker's ego connection:
   ego_probe.exe <absolute path of ego-browser>. It opens a task space named
   [space], serves the commands below through the owner as the server would
   issue them, retires, and then lists the spaces left with that name. *)
module Ego = Masc.Browser_addon_live_ego
module Owner = Masc.Browser_addon_owner
module W = Masc.Browser_addon_wire
module B = Browser_lane
let command = Sys.argv.(1)
let space = "masc ego evidence probe"
let excerpt_bytes = 260
let text = function
  | W.Issue_result (Ok (B.Answered json)) ->
    let t = Yojson.Safe.to_string json in
    if String.length t > excerpt_bytes then String.sub t 0 excerpt_bytes ^ "..." else t
  | W.Issue_result (Ok B.Timed_out) -> "timed out"
  | W.Issue_result (Ok (B.Refused d | B.Rejected_before_effect d)) -> "refused: " ^ d
  | W.Issue_result (Ok B.Lane_absent) -> "lane absent"
  | W.Issue_result (Error _) -> "refused by the lane table before reaching ego"
  | W.Snapshot_result _ | Model_reply _ | Download_reply _ | Poll_result _ | Receipt | Service_refusal _ -> "other reply"
let () =
  Eio_main.run (fun env ->
    Time_compat.set_clock (Eio.Stdenv.clock env);
    let owner = match Owner.create ~incarnation:"0b000000-0000-4000-8000-000000000097" with Ok o -> o | Error e -> failwith e in
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
        let elapsed = Unix.gettimeofday () -. t0 in
        (match reply with
         | W.Issue_result (Ok (B.Answered json)) when name = "page.capture 2" ->
           Printf.printf "%-22s %.2fs %d base64 bytes\n%!" name elapsed
             (String.length Yojson.Safe.Util.(json |> member "data" |> member "data" |> to_string))
         | _ -> Printf.printf "%-22s %.2fs %s\n%!" name elapsed (text reply)) in
      step "tabs.list" B.Tabs_list;
      step "open_tab" (B.Page_act (B.Action.Open_tab "https://example.com/"));
      step "page.read 2" (B.Page_read {tab_id=Some 2; max_chars=Some 80});
      step "page.elements 2" (B.Page_elements {tab_id=Some 2; within=None});
      step "page.scene 2" (B.Page_scene {tab_id=2; max_chars=400; view=B.Content; scope=None});
      step "page.capture 2" (B.Page_capture {tab_id=2});
      step "click 2" (B.Page_interact {tab_id=2;expected_url=None;frame_path=[];action=B.Click "a"});
      step "goto 2" (B.Page_goto {url="https://en.wikipedia.org/wiki/OCaml"; tab_id=Some 2});
      step "page.read 2" (B.Page_read {tab_id=Some 2; max_chars=Some 80});
      step "goto 2 refused port" (B.Page_goto {url="http://127.0.0.1:9/"; tab_id=Some 2});
      step "goto 1 (p1)" (B.Page_goto {url="https://example.org/"; tab_id=Some 1});
      step "goto javascript" (B.Page_goto {url="javascript:1"; tab_id=Some 1});
      step "close_tab 2" (B.Page_act (B.Action.On_tab {tab_id=2;frame_path=[];interaction=B.Action.Close_tab}));
      step "page.read 2 after" (B.Page_read {tab_id=Some 2; max_chars=Some 80});
      step "tabs.list" B.Tabs_list;
      Printf.printf "retire %s\n%!" (match dispatch W.Retire with W.Receipt -> "receipt" | _ -> "not a receipt");
      Printf.printf "clients left %d\n%!" (List.length (B.connected_clients ())) in
    (match Ego.run ~env ~owner {command; space} work with
     | () -> print_endline "run returned"
     | exception (Invalid_argument d | Sys_error d) -> print_endline ("run failed: " ^ d));
    match Ego.run_command ~env ~timeout_s:30. ~command ["nodejs"]
            ~stdin:(Printf.sprintf "const spaces = await listTaskSpaces();\nconsole.log('spaces left with this name: ' + spaces.filter(s => s.name === %S).length);" space) with
    | Ok output -> print_string output
    | Error f -> print_endline (Masc.Browser_ego_peer.run_failure_message f))

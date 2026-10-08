(* This standalone fixture explicitly enables new Browser work. *)
let () = Browser_lane.install_activity_observer (Some (fun _ -> Browser_lane.Enabled))

open Alcotest
module Lane = Browser_lane
module Rejection = Masc_tui_browser_rejection
module Tools = Masc.Tool_misc_browser_lane
module View = Masc_tui_types.Browser_lane_view

(* A workspace path nothing creates: no installed browser-lane host is read. *)
let no_workspace =
  Filename.concat (Filename.get_temp_dir_name ()) "masc-tui-browser-rejection-no-workspace"

(* The text a Keeper and its call log receive for a refused call: the tool's
   own result through the bridge the runtime uses. *)
let recorded result =
  match Masc.Tool_bridge.to_agent_core_typed_result ~base_path:no_workspace result with
  | Error error -> error.message
  | Ok _ -> fail "a refused browser call was projected as success"

let line = Rejection.line ~transport_label:View.transport_label ~capability_word:View.capability_word

let test_refusals_read_back () =
  Eio_main.run (fun env ->
    Time_compat.set_clock (Eio.Stdenv.clock env);
    Eio.Switch.run (fun sw ->
      let info n transport : Lane.client_info =
        let raw = Printf.sprintf "70000000-0000-4000-8000-%012d" n in
        let client_id = match Lane.client_id_of_string raw with
          | Ok id -> id | Error detail -> fail detail in
        {client_id; browser=Lane.Firefox; version="fixture"; transport; engine_version="fixture"} in
      let connect client =
        ignore (Lane.take_command ~client_info:client ~window_sec:0.001);
        Eio.Switch.on_release sw (fun () -> ignore (Lane.disconnect_client ~client_id:client.Lane.client_id)) in
      let tabs () = recorded (Tools.handle_tabs ~base_path:no_workspace ~tool_name:"BrowserTabs"
        ~start_time:(Tool_timing.start ()) (`Assoc [])) in
      let hover (client : Lane.client_info) =
        recorded (fst (Tools.handle_interact_with_phase ~base_path:no_workspace ~tool_name:"BrowserInteract"
          ~start_time:(Tool_timing.start ())
          (`Assoc ["lane",`String "live";"clientId",`String (Lane.client_id_to_string client.client_id);
            "tabId",`Int 1;"expectedUrl",`String "https://example.org/";"action",`String "hover_at";
            "point",`Assoc ["x",`Float 0.5;"y",`Float 0.5];
            "viewport",`Assoc ["documentId",`String "observed";"width",`Int 800;"height",`Int 600;
              "scrollX",`Int 0;"scrollY",`Int 0]]))) in
      (match Rejection.of_result (tabs ()) with
       | Some {case=Lane.No_live_client_case; detail=Rejection.Next_step sentence} ->
         check bool "no connected browser carries its next step" true (sentence <> "")
       | Some _ | None -> fail "a call with no browser connected did not read back as no_live_client");
      let extension = info 1 Lane.Web_extension in
      connect extension;
      let text = hover extension in
      check bool "the bridge's class line follows the refusal on its own line" true
        (String_util.contains_substring text "\nfailure_class=workflow_rejection");
      check bool "the deciding fields lead the recorded text" true
        (String.starts_with text
           ~prefix:{|{"error":"live_transport_unsupported","capability":"trusted_hover","transport":"web_extension",|});
      (match Rejection.of_result text with
       | Some ({case=Lane.Transport_unsupported_case;
                detail=Rejection.Unserved {transport=Lane.Web_extension; capability=Lane.Trusted_hover; serving_clients=0}}
               as rejection) ->
         check string "the row says what was asked of which connection"
           "live_transport_unsupported · this WebExtension connection does not serve hover · no connected browser does"
           (line rejection)
       | Some _ | None -> fail "an unserved hover did not read back");
      let bidi = info 2 Lane.Webdriver_bidi in
      connect bidi;
      (match Rejection.of_result (hover extension) with
       | Some ({detail=Rejection.Unserved {serving_clients=1; _}; _} as rejection) ->
         check string "a connected browser that serves it is counted"
           "live_transport_unsupported · this WebExtension connection does not serve hover · 1 connected browser does"
           (line rejection)
       | Some _ | None -> fail "the serving browser was not counted");
      (match Rejection.of_result (tabs ()) with
       | Some {case=Lane.Ambiguous_clients_case; detail=Rejection.Next_step _} -> ()
       | Some _ | None -> fail "two connected browsers did not read back as ambiguous");
      Lane.install_activity_observer (Some (fun _ -> Lane.Disabled));
      Eio.Switch.on_release sw (fun () -> Lane.install_activity_observer (Some (fun _ -> Lane.Enabled)));
      match Rejection.of_result (tabs ()) with
      | Some ({case=Lane.Lane_off_case; detail=Rejection.Next_step _} as rejection) ->
        check string "a lane that is off says how to turn it on"
          "browser_lane_off · browser.live is off; enable it before issuing new browser work" (line rejection)
      | Some _ | None -> fail "a lane that is off did not read back"))

(* Copied from a Keeper's call log on 2026-10-08, client IDs replaced. *)
let recorded_disconnect =
  {|{"error":"selected_client_disconnected","clients":[{"clientId":"70000000-0000-4000-8000-000000000011","browser":"firefox","version":"157.0","engineVersion":"157.0"}],"clientId":"70000000-0000-4000-8000-000000000012","host":{"launcher":"follows_workspace","workspace_port":8935,"workspace_port_error":null,"serving_port":8935,"polling_hosts":1,"verdict":"connected","message":"A browser lane host polls this server now."},"retry":"That browser is no longer connected. Choose a browser from clients and retry with its clientId. No browser command was dispatched."}|}
  ^ "\nfailure_class=workflow_rejection \xe2\x80\x94 The current state does not admit this action; it is a rule, not a syntax problem. Read the current state first. The same call succeeds only after the state changes."

let test_recorded_log_row () =
  match Rejection.of_result recorded_disconnect with
  | Some ({case=Lane.Selected_client_disconnected_case; detail=Rejection.Next_step _} as rejection) ->
    check string "a logged refusal shows its case and next step, not its JSON"
      "selected_client_disconnected · That browser is no longer connected. Choose a browser from clients and retry with its clientId. No browser command was dispatched."
      (line rejection)
  | Some _ | None -> fail "the logged refusal did not read back"

let test_other_results_are_left_alone () =
  List.iter (fun (name, text) ->
    check bool name true (Rejection.of_result text = None))
    [ "a plain workflow refusal", "the browser lane did not answer in time\nfailure_class=workflow_rejection"
    ; "an argument error's envelope",
      {|{"message":"Invalid browser arguments: activate_tab requires expectedUrl.","masc.tool_disposition":"failed","failure_class":"policy_rejection","data":{"kind":"invalid_input"}}|}
    ; "a successful interaction", {|{"clientId":"70000000-0000-4000-8000-000000000021","tabId":58,"action":"click"}|}
    ; "an error code the lane does not own", {|{"error":"quota_exhausted","retry":"Ask again tomorrow."}|}
    ; "a transport the lane does not know",
      {|{"error":"live_transport_unsupported","capability":"trusted_hover","transport":"carrier_pigeon","servingClients":[]}|}
    ; "a capability the lane does not know",
      {|{"error":"live_transport_unsupported","capability":"mind_reading","transport":"web_extension","servingClients":[]}|}
    ; "a lane case without its sentence", {|{"error":"no_live_client"}|}
    ; "an empty result", "" ]

let () =
  run "browser refusal on the Keeper screen"
    [ "decode",
      [ test_case "refusals read back from what the Keeper was told" `Quick test_refusals_read_back
      ; test_case "a logged refusal row" `Quick test_recorded_log_row
      ; test_case "other results are left alone" `Quick test_other_results_are_left_alone ] ]

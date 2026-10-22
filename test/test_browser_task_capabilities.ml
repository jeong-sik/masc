open Alcotest
module Lane = Browser_lane
module Cap = Masc.Browser_capabilities
module Selection = Masc.Browser_selection

let test_bound_request_keeps_its_browser () =
  check bool "bound automatic request cannot be reselected by capabilities" true
    (Selection.resolve ~required_actions:[Cap.Type_text] ~verb:Lane.Tabs_list ~bound:true Selection.Automatic
      = Error Selection.Binding_required)

let test_button_click_table () =
  let reaches backend operation = match Cap.support backend operation with
    | Cap.Available _ | Cap.Conditional _ -> true | Cap.Unsupported _ -> false in
  List.iter (fun operation ->
    check bool (Cap.operation_name operation ^ " on live BiDi") true
      (reaches (Cap.Connected Lane.Webdriver_bidi) operation);
    check bool (Cap.operation_name operation ^ " on owned Gecko") true (reaches Cap.Owned_gecko operation);
    check bool (Cap.operation_name operation ^ " on Stagehand") true (reaches Cap.Owned_chromium operation);
    check bool (Cap.operation_name operation ^ " is not claimed for the extension") false
      (reaches (Cap.Connected Lane.Web_extension) operation);
    check bool (Cap.operation_name operation ^ " is not claimed for Safari") false
      (reaches Cap.Safari_unavailable operation);
    match Cap.support Cap.Owned_gecko operation with
    | Cap.Conditional {invocation;_} ->
      check bool (Cap.operation_name operation ^ " is invoked through click_at") true
        (invocation.action = Some "click_at" && invocation.tool = Cap.Interact)
    | Cap.Available _ | Cap.Unsupported _ -> fail "a button click is conditional on an observed point")
    [Cap.Right_click; Cap.Middle_click]

let test_resize_viewport_table () =
  let reaches backend = match Cap.support backend Cap.Resize_viewport with
    | Cap.Available _ | Cap.Conditional _ -> true | Cap.Unsupported _ -> false in
  check bool "live BiDi sets the viewport" true (reaches (Cap.Connected Lane.Webdriver_bidi));
  check bool "Stagehand sets the viewport" true (reaches Cap.Owned_chromium);
  check bool "the owned Firefox driver does not" false (reaches Cap.Owned_gecko);
  check bool "the extension does not" false (reaches (Cap.Connected Lane.Web_extension));
  check bool "Safari does not" false (reaches Cap.Safari_unavailable)

let test_tab_history_and_close_table () =
  let reaches backend operation = match Cap.support backend operation with
    | Cap.Available _ | Cap.Conditional _ -> true | Cap.Unsupported _ -> false in
  List.iter (fun operation ->
    check bool (Cap.operation_name operation ^ " on live BiDi") true (reaches (Cap.Connected Lane.Webdriver_bidi) operation);
    check bool (Cap.operation_name operation ^ " on owned Gecko") true (reaches Cap.Owned_gecko operation);
    check bool (Cap.operation_name operation ^ " on Stagehand") true (reaches Cap.Owned_chromium operation);
    check bool (Cap.operation_name operation ^ " is not claimed for the extension") false
      (reaches (Cap.Connected Lane.Web_extension) operation);
    check bool (Cap.operation_name operation ^ " is not claimed for Safari") false (reaches Cap.Safari_unavailable operation))
    [Cap.Back; Cap.Forward; Cap.Reload; Cap.Close_tab]

let test_touch_table () =
  let reaches backend = match Cap.support backend Cap.Touch with
    | Cap.Available _ | Cap.Conditional _ -> true | Cap.Unsupported _ -> false in
  check bool "live BiDi sends touch" true (reaches (Cap.Connected Lane.Webdriver_bidi));
  check bool "the owned Firefox sends touch" true (reaches Cap.Owned_gecko);
  check bool "Stagehand has no touch" false (reaches Cap.Owned_chromium);
  check bool "the extension has no touch" false (reaches (Cap.Connected Lane.Web_extension));
  check bool "Safari has no touch" false (reaches Cap.Safari_unavailable)

let test_select_option_table () =
  let invocation backend = match Cap.support backend Cap.Select_option with
    | Cap.Available invocation | Cap.Conditional {invocation; _} -> Some (invocation.Cap.tool, invocation.Cap.action)
    | Cap.Unsupported _ -> None in
  List.iter (fun (label,backend) ->
    check bool (label ^ " selects through BrowserInteract") true
      (invocation backend = Some (Cap.Interact, Some "select_option")))
    ["live BiDi",Cap.Connected Lane.Webdriver_bidi;"the extension",Cap.Connected Lane.Web_extension;
     "Stagehand",Cap.Owned_chromium;"the owned Firefox",Cap.Owned_gecko];
  check bool "Safari has no select" true (invocation Cap.Safari_unavailable = None)

let test_list_windows_table () =
  let reaches backend = match Cap.support backend Cap.List_windows with
    | Cap.Available _ | Cap.Conditional _ -> true | Cap.Unsupported _ -> false in
  check bool "live BiDi names each tab's window" true (reaches (Cap.Connected Lane.Webdriver_bidi));
  List.iter (fun (label,backend) -> check bool (label ^ " does not") false (reaches backend))
    ["the extension",Cap.Connected Lane.Web_extension;"the owned Firefox",Cap.Owned_gecko;
     "Stagehand",Cap.Owned_chromium;"Safari",Cap.Safari_unavailable]

let () = run "task-aware browser choice" ["scenarios",[
  test_case "a bound request is not reselected by required actions" `Quick test_bound_request_keeps_its_browser;
  test_case "right and middle click are claimed only where a button is pressed" `Quick test_button_click_table;
  test_case "viewport resize is claimed only where a size can be set" `Quick test_resize_viewport_table;
  test_case "history and close are claimed on every backend that acts on tabs" `Quick test_tab_history_and_close_table;
  test_case "touch is claimed only where a touch pointer is sent" `Quick test_touch_table;
  test_case "select_option is claimed where the shared script runs" `Quick test_select_option_table;
  test_case "window listing is claimed only where tabs name their window" `Quick test_list_windows_table]]

open Alcotest
module Keyboard = Browser_lane.Keyboard
module Wire = Masc.Browser_stagehand_wire
let chord key modifiers = match Keyboard.of_wire ~key ~modifiers with
  | Ok value -> value | Error detail -> fail detail
let test_unicode_boundary () =
  List.iter (fun text -> check bool "valid Unicode text" true (Keyboard.validate_text text=Ok ()))
    ["";"한글🙂";"a β";"é"];
  List.iter (fun text -> check bool "malformed UTF-8 refused" true
    (Result.is_error (Keyboard.validate_text text))) ["\255";"\237\160\128";"\240\159"];
  List.iter (fun text -> check bool "text never silently sends navigation or control keys" true
    (Result.is_error (Keyboard.validate_text text))) ["first\tsecond";"first\nsubmit";"first\rsubmit";"\000";"\127"];
  List.iter (fun text -> check string "one scalar retained" text (Keyboard.key_text (chord text []).key))
    ["a";"+";"한";"🙂"];
  List.iter (fun key -> check bool "not one scalar or named key" true
    (Result.is_error (Keyboard.of_wire ~key ~modifiers:[]))) ["";"ab";"é";"\n";"\255"];
  check bool "duplicate modifier refused" true
    (Result.is_error (Keyboard.of_wire ~key:"a" ~modifiers:["Meta";"Meta"]));
  check bool "unknown modifier refused" true
    (Result.is_error (Keyboard.of_wire ~key:"a" ~modifiers:["Command"]))
let test_native_protocol () =
  let cases = [
    Wire.Page_double_click {page_id="P";x=12.;y=34.}, "page.click",
      {|{"page_id":"P","x":12.0,"y":34.0,"options":{"click_count":2}}|};
    Wire.Page_click {page_id="P";x=12.;y=34.;button=Browser_lane.Pointer.Primary}, "page.click",
      {|{"page_id":"P","x":12.0,"y":34.0}|};
    Wire.Page_click {page_id="P";x=12.;y=34.;button=Browser_lane.Pointer.Middle}, "page.click",
      {|{"page_id":"P","x":12.0,"y":34.0,"options":{"button":"middle"}}|};
    Wire.Page_click {page_id="P";x=12.;y=34.;button=Browser_lane.Pointer.Secondary}, "page.click",
      {|{"page_id":"P","x":12.0,"y":34.0,"options":{"button":"right"}}|};
    Wire.Page_set_viewport_size {page_id="P";width=800;height=600}, "page.set_viewport_size",
      {|{"page_id":"P","width":800,"height":600}|};
    Wire.Page_type {page_id="P";text="한글🙂"}, "page.type", {|{"page_id":"P","text":"한글🙂"}|};
    Wire.Page_key_press {page_id="P";key=chord "a" ["Meta";"Shift"]}, "page.key_press",
      {|{"page_id":"P","key":"Meta+Shift+a"}|};
    Wire.Page_key_press {page_id="P";key=chord "+" ["Control"]}, "page.key_press",
      {|{"page_id":"P","key":"Control++"}|};
    Wire.Page_key_press {page_id="P";key=chord "Tab" ["Shift"]}, "page.key_press",
      {|{"page_id":"P","key":"Shift+Tab"}|}] in
  List.iter (fun (request,method_,params) ->
    check string "native method" method_ (Wire.method_name request);
    check string "exact native params" params (Yojson.Safe.to_string (Wire.call_params request));
    check bool "native input never asks a model" false (Wire.uses_model request);
    check bool "native input has no sentence timeout" true (Wire.sentence_timeout_of_call request=None)) cases
let test_w3c_input_sources () =
  let field key json = Yojson.Safe.Util.member key json in
  let actions source = match source with
    | `List [source] -> field "actions" source |> Yojson.Safe.Util.to_list
    | _ -> fail "one keyboard source required" in
  let events = Keyboard.input_source ~id:"owner" (chord "a" ["Meta";"Shift"]) |> actions in
  check (list string) "down and reverse-order up retain ownership"
    ["keyDown";"keyDown";"keyDown";"keyUp";"keyUp";"keyUp"]
    (List.map (fun event -> field "type" event |> Yojson.Safe.Util.to_string) events);
  check (list string) "modifier chord is held until release"
    ["\xee\x80\xbd";"\xee\x80\x88";"a";"a";"\xee\x80\x88";"\xee\x80\xbd"]
    (List.map (fun event -> field "value" event |> Yojson.Safe.Util.to_string) events);
  let unicode = match Keyboard.text_source ~id:"owner" "한🙂" with Ok value -> actions value | Error detail -> fail detail in
  check (list string) "Unicode scalars never split into UTF-8 bytes"
    ["한";"한";"🙂";"🙂"]
    (List.map (fun event -> field "value" event |> Yojson.Safe.Util.to_string) unicode);
  check bool "reserved WebDriver key scalar cannot become text input" true
    (Result.is_error (Keyboard.text_source ~id:"owner" "\xee\x80\x89"))
let () = run "browser keyboard" ["native",[
  test_case "Unicode and closed chord boundary" `Quick test_unicode_boundary;
  test_case "native W3C chord ownership and Unicode scalar input" `Quick test_w3c_input_sources;
  test_case "actual Stagehand protocol fields" `Quick test_native_protocol]]

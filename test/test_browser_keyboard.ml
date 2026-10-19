open Alcotest
module Keyboard = Browser_lane.Keyboard
module Wire = Masc.Browser_stagehand_wire
let chord key modifiers = match Keyboard.of_wire ~key ~modifiers with
  | Ok value -> value | Error detail -> fail detail
let test_unicode_boundary () =
  List.iter (fun text -> check bool "valid Unicode text" true (Keyboard.validate_text text=Ok ()))
    ["";"한글🙂";"a\n\tβ";"é"];
  List.iter (fun text -> check bool "malformed UTF-8 refused" true
    (Result.is_error (Keyboard.validate_text text))) ["\255";"\237\160\128";"\240\159"];
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
let () = run "browser keyboard" ["native",[
  test_case "Unicode and closed chord boundary" `Quick test_unicode_boundary;
  test_case "actual Stagehand protocol fields" `Quick test_native_protocol]]

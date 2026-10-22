type partial_failure = { tab_id : int; message : string; receipt : Yojson.Safe.t }
type failure = Before_effect of string | Partial_failure of partial_failure | Outcome_unknown of string
type verb = Browser_info | Tabs_list | Page_read | Page_elements | Page_capture | Page_scene | Page_interact | Page_act
  | Page_goto
let verb_to_wire = function
  | Browser_info -> "browser.info" | Tabs_list -> "tabs.list" | Page_read -> "page.read"
  | Page_scene -> "page.scene" | Page_elements -> "page.elements" | Page_capture -> "page.capture"
  | Page_interact -> "page.interact" | Page_act -> "page.act" | Page_goto -> "page.goto"
let verb_of_wire = function
  | "browser.info" -> Some Browser_info | "tabs.list" -> Some Tabs_list | "page.read" -> Some Page_read
  | "page.scene" -> Some Page_scene | "page.elements" -> Some Page_elements
  | "page.capture" -> Some Page_capture | "page.interact" -> Some Page_interact | "page.act" -> Some Page_act
  | "page.goto" -> Some Page_goto
  | _ -> None

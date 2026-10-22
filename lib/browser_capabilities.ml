type backend = Connected of Browser_lane.live_transport | Owned_gecko
  | Owned_chromium | Safari_unavailable
type operation =
  | List_tabs | Open_tab | Close_tab | Activate_tab | List_windows | Create_window | Close_window
  | Navigate | Follow_link | Back | Forward | Reload | Session_lifecycle
  | Read_text | Read_html | Read_elements | Read_scene | Read_regions | Screenshot
  | Click | Double_click | Right_click | Middle_click | Pointer_down | Pointer_up | Hover | Pointer_drag | Html5_drop
  | Scroll_page | Scroll_at | Fill | Type_text | Press_key | Key_chord | Select_option
  | Read_frames | Frame_interaction | Read_dialog | Accept_dialog | Dismiss_dialog
  | Upload_file | List_downloads | Page_zoom | Resize_viewport | Touch
  | Read_clipboard | Write_clipboard | Read_network | Intercept_network
  | Read_console | Read_storage | Write_storage | Sentence_action
type tool = Tabs | Read | Interact | Act | Session | Goto | Instruct
type invocation = { tool : tool; action : string option; mode : string option }
type support = Available of invocation
  | Conditional of { invocation : invocation; constraints : string list }
  | Unsupported of string
type entry = { operation : operation; support : support }

let backend_of_target = function
  | Browser_lane.Live_client client -> Connected client.info.transport
  | Browser_lane.Automation -> Owned_gecko
  | Browser_lane.Stagehand -> Owned_chromium
let operations = [List_tabs;Open_tab;Close_tab;Activate_tab;List_windows;Create_window;Close_window;
  Navigate;Follow_link;Back;Forward;Reload;Session_lifecycle;
  Read_text;Read_html;Read_elements;Read_scene;Read_regions;Screenshot;
  Click;Double_click;Right_click;Middle_click;Pointer_down;Pointer_up;Hover;Pointer_drag;Html5_drop;Scroll_page;Scroll_at;
  Fill;Type_text;Press_key;Key_chord;Select_option;Read_frames;Frame_interaction;
  Read_dialog;Accept_dialog;Dismiss_dialog;Upload_file;List_downloads;Page_zoom;
  Resize_viewport;Touch;Read_clipboard;Write_clipboard;Read_network;Intercept_network;
  Read_console;Read_storage;Write_storage;Sentence_action]
let invoke ?action ?mode tool = {tool;action;mode}
let available ?action ?mode tool = Available (invoke ?action ?mode tool)
let conditional ?action ?mode tool constraints =
  Conditional {invocation=invoke ?action ?mode tool;constraints}
let missing = Unsupported "No public browser tool implements this operation."
let viewport_bounds = Printf.sprintf "width and height are CSS pixels between %d and %d, given together"
  Browser_lane.viewport_side_min_px Browser_lane.viewport_side_max_px
let observed = "Keep the observed browser identity and tabId; re-read after an effect or an unknown outcome."
let target = "Use one freshly observed selector or documentId/nodeId; the target must be visible and unobstructed."
let geometry = "Use the current documentId and viewport geometry; stale URL/document/viewport is refused."
let native = function Connected Browser_lane.Webdriver_bidi | Owned_gecko | Owned_chromium -> true
  | Connected Browser_lane.Web_extension | Safari_unavailable -> false
let gecko_only backend invocation constraints = match backend with
  | Owned_gecko -> Conditional {invocation;constraints}
  | Connected (Browser_lane.Web_extension | Browser_lane.Webdriver_bidi) | Owned_chromium ->
    Unsupported "This public operation is implemented only by the owned Gecko adapter."
  | Safari_unavailable -> Unsupported "No Safari adapter is installed in MASC."
let support backend operation = match backend with
  | Safari_unavailable -> Unsupported "No Safari adapter is installed in MASC; installed Safari alone is not a connection."
  | (Connected (Browser_lane.Web_extension | Browser_lane.Webdriver_bidi) | Owned_gecko | Owned_chromium) ->
    match operation with
    | List_tabs -> available Tabs
    | Open_tab -> (match backend with
      | Connected Browser_lane.Webdriver_bidi -> conditional ~action:"open_tab" Act
          ["Requires the exact observed clientId; creation can succeed even if navigation fails. Inspect the returned tabId before another create."]
      | Owned_gecko | Owned_chromium -> conditional ~action:"open_tab" Act
          ["Requires an open work session; creation and navigation can partially succeed. Preserve any created tabId in the partial receipt and inspect that exact browser/tab before another create."]
      | Connected Browser_lane.Web_extension | Safari_unavailable -> missing)
    | Close_tab -> (match backend with
      | Owned_gecko | Owned_chromium -> conditional ~action:"close_tab" Act
          [observed;"Top-level tab only; the ID is retired after confirmed closure, not a lost or unconfirmed receipt."]
      | Connected Browser_lane.Webdriver_bidi -> conditional ~action:"close_tab" Act
          [observed;"Only a tab this connection opened with open_tab; a tab the operator opened is refused before any effect. Closes without running the page's unload prompt."]
      | Connected Browser_lane.Web_extension | Safari_unavailable -> missing)
    | Activate_tab -> (match backend with
      | Connected Browser_lane.Web_extension -> conditional ~action:"activate_tab" Interact
          [observed;"Changes the browser's active tab without promising window focus."]
      | Connected Browser_lane.Webdriver_bidi -> conditional ~action:"activate_tab" Interact
          [observed;"Requires expectedUrl; a tab whose page moved on is refused before any effect.";
           "Brings the tab to the front and gives its browser window system focus, which can take focus from what the operator is doing."]
      | Owned_gecko | Owned_chromium | Safari_unavailable -> missing)
    | List_windows -> (match backend with
      | Connected Browser_lane.Webdriver_bidi -> conditional Tabs
          ["Every list_tabs row carries windowId when Firefox names the tab's window; tabs with the same windowId share a window, and the distinct values are the windows.";
           "windowId is opaque and only comparable within one connection. There is no window title, size or position."]
      | Connected Browser_lane.Web_extension | Owned_gecko | Owned_chromium | Safari_unavailable -> missing)
    | Create_window | Close_window -> missing
    | Navigate -> (match backend with
      | Owned_gecko | Owned_chromium -> conditional Goto ["An open owned session and an HTTP(S) URL are required; preserve its concrete browser binding."]
      | Connected Browser_lane.Webdriver_bidi -> conditional Goto
          [observed;"Requires the exact observed clientId and the tabId of a tab this connection opened with open_tab; a tab the operator opened is refused before any effect.";
           "Waits for the new document. An error after the navigation started leaves the result unknown: inspect the same tab."]
      | Connected Browser_lane.Web_extension -> Unsupported
          "A connected WebExtension does not navigate a tab; use an inspected follow_link, or a live BiDi connection's open_tab and goto."
      | Safari_unavailable -> missing)
    | Follow_link -> conditional ~action:"follow_link" Interact
        [observed;target;"Requires expectedUrl and an observed same-tab HTTP(S) anchor; rejects downloads, new-window targets and unsupported referrer semantics."]
    | Back -> (match backend with
        | Owned_gecko | Owned_chromium -> conditional ~action:"back" Act
          [observed;"Top-level tab only; inspect the same tab after navigation or an unknown result."]
        | Connected Browser_lane.Webdriver_bidi -> conditional ~action:"back" Act
          [observed;"Top-level tab only, and only a tab this connection opened with open_tab; an operator tab is refused before any effect. An error after the step started leaves the result unknown: inspect the same tab."]
        | Connected Browser_lane.Web_extension | Safari_unavailable -> missing)
    | Forward -> (match backend with
        | Owned_gecko | Owned_chromium -> conditional ~action:"forward" Act
          [observed;"Top-level tab only; inspect the same tab after navigation or an unknown result."]
        | Connected Browser_lane.Webdriver_bidi -> conditional ~action:"forward" Act
          [observed;"Top-level tab only, and only a tab this connection opened with open_tab; an operator tab is refused before any effect. An error after the step started leaves the result unknown: inspect the same tab."]
        | Connected Browser_lane.Web_extension | Safari_unavailable -> missing)
    | Reload -> (match backend with
        | Owned_gecko | Owned_chromium -> conditional ~action:"reload" Act
          [observed;"Top-level tab only; inspect the same tab after navigation or an unknown result."]
        | Connected Browser_lane.Webdriver_bidi -> conditional ~action:"reload" Act
          [observed;"Top-level tab only, and only a tab this connection opened with open_tab; an operator tab is refused before any effect. An error after the step started leaves the result unknown: inspect the same tab."]
        | Connected Browser_lane.Web_extension | Safari_unavailable -> missing)
    | Session_lifecycle -> (match backend with
      | Owned_gecko | Owned_chromium -> conditional Session
          ["Actions open/status/close apply to the selected owned browser; status and close remain available while disabled."]
      | Connected (Browser_lane.Web_extension | Browser_lane.Webdriver_bidi) | Safari_unavailable ->
          Unsupported "Connected operator browsers do not expose an owned session lifecycle.")
    | Read_text -> available ~mode:"text" Read
    | Read_html -> Unsupported "Document-source adapters exist, but BrowserRead exposes no HTML/source mode."
    | Read_elements -> available ~mode:"elements" Read
    | Read_scene -> conditional ~mode:"scene" Read [observed;"Explicit tabId; viewport scene may be truncated. Geometry is not an occlusion guarantee."]
    | Read_regions -> conditional ~mode:"regions" Read [observed;"Explicit tabId; copy observed region references for scoped reads."]
    | Screenshot -> conditional ~mode:"screenshot" Read
        [observed;"Requires an owning Keeper and explicit tabId; captures the viewport, not the whole document."]
    | Click -> conditional ~action:"click" Interact
        (observed::target::(match backend with
          | Connected Browser_lane.Web_extension -> ["Uses DOM click; trusted pointerdown/mousedown is not provided."]
          | Connected Browser_lane.Webdriver_bidi | Owned_gecko | Owned_chromium -> ["Uses native pointer input; captures/checks the current URL when expectedUrl is omitted."]
          | Safari_unavailable -> []))
    | Hover -> if native backend then conditional ~action:"hover" Interact [observed;target]
        else Unsupported "WebExtension does not serve trusted hover; the selected tab must not be silently moved to another browser."
    | Pointer_drag -> if native backend then conditional ~action:"drag_to" Interact
        ([observed;target;geometry;"via contains observed viewport fractions. Input receipt does not establish application drop acceptance."]
         @ match backend with Owned_chromium -> ["durationMs must be zero."]
           | Connected (Browser_lane.Web_extension | Browser_lane.Webdriver_bidi) | Owned_gecko | Safari_unavailable -> [])
        else Unsupported "WebExtension does not serve native pointer drag."
    | Html5_drop -> (match backend with
      | Owned_chromium -> conditional ~action:"drag_to" Interact
          [observed;target;"Native HTML5 DataTransfer/drop passed a fixture; target behavior must be observed afterward. Not a universal drop guarantee."]
      | Connected Browser_lane.Webdriver_bidi | Owned_gecko -> Unsupported
          "Native pointer drag exists, but the tested Firefox HTML5 DataTransfer/drop scenario fails; no synthetic fallback."
      | Connected Browser_lane.Web_extension | Safari_unavailable -> missing)
    | Right_click | Middle_click -> (match backend with
      | Connected Browser_lane.Webdriver_bidi | Owned_gecko -> conditional ~action:"click_at" Interact
          [observed;geometry;
           "Pass button \"secondary\" (right) or \"middle\". Only click_at takes a button; selector and node targets do not.";
           "Native pointer input at the observed point; a context menu or application behavior must be observed afterward."]
      | Owned_chromium -> conditional ~action:"click_at" Interact
          [observed;geometry;
           "Pass button \"secondary\" (right) or \"middle\". Only click_at takes a button; selector and node targets do not.";
           "Stagehand's page.click takes the button as a native Chromium mouse event; no real-Chromium run of it has been recorded yet.";
           "A context menu or application behavior must be observed afterward."]
      | Connected Browser_lane.Web_extension -> Unsupported
          "WebExtension clicks through the DOM and cannot press the middle or secondary button; the selected tab must not be silently moved to another browser."
      | Safari_unavailable -> missing)
    | Scroll_page -> conditional ~action:"scroll" Interact [observed;"Scrolls the page; use scroll_at for a nested pane."]
    | Scroll_at -> conditional ~action:"scroll_at" Interact [observed;geometry;"Scrolls the pane at the observed viewport point."]
    | Fill -> conditional ~action:"fill" Interact
        [observed;target;"Replaces the value of a text input or textarea and emits input/change, or replaces the content of a contenteditable editor with insertText (the editor gets input events); this is not trusted keyboard typing or submission."]
    | Double_click -> if native backend then conditional ~action:"double_click" Interact
        [observed;target;"Native double click; application behavior must be observed afterward."] else missing
    | Type_text -> if native backend then conditional ~action:"type_text" Interact
        [observed;"Requires current documentId and expectedUrl; stale document/URL is refused.";"Requires the current enabled editable focus. Unicode text is literal; C0/DEL controls are refused, use press_key for Tab/Enter.";
         "Gecko/BiDi refuse WebDriver-reserved U+E000–U+E05D text. Chromium supports literal private-use text.";
         "An uncertain Chromium keyboard release quarantines this owned session: inspect status and explicitly close/reopen; no replay or automatic page closure."] else missing
    | Press_key | Key_chord -> if native backend then conditional ~action:"press_key" Interact
        [observed;"Requires current documentId and expectedUrl; stale document/URL is refused.";"Targets current enabled focus (or body); accepts named keys or one Unicode scalar with Control/Meta/Alt/Shift modifiers.";
         "Chromium refuses supplementary press-key scalars; use type_text for supplementary Unicode text.";
         "An uncertain Chromium keyboard release quarantines the exact session until explicit close/reopen; pages are preserved."] else missing
    | Page_zoom -> (match backend with
      | Connected Browser_lane.Web_extension -> conditional ~action:"set_zoom" Interact
          [observed;"Requires extension 0.8.0+, exact clientId/tabId, expectedUrl and factor 0.3–5. Uses measured browser zoom, never CSS scaling.";
           "Only automatic zoom mode is supported; per-origin scope may also affect and persist for same-origin tabs. Re-read the scene/screenshot afterward."]
      | Connected Browser_lane.Webdriver_bidi | Owned_gecko | Owned_chromium | Safari_unavailable -> missing)
    | Select_option -> (match backend with
      | Owned_gecko -> Conditional {invocation=invoke ~action:"select" Act;
          constraints=[observed;"Requires one observed native select and exact option value."]}
      | Connected (Browser_lane.Web_extension | Browser_lane.Webdriver_bidi) | Owned_chromium ->
          conditional ~action:"select_option" Interact
            [observed;"Pass the selector of one single-choice select and the exact value of one enabled option; a multiple select, a missing, repeated or disabled option is refused before any effect.";
             "Sets the option and emits input and change; this is not a trusted click on the list."]
      | Safari_unavailable -> missing)
    | Read_frames -> gecko_only backend (invoke ~mode:"frames" Read)
        [observed;"Explicit tabId; framePath consists of observed outer-to-inner frame selectors."]
    | Frame_interaction -> gecko_only backend (invoke Act)
        [observed;"framePath supports element/scroll actions only. Inspect the same tab/frame first; action must be click/fill/press/select/scroll/upload."]
    | Read_dialog -> gecko_only backend (invoke ~mode:"dialog" Read) [observed]
    | Accept_dialog -> gecko_only backend (invoke ~action:"accept_dialog" Act) [observed;"Optional text applies only to an observed prompt."]
    | Dismiss_dialog -> gecko_only backend (invoke ~action:"dismiss_dialog" Act) [observed]
    | Upload_file -> gecko_only backend (invoke ~action:"upload" Act)
        [observed;"Requires an owning Keeper, an observed file input and sandbox-authorized file paths; 16 MiB per file."]
    | List_downloads -> gecko_only backend (invoke ~mode:"downloads" Read)
        [observed;"Explicit tabId and a functioning BiDi download connection; reports observed pending/completed/canceled/interrupted state."]
    | Sentence_action -> (match backend with
      | Owned_chromium -> conditional ~action:"act" Instruct
          [observed;"Model-mediated sentence action; not a substitute for guaranteed native keyboard, double-click or zoom support. observe/extract are separate read actions."]
      | Connected (Browser_lane.Web_extension | Browser_lane.Webdriver_bidi) | Owned_gecko | Safari_unavailable -> missing)
    | Resize_viewport -> (match backend with
      | Connected Browser_lane.Webdriver_bidi -> conditional ~action:"set_viewport" Interact
          [observed;"Requires exact clientId/tabId and expectedUrl; " ^ viewport_bounds ^ ". With neither, the browser's own size returns.";
           "The size is an override on that tab until it is restored, which this connection does for the tabs it sized when its session ends; read the screenshot or scene again afterward. This is the page viewport, not the browser window."]
      | Owned_chromium -> conditional ~action:"set_viewport" Interact
          [observed;"Requires expectedUrl; " ^ viewport_bounds ^ ". Stagehand has no call that restores the browser's own size, so this session keeps the override until it closes.";
           "Read the screenshot or scene again afterward. This is the page viewport, not the browser window."]
      | Owned_gecko -> Unsupported "The owned Firefox driver sets no viewport; use a live BiDi connection or Stagehand."
      | Connected Browser_lane.Web_extension -> Unsupported "WebExtension cannot set the page viewport; the selected tab must not be silently moved to another browser."
      | Safari_unavailable -> missing)
    | Touch -> (match backend with
      | Connected Browser_lane.Webdriver_bidi | Owned_gecko -> conditional ~action:"tap_at" Interact
          [observed;geometry;
           "tap_at is a touch press and release at the observed point; swipe is a held touch from one observed point to another, with the same via and durationMs as drag.";
           "Native touch pointer input: the page sees pointer and touch events. Firefox 158 followed a tap with the mouse events and a click; observe the page afterward."]
      | Owned_chromium -> Unsupported "Stagehand has no touch call."
      | Connected Browser_lane.Web_extension -> Unsupported
          "WebExtension clicks through the DOM and cannot send touch input; the selected tab must not be silently moved to another browser."
      | Safari_unavailable -> missing)
    | Pointer_down | Pointer_up -> missing
    | Read_console -> gecko_only backend (invoke ~mode:"console" Read)
        [observed;"Messages and uncaught errors since the session opened, for one tab, oldest first. At most 200 are kept and the reply says how many older ones were dropped; each text is cut at 4000 bytes and says so. Entries Firefox gave no tab for, and events that were not what BiDi documents, are counted in the reply and do not end the session.";
         "The text is whatever the page printed, and a page can print anything."]
    | Read_network -> gecko_only backend (invoke ~mode:"network" Read)
        [observed;"Requests since the session opened, for one tab, oldest first; at most 200 are kept and the reply says how many older ones were dropped.";
         "Each row has method, address, state, and status, mimeType and bytesReceived once it completed. Header values, cookies and bodies are never returned, only header names; the address keeps its path and replaces every query value with REDACTED. A path can still carry a token."]
    | Read_clipboard | Write_clipboard | Intercept_network -> missing
    | Read_storage -> gecko_only backend (invoke ~mode:"cookies" Read)
        [observed;"The cookies the tab's page can see, at most 200, with the total. Name, domain, path, secure, httpOnly, sameSite and expiry; the value is never returned.";
         "Only cookies are covered. Web storage (localStorage, sessionStorage) is not read."]
    | Write_storage -> missing
let catalog backend = List.map (fun operation -> {operation;support=support backend operation}) operations
let operation_name = function
  | List_tabs -> "list_tabs" | Open_tab -> "open_tab" | Close_tab -> "close_tab"
  | Activate_tab -> "activate_tab" | List_windows -> "list_windows" | Create_window -> "create_window" | Close_window -> "close_window"
  | Navigate -> "navigate" | Follow_link -> "follow_link" | Back -> "back" | Forward -> "forward"
  | Reload -> "reload" | Session_lifecycle -> "session_lifecycle" | Read_text -> "read_text"
  | Read_html -> "read_html" | Read_elements -> "read_elements" | Read_scene -> "read_scene"
  | Read_regions -> "read_regions" | Screenshot -> "screenshot" | Click -> "click"
  | Double_click -> "double_click" | Right_click -> "right_click" | Middle_click -> "middle_click"
  | Pointer_down -> "pointer_down" | Pointer_up -> "pointer_up" | Hover -> "hover"
  | Pointer_drag -> "pointer_drag" | Html5_drop -> "html5_drop" | Scroll_page -> "scroll_page"
  | Scroll_at -> "scroll_at" | Fill -> "fill" | Type_text -> "type_text" | Press_key -> "press_key"
  | Key_chord -> "key_chord" | Select_option -> "select_option" | Read_frames -> "read_frames"
  | Frame_interaction -> "frame_interaction" | Read_dialog -> "read_dialog"
  | Accept_dialog -> "accept_dialog" | Dismiss_dialog -> "dismiss_dialog" | Upload_file -> "upload_file"
  | List_downloads -> "list_downloads" | Page_zoom -> "page_zoom" | Resize_viewport -> "resize_viewport"
  | Touch -> "touch" | Read_clipboard -> "read_clipboard" | Write_clipboard -> "write_clipboard"
  | Read_network -> "read_network" | Intercept_network -> "intercept_network" | Read_console -> "read_console"
  | Read_storage -> "read_storage" | Write_storage -> "write_storage" | Sentence_action -> "sentence_action"
let operation_of_wire name = List.find_opt (fun operation -> String.equal (operation_name operation) name) operations
let parse_required_actions = function
  | `List values ->
      let rec parse seen = function
        | [] -> Ok (List.rev seen)
        | `String name :: rest -> (match operation_of_wire name with
            | None -> Error ("unknown requiredActions operation: " ^ name)
            | Some operation when List.mem operation seen -> Error ("duplicate requiredActions operation: " ^ name)
            | Some operation -> parse (operation::seen) rest)
        | _::_ -> Error "requiredActions must contain public operation names" in
      parse [] values
  | _ -> Error "requiredActions must be an array of public operation names"
let missing_operations backend operations = List.filter (fun operation -> match support backend operation with
  | Available _ | Conditional _ -> false | Unsupported _ -> true) operations
let tool_name = function Tabs -> "masc_browser_tabs" | Read -> "masc_browser_read"
  | Interact -> "masc_browser_interact" | Act -> "masc_browser_act" | Session -> "masc_browser_session"
  | Goto -> "masc_browser_goto" | Instruct -> "masc_browser_instruct"
let invocation_fields invocation = ["tool",`String (tool_name invocation.tool)]
  @ (match invocation.action with None -> [] | Some value -> ["action",`String value])
  @ (match invocation.mode with None -> [] | Some value -> ["mode",`String value])
let entry_json {operation;support} =
  let fields = match support with
    | Available invocation -> ("status",`String "available")::invocation_fields invocation
    | Conditional {invocation;constraints} -> ("status",`String "conditional")::invocation_fields invocation
        @ ["constraints",`List (List.map (fun value -> `String value) constraints)]
    | Unsupported reason -> ["status",`String "unsupported";"reason",`String reason] in
  `Assoc (("operation",`String (operation_name operation))::fields)
let to_json backend = `Assoc [
  "scope",`String "implemented public tools for this browser; not readiness, effect success or dispatch authority";
  "operations",`List (List.map entry_json (catalog backend))]

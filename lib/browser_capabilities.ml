type backend = Connected of Browser_lane.live_transport | Owned_gecko
  | Owned_chromium | Safari_unavailable
type operation =
  | List_tabs | Open_tab | Close_tab | Activate_tab | List_windows | Create_window | Close_window
  | Navigate | Follow_link | Back | Forward | Reload | Session_lifecycle
  | Read_text | Read_html | Read_elements | Read_scene | Read_regions | Read_snapshot | Screenshot
  | Native_workflow
  | Click_snapshot_target | Fill_snapshot_target | Hover_snapshot_target | Double_click_snapshot_target
  | Click | Double_click | Right_click | Middle_click | Pointer_down | Pointer_up | Hover | Pointer_drag | Html5_drop
  | Scroll_page | Scroll_at | Fill | Type_text | Press_key | Key_chord | Select_option
  | Read_frames | Frame_interaction | Read_dialog | Accept_dialog | Dismiss_dialog
  | Hand_off | Take_over | Space_status | Finish_space | Wait_for_control | Adopt_tab | Release_tab
  | Upload_file | List_downloads | Page_zoom | Resize_viewport | Touch
  | Read_clipboard | Write_clipboard | Read_network | Intercept_network
  | Read_console | Read_storage | Write_storage | Emulate_environment | Sentence_action
[@@deriving enumerate]
type tool = Tabs | Read | Interact | Act | Session | Goto | Instruct
type invocation = { tool : tool; action : string option; mode : string option }
type support = Available of invocation
  | Conditional of { invocation : invocation; constraints : string list }
  | Unsupported of string
type entry = { operation : operation; support : support }

(* Every constructor, in declaration order, so the catalog, the wire
   parser and the tool schemas cannot skip one. *)
let operations = all_of_operation
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
  | Connected (Browser_lane.Web_extension | Browser_lane.Ego_task_space) | Safari_unavailable -> false
let ego_pages = "Only a page the ego task space manages; a tab the operator opened in that space is listed and refused before any read."
(* A read every connection serves, which an ego connection serves only on its own pages. *)
let read backend invocation constraints = match backend with
  | Connected Browser_lane.Ego_task_space -> Conditional {invocation;constraints=constraints @ [ego_pages]}
  | Connected (Browser_lane.Web_extension | Browser_lane.Webdriver_bidi) | Owned_gecko | Owned_chromium | Safari_unavailable ->
    (match constraints with [] -> Available invocation | _ :: _ -> Conditional {invocation;constraints})
let ego_agent_pages = "Only a page an agent opened in the ego task space, its first page included; a tab the operator opened there is refused before any effect."
(* An effect an ego connection takes only on the pages its space opened. *)
let on_agent_pages = function
  | Available invocation -> Conditional {invocation;constraints=[ego_agent_pages]}
  | Conditional {invocation;constraints} -> Conditional {invocation;constraints=constraints @ [ego_agent_pages]}
  | Unsupported _ as unsupported -> unsupported
(* A DOM input every connection serves, an ego connection on its own pages. *)
let dom_input backend support = match backend with
  | Connected (Browser_lane.Web_extension | Browser_lane.Webdriver_bidi) | Owned_gecko | Owned_chromium -> support
  | Connected Browser_lane.Ego_task_space -> on_agent_pages support
  | Safari_unavailable -> missing
let gecko_only backend invocation constraints = match backend with
  | Owned_gecko -> Conditional {invocation;constraints}
  | Connected (Browser_lane.Web_extension | Browser_lane.Webdriver_bidi | Browser_lane.Ego_task_space) | Owned_chromium ->
    Unsupported "This public operation is implemented only by the owned Gecko adapter."
  | Safari_unavailable -> Unsupported "No Safari adapter is installed in MASC."
(* Native element input on a target the ego connection's own snapshot named. *)
let snapshot_target backend ~action = match backend with
  | Connected Browser_lane.Ego_task_space -> conditional ~action Interact
      [observed;"target is {ref} from the latest snapshot of the same page, {role, name, exact} or {text, exact}, given alone with expectedUrl.";
       "The URL is checked before SDK entry. Ego owns locator resolution, actionability and auto-scrolling; native method failures, including missing or ambiguous targets, leave the result uncertain and are never replayed.";
       "The receipt lists the pages the action opened as popups (tabIds) and a JavaScript dialog it raised; the dialog stays open.";ego_agent_pages]
  | Connected (Browser_lane.Web_extension | Browser_lane.Webdriver_bidi) | Owned_gecko | Owned_chromium ->
    Unsupported "Only an ego connection acts on its own snapshot targets; use selector or documentId/nodeId instead."
  | Safari_unavailable -> missing
let manage_page backend ~action = match backend with
  | Connected Browser_lane.Ego_task_space -> conditional ~action Act [observed;
      "Requires exact clientId and tabId in an agent-controlled Space. Adoption explicitly manages an observed unmanaged tab; optional pageLabel is the native SDK as option. Release unmanages an unknown-origin Page without closing it; agent-created Pages must be closed.";
      "Origin is preserved. Reads support adopted Pages; current mutation paths still require agent-created Pages. Neither action resolves uncertain input release; after a lost receipt list the same Space's tabs, never replay."]
  | Connected (Browser_lane.Web_extension|Browser_lane.Webdriver_bidi)|Owned_gecko|Owned_chromium|Safari_unavailable ->
      Unsupported "Only an ego connection provides native Page adoption and release."
let support backend operation = match backend with
  | Safari_unavailable -> Unsupported "No Safari adapter is installed in MASC; installed Safari alone is not a connection."
  | (Connected (Browser_lane.Web_extension | Browser_lane.Webdriver_bidi | Browser_lane.Ego_task_space) | Owned_gecko | Owned_chromium) ->
    match operation with
    | List_tabs -> available Tabs
    | Open_tab -> (match backend with
      | Connected Browser_lane.Webdriver_bidi -> conditional ~action:"open_tab" Act
          ["Requires the exact observed clientId; creation can succeed even if navigation fails. Inspect the returned tabId before another create."]
      | Owned_gecko | Owned_chromium -> conditional ~action:"open_tab" Act
          ["Requires an open work session; creation and navigation can partially succeed. Preserve any created tabId in the partial receipt and inspect that exact browser/tab before another create."]
      | Connected Browser_lane.Ego_task_space -> conditional ~action:"open_tab" Act
          ["Requires the exact observed clientId. Opens a page in the connection's ego task space; it shares the cookies of the operator's ego profile.";
           "Creation can succeed even if navigation fails. Inspect the returned tabId before another create."]
      | Connected Browser_lane.Web_extension | Safari_unavailable -> missing)
    | Close_tab -> (match backend with
      | Owned_gecko | Owned_chromium -> conditional ~action:"close_tab" Act
          [observed;"Top-level tab only; the ID is retired after confirmed closure, not a lost or unconfirmed receipt."]
      | Connected Browser_lane.Webdriver_bidi -> conditional ~action:"close_tab" Act
          [observed;"Only a tab this connection opened with open_tab; a tab the operator opened is refused before any effect. Closes without running the page's unload prompt."]
      | Connected Browser_lane.Ego_task_space -> conditional ~action:"close_tab" Act [observed;ego_agent_pages]
      | Connected Browser_lane.Web_extension | Safari_unavailable -> missing)
    | Activate_tab -> (match backend with
      | Connected Browser_lane.Web_extension -> conditional ~action:"activate_tab" Interact
          [observed;"Changes the browser's active tab without promising window focus."]
      | Connected Browser_lane.Webdriver_bidi -> conditional ~action:"activate_tab" Interact
          [observed;"Requires expectedUrl; a tab whose page moved on is refused before any effect.";
           "Brings the tab to the front and gives its browser window system focus, which can take focus from what the operator is doing."]
      | Connected Browser_lane.Ego_task_space -> conditional ~action:"activate_tab" Interact
          [observed;ego_agent_pages;"Requires expectedUrl. Uses native TaskSpace CDP to activate this Page and restore its window only when minimized. Reports native active/window state; it does not prove rendered UI or OS focus. Use before hand_off, never while delegated to the operator."]
      | Owned_gecko | Owned_chromium | Safari_unavailable -> missing)
    | List_windows -> (match backend with
      | Connected Browser_lane.Webdriver_bidi -> conditional Tabs
          ["Every list_tabs row carries windowId when Firefox names the tab's window; tabs with the same windowId share a window, and the distinct values are the windows.";
           "windowId is opaque and only comparable within one connection. There is no window title, size or position."]
      | Connected (Browser_lane.Web_extension | Browser_lane.Ego_task_space) | Owned_gecko | Owned_chromium | Safari_unavailable -> missing)
    | Create_window -> (match backend with
      | Connected Browser_lane.Webdriver_bidi -> conditional ~action:"open_window" Act
          ["Requires the exact observed clientId; the window opens in the background and is addressed by its returned tabId. Creation can succeed even if navigation fails: inspect the returned tabId before another create."]
      | Owned_gecko -> conditional ~action:"open_window" Act
          ["Requires an open work session; the new window holds one tab, addressed by its returned tabId. Creation and navigation can partially succeed."]
      | Connected (Browser_lane.Web_extension | Browser_lane.Ego_task_space) | Owned_chromium | Safari_unavailable -> missing)
    | Close_window -> missing
    | Navigate -> (match backend with
      | Owned_gecko | Owned_chromium -> conditional Goto ["An open owned session and an HTTP(S) URL are required; preserve its concrete browser binding."]
      | Connected Browser_lane.Webdriver_bidi -> conditional Goto
          [observed;"Requires the exact observed clientId and the tabId of a tab this connection opened with open_tab; a tab the operator opened is refused before any effect.";
           "Waits for the new document. An error after the navigation started leaves the result unknown: inspect the same tab."]
      | Connected Browser_lane.Web_extension -> Unsupported
          "A connected WebExtension does not navigate a tab; use an inspected follow_link, or a live BiDi connection's open_tab and goto."
      | Connected Browser_lane.Ego_task_space -> conditional Goto
          [observed;"Requires the exact observed clientId and the tabId of a page an agent opened in the ego task space, its first page included; a tab the operator opened there is refused before any effect.";
           "Waits for the page to load. A failed load is answered with where the tab is now; a stopped run leaves the result unknown: inspect the same tab."]
      | Safari_unavailable -> missing)
    | Follow_link -> dom_input backend (conditional ~action:"follow_link" Interact
        [observed;target;"Requires expectedUrl and an observed same-tab HTTP(S) anchor; rejects downloads, new-window targets and unsupported referrer semantics."])
    | Back -> (match backend with
        | Owned_gecko | Owned_chromium -> conditional ~action:"back" Act
          [observed;"Top-level tab only; inspect the same tab after navigation or an unknown result."]
        | Connected Browser_lane.Webdriver_bidi -> conditional ~action:"back" Act
          [observed;"Top-level tab only, and only a tab this connection opened with open_tab; an operator tab is refused before any effect. An error after the step started leaves the result unknown: inspect the same tab."]
        | Connected Browser_lane.Ego_task_space -> conditional ~action:"back" Act
          [observed;"Moves one entry in the tab's own history and is refused before any effect when there is none.";"A failed load is answered with where the tab is now; a stopped run leaves the result unknown: inspect the same tab.";ego_agent_pages]
        | Connected Browser_lane.Web_extension | Safari_unavailable -> missing)
    | Forward -> (match backend with
        | Owned_gecko | Owned_chromium -> conditional ~action:"forward" Act
          [observed;"Top-level tab only; inspect the same tab after navigation or an unknown result."]
        | Connected Browser_lane.Webdriver_bidi -> conditional ~action:"forward" Act
          [observed;"Top-level tab only, and only a tab this connection opened with open_tab; an operator tab is refused before any effect. An error after the step started leaves the result unknown: inspect the same tab."]
        | Connected Browser_lane.Ego_task_space -> conditional ~action:"forward" Act
          [observed;"Moves one entry in the tab's own history and is refused before any effect when there is none.";"A failed load is answered with where the tab is now; a stopped run leaves the result unknown: inspect the same tab.";ego_agent_pages]
        | Connected Browser_lane.Web_extension | Safari_unavailable -> missing)
    | Reload -> (match backend with
        | Owned_gecko | Owned_chromium -> conditional ~action:"reload" Act
          [observed;"Top-level tab only; inspect the same tab after navigation or an unknown result."]
        | Connected Browser_lane.Webdriver_bidi -> conditional ~action:"reload" Act
          [observed;"Top-level tab only, and only a tab this connection opened with open_tab; an operator tab is refused before any effect. An error after the step started leaves the result unknown: inspect the same tab."]
        | Connected Browser_lane.Ego_task_space -> conditional ~action:"reload" Act
          [observed;"A failed load is answered with where the tab is now; a stopped run leaves the result unknown: inspect the same tab.";ego_agent_pages]
        | Connected Browser_lane.Web_extension | Safari_unavailable -> missing)
    | Session_lifecycle -> (match backend with
      | Owned_gecko | Owned_chromium -> conditional Session
          ["Actions open/status/close apply to the selected owned browser."]
      | Connected (Browser_lane.Web_extension | Browser_lane.Webdriver_bidi | Browser_lane.Ego_task_space) | Safari_unavailable ->
          Unsupported "Connected operator browsers do not expose an owned session lifecycle.")
    | Read_text -> read backend (invoke ~mode:"text" Read) []
    | Read_html -> (match backend with
      | Connected (Browser_lane.Web_extension | Browser_lane.Webdriver_bidi) | Owned_gecko ->
          conditional ~mode:"html" Read
            [observed;"Explicit tabId, top document only; maxChars does not apply. The source is never cut: when the JSON reply would pass 1 MiB, html is null with htmlComplete false."]
      | Connected Browser_lane.Ego_task_space ->
          Unsupported "An ego connection does not return document source; read text, elements or a snapshot instead."
      | Owned_chromium -> Unsupported "Stagehand does not return document source; read text or elements instead."
      | Safari_unavailable -> missing)
    | Read_elements -> read backend (invoke ~mode:"elements" Read) []
    | Read_scene -> read backend (invoke ~mode:"scene" Read) [observed;"Explicit tabId; viewport scene may be truncated. Geometry is not an occlusion guarantee."]
    | Read_regions -> read backend (invoke ~mode:"regions" Read) [observed;"Explicit tabId; copy observed region references for scoped reads."]
    | Read_snapshot -> (match backend with
      | Connected Browser_lane.Ego_task_space -> conditional ~mode:"snapshot" Read
          [observed;"Explicit tabId; ego's own accessibility tree, each actionable node with a ref (ref=12). snapshotScope is viewport (default), full_page, or subtree with root, a ref an earlier snapshot of the same page printed.";
           "A ref names the page as it was read; read again after an effect or a page change.";ego_pages]
      | Connected (Browser_lane.Web_extension | Browser_lane.Webdriver_bidi) | Owned_gecko | Owned_chromium ->
          Unsupported "Only an ego connection returns its own accessibility snapshot; read scene or elements instead."
      | Safari_unavailable -> missing)
    | Screenshot -> read backend (invoke ~mode:"screenshot" Read)
        [observed;"Requires explicit tabId; captures the viewport by default, not the whole document. A Keeper gets a workspace artifact; another caller gets the PNG as an image block. On Ego, screenshotOptions forwards native fullPage/clip/scale/raw and returns a separate page image by the same owner-specific route, not a viewport coordinate frame."]
    | Click -> (match backend with
      | Connected Browser_lane.Web_extension -> conditional ~action:"click" Interact
          [observed;target;"Uses DOM click; trusted pointerdown/mousedown is not provided."]
      | Connected Browser_lane.Webdriver_bidi | Owned_gecko | Owned_chromium -> conditional ~action:"click" Interact
          [observed;target;"Uses native pointer input; captures/checks the current URL when expectedUrl is omitted."]
      | Connected Browser_lane.Ego_task_space -> conditional ~action:"click" Interact
          [observed;"Selector uses Ego SDK locators and native click, including iframe/shadow traversal and auto-scrolling. Scene references retain MASC identity and coordinate guards.";"The URL read before SDK entry is reported; it is not an atomic navigation guard.";ego_agent_pages]
      | Safari_unavailable -> missing)
    | Hover -> (match backend with
      | Connected Browser_lane.Webdriver_bidi | Owned_gecko | Owned_chromium -> conditional ~action:"hover" Interact [observed;target]
      | Connected Browser_lane.Ego_task_space -> conditional ~action:"hover" Interact [observed;"Selector uses native Ego hover and auto-scrolling. Scene references retain MASC identity and coordinate guards.";ego_agent_pages]
      | Connected Browser_lane.Web_extension ->
        Unsupported "WebExtension does not serve trusted hover; the selected tab must not be silently moved to another browser."
      | Safari_unavailable -> missing)
    | Pointer_drag -> (match backend with
      | Connected Browser_lane.Webdriver_bidi | Owned_gecko | Owned_chromium -> conditional ~action:"drag_to" Interact
        ([observed;target;geometry;"via contains observed viewport fractions. Input receipt does not establish application drop acceptance."]
         @ match backend with Owned_chromium -> ["durationMs must be zero."]
           | Connected (Browser_lane.Web_extension | Browser_lane.Webdriver_bidi | Browser_lane.Ego_task_space) | Owned_gecko | Safari_unavailable -> [])
      | Connected Browser_lane.Web_extension -> Unsupported "WebExtension does not serve native pointer drag."
      | Connected Browser_lane.Ego_task_space -> conditional ~action:"drag_to" Interact
          [observed;target;geometry;ego_agent_pages;
           "Uses ego's native mouse API with observed waypoints; durationMs must be zero. Input receipt does not establish application drop acceptance."]
      | Safari_unavailable -> missing)
    | Html5_drop -> (match backend with
      | Owned_chromium -> conditional ~action:"drag_to" Interact
          [observed;target;"Native HTML5 DataTransfer/drop passed a fixture; target behavior must be observed afterward. Not a universal drop guarantee."]
      | Connected Browser_lane.Webdriver_bidi | Owned_gecko -> Unsupported
          "Native pointer drag exists, but the tested Firefox HTML5 DataTransfer/drop scenario fails; no synthetic fallback."
      | Connected (Browser_lane.Web_extension | Browser_lane.Ego_task_space) | Safari_unavailable -> missing)
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
      | Connected Browser_lane.Ego_task_space -> conditional ~action:"click_at" Interact
          [observed;geometry;
           "Pass button \"secondary\" (right) or \"middle\". Only click_at takes a button; selector and node targets do not.";
           "ego's native mouse input at the observed point; a context menu or application behavior must be observed afterward.";
           ego_agent_pages]
      | Connected Browser_lane.Web_extension -> Unsupported
          "WebExtension clicks through the DOM and cannot press the middle or secondary button; the selected tab must not be silently moved to another browser."
      | Safari_unavailable -> missing)
    | Scroll_page -> dom_input backend (conditional ~action:"scroll" Interact [observed;"Scrolls the page; use scroll_at for a nested pane."])
    | Scroll_at -> dom_input backend (conditional ~action:"scroll_at" Interact [observed;geometry;"Scrolls the pane at the observed viewport point."])
    | Native_workflow -> (match backend with
      | Connected Browser_lane.Ego_task_space -> conditional ~action:"workflow" Interact
          [observed;ego_agent_pages;"Known native Page calls run serially with SDK waits and one final snapshot. expectedUrl checks the starting page; navigation can change it afterward. Per-method options use native SDK names and milliseconds; selectionJson preserves string/object/array/null forms. No cumulative command window. Failures retain completed steps; never replay the sequence. Unconfirmed button/key release blocks further input."]
      | Connected (Browser_lane.Web_extension | Browser_lane.Webdriver_bidi) | Owned_gecko | Owned_chromium | Safari_unavailable ->
          Unsupported "Native workflows require an ego connection.")
    | Click_snapshot_target -> snapshot_target backend ~action:"click"
    | Fill_snapshot_target -> snapshot_target backend ~action:"fill"
    | Hover_snapshot_target -> snapshot_target backend ~action:"hover"
    | Double_click_snapshot_target -> snapshot_target backend ~action:"double_click"
    | Fill -> (match backend with
      | Connected Browser_lane.Ego_task_space -> conditional ~action:"fill" Interact
          [observed;"Selector uses native Ego fill, locator resolution and auto-scrolling. Scene references retain the MASC DOM adapter. Fill does not press Enter or submit.";ego_agent_pages]
      | Connected (Browser_lane.Web_extension | Browser_lane.Webdriver_bidi) | Owned_gecko | Owned_chromium | Safari_unavailable ->
        dom_input backend (conditional ~action:"fill" Interact
          [observed;target;"Replaces the value of a text input or textarea and emits input/change, or replaces the content of a contenteditable editor with insertText (the editor gets input events); this is not trusted keyboard typing or submission."]))
    | Double_click -> (match backend with
      | Connected Browser_lane.Ego_task_space -> conditional ~action:"double_click" Interact
          [observed;"Selector uses native Ego double click and SDK actionability. Scene references retain MASC identity and coordinate guards; observe the application result.";ego_agent_pages]
      | Connected (Browser_lane.Web_extension | Browser_lane.Webdriver_bidi) | Owned_gecko | Owned_chromium | Safari_unavailable ->
        if native backend then conditional ~action:"double_click" Interact
          [observed;target;"Native double click; application behavior must be observed afterward."] else missing)
    | Type_text -> (match backend with
      | Connected Browser_lane.Ego_task_space -> conditional ~action:"type_text" Interact
          [observed;"Requires current documentId and expectedUrl; stale document/URL is refused.";
           "Requires the current enabled editable focus. Unicode text is literal; C0/DEL controls are refused, use press_key for Tab/Enter.";
           "ego types with its native keyboard input.";ego_agent_pages]
      | Connected (Browser_lane.Web_extension | Browser_lane.Webdriver_bidi) | Owned_gecko | Owned_chromium | Safari_unavailable ->
      if native backend then conditional ~action:"type_text" Interact
        [observed;"Requires current documentId and expectedUrl; stale document/URL is refused.";"Requires the current enabled editable focus. Unicode text is literal; C0/DEL controls are refused, use press_key for Tab/Enter.";
         "Gecko/BiDi refuse WebDriver-reserved U+E000–U+E05D text. Chromium supports literal private-use text.";
         "An uncertain Chromium keyboard release quarantines this owned session: inspect status and explicitly close/reopen; no replay or automatic page closure."] else missing)
    | Press_key | Key_chord -> (match backend with
      | Connected Browser_lane.Ego_task_space -> conditional ~action:"press_key" Interact
          [observed;"Requires current documentId and expectedUrl; stale document/URL is refused.";
           "Targets current enabled focus (or body); accepts named keys or one printable ASCII character with Control/Meta/Alt/Shift modifiers. Type other text with type_text.";
           ego_agent_pages]
      | Connected (Browser_lane.Web_extension | Browser_lane.Webdriver_bidi) | Owned_gecko | Owned_chromium | Safari_unavailable ->
      if native backend then conditional ~action:"press_key" Interact
        [observed;"Requires current documentId and expectedUrl; stale document/URL is refused.";"Targets current enabled focus (or body); accepts named keys or one Unicode scalar with Control/Meta/Alt/Shift modifiers.";
         "Chromium refuses supplementary press-key scalars; use type_text for supplementary Unicode text.";
         "An uncertain Chromium keyboard release quarantines the exact session until explicit close/reopen; pages are preserved."] else missing)
    | Page_zoom -> (match backend with
      | Connected Browser_lane.Web_extension -> conditional ~action:"set_zoom" Interact
          [observed;"Requires extension 0.8.0+, exact clientId/tabId, expectedUrl and factor 0.3–5. Uses measured browser zoom, never CSS scaling.";
           "Only automatic zoom mode is supported; per-origin scope may also affect and persist for same-origin tabs. Re-read the scene/screenshot afterward."]
      | Connected (Browser_lane.Webdriver_bidi | Browser_lane.Ego_task_space) | Owned_gecko | Owned_chromium | Safari_unavailable -> missing)
    | Select_option -> (match backend with
      | Connected Browser_lane.Ego_task_space -> conditional ~action:"select_option" Interact
          [observed;"Pass value or distinct values ([] clears). Ego receives exact {value} objects and returns its native selected values. Disabled options are programmatically selectable. Native method failures are uncertain and are never replayed.";ego_agent_pages]
      | Connected (Browser_lane.Web_extension | Browser_lane.Webdriver_bidi) | Owned_gecko | Owned_chromium ->
          dom_input backend (conditional ~action:"select_option" Interact
            [observed;"Pass one select's selector and either value for a single-choice select or distinct values for a multiple select ([] clears it). Missing, ambiguous or disabled requested options are refused before any effect.";
             "Replaces the selection, emits input and change once, and reports selectedValues after page handlers. This is DOM selection, not trusted pointer input."])
      | Safari_unavailable -> missing)
    | Read_frames -> (match backend with
      | Connected Browser_lane.Webdriver_bidi | Owned_gecko ->
          conditional ~mode:"frames" Read
            [observed;"Explicit tabId; framePath consists of observed outer-to-inner frame selectors. Text and elements reads accept the same framePath."]
      | Connected Browser_lane.Ego_task_space -> conditional ~mode:"snapshot" Read
          [observed;"Explicit tabId and no framePath: the viewport snapshot holds each iframe's content, a cross-origin one included, with refs; snapshotScope subtree with root set to the iframe's ref reads that frame alone.";ego_pages]
      | Connected Browser_lane.Web_extension | Owned_chromium | Safari_unavailable -> missing)
    | Frame_interaction -> (match backend with
      | Connected Browser_lane.Webdriver_bidi | Owned_gecko ->
          conditional ~action:"click" Interact
            [observed;"framePath (observed outer-to-inner iframe selectors) applies to click, fill, select_option and scroll with a selector. Inspect the same frame first; expectedUrl is the frame document's URL.";
             "Cross-origin frames work: the frame is entered through WebDriver or its own BiDi browsing context."]
      | Connected Browser_lane.Ego_task_space -> conditional ~action:"click" Interact
          [observed;"click and fill with target and no framePath: a ref from the frame's snapshot acts inside that frame, and a role or text target is found inside frames, a cross-origin one included, when the top document has none. expectedUrl is the top page's URL.";ego_agent_pages]
      | Connected Browser_lane.Web_extension | Owned_chromium | Safari_unavailable -> missing)
    | Read_dialog -> (match backend with
      | Connected Browser_lane.Webdriver_bidi -> conditional Tabs
          ["Each list_tabs row of a tab blocked on a dialog carries dialog: type (alert, confirm, prompt or beforeunload), message and, for a prompt, defaultValue. It comes from the browser's own events since this connection began, so a dialog that was already open then is not listed.";
           "The message is whatever the page wrote, and a page can write anything."]
      | Connected Browser_lane.Ego_task_space -> conditional Tabs
          ["Each list_tabs row of a page blocked on a dialog carries dialog: type (alert, confirm, prompt or beforeunload), message and, for a prompt, defaultValue, as ego reads the page now.";
           "An input that opens a dialog answers with it in the receipt; while it is open, reads, moves and input on that page are refused before any effect.";
           "The message is whatever the page wrote, and a page can write anything.";ego_pages]
      | Owned_gecko | Owned_chromium | Connected Browser_lane.Web_extension | Safari_unavailable ->
          gecko_only backend (invoke ~mode:"dialog" Read) [observed])
    | Accept_dialog -> (match backend with
      | Connected Browser_lane.Webdriver_bidi -> conditional ~action:"accept_dialog" Act
          [observed;"Only a tab this connection opened with open_tab; the person using the browser answers a dialog on their own tab.";
           "Optional text applies only to a prompt. The receipt names the dialog that was answered."]
      | Connected Browser_lane.Ego_task_space -> conditional ~action:"accept_dialog" Act
          [observed;"Optional text applies only to a prompt. The receipt names the dialog that was answered; with none open it is refused before any effect.";ego_agent_pages]
      | Owned_gecko | Owned_chromium | Connected Browser_lane.Web_extension | Safari_unavailable ->
          gecko_only backend (invoke ~action:"accept_dialog" Act) [observed;"Optional text applies only to an observed prompt."])
    | Dismiss_dialog -> (match backend with
      | Connected Browser_lane.Webdriver_bidi -> conditional ~action:"dismiss_dialog" Act
          [observed;"Only a tab this connection opened with open_tab; the person using the browser answers a dialog on their own tab."]
      | Connected Browser_lane.Ego_task_space -> conditional ~action:"dismiss_dialog" Act
          [observed;"The receipt names the dialog that was dismissed; with none open it is refused before any effect.";ego_agent_pages]
      | Owned_gecko | Owned_chromium | Connected Browser_lane.Web_extension | Safari_unavailable ->
          gecko_only backend (invoke ~action:"dismiss_dialog" Act) [observed])
    | Hand_off -> (match backend with
      | Connected Browser_lane.Ego_task_space -> conditional ~action:"hand_off" Act
          ["Requires the exact observed clientId. Hands the whole ego task space, tabs the operator opened there included, to the operator for a step only a person can take, such as a sign-in or a captcha; tell them what to do.";
           "While the operator holds the space, Page work is refused before any effect until take_over; space_status remains a metadata-only query."]
      | Connected (Browser_lane.Web_extension | Browser_lane.Webdriver_bidi) | Owned_gecko | Owned_chromium | Safari_unavailable ->
          Unsupported "Only an ego connection hands its task space to the operator.")
    | Space_status -> (match backend with
      | Connected Browser_lane.Ego_task_space -> conditional ~action:"space_status" Act
          ["Requires the exact observed clientId. Reads only the already bound numeric Space's native name/ownership, including delegated control, without Page calls or control changes.";
           "The dated ownership value is metadata, not input admission, a reset assertion, visible UI or login proof."]
      | Connected (Browser_lane.Web_extension|Browser_lane.Webdriver_bidi)|Owned_gecko|Owned_chromium|Safari_unavailable ->
          Unsupported "Only an ego connection has native Space metadata.")
    | Finish_space -> (match backend with
      | Connected Browser_lane.Ego_task_space -> conditional ~action:"finish_space" Act
          ["Requires the exact observed clientId and agent-controlled Space. Complete a successful task exactly once, with optional keepPages: native all or permanent label array (default empty). All retains the Space even with no managed Pages.";
           "Ends all former Page labels. Never use for user control, errors or transport retirement. A lost receipt requires reconciliation, never replay. Retained Spaces preserve file leases."]
      | Connected (Browser_lane.Web_extension|Browser_lane.Webdriver_bidi)|Owned_gecko|Owned_chromium|Safari_unavailable ->
          Unsupported "Only an ego connection completes a native task Space.")
    | Wait_for_control -> (match backend with
      | Connected Browser_lane.Ego_task_space -> conditional ~action:"wait_for_control" Act
          ["Requires the exact observed clientId and an agent-owned Space. Native SDK wait only; never claims or takes over user control.";
           "controlOptions accepts positive finite interval/timeout milliseconds. The timeout must fit this action's reply window: a longer one is refused before the wait starts, and an omitted one waits for that window; an omitted interval keeps the SDK default. Availability is an observation, not permission for later input or proof of input release."]
      | Connected (Browser_lane.Web_extension|Browser_lane.Webdriver_bidi)|Owned_gecko|Owned_chromium|Safari_unavailable ->
          Unsupported "Only an ego connection provides the native Space control wait.")
    | Adopt_tab -> manage_page backend ~action:"adopt_tab"
    | Release_tab -> manage_page backend ~action:"release_tab"
    | Take_over -> (match backend with
      | Connected Browser_lane.Ego_task_space -> conditional ~action:"take_over" Act
          ["Requires the exact observed clientId. Only after the operator has said they are done; nothing checks that they did, so taking it early takes the browser from under them.";
           "Refused before any effect when the agent already holds the space. The receipt carries the tab that was active, unless it is a tab the operator opened; list the tabs before the next step."]
      | Connected (Browser_lane.Web_extension | Browser_lane.Webdriver_bidi) | Owned_gecko | Owned_chromium | Safari_unavailable ->
          Unsupported "Only an ego connection takes its task space back from the operator.")
    | Upload_file -> (match backend with
      | Connected Browser_lane.Ego_task_space -> conditional ~action:"upload" Act
          [observed;"Requires an owning Keeper, an explicit ego browser, a native Ego file-input locator or snapshot ref and sandbox-authorized file paths; 16 MiB per file.";
           "The receipt's chosen lists staged files handed to the SDK, not observed input.files; the page reads them later, so this connection keeps the copies until its space ends.";
           "For a page that makes its file input only on a click, give opener instead of selector: one native Ego control locator. The SDK owns the chooser wait; the click is the effect, ego hands its file chooser the copies, and the receipt's chosen lists them.";ego_agent_pages]
      | Owned_gecko | Owned_chromium | Connected (Browser_lane.Web_extension | Browser_lane.Webdriver_bidi) | Safari_unavailable ->
          gecko_only backend (invoke ~action:"upload" Act)
            [observed;"Requires an owning Keeper, an observed file input and sandbox-authorized file paths; 16 MiB per file. opener is refused before any effect: name the file input with selector."])
    | List_downloads -> (match backend with
      | Connected Browser_lane.Ego_task_space -> conditional ~mode:"downloads" Read
          [observed;"Explicit tabId and an explicit ego browser. Lists the downloads the page started from the first step this connection took on it, opening it included, as pending, completed or interrupted. watchingSince says from when: a stopped command restarts ego's process, and with it the list.";
           "A completed file is saved in the worker's own folder and returned as an artifact. ego's browser touches the operator's download folder while a download runs and leaves nothing there.";ego_pages]
      | Owned_gecko | Owned_chromium | Connected (Browser_lane.Web_extension | Browser_lane.Webdriver_bidi) | Safari_unavailable ->
          gecko_only backend (invoke ~mode:"downloads" Read)
            [observed;"Explicit tabId and a functioning BiDi download connection; reports observed pending/completed/canceled/interrupted state."])
    | Sentence_action -> (match backend with
      | Owned_chromium -> conditional ~action:"act" Instruct
          [observed;"Model-mediated sentence action; not a substitute for guaranteed native keyboard, double-click or zoom support. observe/extract are separate read actions."]
      | Connected (Browser_lane.Web_extension | Browser_lane.Webdriver_bidi | Browser_lane.Ego_task_space) | Owned_gecko | Safari_unavailable -> missing)
    | Resize_viewport -> (match backend with
      | Connected Browser_lane.Webdriver_bidi -> conditional ~action:"set_viewport" Interact
          [observed;"Requires exact clientId/tabId and expectedUrl; " ^ viewport_bounds ^ ". With neither, the browser's own size returns.";
           "The size is an override on that tab until it is restored, which this connection does for the tabs it sized when its session ends; read the screenshot or scene again afterward. This is the page viewport, not the browser window."]
      | Owned_chromium -> conditional ~action:"set_viewport" Interact
          [observed;"Requires expectedUrl; " ^ viewport_bounds ^ ". Stagehand has no call that restores the browser's own size, so this session keeps the override until it closes.";
           "Read the screenshot or scene again afterward. This is the page viewport, not the browser window."]
      | Owned_gecko -> conditional ~action:"set_viewport" Interact
          [observed;"Requires expectedUrl; " ^ viewport_bounds ^ ". With neither, the window's first size returns.";
           "This resizes the browser window to the viewport plus its chrome. Headless Firefox keeps a window at least about 500 x 120 outer pixels, so a smaller request is refused with the size the page kept; read the screenshot or scene again afterward."]
      | Connected Browser_lane.Web_extension -> Unsupported "WebExtension cannot set the page viewport; the selected tab must not be silently moved to another browser."
      | Connected Browser_lane.Ego_task_space | Safari_unavailable -> missing)
    | Touch -> (match backend with
      | Connected Browser_lane.Webdriver_bidi | Owned_gecko -> conditional ~action:"tap_at" Interact
          [observed;geometry;
           "tap_at is a touch press and release at the observed point; swipe is a held touch from one observed point to another, with the same via and durationMs as drag.";
           "Native touch pointer input: the page sees pointer and touch events. Firefox 158 followed a tap with the mouse events and a click; observe the page afterward."]
      | Owned_chromium -> Unsupported "Stagehand has no touch call."
      | Connected Browser_lane.Web_extension -> Unsupported
          "WebExtension clicks through the DOM and cannot send touch input; the selected tab must not be silently moved to another browser."
      | Connected Browser_lane.Ego_task_space | Safari_unavailable -> missing)
    | Pointer_down | Pointer_up -> missing
    | Read_console -> gecko_only backend (invoke ~mode:"console" Read)
        [observed;"Messages and uncaught errors since the session opened, for one tab, oldest first. At most 200 are kept and the reply says how many older ones were dropped; each text is cut at 4000 bytes and says so. Entries Firefox gave no tab for, and events that were not what BiDi documents, are counted in the reply and do not end the session.";
         "The text is whatever the page printed, and a page can print anything."]
    | Read_network -> gecko_only backend (invoke ~mode:"network" Read)
        [observed;"Requests since the session opened, for one tab, oldest first; at most 200 are kept and the reply says how many older ones were dropped.";
         "Each row has method, address, state, and status, mimeType and bytesReceived once it completed. Header values, cookies and bodies are never returned, only header names; the address keeps its path and replaces every query value with REDACTED. A path can still carry a token."]
    | Read_clipboard | Write_clipboard -> missing
    | Intercept_network -> gecko_only backend (invoke ~action:"block_requests" Act)
        [observed;"Makes every request from the tab and its frames to the listed hosts fail as a network error. A host is an exact lowercase host name or IPv4 address compared with the request's host, so a subdomain is a host of its own. unblock_requests lifts every block on the tab; closing the session lifts them too.";
         "Only on an automation browser the Keeper owns. Requests are only failed, never answered or changed."]
    | Read_storage -> gecko_only backend (invoke ~mode:"cookies" Read)
        [observed;"The cookies the tab's page can see, at most 200, with the total. Name, domain, path, secure, httpOnly, sameSite and expiry; the value is never returned.";
         "The reply also lists the page origin's localStorage and sessionStorage key names and its IndexedDB database names (at most 100 each, names cut at 200 characters) under storage, with counts. Storage values are never read."]
    | Emulate_environment -> gecko_only backend (invoke ~action:"set_emulation" Act)
        [observed;"Sets the tab's reported location (latitude and longitude together, optional accuracyMeters up to 10000), language tag (locale) and IANA time zone, any of the three. A location also grants the page its geolocation permission; clear_emulation restores overrides only and leaves permissions unchanged. Geolocation grants remain until this owned browser session closes.";
         "Only on an automation browser the Keeper owns. A page that already read its location, language or time zone keeps what it read: reload it afterwards."]
    | Write_storage -> gecko_only backend (invoke ~action:"set_cookie" Act)
        [observed;"Sets one cookie for the tab's current page host (the domain is never a parameter): cookieName, cookieValue, optional cookiePath, cookieSecure, cookieHttpOnly, cookieSameSite and cookieMaxAgeSec. A cookie lives at most 7 days, with no lifetime it is a session cookie, and a value is at most 4096 bytes. delete_cookie removes one by name.";
         "Only on an automation browser the Keeper owns. The value is never returned. Web storage cannot be written."]
let catalog backend = List.map (fun operation -> {operation;support=support backend operation}) operations
let operation_name = function
  | List_tabs -> "list_tabs" | Open_tab -> "open_tab" | Close_tab -> "close_tab"
  | Activate_tab -> "activate_tab" | List_windows -> "list_windows" | Create_window -> "create_window" | Close_window -> "close_window"
  | Navigate -> "navigate" | Follow_link -> "follow_link" | Back -> "back" | Forward -> "forward"
  | Reload -> "reload" | Session_lifecycle -> "session_lifecycle" | Read_text -> "read_text"
  | Read_html -> "read_html" | Read_elements -> "read_elements" | Read_scene -> "read_scene"
  | Read_regions -> "read_regions" | Read_snapshot -> "read_snapshot" | Screenshot -> "screenshot"
  | Native_workflow -> "native_workflow"
  | Click_snapshot_target -> "click_snapshot_target" | Fill_snapshot_target -> "fill_snapshot_target"
  | Hover_snapshot_target -> "hover_snapshot_target" | Double_click_snapshot_target -> "double_click_snapshot_target" | Click -> "click"
  | Double_click -> "double_click" | Right_click -> "right_click" | Middle_click -> "middle_click"
  | Pointer_down -> "pointer_down" | Pointer_up -> "pointer_up" | Hover -> "hover"
  | Pointer_drag -> "pointer_drag" | Html5_drop -> "html5_drop" | Scroll_page -> "scroll_page"
  | Scroll_at -> "scroll_at" | Fill -> "fill" | Type_text -> "type_text" | Press_key -> "press_key"
  | Key_chord -> "key_chord" | Select_option -> "select_option" | Read_frames -> "read_frames"
  | Frame_interaction -> "frame_interaction" | Read_dialog -> "read_dialog"
  | Accept_dialog -> "accept_dialog" | Dismiss_dialog -> "dismiss_dialog" | Hand_off -> "hand_off" | Take_over -> "take_over" | Space_status -> "space_status" | Finish_space -> "finish_space" | Wait_for_control -> "wait_for_control"
  | Adopt_tab -> "adopt_tab" | Release_tab -> "release_tab"
  | Upload_file -> "upload_file"
  | List_downloads -> "list_downloads" | Page_zoom -> "page_zoom" | Resize_viewport -> "resize_viewport"
  | Touch -> "touch" | Read_clipboard -> "read_clipboard" | Write_clipboard -> "write_clipboard"
  | Read_network -> "read_network" | Intercept_network -> "intercept_network" | Read_console -> "read_console"
  | Read_storage -> "read_storage" | Write_storage -> "write_storage" | Emulate_environment -> "emulate_environment" | Sentence_action -> "sentence_action"
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

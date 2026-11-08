type backend = Connected of Browser_lane.live_transport
  | Safari_unavailable
type operation =
  | List_tabs | Open_tab | Close_tab | Activate_tab | List_windows | Create_window | Close_window
  | Navigate | Follow_link | Back | Forward | Reload | Stop_loading
  | Read_text | Read_html | Read_elements | Read_scene | Read_regions | Read_snapshot | Screenshot
  | Native_workflow
  | Click_snapshot_target | Fill_snapshot_target | Hover_snapshot_target | Double_click_snapshot_target
  | Click | Double_click | Right_click | Middle_click | Pointer_down | Pointer_up | Hover | Pointer_drag | Html5_drop
  | Scroll_page | Scroll_at | Fill | Type_text | Press_key | Key_chord | Select_option
  | Read_frames | Frame_interaction | Read_dialog | Accept_dialog | Dismiss_dialog
  | Hand_off | Take_over | Space_status | Finish_space | Wait_for_control | Adopt_tab | Release_tab
  | Upload_file | List_downloads | Page_zoom | Resize_viewport | Touch
  | Read_clipboard | Write_clipboard | Emulate_environment | Intercept_network | Read_storage | Read_network | Read_console
  | Write_storage
[@@deriving enumerate]
type tool = Tabs | Read | Interact | Act | Session | Goto
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
let ego_input_availability method_ support =
  match Browser_lane.Native_input.contract method_ with
  | Browser_lane.Native_input.No_hold | Browser_lane.Native_input.Observed_receipt
  | Browser_lane.Native_input.Observed_native_window -> support
  | Browser_lane.Native_input.Unattestable_raw_hold reason -> Unsupported (Browser_lane.Native_input.message reason)
let missing = Unsupported "No public browser tool implements this operation."
let viewport_bounds = Printf.sprintf "width and height are CSS pixels between %d and %d, given together"
  Browser_lane.viewport_side_min_px Browser_lane.viewport_side_max_px
let observed = "Keep the observed browser identity and tabId; re-read after an effect or an unknown outcome."
let target = "Use one freshly observed selector or documentId/nodeId; the target must be visible and unobstructed."
let geometry = "Use the current documentId and viewport geometry; stale URL/document/viewport is refused."
let window_scope = "windowId is opaque and only comparable within one connection. There is no window title, size or position."
let ego_pages = "Only a Page the ego task space manages, including an explicitly adopted Page; an unmanaged operator tab must be adopted before a read or effect."
(* A read every connection serves, which an ego connection serves only on its own pages. *)
let read backend invocation constraints = match backend with
  | Connected Browser_lane.Ego_task_space -> Conditional {invocation;constraints=constraints @ [ego_pages]}
  | Safari_unavailable ->
    (match constraints with [] -> Available invocation | _ :: _ -> Conditional {invocation;constraints})
let ego_agent_pages = ego_pages
let ego_closable_pages = "Only a page an agent opened in the ego task space, its first page included; release an adopted unknown-origin Page without closing it."
(* Page effects use the managed-page boundary; closing also requires known agent origin. *)
let on_agent_pages = function
  | Available invocation -> Conditional {invocation;constraints=[ego_agent_pages]}
  | Conditional {invocation;constraints} -> Conditional {invocation;constraints=constraints @ [ego_agent_pages]}
  | Unsupported _ as unsupported -> unsupported
(* A DOM input every connection serves, an ego connection on its own pages. *)
let dom_input backend support = match backend with
  | Connected Browser_lane.Ego_task_space -> on_agent_pages support
  | Safari_unavailable -> missing
(* Native element input on a target the ego connection's own snapshot named. *)
let snapshot_target backend ~action = match backend with
  | Connected Browser_lane.Ego_task_space -> conditional ~action Interact
      [observed;"target is {ref} from the latest snapshot of the same page, {role, name, exact} or {text, exact}, given alone with expectedUrl.";
       "The URL is checked before SDK entry. Ego owns locator resolution, actionability and auto-scrolling; native method failures, including missing or ambiguous targets, leave the result uncertain and are never replayed.";
       "The receipt lists the pages the action opened as popups (tabIds) and a JavaScript dialog it raised; the dialog stays open.";ego_agent_pages]
  | Safari_unavailable -> missing
let manage_page backend ~action = match backend with
  | Connected Browser_lane.Ego_task_space -> conditional ~action Act [observed;
      "Requires exact clientId and tabId in an agent-controlled Space. Adoption explicitly manages an observed unmanaged tab; optional pageLabel is the native SDK as option. Release unmanages an unknown-origin Page without closing it; agent-created Pages must be closed.";
      "Origin is preserved. Adopted Pages support reads, input, navigation and activation; closing still requires an agent-created Page. Neither action resolves uncertain input release; after a lost receipt list the same Space's tabs, never replay."]
  | Safari_unavailable ->
      Unsupported "Only an ego connection provides native Page adoption and release."
let support backend operation = match backend with
  | Safari_unavailable -> Unsupported "No Safari adapter is installed in MASC; installed Safari alone is not a connection."
  | Connected Browser_lane.Ego_task_space ->
    match operation with
    | List_tabs -> available Tabs
    | Open_tab -> (match backend with
      | Connected Browser_lane.Ego_task_space -> conditional ~action:"open_tab" Act
          ["Requires the exact observed clientId. Opens a page in the connection's ego task space; it shares the cookies of the operator's ego profile.";
           "Creation can succeed even if navigation fails. Inspect the returned tabId before another create."]
      | Safari_unavailable -> missing)
    | Close_tab -> (match backend with
      | Connected Browser_lane.Ego_task_space -> conditional ~action:"close_tab" Act [observed;ego_closable_pages]
      | Safari_unavailable -> missing)
    | Activate_tab -> (match backend with
      | Connected Browser_lane.Ego_task_space -> conditional ~action:"activate_tab" Interact
          [observed;ego_agent_pages;"Requires expectedUrl. Uses native TaskSpace CDP to activate this Page and restore its window only when minimized. Reports native active/window state; it does not prove rendered UI or OS focus. Use before hand_off, never while delegated to the operator."]
      | Safari_unavailable -> missing)
    | List_windows -> (match backend with
      | Connected Browser_lane.Ego_task_space -> conditional Tabs
          ["Every list_tabs row carries windowId when ego places the tab in a window; tabs with the same windowId share a window, and the distinct values are the windows.";
           "An ego task space is one browser window: popups the agent opens become tabs of it.";
           window_scope]
      | Safari_unavailable -> missing)
    | Create_window -> (match backend with
      | Connected Browser_lane.Ego_task_space | Safari_unavailable -> missing)
    | Close_window -> missing
    | Navigate -> (match backend with
      | Connected Browser_lane.Ego_task_space -> conditional Goto
          [observed;"Requires the exact observed clientId and the tabId of a managed Page in the ego task space.";
           "Waits for the page to load. A failed load is answered with where the tab is now; a stopped run leaves the result unknown: inspect the same tab.";ego_agent_pages]
      | Safari_unavailable -> missing)
    | Follow_link -> dom_input backend (conditional ~action:"follow_link" Interact
        [observed;target;"Requires expectedUrl and an observed same-tab HTTP(S) anchor; rejects downloads, new-window targets and unsupported referrer semantics."])
    | Back -> (match backend with
        | Connected Browser_lane.Ego_task_space -> conditional ~action:"back" Act
          [observed;"Moves one entry in the tab's own history and is refused before any effect when there is none.";"A failed load is answered with where the tab is now; a stopped run leaves the result unknown: inspect the same tab.";ego_agent_pages]
        | Safari_unavailable -> missing)
    | Forward -> (match backend with
        | Connected Browser_lane.Ego_task_space -> conditional ~action:"forward" Act
          [observed;"Moves one entry in the tab's own history and is refused before any effect when there is none.";"A failed load is answered with where the tab is now; a stopped run leaves the result unknown: inspect the same tab.";ego_agent_pages]
        | Safari_unavailable -> missing)
    | Reload -> (match backend with
        | Connected Browser_lane.Ego_task_space -> conditional ~action:"reload" Act
          [observed;"A failed load is answered with where the tab is now; a stopped run leaves the result unknown: inspect the same tab.";ego_agent_pages]
        | Safari_unavailable -> missing)
    | Stop_loading -> (match backend with
      | Connected Browser_lane.Ego_task_space -> conditional ~action:"stop_loading" Act
          ["Requires the exact observed live clientId and managed tabId. Uses the native Page.stopLoading CDP command without Page reads, so it can recover a navigation that has not committed.";
           "The receipt acknowledges the native command's return on that Page, not document readiness, expected URL, or key/button release. Re-read the same Page before further work.";
           "Requires a native managed Page, including an explicitly adopted unknown-origin Page. A tab the operator opened must first be explicitly adopted in this same Space; recovery neither adopts it nor changes its origin."]
      | Safari_unavailable ->
          Unsupported "Native stop_loading recovery requires an ego connection.")
    | Read_text -> read backend (invoke ~mode:"text" Read) []
    | Read_html -> (match backend with
      | Connected Browser_lane.Ego_task_space ->
          read backend (invoke ~mode:"html" Read)
            [observed;"Explicit tabId, top document only; maxChars does not apply. The source is never cut: when the JSON reply would pass 1 MiB, html is null with htmlComplete false."]
      | Safari_unavailable -> missing)
    | Read_elements -> read backend (invoke ~mode:"elements" Read) []
    | Read_scene -> read backend (invoke ~mode:"scene" Read) [observed;"Explicit tabId; viewport scene may be truncated. Geometry is not an occlusion guarantee."]
    | Read_regions -> read backend (invoke ~mode:"regions" Read) [observed;"Explicit tabId; copy observed region references for scoped reads."]
    | Read_snapshot -> (match backend with
      | Connected Browser_lane.Ego_task_space -> conditional ~mode:"snapshot" Read
          [observed;"Explicit tabId; ego's own accessibility tree, each actionable node with a ref (ref=12). snapshotScope is viewport (default), full_page, or subtree with root, a ref an earlier snapshot of the same page printed.";
           "A ref names the page as it was read; read again after an effect or a page change.";ego_pages]
      | Safari_unavailable -> missing)
    | Screenshot -> read backend (invoke ~mode:"screenshot" Read)
        [observed;"Requires explicit tabId; captures the viewport by default, not the whole document. A Keeper gets a workspace artifact; another caller gets the PNG as an image block. On Ego, screenshotOptions forwards native fullPage/clip/scale/raw and returns a separate page image by the same owner-specific route, not a viewport coordinate frame."]
    | Click -> (match backend with
      | Connected Browser_lane.Ego_task_space -> conditional ~action:"click" Interact
          [observed;"Selector uses Ego SDK locators and native click, including iframe/shadow traversal and auto-scrolling. Scene references retain MASC identity and coordinate guards.";"The URL read before SDK entry is reported; it is not an atomic navigation guard.";ego_agent_pages]
      | Safari_unavailable -> missing)
    | Hover -> (match backend with
      | Connected Browser_lane.Ego_task_space -> conditional ~action:"hover" Interact [observed;"Selector uses native Ego hover and auto-scrolling. Scene references retain MASC identity and coordinate guards.";ego_agent_pages]
      | Safari_unavailable -> missing)
    | Pointer_drag -> (match backend with
      | Connected Browser_lane.Ego_task_space -> ego_input_availability Browser_lane.Native_input.Drag_and_drop
          (conditional ~action:"drag_to" Interact
            [observed;ego_agent_pages;
             "Only selector-to-selector drag_to without via and with durationMs=0, using native dragAndDrop. The SDK receipt does not establish application drop acceptance.";
             Browser_lane.Native_input.message Browser_lane.Native_input.Raw_pointer_drag_void])
      | Safari_unavailable -> missing)
    | Html5_drop -> (match backend with
      | Connected Browser_lane.Ego_task_space -> ego_input_availability Browser_lane.Native_input.Drag_and_drop
          (conditional ~action:"drag_to" Interact
            [observed;ego_agent_pages;
             "Only selector-to-selector drag_to without via and with durationMs=0, using native dragAndDrop. Native HTML5 DataTransfer/drop passed a fixture; target behavior must be observed afterward. Not a universal drop guarantee."])
      | Safari_unavailable -> missing)
    | Right_click | Middle_click -> (match backend with
      | Connected Browser_lane.Ego_task_space -> conditional ~action:"click_at" Interact
          [observed;geometry;
           "Pass button \"secondary\" (right) or \"middle\". Only click_at takes a button; selector and node targets do not.";
           "ego's native mouse input at the observed point; a context menu or application behavior must be observed afterward.";
           ego_agent_pages]
      | Safari_unavailable -> missing)
    | Scroll_page -> dom_input backend (conditional ~action:"scroll" Interact [observed;"Scrolls the page; use scroll_at for a nested pane."])
    | Scroll_at -> dom_input backend (conditional ~action:"scroll_at" Interact [observed;geometry;"Scrolls the pane at the observed viewport point."])
    | Native_workflow -> (match backend with
      | Connected Browser_lane.Ego_task_space -> conditional ~action:"workflow" Interact
          [observed;ego_agent_pages;"Known native Page calls run serially with SDK waits and one final snapshot. expectedUrl checks the starting page; navigation can change it afterward. Per-method options use native SDK names and milliseconds; selectionJson preserves string/object/array/null forms. No cumulative command window. Failures retain completed steps; never replay the sequence.";
           "Native keyboard.type preserves its void receipt and returns separate nativeCompletion only after its same-command native window verifies. An unconfirmed window stops before the next step. Typing consumes the native Page event buffer; later events are not a full history. Native fill replaces an observed field/editor; keyboard.insertText inserts literal text without key-down/up; keyboard.paste supports text/HTML."]
      | Safari_unavailable ->
          Unsupported "Native workflows require an ego connection.")
    | Click_snapshot_target -> snapshot_target backend ~action:"click"
    | Fill_snapshot_target -> snapshot_target backend ~action:"fill"
    | Hover_snapshot_target -> snapshot_target backend ~action:"hover"
    | Double_click_snapshot_target -> snapshot_target backend ~action:"double_click"
    | Fill -> (match backend with
      | Connected Browser_lane.Ego_task_space -> conditional ~action:"fill" Interact
          [observed;"Selector uses native Ego fill, locator resolution and auto-scrolling. Scene references retain the MASC DOM adapter. Fill does not press Enter or submit.";ego_agent_pages]
      | Safari_unavailable ->
        dom_input backend (conditional ~action:"fill" Interact
          [observed;target;"Replaces the value of a text input or textarea and emits input/change, or replaces the content of a contenteditable editor with insertText (the editor gets input events); this is not trusted keyboard typing or submission."]))
    | Double_click -> (match backend with
      | Connected Browser_lane.Ego_task_space -> conditional ~action:"double_click" Interact
          [observed;"Selector uses native Ego double click and SDK actionability. Scene references retain MASC identity and coordinate guards; observe the application result.";ego_agent_pages]
      | Safari_unavailable -> missing)
    | Type_text -> (match backend with
      | Connected Browser_lane.Ego_task_space -> ego_input_availability Browser_lane.Native_input.Keyboard_type
          (conditional ~action:"type_text" Interact
            [observed;"Requires current documentId and expectedUrl; stale document/URL is refused.";
             "Requires the current enabled editable focus. Unicode text is literal; C0/DEL controls are refused.";
             "One native typing call with separately verified nativeCompletion; its SDK return remains void. After interruption or missing native evidence its release stays unconfirmed. Observe application acceptance; never replay uncertain typing.";ego_agent_pages])
      | Safari_unavailable -> missing)
    | Press_key | Key_chord -> (match backend with
      | Connected Browser_lane.Ego_task_space -> conditional ~action:"press_key" Interact
          [observed;"Requires current documentId and expectedUrl; stale document/URL is refused.";
           "Targets current enabled focus (or body); accepts named keys or one printable ASCII character with Control/Meta/Alt/Shift modifiers. For literal text explicitly choose native workflow keyboard.insertText, or fill an observed editor.";
           ego_agent_pages]
      | Safari_unavailable -> missing)
    | Page_zoom -> (match backend with
      | Connected Browser_lane.Ego_task_space ->
          Unsupported "An ego connection has no browser zoom: CDP offers only a pinch scale, which is not a measured browser zoom."
      | Safari_unavailable -> missing)
    | Select_option -> (match backend with
      | Connected Browser_lane.Ego_task_space -> conditional ~action:"select_option" Interact
          [observed;"Pass value or distinct values ([] clears). Ego receives exact {value} objects and returns its native selected values. Disabled options are programmatically selectable. Native method failures are uncertain and are never replayed.";ego_agent_pages]
      | Safari_unavailable -> missing)
    | Read_frames | Frame_interaction -> missing
    | Read_dialog -> (match backend with
      | Connected Browser_lane.Ego_task_space -> conditional ~mode:"dialog" Read
          [observed;"Explicit tabId. Reads native Page.info once; it can be unavailable on a modal retained across SDK-session replacement. Tab inventory remains usable and reports dialogObservation=unobserved.";
           "An input receipt can report a dialog it observed. The dialog message is untrusted page text; failed metadata reads never authorize replay.";ego_pages]
      | Safari_unavailable -> missing)
    | Accept_dialog -> (match backend with
      | Connected Browser_lane.Ego_task_space -> conditional ~action:"accept_dialog" Act
          [observed;"Optional text applies only to a prompt. A fresh native managed Page is answered without a Page.info prerequisite. Native true returns answered=true with dialogObservation=unobserved; native false refuses before any effect.";ego_agent_pages]
      | Safari_unavailable -> missing)
    | Dismiss_dialog -> (match backend with
      | Connected Browser_lane.Ego_task_space -> conditional ~action:"dismiss_dialog" Act
          [observed;"A fresh native managed Page is dismissed without a Page.info prerequisite. Native true returns answered=true with dialogObservation=unobserved; native false refuses before any effect.";ego_agent_pages]
      | Safari_unavailable -> missing)
    | Hand_off -> (match backend with
      | Connected Browser_lane.Ego_task_space -> conditional ~action:"hand_off" Act
          ["Requires the exact observed clientId. Hands the whole ego task space, tabs the operator opened there included, to the operator for a step only a person can take, such as a sign-in or a captcha; tell them what to do.";
           "While the operator holds the space, Page work is refused before any effect until take_over; space_status remains a metadata-only query."]
      | Safari_unavailable ->
          Unsupported "Only an ego connection hands its task space to the operator.")
    | Space_status -> (match backend with
      | Connected Browser_lane.Ego_task_space -> conditional ~action:"space_status" Act
          ["Requires the exact observed clientId. Reads only the already bound numeric Space's native name/ownership, including delegated control, without Page calls or control changes.";
           "The dated ownership value is metadata, not visible UI or login proof."]
      | Safari_unavailable ->
          Unsupported "Only an ego connection has native Space metadata.")
    | Finish_space -> (match backend with
      | Connected Browser_lane.Ego_task_space -> conditional ~action:"finish_space" Act
          ["Requires the exact observed clientId and agent-controlled Space. Complete a successful task exactly once, with optional keepPages: native all or permanent label array (default empty). All retains the Space even with no managed Pages.";
           "Ends all former Page labels. Never use for user control, errors or transport retirement. A lost receipt requires reconciliation, never replay. Retained Spaces preserve file leases."]
      | Safari_unavailable ->
          Unsupported "Only an ego connection completes a native task Space.")
    | Wait_for_control -> (match backend with
      | Connected Browser_lane.Ego_task_space -> conditional ~action:"wait_for_control" Act
          ["Requires the exact observed clientId and an agent-owned Space. Native SDK wait only; never claims or takes over user control.";
           "controlOptions accepts positive finite interval/timeout milliseconds, forwarded unchanged; omitted options retain their SDK defaults. The SDK owns the polling deadline and the executor-owned caller adds no host reply-window limit. Availability is an observation, not permission for later input or proof of input release."]
      | Safari_unavailable ->
          Unsupported "Only an ego connection provides the native Space control wait.")
    | Adopt_tab -> manage_page backend ~action:"adopt_tab"
    | Release_tab -> manage_page backend ~action:"release_tab"
    | Take_over -> (match backend with
      | Connected Browser_lane.Ego_task_space -> conditional ~action:"take_over" Act
          ["Takes the space back after the operator has said they are done; nothing checks that they did, so taking it early takes the browser from under them. With the exact observed clientId it resumes a space handed off with hand_off. With lane=live and no clientId it reclaims the Space whose task ended while the operator held it, which the lane's inventory reports as a user-owned refusal (the receipt says reclaimed and names no tab), or, when the worker names its Space rather than its number, opens again a Space ego no longer lists (the receipt says reopening).";
           "Refused before any effect when the agent already holds the space. The clientId receipt carries the tab that was active, unless it is a tab the operator opened; list the tabs before the next step."]
      | Safari_unavailable ->
          Unsupported "Only an ego connection takes its task space back from the operator.")
    | Upload_file -> (match backend with
      | Connected Browser_lane.Ego_task_space -> conditional ~action:"upload" Act
          [observed;"Requires an owning Keeper, an explicit ego browser, a native Ego file-input locator or snapshot ref and sandbox-authorized file paths; 16 MiB per file.";
           "The receipt's chosen lists staged files handed to the SDK, not observed input.files; the page reads them later, so this connection keeps the copies until its space ends.";
           "For a page that makes its file input only on a click, give opener instead of selector: one native Ego control locator. The SDK owns the chooser wait; the click is the effect, ego hands its file chooser the copies, and the receipt's chosen lists them.";ego_agent_pages]
      | Safari_unavailable -> missing)
    | List_downloads -> (match backend with
      | Connected Browser_lane.Ego_task_space -> conditional ~mode:"downloads" Read
          [observed;"Explicit tabId and an explicit ego browser. Lists the downloads the page started from the first step this connection took on it, opening it included, as pending, completed or interrupted. watchingSince says from when: a stopped command restarts ego's process, and with it the list.";
           "A completed file is saved in the worker's own folder and returned as an artifact. ego's browser touches the operator's download folder while a download runs and leaves nothing there.";ego_pages]
      | Safari_unavailable -> missing)

    | Resize_viewport -> (match backend with
      | Connected Browser_lane.Ego_task_space -> conditional ~action:"set_viewport" Interact
          [observed;"Requires exact clientId/tabId and expectedUrl; " ^ viewport_bounds ^ ". With neither, the browser's own size returns.";
           "The size is a CDP override on that Page. It stays while the SDK process that set it runs; every answer's sdkProcessStartedAt names that process, and another value means the size is gone. Restoring waits up to 2 s for the page to resize before its receipt. The override invalidates snapshot refs (refsInvalidated): take a new snapshot, and read the screenshot or scene again. This is the page viewport, not the browser window.";
           ego_agent_pages]
      | Safari_unavailable -> missing)
    | Touch -> (match backend with
      | Connected Browser_lane.Ego_task_space -> conditional ~action:"tap_at" Interact
          [observed;geometry;
           "tap_at is a touch press and release at the observed point; swipe is a held touch from one observed point to another, through the via points in order, each move taking durationMs. A swipe longer than the command's window is refused before it starts.";
           "CDP touch events with no touch emulation: the page sees trusted pointer (pointerType touch) and touch events, and a tap ends with a click; a swipe scrolls the page and its pointer events end with pointercancel. The page's maxTouchPoints stays 0. A gesture that fails after its press is cancelled with touchCancel. The input invalidates snapshot refs (refsInvalidated): take a new snapshot.";
           ego_agent_pages]
      | Safari_unavailable -> missing)
    | Pointer_down | Pointer_up -> missing
    | Read_clipboard | Write_clipboard -> missing
    | Emulate_environment -> (match backend with
      | Connected Browser_lane.Ego_task_space -> conditional ~action:"set_emulation" Act
          [observed;"Sets the Page's reported location (latitude and longitude together, optional accuracyMeters up to 10000), locale and IANA time zone, any of the three, through CDP overrides on that Page. The page's own Intl checks the locale and time zone first: a name it does not know is refused before any change, and a time zone the page does not report afterwards is a failure.";
           "The locale changes Intl only; navigator.language and Accept-Language stay. A location also grants the page's origin geolocation for every tab of that origin in the ego profile. Overrides and grant stay while the SDK process that set them runs; every answer's sdkProcessStartedAt names that process, and another value means they are gone. clear_emulation restores the overrides only and leaves the grant.";
           "A page that already read its location, language or time zone keeps what it read: reload it afterwards.";
           ego_agent_pages]
      | Safari_unavailable -> missing)
    | Intercept_network -> (match backend with
      | Connected Browser_lane.Ego_task_space -> conditional ~action:"block_requests" Act
          [observed;"Makes the Page's subresource requests to the listed hosts, such as fetch and images, fail as network errors, and those of its same-origin frames. A host is an exact lowercase host name or IPv4 address compared with the request's host on any port, so a subdomain is a host of its own.";
           "Navigations are not blocked: the tab or a frame still loads a document from a blocked host. Requests from a frame of another site, which runs in its own process, are not blocked either. A request already sent is not affected.";
           "Each block_requests adds to the tab's blocks; unblock_requests lifts every one. Blocks stay while the SDK process that set them runs; every answer's sdkProcessStartedAt names that process, and another value means they are gone. The setting invalidates snapshot refs (refsInvalidated): take a new snapshot.";
           ego_agent_pages]
      | Safari_unavailable -> missing)
    | Read_storage -> (match backend with
      | Connected Browser_lane.Ego_task_space -> conditional ~mode:"cookies" Read
          [observed;Printf.sprintf "Explicit tabId and an explicit ego browser. Lists the cookies the tab's top document sees, at most %d with the total: name, domain, path, secure and httpOnly, and sameSite and expiry when the cookie has them. A cookie value is never returned (valuesWithheld)." Browser_lane.storage_cookies_limit;
           Printf.sprintf "Also lists the page origin's localStorage and sessionStorage keys and its IndexedDB database names under storage, at most %d each with their count, each name cut at %d characters. An area the page may not use answers its error instead. Storage values are never read (storageValuesWithheld)." Browser_lane.storage_names_limit Browser_lane.storage_name_chars;
           "The cookies a frame of another site holds for its own site are not listed. Names come back as the site wrote them, and a name can carry an account, user or session id.";
           ego_pages]
      | Safari_unavailable -> missing)
    | Read_network -> (match backend with
      | Connected Browser_lane.Ego_task_space -> conditional ~mode:"network" Read
          [observed;Printf.sprintf "Explicit tabId and an explicit ego browser. Lists the tab's requests oldest first; at most %d are kept and dropped says how many older ones were removed." Browser_ego_page_events.requests_limit;
           Printf.sprintf "Each row has method, address, timestamp and state: pending; responded with status and mimeType when the response came but its body has not finished loading, as when the page never reads a fetch body; completed with status, mimeType and bytesReceived; or failed with its error. Header values, cookies and bodies are never returned, only header names, at most %d with the total. The address keeps its path, cut at %d bytes (urlCut), and replaces every query value with %s. A path can still carry a token." Browser_ego_page_events.header_names_limit Browser_ego_page_events.path_bytes_limit Browser_ego_page_events.redacted_value;
           Printf.sprintf "A request is listed once ego held it for the tab in the SDK process named by sdkProcessStartedAt. Missing: requests from before that process held the tab, often the first document load of a popup, and requests a frame of another site makes. fullBufferReads counts reads that found ego's buffer for the tab full at %d events, when older ones may be lost." Browser_ego_page_events.ego_buffer_events;
           ego_pages]
      | Safari_unavailable -> missing)
    | Read_console -> (match backend with
      | Connected Browser_lane.Ego_task_space -> conditional ~mode:"console" Read
          [observed;Printf.sprintf "Explicit tabId and an explicit ego browser. Lists what the tab's current document wrote to its console and the errors it did not catch, oldest first: type (console or javascript), level, text and timestamp; at most %d entries with dropped, each text cut at %d bytes (textCut). The arguments of a line are joined by a space as the browser describes them; a format specifier such as %%s is not applied." Browser_ego_console.entries_limit Browser_ego_console.text_bytes_limit;
           Printf.sprintf "The browser keeps the newest %d entries since the document loaded, so older ones and those before a reload are gone without a count. A frame of the same site is included; a frame of another site is not. A text is what the page wrote and can carry a token or personal data." Browser_ego_console.browser_kept_entries;
           "To read them the step turns ego's console hiding off for this tab and back on; sites can detect automation while it is off, and hiding.offMs says for how long, seconds when the page is busy. hiding.restored false means it stayed off until the next console read or a new ego SDK process (sdkProcessStartedAt).";
           ego_pages]
      | Safari_unavailable -> missing)
    | Write_storage -> (match backend with
      | Connected Browser_lane.Ego_task_space -> conditional ~action:"set_cookie" Act
          [observed;Printf.sprintf "Sets one cookie for the tab's top document host, which must be an http or https address; the domain is never a parameter: cookieName, cookieValue, optional cookiePath, cookieSecure, cookieHttpOnly, cookieSameSite and cookieMaxAgeSec. A cookie lives at most %d days and without a lifetime it is a session cookie. The name is at most %d bytes, the name and value together at most %d bytes, the path at most %d bytes." (Browser_lane.Action.max_cookie_age_sec / 86_400) Browser_lane.Action.max_cookie_name_bytes Browser_lane.Action.max_cookie_bytes Browser_lane.Action.max_cookie_path_bytes;
           "delete_cookie removes every cookie of that name the tab's top document sees, of whatever domain or path, and the answer lists their domain and path. Web storage is not written.";
           "Both change the operator's ego profile: the operator's own tabs and every task space on that profile see the change, and it stays after the ego SDK process ends. A set can replace a cookie the operator's sign-in uses (replaced), and a delete can sign the operator out. The value is never returned (valueWithheld).";
           ego_pages]
      | Safari_unavailable -> missing)
let catalog backend = List.map (fun operation -> {operation;support=support backend operation}) operations
let operation_name = function
  | List_tabs -> "list_tabs" | Open_tab -> "open_tab" | Close_tab -> "close_tab"
  | Activate_tab -> "activate_tab" | List_windows -> "list_windows" | Create_window -> "create_window" | Close_window -> "close_window"
  | Navigate -> "navigate" | Follow_link -> "follow_link" | Back -> "back" | Forward -> "forward"
  | Reload -> "reload" | Stop_loading -> "stop_loading" | Read_text -> "read_text"
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
  | Emulate_environment -> "emulate_environment" | Intercept_network -> "intercept_network"
  | Read_storage -> "read_storage" | Read_network -> "read_network" | Read_console -> "read_console"
  | Write_storage -> "write_storage"
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
  | Goto -> "masc_browser_goto"
let invocation_fields invocation = ["tool",`String (tool_name invocation.tool)]
  @ (match invocation.action with None -> [] | Some value -> ["action",`String value])
  @ (match invocation.mode with None -> [] | Some value -> ["mode",`String value])
let entry_json ~with_constraints {operation;support} =
  let fields = match support with
    | Available invocation -> ("status",`String "available")::invocation_fields invocation
    | Conditional {invocation;constraints} -> ("status",`String "conditional")::invocation_fields invocation
        @ (if with_constraints then ["constraints",`List (List.map (fun value -> `String value) constraints)] else [])
    | Unsupported reason -> ["status",`String "unsupported";"reason",`String reason] in
  `Assoc (("operation",`String (operation_name operation))::fields)
(* The constraints are long and the same text on every call, so a Conditional
   row carries them only for an operation the caller named. *)
let to_json backend ~constraints_for = `Assoc [
  "scope",`String "implemented public tools for this browser; not readiness, effect success or dispatch authority; a conditional row lists its constraints only when its operation is in requiredActions";
  "operations",`List (List.map (fun entry ->
    entry_json ~with_constraints:(List.mem entry.operation constraints_for) entry) (catalog backend))]

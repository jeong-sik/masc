(** Closed browser interactions. Caller strings are values, never script source. *)
type request = { route : Browser_selection.preference; tab_id : int;
  expected_url : string option; action : Browser_lane.interaction }
let ( let* ) = Result.bind
let parse = function
  | `Assoc fields ->
    let allowed = ["lane"; "clientId"; "tabId"; "expectedUrl"; "action"; "selector"; "text"; "x"; "y"; "documentId"; "nodeId"; "point"; "from"; "to"; "viewport"; "button"; "source"; "destination"; "via"; "durationMs"; "key"; "modifiers"; "factor"; "width"; "height"] in
    let* () = if List.for_all (fun (key, _) -> List.mem key allowed) fields
      && List.length fields = List.length (List.sort_uniq String.compare (List.map fst fields))
      then Ok () else Error "unknown or duplicate browser interaction argument" in
    let* base = Browser_surface.parse_capture_request
      (`Assoc (List.filter (fun (key, _) -> List.mem key ["lane"; "tabId"; "clientId"]) fields)) in
    let* tab_id = match base.tab_id with Some id -> Ok id | None -> Error "tabId is required" in
    let* expected_url = match List.assoc_opt "expectedUrl" fields with
      | None -> Ok None
      | Some (`String url) when String.trim url <> "" -> Ok (Some url)
      | _ -> Error "expectedUrl must be a nonempty string" in
    let selector () = match List.assoc_opt "selector" fields with
      | Some (`String value) when String.trim value <> "" -> Ok value
      | _ -> Error "selector must be a nonempty CSS selector" in
    let node_target () =
      match List.assoc_opt "documentId" fields, List.assoc_opt "nodeId" fields with
      | None, None -> Ok None
      | Some (`String document_id), Some (`String node_id)
        when document_id <> "" && node_id <> "" && not (List.mem_assoc "selector" fields) ->
          Ok (Some ({document_id;node_id} : Browser_lane.node_ref))
      | _ -> Error "provide documentId and nodeId together, without selector"
    in
    let integer key = match List.assoc_opt key fields with
      | Some (`Int value) when Int64.abs (Int64.of_int value) <= 9007199254740991L -> Ok value
      | _ -> Error (key ^ " must be a JavaScript-safe integer") in
    let pointer_target fields =
      match fields with
      | ["selector", `String selector] when String.trim selector <> "" ->
        Ok (Browser_lane.Selector selector)
      | fields when List.length fields = 2 ->
        (match List.assoc_opt "documentId" fields, List.assoc_opt "nodeId" fields with
         | Some (`String document_id), Some (`String node_id) when document_id <> "" && node_id <> "" ->
           Ok (Browser_lane.Scene_node {document_id;node_id})
         | _ -> Error "pointer target requires selector or documentId/nodeId")
      | _ -> Error "pointer target requires selector or documentId/nodeId" in
    let excludes keys =
      let keys = match List.assoc_opt "action" fields with
        | Some (`String "set_zoom") -> keys
        | _ -> "factor" :: keys in
      let keys = (match List.assoc_opt "action" fields with
        | Some (`String "press_key") -> keys
        | _ -> "key" :: "modifiers" :: keys) in
      let keys = match List.assoc_opt "action" fields with
        | Some (`String "drag_to") -> keys
        | Some (`String ("drag" | "swipe")) -> "source" :: "destination" :: keys
        | _ -> "source" :: "destination" :: "via" :: "durationMs" :: keys in
      let keys = match List.assoc_opt "action" fields with
        | Some (`String "click_at") -> keys
        | _ -> "button" :: keys in
      let keys = match List.assoc_opt "action" fields with
        | Some (`String "set_viewport") -> keys
        | _ -> "width" :: "height" :: keys in
      if List.exists (fun key -> List.mem_assoc key fields) keys
      then Error "arguments do not match the selected interaction action" else Ok () in
    let required key = match List.assoc_opt key fields with
      | Some value -> Ok value
      | None -> Error ("pointer action requires " ^ key) in
    let geometry parser key =
      let* value = required key in
      parser value in
    let drag_options () =
      let* via = match List.assoc_opt "via" fields with
        | None -> Ok []
        | Some (`List points) ->
          let rec parse acc = function
            | [] -> Ok (List.rev acc)
            | raw::rest -> let* point = Browser_lane.Pointer.point_of_json raw in parse (point::acc) rest in
          parse [] points
        | Some _ -> Error "via must be a list of normalized viewport points" in
      let* duration_ms = match List.assoc_opt "durationMs" fields with
        | None -> Ok 0
        | Some (`Int value) when value >= 0 && Int64.of_int value <= 9007199254740991L -> Ok value
        | Some _ -> Error "durationMs must be a nonnegative JavaScript-safe integer" in
      Ok (via,duration_ms) in
    let* action = match List.assoc_opt "action" fields with
      | Some (`String "set_viewport") ->
        let* () = excludes ["selector";"text";"documentId";"nodeId";"x";"y";"point";"from";"to";"viewport"] in
        let* () = match expected_url with Some _ -> Ok () | None -> Error "set_viewport requires expectedUrl" in
        let side key =
          let* value = integer key in
          if value >= Browser_lane.viewport_side_min_px && value <= Browser_lane.viewport_side_max_px then Ok value
          else Error (Printf.sprintf "%s must be between %d and %d" key
            Browser_lane.viewport_side_min_px Browser_lane.viewport_side_max_px) in
        (match List.mem_assoc "width" fields, List.mem_assoc "height" fields with
         | false, false -> Ok (Browser_lane.Set_viewport Browser_lane.Browser_default)
         | true, true ->
           let* width = side "width" in
           let* height = side "height" in
           Ok (Browser_lane.Set_viewport (Browser_lane.Fit {width;height}))
         | true, false | false, true -> Error "set_viewport takes width and height together, or neither to restore the browser's size")
      | Some (`String "set_zoom") ->
        let* () = excludes ["selector";"text";"documentId";"nodeId";"x";"y";"point";"from";"to";"viewport"] in
        let* () = match expected_url with Some _ -> Ok () | None -> Error "set_zoom requires expectedUrl" in
        let* factor = match List.assoc_opt "factor" fields with
          | Some (`Int value) -> Ok (float_of_int value)
          | Some (`Float value) when Float.is_finite value -> Ok value
          | Some _ | None -> Error "set_zoom requires a finite factor" in
        let* () = if factor >= 0.3 && factor <= 5. then Ok ()
          else Error "set_zoom factor must be between 0.3 and 5" in
        Ok (Browser_lane.Set_zoom {factor})
      | Some (`String ("type_text" | "press_key" as action)) ->
        let* () = excludes (["selector";"nodeId";"x";"y";"point";"from";"to";"viewport"] @
          if action = "press_key" then ["text"] else []) in
        let* () = match expected_url with Some _ -> Ok () | None -> Error "native keyboard input requires expectedUrl" in
        let* document_id = match List.assoc_opt "documentId" fields with
          | Some (`String id) when id <> "" -> Ok id | _ -> Error "native keyboard input requires observed documentId" in
        if action = "type_text" then
          let* text = match List.assoc_opt "text" fields with Some (`String text) -> Ok text
            | _ -> Error "type_text requires string text" in
          let* () = Browser_lane.Keyboard.validate_text text in
          Ok (Browser_lane.Type_text {document_id;text})
        else
          let* key = match List.assoc_opt "key" fields with Some (`String key) -> Ok key
            | _ -> Error "press_key requires key" in
          let* modifiers = match List.assoc_opt "modifiers" fields with
            | None -> Ok []
            | Some (`List values) ->
              let rec strings = function [] -> Ok [] | `String value::rest ->
                let* rest = strings rest in Ok (value::rest)
                | _ -> Error "modifiers must contain strings" in strings values
            | Some _ -> Error "modifiers must be an array" in
          let* key = Browser_lane.Keyboard.of_wire ~key ~modifiers in
          Ok (Browser_lane.Press_key {document_id;key})
      | Some (`String "double_click") ->
        let* () = excludes ["text";"x";"y";"point";"from";"to";"viewport"] in
        let* () = match expected_url with Some _ -> Ok () | None -> Error "double_click requires expectedUrl" in
        let* target = pointer_target (List.filter (fun (key,_) ->
          List.mem key ["selector";"documentId";"nodeId"]) fields) in
        Ok (Browser_lane.Double_click target)
      | Some (`String "hover") ->
        let* () = excludes ["text";"x";"y";"point";"from";"to";"viewport"] in
        let* () = match expected_url with Some _ -> Ok () | None -> Error "hover requires expectedUrl" in
        let* target = pointer_target (List.filter (fun (key,_) ->
          List.mem key ["selector";"documentId";"nodeId"]) fields) in
        Ok (Browser_lane.Hover target)
      | Some (`String "drag_to") ->
        let* () = excludes ["selector";"documentId";"nodeId";"text";"x";"y";"point";"from";"to";"viewport"] in
        let* () = match expected_url with Some _ -> Ok () | None -> Error "drag_to requires expectedUrl" in
        let target key = match List.assoc_opt key fields with
          | Some (`Assoc fields) -> pointer_target fields
          | _ -> Error ("drag_to requires " ^ key ^ " target") in
        let* source = target "source" in let* destination = target "destination" in
        let* via,duration_ms = drag_options () in
        Ok (Browser_lane.Drag_to {source;destination;via;duration_ms})
      | Some (`String "follow_link") ->
        let* () = excludes ["selector";"text";"x";"y";"point";"from";"to";"viewport"] in
        let* () = match expected_url with Some _ -> Ok () | None -> Error "follow_link requires expectedUrl" in
        let* target = node_target () in
        (match target with Some target -> Ok (Browser_lane.Follow_link target)
         | None -> Error "follow_link requires an observed documentId/nodeId")
      | Some (`String "activate_tab") ->
        let* () = excludes ["selector";"text";"x";"y";"documentId";"nodeId";"point";"from";"to";"viewport"] in
        let* () = match expected_url with Some _ -> Ok () | None -> Error "activate_tab requires expectedUrl" in
        let* () = match base.route with
          | Browser_selection.Exact (Browser_lane.Live_route _) -> Ok ()
          | Browser_selection.Automatic
          | Browser_selection.Exact (Browser_lane.Automation_route | Browser_lane.Stagehand_route) ->
              Error "activate_tab requires an observed live clientId or lane" in
        Ok Browser_lane.Activate_tab
      | Some (`String "click") ->
        let* () = excludes ["text"; "x"; "y"; "point"; "from"; "to"; "viewport"] in
        let* target = node_target () in
        (match target with Some target -> Ok (Browser_lane.Click_node target)
         | None -> let* selector = selector () in Ok (Browser_lane.Click selector))
      | Some (`String "fill") ->
        let* () = excludes ["x"; "y"; "point"; "from"; "to"; "viewport"] in
        let* target = node_target () in
        (match List.assoc_opt "text" fields with
         | Some (`String text) -> (match target with
             | Some target -> Ok (Browser_lane.Fill_node {target;text})
             | None -> let* selector = selector () in Ok (Browser_lane.Fill {selector;text}))
         | _ -> Error "fill requires string text (empty text clears the input)")
      | Some (`String "scroll") ->
        let* () = excludes ["selector"; "text"; "documentId"; "nodeId"; "point"; "from"; "to"; "viewport"] in
        let* x = integer "x" in let* y = integer "y" in Ok (Browser_lane.Scroll {x; y})
      | Some (`String "scroll_at") ->
        let* () = excludes ["selector";"text";"documentId";"nodeId";"from";"to"] in
        let* () = match expected_url with Some _ -> Ok () | None -> Error "pointer actions require expectedUrl" in
        let* viewport = geometry Browser_lane.Pointer.viewport_of_json "viewport" in
        let* point = geometry Browser_lane.Pointer.point_of_json "point" in
        let* x = integer "x" in let* y = integer "y" in
        Ok (Browser_lane.Scroll_at {point;viewport;x;y})
      | Some (`String "tap_at") ->
        let* () = excludes ["selector";"text";"documentId";"nodeId";"x";"y";"from";"to"] in
        let* () = match expected_url with Some _ -> Ok () | None -> Error "tap_at requires expectedUrl" in
        let* viewport = geometry Browser_lane.Pointer.viewport_of_json "viewport" in
        let* point = geometry Browser_lane.Pointer.point_of_json "point" in
        Ok (Browser_lane.Tap_at {point;viewport})
      | Some (`String "swipe") ->
        let* () = excludes ["selector";"text";"documentId";"nodeId";"x";"y";"point"] in
        let* () = match expected_url with Some _ -> Ok () | None -> Error "swipe requires expectedUrl" in
        let* viewport = geometry Browser_lane.Pointer.viewport_of_json "viewport" in
        let* from = geometry Browser_lane.Pointer.point_of_json "from" in
        let* to_ = geometry Browser_lane.Pointer.point_of_json "to" in
        let* via,duration_ms = drag_options () in
        Ok (Browser_lane.Swipe {from;to_;viewport;via;duration_ms})
      | Some (`String ("hover_at" | "double_click_at" as action)) ->
        let* () = excludes ["selector";"text";"documentId";"nodeId";"x";"y";"from";"to"] in
        let* () = match expected_url with Some _ -> Ok () | None -> Error (action ^ " requires expectedUrl") in
        let* viewport = geometry Browser_lane.Pointer.viewport_of_json "viewport" in
        let* point = geometry Browser_lane.Pointer.point_of_json "point" in
        Ok (if action = "double_click_at" then Browser_lane.Double_click_at {point;viewport}
          else Browser_lane.Hover_at {point;viewport})
      | Some (`String ("click_at" | "drag" as action)) ->
        let* () = excludes (["selector"; "text"; "documentId"; "nodeId"; "x"; "y"] @
          if action = "click_at" then ["from"; "to"] else ["point"]) in
        let* () = match expected_url with Some _ -> Ok () | None -> Error "pointer actions require expectedUrl" in
        let* viewport = geometry Browser_lane.Pointer.viewport_of_json "viewport" in
        if action = "click_at" then
          let* point = geometry Browser_lane.Pointer.point_of_json "point" in
          let* button = match List.assoc_opt "button" fields with
            | None -> Ok Browser_lane.Pointer.Primary
            | Some (`String raw) ->
              (match Browser_lane.Pointer.button_of_string raw with
               | Some button -> Ok button
               | None -> Error "button must be primary, middle or secondary")
            | Some _ -> Error "button must be primary, middle or secondary" in
          Ok (Browser_lane.Click_at {point;viewport;button})
        else
          let* from = geometry Browser_lane.Pointer.point_of_json "from" in
          let* to_ = geometry Browser_lane.Pointer.point_of_json "to" in
          let* via,duration_ms = drag_options () in
          Ok (Browser_lane.Drag {from;to_;viewport;via;duration_ms})
      | _ -> Error "action must be set_zoom, set_viewport, activate_tab, tap_at, swipe, click, double_click, double_click_at, type_text, press_key, follow_link, fill, scroll, click_at, scroll_at, hover, hover_at, drag or drag_to" in
    Ok { route = base.route; tab_id; expected_url; action }
  | _ -> Error "browser interaction arguments must be an object"

let perform request =
  let verb = Browser_lane.Page_interact {tab_id=request.tab_id;
    expected_url=request.expected_url; action=request.action} in
  let* selected = Browser_selection.resolve ~verb ~bound:true request.route
    |> Result.map_error Browser_selection.error_message in
  let* target = Browser_lane.resolve_target ~verb selected.route
    |> Result.map_error Browser_lane.selection_error_message in
  let* answer = Browser_lane.issue_for ~target
    ~verb
    ~timeout_sec:20.
    |> Result.map_error Browser_lane.selection_error_message in
  let selected = Browser_selection.bind_target selected target in
  Browser_surface.decode_answer ~lane:(Browser_lane.target_lane target) answer
  |> Result.map (function
    | `Assoc fields -> `Assoc (["browserSelection",Browser_selection.to_json selected;
        "lane",`String (Browser_lane.Lane_name.to_wire (Browser_lane.target_lane target))]
        @ Browser_lane.with_connection_fields target
            (List.filter (fun (key,_) -> not (List.mem key ["lane";"browserSelection"])) fields))
    | value -> value)

let script = {js|function interactInPage(args) {
  let effectStarted = false;
  try {
  if (args.expectedUrl !== undefined && args.expectedUrl !== location.href)
    throw new Error("page_url_changed");
  const before = location.href;
  // The same predicate the scene admits a control by (browser_scene_script.ml
  // `rendered`/`visible`). display and opacity take effect through ancestors,
  // so a page that withdrew the target by setting opacity 0 on a wrapper
  // leaves an element that still reports client rects and its own computed
  // display. Checking only the element acted on a link the read surface had
  // already stopped showing.
  const labelTextRects = (element, admit = rects => Array.from(rects)) => {
    if (element.localName !== 'label') return [];
    const walker = document.createTreeWalker(element, NodeFilter.SHOW_TEXT), rects = [];
    while (walker.nextNode()) {
      const text = walker.currentNode, parent = text.parentElement;
      if (!text.textContent.trim() || !parent || getComputedStyle(parent).visibility !== 'visible') continue;
      let hidden = false;
      for (let node = parent; node; node = node.parentElement) {
        const style = getComputedStyle(node);
        if (style.display === 'none' || Number(style.opacity) === 0) { hidden = true; break; }
      }
      if (hidden) continue;
      const range = document.createRange(); range.selectNodeContents(text);
      rects.push(...admit(range.getClientRects(), parent).filter(r => r.width > 0 && r.height > 0));
    }
    return rects;
  };
  const observable = element => {
    if (!element.getClientRects().length && !labelTextRects(element).length) return false;
    if (getComputedStyle(element).visibility !== 'visible') return false;
    for (let node = element; node; node = node.parentElement) {
      const style = getComputedStyle(node);
      if (style.display === 'none' || Number(style.opacity) === 0) return false;
    }
    return true;
  };
  if (args.action === "follow_link") {
    const element = browserScene({...args,mode:'resolve_link'});
    if (!(element instanceof HTMLAnchorElement) && !(typeof SVGAElement !== 'undefined' && element instanceof SVGAElement))
      throw new Error('follow_link_requires_anchor');
    if (!observable(element)) throw new Error('element_not_visible');
    const target = element.getAttribute('target') ?? document.querySelector('base[target]')?.getAttribute('target') ?? '';
    const normalizedTarget = target.toLowerCase();
    const sameTab = normalizedTarget === '' || normalizedTarget === '_self'
      || (window === window.top && (normalizedTarget === '_top' || normalizedTarget === '_parent'));
    if (!sameTab) throw new Error('follow_link_requires_same_tab');
    const rel = (element.getAttribute('rel') || '').toLowerCase().split(/\s+/);
    if (rel.includes('noreferrer') || element.hasAttribute('referrerpolicy'))
      throw new Error('follow_link_referrer_policy_unsupported');
    if (element.hasAttribute('download')) throw new Error('follow_link_rejects_download');
    const rawHref = typeof element.href === 'string' ? element.href : element.href.baseVal;
    const destination = new URL(rawHref, element.baseURI || document.baseURI || location.href);
    if (!['http:','https:'].includes(destination.protocol)) throw new Error('follow_link_requires_http_url');
    const result = {action:args.action,urlBefore:before,url:before,destinationUrl:destination.href,
      navigationSource:{url:before,documentId:args.documentId},
      title:document.title,scrollX:scrollX,scrollY:scrollY};
    // Follow the observed href directly: page click handlers cannot redirect
    // this primitive into window.open or an unrelated application action.
    effectStarted = true;
    location.assign(destination.href);
    return result;
  }
  if (args.action === "click_at" || args.action === "scroll_at") {
    const current = browserScene({mode:'viewport'}), expected = args.viewport;
    if (!expected || Object.keys(current).some(key => current[key] !== expected[key]))
      throw new Error('observed_viewport_changed');
    const point = args.point;
    if (!point || !Number.isFinite(point.x) || !Number.isFinite(point.y)
        || point.x < 0 || point.x >= 1 || point.y < 0 || point.y >= 1)
      throw new Error('invalid_viewport_point');
    let element = document.elementFromPoint(point.x * innerWidth, point.y * innerHeight);
    if (!element) throw new Error('point_has_no_element');
    if (args.action === 'click_at') {
      if (typeof element.click !== 'function') throw new Error('point_has_no_clickable_element');
      if (element.matches(':disabled')) throw new Error('element_disabled');
    effectStarted = true;
      element.click();
    } else {
      if (!Number.isSafeInteger(args.x) || !Number.isSafeInteger(args.y))
        throw new Error('scroll_coordinates_must_be_integers');
      // Hit testing stops at shadow hosts and frame elements. Resolve both
      // before scrolling; never redirect an inaccessible frame hit to its page.
      let hitWindow = window, hitX = point.x * innerWidth, hitY = point.y * innerHeight;
      for (;;) {
        if (element.shadowRoot && typeof element.shadowRoot.elementFromPoint === 'function') {
          const inner = element.shadowRoot.elementFromPoint(hitX, hitY);
          if (inner && inner !== element) { element = inner; continue; }
        }
        if (element.localName !== 'iframe' && element.localName !== 'frame') break;
        let childDocument;
        try { childDocument = element.contentDocument; }
        catch { throw new Error('scroll_frame_inaccessible'); }
        if (!childDocument || !childDocument.defaultView) throw new Error('scroll_frame_inaccessible');
        // A bounding rectangle cannot invert rotation, skew or perspective.
        // Reject transformed frames/ancestors before either scroll axis acts.
        for (let node = element; node; node = node.parentElement || node.getRootNode().host) {
          const style = hitWindow.getComputedStyle(node);
          if (style.transform !== 'none' || style.perspective !== 'none'
              || (style.rotate && style.rotate !== 'none')
              || (style.scale && style.scale !== 'none')
              || (style.translate && style.translate !== 'none')
              || (style.zoom && style.zoom !== 'normal' && Number(style.zoom) !== 1))
            throw new Error('scroll_frame_geometry_unsupported');
        }
        const rect = element.getBoundingClientRect(), style = hitWindow.getComputedStyle(element);
        hitX -= rect.left + element.clientLeft + Number.parseFloat(style.paddingLeft);
        hitY -= rect.top + element.clientTop + Number.parseFloat(style.paddingTop);
        hitWindow = childDocument.defaultView;
        if (hitX < 0 || hitY < 0 || hitX >= hitWindow.innerWidth || hitY >= hitWindow.innerHeight)
          throw new Error('scroll_point_outside_frame_content');
        element = childDocument.elementFromPoint(hitX, hitY);
        if (!element) throw new Error('point_has_no_element');
      }
      // Follow actual scroll containers under the pointer. Slack's message
      // pane scrolls independently of document.body and its channel sidebar.
      const scrollAxis = (delta, axis) => {
        if (delta === 0) return;
        const vertical = axis === 'y';
        for (let node = element; node; node = node.parentElement || node.getRootNode().host) {
          const style = hitWindow.getComputedStyle(node);
          const overflow = vertical ? style.overflowY : style.overflowX;
          const position = vertical ? node.scrollTop : node.scrollLeft;
          const maximum = vertical ? node.scrollHeight-node.clientHeight : node.scrollWidth-node.clientWidth;
          if ((overflow === 'auto' || overflow === 'scroll') && maximum > 0) {
            node.scrollBy({left:vertical ? 0 : delta,top:vertical ? delta : 0,behavior:'instant'});
            const after = vertical ? node.scrollTop : node.scrollLeft;
            // Reverse-flow chat and RTL scrollers may have negative positions.
            // The browser's actual movement establishes consumption, not a range guess.
            if (after !== position) return;
            const chain = vertical ? style.overscrollBehaviorY : style.overscrollBehaviorX;
            if (chain === 'contain' || chain === 'none') return;
          }
        }
        hitWindow.scrollBy({left:vertical ? 0 : delta,top:vertical ? delta : 0,behavior:'instant'});
      };
    effectStarted = true;
      scrollAxis(args.x,'x'); scrollAxis(args.y,'y');
    }
  } else if (args.action === "scroll") {
    if (!Number.isSafeInteger(args.x) || !Number.isSafeInteger(args.y))
      throw new Error("scroll_coordinates_must_be_integers");
    effectStarted = true;
    window.scrollBy({left: args.x, top: args.y, behavior: "instant"});
  } else if (args.action === "click" || args.action === "fill") {
    let element;
    if (args.nodeId !== undefined || args.documentId !== undefined) {
      if (args.selector !== undefined || typeof args.nodeId !== "string" || typeof args.documentId !== "string")
        throw new Error("invalid_scene_reference");
      element = browserScene({...args,mode:'resolve'});
    } else {
      if (typeof args.selector !== "string" || !args.selector.trim()) throw new Error("selector_required");
      let elements;
      try { elements = document.querySelectorAll(args.selector); }
      catch { throw new Error("invalid_css_selector"); }
      if (elements.length !== 1)
        throw new Error(elements.length === 0 ? "element_not_found" : "selector_is_ambiguous");
      element = elements[0];
    }
    if (!observable(element)) throw new Error("element_not_visible");
    const activationTarget=(element.localName === 'label' && element.control) || element;
    if (activationTarget.matches(":disabled")) throw new Error("element_disabled");
    for (const start of new Set([element,activationTarget]))
      for (let parent=start; parent; parent=parent.parentElement)
      if (parent.getAttribute?.('aria-disabled') === 'true') throw new Error("element_disabled");
    if (args.action === "click") {
      if (typeof element.click !== "function") throw new Error("element_not_clickable");
    effectStarted = true;
      element.click();
    } else {
      if (typeof args.text !== "string") throw new Error("fill_text_required");
      const input = element instanceof HTMLInputElement;
      const textarea = element instanceof HTMLTextAreaElement;
      if ((!input && !textarea) || (input && !["text", "search", "email", "url", "tel", "password", "number"].includes(element.type)))
        throw new Error("element_is_not_a_text_input");
      if (element.readOnly) throw new Error("element_read_only");
      const prototype = input ? HTMLInputElement.prototype : HTMLTextAreaElement.prototype;
      const setter = Object.getOwnPropertyDescriptor(prototype, "value").set;
      const previousValue = element.value;
    effectStarted = true;
      setter.call(element, args.text);
      if (element.value !== args.text) {
        setter.call(element, previousValue);
        throw new Error("input_rejected_value");
      }
      element.dispatchEvent(new Event("input", {bubbles: true}));
      element.dispatchEvent(new Event("change", {bubbles: true}));
      if (element.value !== args.text) throw new Error("input_changed_during_events");
    }
  } else throw new Error("unknown_interaction_action");
  return {action: args.action, urlBefore: before, url: location.href,
    title: document.title, scrollX: window.scrollX, scrollY: window.scrollY};
  } catch (error) {
    return {interactionFailure:{message:String(error?.message ?? error),effectStarted}};
  }
}

return interactInPage(arguments[0]);
|js}

let pointer_guard_script = {js|
const args = arguments[0];
if (args.expectedUrl !== location.href) throw new Error('page_url_changed');
const current = browserScene({mode:'viewport'}), expected = args.viewport;
if (!expected || Object.keys(current).some(key => current[key] !== expected[key]))
  throw new Error('observed_viewport_changed');
return {url:location.href,title:document.title,scrollX,scrollY};
|js}

let keyboard_guard_script = {js|
const args = arguments[0];
if (args.expectedUrl !== location.href) throw new Error('page_url_changed');
if (browserScene({mode:'viewport'}).documentId !== args.documentId)
  throw new Error('scene_document_changed');
let focused = document.activeElement;
while (focused?.shadowRoot?.activeElement) focused = focused.shadowRoot.activeElement;
if (!focused || !focused.isConnected) throw new Error('keyboard_focus_unavailable');
for (let node = focused; node; node = node.parentElement ?? node.getRootNode?.().host ?? null) {
  if (node.inert || node.getAttribute('aria-disabled') === 'true') throw new Error('keyboard_focus_disabled');
}
if (focused.disabled || focused.matches(':disabled')) throw new Error('keyboard_focus_disabled');
if (args.action === 'type_text') {
  const input = focused.localName === 'input' &&
    ['text','search','email','url','tel','password','number'].includes(focused.type);
  if ((!input && focused.localName !== 'textarea' && !focused.isContentEditable) || focused.readOnly ||
      focused.getAttribute('aria-readonly') === 'true') throw new Error('keyboard_focus_not_editable');
}
return {url:location.href,title:document.title,scrollX,scrollY};
|js}

(* The guard of an action that acts on the tab and no pointer or focus. *)
let url_guard_script = {js|
const args = arguments[0];
if (args.expectedUrl !== location.href) throw new Error('page_url_changed');
return {url:location.href,title:document.title,scrollX,scrollY};
|js}

(* What a viewport resize reports once the browser has taken it. *)
let viewport_receipt_script = "return {url:location.href,title:document.title,innerWidth,innerHeight,devicePixelRatio};"

(* What a pointer action reports once the browser has taken it. *)
let pointer_receipt_script = "return {url:location.href,title:document.title,scrollX,scrollY};"

let pointer_target_script = {js|
const args = arguments[0];
try {
  if (args.expectedUrl !== undefined && args.expectedUrl !== location.href) throw new Error('page_url_changed');
  const target = (spec, withArrival = false) => {
    let element;
    if (spec.selector !== undefined) {
      let found;
      try { found = document.querySelectorAll(spec.selector); }
      catch { throw new Error('invalid_css_selector'); }
      if (found.length !== 1) throw new Error(found.length ? 'selector_is_ambiguous' : 'element_not_found');
      element = found[0];
    } else element = browserScene({...spec,mode:'resolve'});
    if (!element.isConnected) throw new Error('element_detached');
    if ((args.action === 'click' || args.action === 'double_click')) {
      const activationTarget = (element.localName === 'label' && element.control) || element;
      if (activationTarget.matches(':disabled')) throw new Error('element_disabled');
      for (const start of new Set([element,activationTarget]))
        for (let node = start; node; node = node.parentElement || node.getRootNode().host)
          if (node.getAttribute?.('aria-disabled') === 'true') throw new Error('element_disabled');
    }
    if (getComputedStyle(element).visibility !== 'visible') throw new Error('element_not_visible');
    for (let node = element; node; node = node.parentElement || node.getRootNode().host) {
      const style = getComputedStyle(node);
      if (style.display === 'none' || Number(style.opacity) === 0)
        throw new Error('element_not_visible');
    }
    const rects = Array.from(element.getClientRects());
    // display:contents labels have no box of their own. Their visible text
    // still activates the associated control through native label behavior.
    if ((args.action === 'click' || args.action === 'double_click') && element.localName === 'label') {
      const walker = document.createTreeWalker(element,NodeFilter.SHOW_TEXT);
      while (walker.nextNode()) {
        const text = walker.currentNode, parent = text.parentElement;
        if (!text.textContent.trim() || !parent || getComputedStyle(parent).visibility !== 'visible') continue;
        let hidden = false;
        for (let node = parent; node; node = node.parentElement) {
          const style = getComputedStyle(node);
          if (style.display === 'none' || Number(style.opacity) === 0) { hidden = true; break; }
        }
        if (hidden) continue;
        const range = document.createRange(); range.selectNodeContents(text);
        rects.push(...Array.from(range.getClientRects()).filter(rect => rect.width > 0 && rect.height > 0));
      }
    }
    const containsPointer = (x,y) => {
      let hit = document.elementFromPoint(x,y);
      while (hit?.shadowRoot?.elementFromPoint) {
        const next = hit.shadowRoot.elementFromPoint(x,y);
        if (!next || next === hit) break;
        hit = next;
      }
      for (let node = hit; node; node = node.parentElement || node.getRootNode().host)
        if (node === element) return true;
      return false;
    };
    const point = (x,y) => ({x:x/innerWidth,y:y/innerHeight});
    for (const rect of rects) {
      const left = Math.max(0,rect.left), right = Math.min(innerWidth,rect.right);
      const top = Math.max(0,rect.top), bottom = Math.min(innerHeight,rect.bottom);
      if (right <= left || bottom <= top) continue;
      const x = Math.floor((left+right)/2), y = Math.floor((top+bottom)/2);
      if (!containsPointer(x,y)) continue;
      const resolved = {point:point(x,y)};
      if (withArrival) {
        // Enter the observed drop rectangle before its center, so a later
        // native move can deliver dragover after dragenter on this target.
        const candidates = [[Math.floor((left+x)/2),y],[Math.floor((x+right)/2),y],
          [x,Math.floor((top+y)/2)],[x,Math.floor((y+bottom)/2)]];
        const arrival = candidates.find(([ax,ay]) => (ax !== x || ay !== y)
          && ax >= left && ax < right && ay >= top && ay < bottom && containsPointer(ax,ay));
        if (arrival) resolved.arrival = point(...arrival);
      }
      return resolved;
    }
    if (!rects.some(rect =>
      rect.right > 0 && rect.bottom > 0 && rect.left < innerWidth && rect.top < innerHeight))
      throw new Error('element_outside_viewport');
    throw new Error('element_pointer_obstructed');
  };
  let geometry;
  if (args.action === 'hover' || (args.action === 'click' || args.action === 'double_click')) geometry = {point:target(args).point};
  else {
    const source = target(args.source), destination = target(args.destination,true);
    geometry = {from:source.point,to:destination.point,
      ...(destination.arrival ? {arrival:destination.arrival} : {})};
  }
  return {...geometry,url:location.href,viewport:browserScene({mode:'viewport'})};
} catch (error) {
  return {interactionFailure:{message:String(error?.message ?? error),effectStarted:false}};
}
|js}

let resolve_pointer_action action = function
  | `Assoc fields ->
    let required key = match List.assoc_opt key fields with
      | Some value -> Ok value | None -> Error ("pointer resolution missing " ^ key) in
    let* () = match List.assoc_opt "interactionFailure" fields with
      | Some (`Assoc failure) -> (match List.assoc_opt "message" failure with
          | Some (`String message) -> Error message | _ -> Error "invalid pointer target refusal")
      | None -> Ok () | Some _ -> Error "invalid pointer target refusal" in
    let* raw_viewport = required "viewport" in
    let* viewport = Browser_lane.Pointer.viewport_of_json raw_viewport in
    let point key = let* raw = required key in Browser_lane.Pointer.point_of_json raw in
    (match action with
     | Browser_lane.Double_click _ -> let* point = point "point" in Ok (Browser_lane.Double_click_at {point;viewport})
     | Browser_lane.Hover _ -> let* point = point "point" in Ok (Browser_lane.Hover_at {point;viewport})
     | Browser_lane.Click _ | Browser_lane.Click_node _ ->
       let* point = point "point" in
       Ok (Browser_lane.Click_at {point;viewport;button=Browser_lane.Pointer.Primary})
     | Browser_lane.Drag_to {via;duration_ms;_} -> let* from = point "from" in let* to_ = point "to" in
       Ok (Browser_lane.Drag {from;to_;viewport;via;duration_ms})
     | Browser_lane.Activate_tab | Browser_lane.Fill _
     | Browser_lane.Set_zoom _ | Browser_lane.Set_viewport _ | Browser_lane.Double_click_at _ | Browser_lane.Type_text _ | Browser_lane.Press_key _
     | Browser_lane.Scroll _ | Browser_lane.Hover_at _ | Browser_lane.Click_at _
     | Browser_lane.Tap_at _ | Browser_lane.Swipe _
     | Browser_lane.Scroll_at _ | Browser_lane.Drag _ | Browser_lane.Follow_link _
     | Browser_lane.Fill_node _ -> Error "semantic pointer action required")
  | _ -> Error "invalid pointer target resolution"

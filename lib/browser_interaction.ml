(** Closed browser interactions. Caller strings are values, never script source. *)
type request = { source : Browser_surface.source; tab_id : int; client_id : Browser_lane.client_id option;
  expected_url : string option; action : Browser_lane.interaction }
let ( let* ) = Result.bind
let parse = function
  | `Assoc fields ->
    let allowed = ["lane"; "clientId"; "tabId"; "expectedUrl"; "action"; "selector"; "text"; "x"; "y"; "documentId"; "nodeId"; "point"; "from"; "to"; "viewport"] in
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
    let excludes keys =
      if List.exists (fun key -> List.mem_assoc key fields) keys
      then Error "arguments do not match the selected interaction action" else Ok () in
    let required key = match List.assoc_opt key fields with
      | Some value -> Ok value
      | None -> Error ("pointer action requires " ^ key) in
    let geometry parser key =
      let* value = required key in
      parser value in
    let* action = match List.assoc_opt "action" fields with
      | Some (`String "follow_link") ->
        let* () = excludes ["selector";"text";"x";"y";"point";"from";"to";"viewport"] in
        let* () = match expected_url with Some _ -> Ok () | None -> Error "follow_link requires expectedUrl" in
        let* target = node_target () in
        (match target with Some target -> Ok (Browser_lane.Follow_link target)
         | None -> Error "follow_link requires an observed documentId/nodeId")
      | Some (`String "activate_tab") ->
        let* () = excludes ["selector";"text";"x";"y";"documentId";"nodeId";"point";"from";"to";"viewport"] in
        let* () = match expected_url with Some _ -> Ok () | None -> Error "activate_tab requires expectedUrl" in
        let* () = match base.source with Browser_surface.Live -> Ok ()
          | Automation -> Error "activate_tab requires live lane" in
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
      | Some (`String ("click_at" | "drag" as action)) ->
        let* () = excludes (["selector"; "text"; "documentId"; "nodeId"; "x"; "y"] @
          if action = "click_at" then ["from"; "to"] else ["point"]) in
        let* () = match expected_url with Some _ -> Ok () | None -> Error "pointer actions require expectedUrl" in
        let* viewport = geometry Browser_lane.Pointer.viewport_of_json "viewport" in
        if action = "click_at" then
          let* point = geometry Browser_lane.Pointer.point_of_json "point" in
          Ok (Browser_lane.Click_at {point;viewport})
        else
          let* from = geometry Browser_lane.Pointer.point_of_json "from" in
          let* to_ = geometry Browser_lane.Pointer.point_of_json "to" in
          Ok (Browser_lane.Drag {from;to_;viewport})
      | _ -> Error "action must be activate_tab, click, follow_link, fill, scroll, click_at, scroll_at or drag" in
    Ok { source = base.source; tab_id; client_id=base.client_id; expected_url; action }
  | _ -> Error "browser interaction arguments must be an object"

let perform request =
  let lane_name = match request.source with Browser_surface.Live -> "live" | Automation -> "automation" in
  let* target = Browser_lane.resolve_target ~lane_name ~client_id:request.client_id in
  Browser_lane.issue_for ~target
    ~verb:(Browser_lane.Page_interact {tab_id=request.tab_id;
      expected_url=request.expected_url; action=request.action})
    ~timeout_sec:20.
  |> Browser_surface.decode_answer

let script = {js|function interactInPage(args) {
  let effectStarted = false;
  try {
  if (args.expectedUrl !== undefined && args.expectedUrl !== location.href)
    throw new Error("page_url_changed");
  const before = location.href;
  if (args.action === "follow_link") {
    const element = browserScene({...args,mode:'resolve_link'});
    if (!(element instanceof HTMLAnchorElement) || !element.hasAttribute('href'))
      throw new Error('follow_link_requires_anchor');
    const style = getComputedStyle(element);
    if (!element.getClientRects().length || style.visibility !== 'visible' || style.display === 'none')
      throw new Error('element_not_visible');
    const target = element.getAttribute('target') ?? document.querySelector('base[target]')?.getAttribute('target') ?? '';
    if (target !== '' && target.toLowerCase() !== '_self') throw new Error('follow_link_requires_same_tab');
    if (element.hasAttribute('download')) throw new Error('follow_link_rejects_download');
    const destination = new URL(element.href, location.href);
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
  if (args.action === "drag") throw new Error("trusted_drag_requires_automation");
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
    const style = getComputedStyle(element);
    if (!element.getClientRects().length || style.visibility === "hidden" || style.display === "none")
      throw new Error("element_not_visible");
    if (element.matches(":disabled")) throw new Error("element_disabled");
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

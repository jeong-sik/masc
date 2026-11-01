let script = {js|async function nativeWorkflow(page, args, task, watchPage) {
  const completed = [];
  let pages = null, pendingAction = null;
  const hasPopup = args.steps.some(step => step.method === 'clickAndWaitForPopup');
  // The lightweight event/task.page handle can lack targetId/openedBy. Only
  // the unique native inventory row supplies the canonical enriched Page.
  const canonicalPage = async observed => {
    if (!task || observed?.spaceId !== task.spaceId
        || typeof observed.label !== 'string' || observed.label.trim() === '')
      throw new Error('popup Page is not a managed handle in the bound Space');
    const matches = (await task.tabs()).filter(row => row.label === observed.label);
    if (matches.length !== 1) throw new Error('native Page label is absent or ambiguous');
    const row = matches[0], canonical = row.page;
    if (typeof row.targetId !== 'string' || row.targetId.trim() === ''
        || !['agent','unknown'].includes(row.openedBy)
        || !canonical || canonical.spaceId !== task.spaceId
        || canonical.label !== observed.label || canonical.targetId !== row.targetId
        || canonical.openedBy !== row.openedBy
        || (observed.targetId !== undefined && observed.targetId !== row.targetId)
        || (observed.openedBy !== undefined && observed.openedBy !== row.openedBy))
      throw new Error('native Page inventory identity disagrees with the observed handle');
    return {page:canonical, identity:{spaceId:task.spaceId,label:row.label,
      targetId:row.targetId,openedBy:row.openedBy}};
  };
  // These strings are evaluated only by the SDK's browser Page channel.
  // Never eval, import, or compile a caller's source in this Node process.
  const pageExpression = step => step.argumentJson === undefined ? step.source
    : '(' + step.source + ')(JSON.parse(' + JSON.stringify(step.argumentJson) + '))';
  let effectStarted = false, completedEffect = false;
  let inputReleased = true;
  const failure = (index, method, error, extra = {}) => {
    const nativeError = (() => {
      if (method === 'popupWait') return undefined;
      switch (error?.code) {
        case 'EGO_PAGE_EVALUATION_TIMED_OUT': return {
          code: error.code, timeoutMs: error.timeoutMs,
          executionStopped: error.executionStopped,
          mayHaveLateEffects: error.mayHaveLateEffects,
          pageResponsive: error.pageResponsive
        };
        case 'EGO_NAVIGATION_TIMEOUT': return {
          code: error.code, timeoutMs: error.timeoutMs,
          committed: error.committed, waitUntil: error.waitUntil,
          ...(error.url === undefined ? {} : {url: error.url}),
          ...(error.readyState === undefined ? {} : {readyState: error.readyState})
        };
        default: return undefined;
      }
    })();
    return {
      completed, effectStarted, completedEffect, inputReleased,
      ...(pages === null ? {} : {pages}),
      ...(pendingAction === null ? {} : {pendingAction}),
      failure: {index, method, message: String(error?.message ?? error),
        ...(nativeError === undefined ? {} : {nativeError}),
        ...(method !== 'popupWait' ? {} : {eventError:{
          ...(typeof error?.name === 'string' ? {name:error.name} : {}),
          ...(typeof error?.code === 'string' ? {code:error.code} : {}),
          ...(typeof error?.timeoutMs === 'number' && Number.isFinite(error.timeoutMs) && error.timeoutMs >= 0
            ? {timeoutMs:error.timeoutMs} : {})}}), ...extra}
    };
  };
  let initialUrl;
  try { initialUrl = await page.url(); }
  catch (error) { return failure(0, 'initialUrl', error); }
  if (initialUrl !== args.expectedUrl)
    return failure(0, 'initialUrl', 'the tab is at ' + initialUrl + ', not at expectedUrl; read it again');
  if (hasPopup) {
    try {
      if (typeof watchPage !== 'function') throw new Error('popup workflow requires its fixed managed-Page download observer');
      const original = await canonicalPage(page); page = original.page;
      pages = {source:original.identity,current:original.identity,transitions:[]};
    } catch (error) { return failure(0, 'pageIdentity', error); }
  }
  for (let index = 0; index < args.steps.length; index++) {
    const step = args.steps[index];
    const options = step.options ?? {};
    const pointerOptions = {...options, label: args.cursor + (options.label ? ' · ' + options.label : '')};
    let receipt = null, effect = false, pageResult = false, holdingInput = false;
    try {
      switch (step.method) {
        case 'clickAndWaitForPopup': {
          // Always consume the SDK waiter, including trigger failure. There is
          // no documented cancellation API and no host timeout/race is added.
          let waiter;
          try {
            waiter = page.waitForEvent('popup', step.popupOptions);
          } catch (error) { return failure(index, 'popupPreflight', error); }
          const event = Promise.resolve(waiter).then(
            popup => ({ok:true,popup}), error => ({ok:false,error}));
          let triggerError;
          holdingInput = effect = effectStarted = true; inputReleased = false;
          try {
            receipt = await page.click(step.selector, pointerOptions);
            pendingAction = {index,method:step.method,receipt:receipt ?? null};
            completedEffect = true;
            inputReleased = receipt !== null && typeof receipt === 'object'
              && !Array.isArray(receipt) && !receipt.dialog;
          } catch (error) { triggerError = error; }
          const observed = await event;
          let acquired, identityError;
          if (observed.ok) {
            try {
              acquired = await canonicalPage(observed.popup);
              pages.transitions.push({index,source:pages.current,popup:acquired.identity,selected:false});
            } catch (error) { identityError = error; }
          }
          if (triggerError) return failure(index, step.method, triggerError);
          if (!inputReleased) return failure(index, step.method,
            'the popup trigger did not confirm input release; never replay it',
            receipt?.dialog ? {dialog:receipt.dialog} : {});
          if (!observed.ok) return failure(index, 'popupWait', observed.error);
          if (identityError) return failure(index, 'popupIdentity', identityError);
          watchPage(acquired.page, acquired.identity.label);
          pages.transitions[pages.transitions.length - 1].selected = true;
          pages.current = acquired.identity; page = acquired.page;
          pendingAction = null;
          break;
        }
        case 'click':
          holdingInput = effect = effectStarted = true; inputReleased = false;
          receipt = await page.click(step.selector, pointerOptions); break;
        case 'dblclick':
          holdingInput = effect = effectStarted = true; inputReleased = false;
          receipt = await page.dblclick(step.selector, pointerOptions); break;
        case 'hover': effect = effectStarted = true; receipt = await page.hover(step.selector, pointerOptions); break;
        case 'dragAndDrop':
          holdingInput = effect = effectStarted = true; inputReleased = false;
          receipt = await page.dragAndDrop(step.selector, step.destination, pointerOptions);
          break;
        case 'mouse.click':
          holdingInput = effect = effectStarted = true; inputReleased = false;
          receipt = await page.mouse.click(step.x, step.y, pointerOptions); break;
        case 'mouse.move': effect = effectStarted = true; receipt = await page.mouse.move(step.x, step.y, pointerOptions); break;
        case 'mouse.wheel': effect = effectStarted = true; receipt = await page.mouse.wheel(step.x, step.y, pointerOptions); break;
        case 'fill': effect = effectStarted = true; receipt = await page.fill(step.selector, step.text, options); break;
        case 'press':
          // This SDK selector wait is read-only. Failure is before this press;
          // a failure of the later press itself remains uncertain.
          try {
            await page.waitForSelector(step.selector, {
              state: 'attached', ...(options.timeout === undefined ? {} : {timeout: options.timeout})
            });
          } catch (error) { return failure(index, 'inputPreflight', error); }
          holdingInput = effect = effectStarted = true; inputReleased = false;
          receipt = await page.press(step.selector, step.key, options); break;
        case 'focus': effect = effectStarted = true; receipt = await page.focus(step.selector, options); break;
        case 'reload': effect = effectStarted = true; receipt = await page.reload(options); break;
        case 'keyboard.type':
          holdingInput = effect = effectStarted = true; inputReleased = false;
          receipt = await page.keyboard.type(step.text, options); break;
        case 'keyboard.insertText': effect = effectStarted = true; receipt = await page.keyboard.insertText(step.text); break;
        case 'keyboard.paste':
          holdingInput = effect = effectStarted = true; inputReleased = false;
          receipt = await page.keyboard.paste(step.html === undefined ? step.text : {text: step.text, html: step.html});
          break;
        case 'keyboard.press':
          holdingInput = effect = effectStarted = true; inputReleased = false;
          receipt = await page.keyboard.press(step.key, options); break;
        case 'selectOption': {
          const selection = JSON.parse(step.selectionJson);
          effect = effectStarted = true;
          receipt = await page.selectOption(step.selector, selection, options); break;
        }
        case 'goto': effect = effectStarted = true; receipt = await page.goto(step.url, options); break;
        case 'waitForURL': {
          const matcher = step.urlRegex === undefined ? step.url
            : new RegExp(step.urlRegex.source, step.urlRegex.flags);
          await page.waitForURL(matcher, options); break;
        }
        case 'waitForSelector': await page.waitForSelector(step.selector, {...options, state: step.state}); break;
        case 'waitForLoadState': await page.waitForLoadState(step.state, options); break;
        case 'evaluate': {
          const expression = pageExpression(step);
          effect = effectStarted = pageResult = true;
          receipt = await page.evaluate(expression); break;
        }
        case 'waitForFunction': {
          const expression = pageExpression(step);
          effect = effectStarted = pageResult = true;
          receipt = await page.waitForFunction(expression, undefined, options); break;
        }
        case 'fetch': {
          effect = effectStarted = pageResult = true;
          if (options.saveAs === undefined) {
            receipt = await page.fetch(step.url, options); break;
          }
          // saveAs is a requested artifact filename, never a host pathname.
          // The native SDK writes the bytes; the existing download reader
          // verifies and brokers only a positively completed save.
          const id = crypto.randomUUID();
          const path = args.downloads + '/' + id;
          const registry = globalThis.mascDownloads ??= {
            since: new Date().toISOString(), rows: [], watched: new Set()
          };
          const row = {id, label: pages === null ? args.label : pages.current.label, source: 'fetch', url: step.url,
            suggestedFilename: options.saveAs, state: 'pending', path: null, reason: null};
          registry.rows.push(row);
          try {
            const saved = await page.fetch(step.url, {...options, saveAs: path});
            const fields = ['ok', 'status', 'statusText', 'url', 'headers', 'savedPath'];
            if (saved === null || typeof saved !== 'object' || Array.isArray(saved)
                || Object.keys(saved).length !== fields.length
                || !fields.every(key => Object.hasOwn(saved, key))
                || typeof saved.ok !== 'boolean' || !Number.isSafeInteger(saved.status) || saved.status < 0
                || typeof saved.statusText !== 'string' || typeof saved.url !== 'string'
                || saved.headers === null || typeof saved.headers !== 'object' || Array.isArray(saved.headers)
                || !Object.values(saved.headers).every(value => typeof value === 'string')
                || saved.savedPath !== path)
              throw new Error('Ego returned an invalid binary fetch receipt');
            const {savedPath, ...metadata} = saved;
            receipt = {...metadata, downloadId: id, suggestedFilename: options.saveAs, source: 'fetch'};
            row.url = saved.url;
            row.path = savedPath;
            row.state = 'completed';
          } catch (error) {
            row.state = 'interrupted'; row.reason = String(error?.message ?? error);
            throw error;
          }
          break;
        }
        case 'download.cancel': {
          const registry = globalThis.mascDownloads;
          const row = registry?.rows.find(row => row.id === step.downloadId && row.label === (pages === null ? args.label : pages.current.label)
            && row.source === 'native_download' && row.state === 'pending');
          const handle = registry?.handles?.get(step.downloadId);
          if (row === undefined || handle === undefined || handle.label !== (pages === null ? args.label : pages.current.label))
            return failure(index, 'downloadPreflight', 'no pending native Download handle on this Page; re-read downloads');
          effect = effectStarted = pageResult = true;
          await handle.download.cancel();
          receipt = {downloadId: step.downloadId, source: 'native_download', cancelReturned: true};
          break;
        }
        case 'url':
          receipt = await page.url();
          if (typeof receipt !== 'string') throw new Error('ego returned a non-text URL');
          break;
        case 'title':
          receipt = await page.title();
          if (typeof receipt !== 'string') throw new Error('ego returned a non-text title');
          break;
        case 'info':
          receipt = await page.info();
          if (receipt === null || typeof receipt !== 'object' || Array.isArray(receipt))
            throw new Error('ego returned non-object Page info');
          break;
        case 'snapshot':
          receipt = await page.snapshot(options);
          if (typeof receipt !== 'string') throw new Error('ego returned a non-text snapshot');
          break;
        case 'waitForTimeout': await page.waitForTimeout(step.milliseconds); break;
        case 'events':
          // Draining consumes observations even though it does not change the site.
          effect = effectStarted = pageResult = true;
          receipt = await page.events();
          if (!Array.isArray(receipt)) throw new Error('ego returned a non-array event buffer');
          break;
        default: return failure(index, step.method, 'unsupported native Page method');
      }
    } catch (error) {
      // The SDK's mouse.up can swallow a dialog interruption as normal void.
      // It also lacks the original selector click's coordinates on this Page
      // handle. Do not synthesize cleanup or treat that void as release proof.
      return failure(index, step.method, error);
    }
    if (holdingInput) {
      // The SDK's raw keyboard.type boundary can swallow a dialog interruption
      // into normal void. A later info() without a dialog cannot distinguish
      // that from completed typing, so do not complete this step or continue.
      if (receipt === null || typeof receipt !== 'object' || Array.isArray(receipt)) {
        let dialog;
        try { dialog = (await page.info()).dialog; }
        catch (error) { return failure(index, step.method, error); }
        return failure(index, step.method,
          'Ego returned no native action receipt; input release remains unconfirmed. Inspect this Space and use its private operator input-reset confirmation before another input. Never replay this step.',
          dialog ? {dialog} : {});
      }
      inputReleased = !receipt.dialog;
    }
    completedEffect ||= effect;
    completed.push({index, method: step.method, receipt: receipt ?? null});
    // Receipt-less non-holding effects can still open a dialog. Observe it
    // before dispatching another operation; this read never proves key-up.
    let dialog = pageResult ? null : receipt?.dialog;
    if (effect && (receipt == null || pageResult)) {
      try { dialog = (await page.info()).dialog; }
      catch (error) { return failure(index + 1, 'observation', error); }
    }
    if (dialog) return failure(index, step.method, 'answer the JavaScript dialog before continuing', {dialog});
  }
  try {
    const snapshot = await (args.snapshotScope === 'viewport'
      ? page.snapshot() : page.snapshot({scope: args.snapshotScope}));
    if (typeof snapshot !== 'string') throw new Error('ego answered a snapshot that is not text');
    let end = Math.min(args.maxChars, snapshot.length);
    if (end > 0 && end < snapshot.length && snapshot.charCodeAt(end - 1) >= 0xD800
        && snapshot.charCodeAt(end - 1) <= 0xDBFF && snapshot.charCodeAt(end) >= 0xDC00
        && snapshot.charCodeAt(end) <= 0xDFFF) end--;
    const url = await page.url(), title = await page.title();
    return {completed, effectStarted, completedEffect, inputReleased, failure: null, urlBefore: initialUrl, url, title,
      ...(pages === null ? {} : {pages}),
      snapshot: snapshot.slice(0, end), truncated: end < snapshot.length, chars: snapshot.length};
  } catch (error) { return failure(args.steps.length, 'snapshot', error); }
}|js}

type evaluation_timeout = {
  timeout_ms : float;
  execution_stopped : bool;
  may_have_late_effects : bool;
  page_responsive : bool;
}
type navigation_wait = Commit | Dom_content_loaded | Load | Network_idle
type navigation_timeout = {
  timeout_ms : float;
  committed : bool;
  url : string option;
  ready_state : string option;
  wait_until : navigation_wait;
}
type popup_event_error = { name : string option; code : string option; timeout_ms : float option }
type native_error = Evaluation_timed_out of evaluation_timeout
  | Navigation_timed_out of navigation_timeout | Popup_event_failed of popup_event_error
module Release = Browser_ego_release
type page_identity = { space_id : int; label : string; target_id : string;
  opened_by : Browser_surface.ego_page_origin }
type transition = { index : int; source : page_identity; popup : page_identity; selected : bool }
type pages = { source : page_identity; current : page_identity; transitions : transition list }
type outcome =
  | Completed of { reply : Yojson.Safe.t; input : Release.settled; pages : pages option }
  | Stopped of { receipt : Yojson.Safe.t; message : string;
      effect_started : bool; completed_effect : bool; input : Release.t;
      native_error : native_error option; pages : pages option }
open Result.Syntax
let object_fields allowed = function
  | `Assoc fields when List.for_all (fun (key,_) -> List.mem key allowed) fields
      && List.length fields=List.length (List.sort_uniq String.compare (List.map fst fields)) -> Ok fields
  | _ -> Error "invalid native workflow receipt fields"
let get key fields = Option.to_result ~none:("workflow receipt lacks " ^ key) (List.assoc_opt key fields)
let text key fields = let* value=get key fields in match value with `String text -> Ok text
  | _ -> Error ("workflow receipt has invalid " ^ key)
let bool key fields = let* value=get key fields in match value with `Bool value -> Ok value
  | _ -> Error ("workflow receipt has invalid " ^ key)
let integer key fields = let* value=get key fields in match value with `Int value when value>=0 -> Ok value
  | _ -> Error ("workflow receipt has invalid " ^ key)
let timeout_ms fields =
  let* timeout=get "timeoutMs" fields in
  match timeout with
  | `Int value when value>=0 -> Ok (float_of_int value)
  | `Float value when Float.is_finite value && value>=0. -> Ok value
  | _ -> Error "invalid native timeout"
let optional_text key fields = match List.assoc_opt key fields with
  | None -> Ok None
  | Some (`String value) -> Ok (Some value)
  | Some _ -> Error ("invalid native " ^ key ^ " observation")
let native_error fields = match List.assoc_opt "eventError" fields,List.assoc_opt "nativeError" fields with
  | Some value,None ->
    let* fields=object_fields ["name";"code";"timeoutMs"] value in
    let* name=optional_text "name" fields in let* code=optional_text "code" fields in
    let* timeout_ms=match List.assoc_opt "timeoutMs" fields with
      | None -> Ok None | Some _ -> timeout_ms fields |> Result.map Option.some in
    Ok (Some (Popup_event_failed {name;code;timeout_ms}))
  | Some _,Some _ -> Error "popup event failure cannot claim another native error"
  | None,value -> match value with
  | None -> Ok None
  | Some value ->
    let* code=match value with `Assoc fields -> text "code" fields
      | _ -> Error "native error is not an object" in
    match code with
    | "EGO_PAGE_EVALUATION_TIMED_OUT" ->
    let* fields=object_fields ["code";"timeoutMs";"executionStopped";"mayHaveLateEffects";"pageResponsive"] value in
    let* timeout_ms=timeout_ms fields in
    let* execution_stopped=bool "executionStopped" fields in
    let* may_have_late_effects=bool "mayHaveLateEffects" fields in
    let* page_responsive=bool "pageResponsive" fields in
    Ok (Some (Evaluation_timed_out {timeout_ms;execution_stopped;may_have_late_effects;page_responsive}))
    | "EGO_NAVIGATION_TIMEOUT" ->
    let* fields=object_fields ["code";"timeoutMs";"committed";"url";"readyState";"waitUntil"] value in
    let* timeout_ms=timeout_ms fields in let* committed=bool "committed" fields in
    let* url=optional_text "url" fields in let* ready_state=optional_text "readyState" fields in
    let* requested=text "waitUntil" fields in
    let* wait_until=match requested with
      | "commit" -> Ok Commit | "domcontentloaded" -> Ok Dom_content_loaded
      | "load" -> Ok Load | "networkidle" -> Ok Network_idle
      | _ -> Error "invalid native navigation lifecycle" in
    Ok (Some (Navigation_timed_out {timeout_ms;committed;url;ready_state;wait_until}))
    | _ -> Error "unsupported native workflow error code"
let saved_fetch_receipt filename value =
  let* fields=object_fields ["ok";"status";"statusText";"url";"headers";"downloadId";"suggestedFilename";"source"] value in
  let* _=bool "ok" fields in let* _=integer "status" fields in
  let* _=text "statusText" fields in let* _=text "url" fields in
  let* headers=get "headers" fields in
  let* ()=match headers with
    | `Assoc headers when List.length headers=List.length (List.sort_uniq String.compare (List.map fst headers))
        && List.for_all (function _,`String _ -> true | _,_ -> false) headers -> Ok ()
    | _ -> Error "invalid saved fetch headers" in
  let* id=text "downloadId" fields in
  let* ()=match Uuidm.of_string id with Some uuid when Uuidm.to_string uuid=id -> Ok ()
    | None|Some _ -> Error "invalid saved fetch download ID" in
  let* name=text "suggestedFilename" fields in let* source=text "source" fields in
  if name=filename && source="fetch" then Ok () else Error "saved fetch provenance does not match its request"
let observation_receipt (step:Browser_lane.Native_workflow.step) value =
  let module W = Browser_lane.Native_workflow in
  let* ()=match W.fetch_save_name step with None -> Ok () | Some filename -> saved_fetch_receipt filename value in
  let valid=match step.action with
    | W.Url|Title|Snapshot -> (match value with `String _ -> true | _ -> false)
    | Info -> (match value with `Assoc _ -> true | _ -> false)
    | Events -> (match value with `List _ -> true | _ -> false)
    | Wait_for_timeout _ -> value=`Null
    | Cancel_download id ->
      (match object_fields ["downloadId";"source";"cancelReturned"] value with
       | Error _ -> false
       | Ok fields -> List.length fields=3 && List.assoc_opt "downloadId" fields=Some (`String id)
           && List.assoc_opt "source" fields=Some (`String "native_download")
           && List.assoc_opt "cancelReturned" fields=Some (`Bool true))
    | Click _|Click_and_wait_for_popup _|Double_click _|Hover _|Drag_and_drop _|Mouse_click _|Mouse_move _|Mouse_wheel _
    | Fill _|Press _|Focus _|Reload|Keyboard_type _|Keyboard_insert_text _|Keyboard_paste _|Keyboard_press _
    | Select_option _|Goto _|Wait_for_url _|Wait_for_selector _|Wait_for_load_state _
    | Evaluate _|Wait_for_function _|Fetch _ -> true in
  if valid then Ok () else Error ("invalid native " ^ W.method_name step.action ^ " observation receipt")
let page_identity_of_json value =
  let* fields=object_fields ["spaceId";"label";"targetId";"openedBy"] value in
  let* space_id=integer "spaceId" fields in
  let* page=Browser_surface.ego_page_of_json (`Assoc (List.remove_assoc "spaceId" fields)) in
  match page.label with
  | Some label -> Ok {space_id;label;target_id=page.target_id;opened_by=page.opened_by}
  | None -> Error "workflow Page must remain managed"
let popup_step (step:Browser_lane.Native_workflow.step) = match step.action with
  | Click_and_wait_for_popup _ -> true
  | Click _|Double_click _|Hover _|Drag_and_drop _|Mouse_click _|Mouse_move _|Mouse_wheel _
  | Fill _|Press _|Focus _|Reload|Keyboard_type _|Keyboard_insert_text _|Keyboard_paste _|Keyboard_press _
  | Select_option _|Goto _|Wait_for_url _|Wait_for_selector _|Wait_for_load_state _
  | Evaluate _|Wait_for_function _|Fetch _|Cancel_download _|Url|Title|Info|Snapshot|Events|Wait_for_timeout _ -> false
let popup_at (request:Browser_lane.Native_workflow.t) index =
  match List.nth_opt request.steps index with Some step -> popup_step step | None -> false
let pages_of_json (request:Browser_lane.Native_workflow.t) ~count fields =
  match List.assoc_opt "pages" fields with
  | None -> Ok None
  | Some value ->
    let* ()=if List.exists popup_step request.steps then Ok () else Error "workflow declared unrequested Page transitions" in
    let* fields=object_fields ["source";"current";"transitions"] value in
    let page key=let* value=get key fields in page_identity_of_json value in
    let* source=page "source" in let* current=page "current" in
    let* rows=get "transitions" fields in
    let* rows=match rows with `List rows -> Ok rows | _ -> Error "workflow Page transitions must be an array" in
    let rec decode previous active acc = function
      | [] -> if active=current then Ok (List.rev acc) else Error "workflow current Page disagrees with its transitions"
      | value::rest ->
        let* fields=object_fields ["index";"source";"popup";"selected"] value in
        let* index=integer "index" fields in let* selected=bool "selected" fields in
        let* raw=get "source" fields in let* observed=page_identity_of_json raw in
        let* raw=get "popup" fields in let* popup=page_identity_of_json raw in
        let* ()=if index>previous && popup_at request index && observed=active
            && popup.space_id=source.space_id && popup.label<>active.label
            && popup.target_id<>active.target_id
            && (if selected then index<count else index=count && rest=[])
          then Ok () else Error "workflow popup identity or progress does not match the request" in
        let transition={index;source=observed;popup;selected} in
        decode index (if selected then popup else active) (transition::acc) rest in
    let* transitions=decode (-1) source [] rows in
    let* ()=if List.mapi (fun index step -> index,step) request.steps |> List.for_all (fun (index,step) ->
        index>=count || not (popup_step step) || List.exists (fun transition -> transition.index=index && transition.selected) transitions)
      then Ok () else Error "completed popup step has no canonical Page transition" in
    Ok (Some {source;current;transitions})
let pending_action (request:Browser_lane.Native_workflow.t) ~count fields =
  match List.assoc_opt "pendingAction" fields with
  | None -> Ok None
  | Some value ->
    let* fields=object_fields ["index";"method";"receipt"] value in
    let* index=integer "index" fields in let* method_=text "method" fields in
    let* receipt=get "receipt" fields in
    if index=count && method_="clickAndWaitForPopup" && popup_at request index
    then Ok (Some (index,Release.answer_of_json receipt))
    else Error "pending popup trigger does not match the request"
let receipts_do_not_show reason =
  "workflow reports a released input that its receipts do not show: " ^ Release.describe reason
let decode (request : Browser_lane.Native_workflow.t) receipt =
  let* fields=object_fields ["completed";"effectStarted";"completedEffect";"inputReleased";"failure";"urlBefore";"url";"title";"snapshot";"truncated";"chars";"pages";"pendingAction"] receipt in
  let* started=bool "effectStarted" fields in let* completed_effect=bool "completedEffect" fields in
  let* input_released=bool "inputReleased" fields in
  let* ()=if input_released || (started && List.exists (fun (step : Browser_lane.Native_workflow.step) ->
      Browser_lane.Native_workflow.holds_input step.action) request.steps) then Ok ()
    else Error "workflow claims a held input without an input-holding effect" in
  let* raw=get "completed" fields in
  let* completed=match raw with `List values -> Ok values | _ -> Error "workflow completed is not an array" in
  let methods=List.map (fun (step : Browser_lane.Native_workflow.step) ->
    Browser_lane.Native_workflow.method_name step.action) request.steps in
  let method_at index = Option.to_result ~none:"workflow step index is outside the request" (List.nth_opt methods index) in
  let holds_at index = match List.nth_opt request.steps index with
    | Some step -> Browser_lane.Native_workflow.holds_input step.action | None -> false in
  (* [answers]: the SDK's answer for each input-holding step that returned, newest first. *)
  let rec progress index has_effect answers steps = function
    | [] -> Ok (index,has_effect,List.rev answers,steps)
    | value::rest ->
      let* row=object_fields ["index";"method";"receipt"] value in
      let* observed=integer "index" row in let* method_=text "method" row in let* receipt=get "receipt" row in
      let* expected=method_at index in
      if observed<>index || method_<>expected then Error "workflow completed steps do not match the request"
      else match steps with
        | [] -> Error "workflow completed more steps than requested"
        | (step : Browser_lane.Native_workflow.step)::steps ->
          let* ()=observation_receipt step receipt in
          let answers=if Browser_lane.Native_workflow.holds_input step.action
            then (index,Release.answer_of_json receipt)::answers else answers in
          progress (index+1) (has_effect || Browser_lane.Native_workflow.is_effect step.action) answers steps rest in
  let* count,has_effect,answers,remaining=progress 0 false [] request.steps completed in
  let* pending=pending_action request ~count fields in
  let* pages=pages_of_json request ~count fields in
  let* ()=if (not started || not (List.exists popup_step request.steps) || Option.is_some pages) then Ok ()
    else Error "started popup workflow omitted its source Page identity" in
  let* ()=if completed_effect=(has_effect || Option.is_some pending) && (not completed_effect || started) then Ok ()
    else Error "workflow effect flags do not match completed steps" in
  let* failure=get "failure" fields in
  match failure with
  | `Null ->
    let* ()=if remaining=[] && pending=None && started=has_effect && input_released then Ok () else Error "workflow success omitted requested steps or input release" in
    let* input=match Release.judge answers with
      | Release.Settled settled -> Ok settled
      | Release.Unconfirmed reason -> Error (receipts_do_not_show reason) in
    let* url_before=text "urlBefore" fields in
    let* ()=if url_before=request.expected_url then Ok () else Error "workflow starting URL does not match request" in
    let* _=text "url" fields in let* _=text "title" fields in let* _=text "snapshot" fields in
    let* truncated=bool "truncated" fields in let* chars=integer "chars" fields in
    let* ()=if truncated=(chars>request.max_chars) then Ok () else Error "workflow snapshot cut flags disagree" in
    Ok (Completed {reply=receipt; input;pages})
  | `Assoc _ ->
    let* failed=object_fields ["index";"method";"message";"dialog";"nativeError";"eventError"] failure in
    let* index=integer "index" failed in let* method_=text "method" failed in let* message=text "message" failed in
    let* ()=if not (List.mem_assoc "eventError" failed) || method_="popupWait" then Ok ()
      else Error "popup event diagnostics do not match the failed operation" in
    let* native_error=native_error failed in
    (* [entered]: when the failed step holds input, what the SDK did not give for it: no answer, or a dialog. *)
    let* expected_started,entered=match method_ with
      | ("initialUrl"|"pageIdentity") when index=0 && count=0 && pending=None -> Ok (false,None)
      | "popupPreflight" when index=count && pending=None && popup_at request index -> Ok (has_effect,None)
      | ("popupWait"|"popupIdentity") when index=count && Option.is_some pending && popup_at request index -> Ok (true,None)
      | "downloadPreflight" when index=count ->
        (match remaining with
         | [] -> Error "workflow download preflight is outside the request"
         | step :: _ ->
           match step.action with
           | Browser_lane.Native_workflow.Cancel_download _ -> Ok (has_effect,None)
           | Click _ | Click_and_wait_for_popup _ | Double_click _ | Hover _ | Drag_and_drop _ | Mouse_click _
           | Mouse_move _ | Mouse_wheel _ | Fill _ | Press _ | Focus _ | Reload
           | Keyboard_type _ | Keyboard_insert_text _ | Keyboard_paste _ | Keyboard_press _
           | Select_option _ | Goto _ | Wait_for_url _ | Wait_for_selector _
           | Wait_for_load_state _ | Evaluate _ | Wait_for_function _ | Fetch _
           | Url | Title | Info | Snapshot | Events | Wait_for_timeout _ ->
             Error "workflow download preflight does not match a pending cancellation")
      | "inputPreflight" when index=count ->
        (match remaining with
         | [] -> Error "workflow input preflight is outside the request"
         | step :: _ ->
           match step.action with
           | Browser_lane.Native_workflow.Press _ -> Ok (has_effect,None)
           | Click _ | Click_and_wait_for_popup _ | Double_click _ | Hover _ | Drag_and_drop _ | Mouse_click _
           | Mouse_move _ | Mouse_wheel _ | Fill _ | Focus _ | Reload
           | Keyboard_type _ | Keyboard_insert_text _ | Keyboard_paste _ | Keyboard_press _
           | Select_option _ | Goto _ | Wait_for_url _ | Wait_for_selector _
           | Wait_for_load_state _ | Evaluate _ | Wait_for_function _ | Fetch _ | Cancel_download _
           | Url | Title | Info | Snapshot | Events | Wait_for_timeout _ ->
             Error "workflow input preflight does not match a pending press")
      | "observation" when index=count && count>0 -> Ok (has_effect,None)
      | "snapshot" when index=count && remaining=[] -> Ok (has_effect,None)
      | _ ->
        let* expected=method_at index in
        if expected<>method_ then Error "workflow failed method does not match its step"
        else if index=count then
          (match remaining with
           | step::_ -> Ok (has_effect || Browser_lane.Native_workflow.is_effect step.action,
               if Browser_lane.Native_workflow.holds_input step.action && pending=None then Some (index,Release.of_unreleased Release.Never_returned) else None)
           | [] -> Error "workflow failed step is outside request")
        else if index+1=count && List.mem_assoc "dialog" failed then
          Ok (has_effect,if holds_at index then Some (index,Release.of_unreleased Release.Receipt_with_dialog) else None)
        else Error "workflow failure index does not match progress" in
    let* ()=if started=expected_started then Ok () else Error "workflow failed-step effect flag disagrees" in
    (* The failed step is one more answer for the same rule as the completed ones. *)
    let judged=Release.judge (answers @ Option.to_list pending @ Option.to_list entered) in
    let* input=match input_released,judged with
      | true,Release.Settled _ -> Ok judged
      | true,Release.Unconfirmed reason -> Error (receipts_do_not_show reason)
      | false,Release.Unconfirmed _ -> Ok judged
      | false,Release.Settled _ -> Ok (Release.Unconfirmed Release.Held_by_script_report) in
    Ok (Stopped {receipt;message;effect_started=started;completed_effect;input;native_error;pages})
  | _ -> Error "workflow failure must be null or an object"

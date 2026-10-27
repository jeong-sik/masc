let script = {js|async function nativeWorkflow(page, args) {
  const completed = [];
  // These strings are evaluated only by the SDK's browser Page channel.
  // Never eval, import, or compile a caller's source in this Node process.
  const pageExpression = step => step.argumentJson === undefined ? step.source
    : '(' + step.source + ')(JSON.parse(' + JSON.stringify(step.argumentJson) + '))';
  let effectStarted = false, completedEffect = false;
  let inputReleased = true;
  const failure = (index, method, error, extra = {}) => ({
    completed, effectStarted, completedEffect, inputReleased,
    failure: {index, method, message: String(error?.message ?? error), ...extra}
  });
  // A selector gesture whose target the SDK cannot resolve (no match, hidden,
  // disabled, obscured, invalid selector) throws a typed ElementResolutionError.
  // Those gestures resolve the target before the first press and between
  // complete press and release pairs, never between a press and its release,
  // so nothing is held when this error arrives. Any other error is unknown.
  const selectorGestures = new Set(['click', 'dblclick', 'dragAndDrop', 'press']);
  const refusedByTarget = error => error?.name === 'ElementResolutionError'
    && (error.kind === 'transient' || error.kind === 'permanent');
  // The SDK buffers the Page's CDP events until someone reads them, and
  // page.events() hands them over and clears the buffer. Typing needs that
  // record to tell completion from a dialog interruption, so what this script
  // reads for itself is parked here for the Keeper's own events step. The
  // backlog is per Page label, lives as long as this process and keeps the
  // newest 10000 events, the size of the SDK's own buffer.
  const sdkEventBufferSize = 10000;
  const eventBacklog = globalThis.mascPageEvents ??= new Map();
  const readEvents = async () => {
    const fresh = await page.events();
    if (!Array.isArray(fresh)) throw new Error('ego returned a non-array event buffer');
    if (fresh.length > 0)
      eventBacklog.set(args.label, (eventBacklog.get(args.label) ?? []).concat(fresh).slice(-sdkEventBufferSize));
    return fresh;
  };
  let initialUrl;
  try { initialUrl = await page.url(); }
  catch (error) { return failure(0, 'initialUrl', error); }
  if (initialUrl !== args.expectedUrl)
    return failure(0, 'initialUrl', 'the tab is at ' + initialUrl + ', not at expectedUrl; read it again');
  for (let index = 0; index < args.steps.length; index++) {
    const step = args.steps[index];
    const options = step.options ?? {};
    const pointerOptions = {...options, label: args.cursor + (options.label ? ' · ' + options.label : '')};
    let receipt = null, effect = false, pageResult = false, holdingInput = false;
    try {
      switch (step.method) {
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
          // Typing is judged by the dialog-open events it leaves behind, so
          // park what is buffered now and the events read afterwards are this
          // step's own. Nothing is typed until this read succeeds, so a failed
          // read leaves the input released.
          effect = effectStarted = true;
          try { await readEvents(); }
          catch (error) { return failure(index, step.method, error); }
          holdingInput = true; inputReleased = false;
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
        case 'waitForURL': await page.waitForURL(step.url, options); break;
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
          const row = {id, label: args.label, source: 'fetch', url: step.url,
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
          await readEvents();
          receipt = eventBacklog.get(args.label) ?? [];
          eventBacklog.delete(args.label);
          break;
        default: return failure(index, step.method, 'unsupported native Page method');
      }
    } catch (error) {
      // The SDK's mouse.up can swallow a dialog interruption as normal void.
      // It also lacks the original selector click's coordinates on this Page
      // handle. Do not synthesize cleanup or treat that void as release proof.
      // A refused target is the exception: no press is outstanding.
      if (holdingInput && selectorGestures.has(step.method) && refusedByTarget(error)) inputReleased = true;
      return failure(index, step.method, error);
    }
    if (holdingInput) {
      if (receipt === null || typeof receipt !== 'object' || Array.isArray(receipt)) {
        // The SDK's raw keyboard boundary answers void when typing ran to its
        // end and also when a dialog interrupted it, and a dialog closed
        // before info() leaves nothing for info() to show. The dialog-open
        // event stays in the event buffer, so its absence proves that typing
        // was not interrupted. Every other holding method answers a receipt,
        // and a value that is neither void nor a receipt is not the SDK's
        // answer; without a receipt nothing is proven.
        const sdkVoid = step.method === 'keyboard.type' && receipt == null;
        let dialog, opened = false;
        try {
          if (sdkVoid)
            opened = (await readEvents()).some(event => event?.method === 'Page.javascriptDialogOpening');
          dialog = (await page.info()).dialog;
        } catch (error) { return failure(index, step.method, error); }
        if (!sdkVoid)
          return failure(index, step.method,
            'Ego returned no native action receipt; input release remains unconfirmed. Inspect this Space and use its private operator input-reset confirmation before another input. Never replay this step.',
            dialog ? {dialog} : {});
        if (opened || dialog)
          return failure(index, step.method,
            dialog ? 'a JavaScript dialog interrupted typing; answer it before continuing'
              : 'a JavaScript dialog interrupted typing and is already closed',
            dialog ? {dialog} : {});
        inputReleased = true;
      } else inputReleased = !receipt.dialog;
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
      snapshot: snapshot.slice(0, end), truncated: end < snapshot.length, chars: snapshot.length};
  } catch (error) { return failure(args.steps.length, 'snapshot', error); }
}|js}

type outcome = Completed of Yojson.Safe.t
  | Stopped of { receipt : Yojson.Safe.t; message : string;
      effect_started : bool; completed_effect : bool; input_released : bool }
let ( let* ) = Result.bind
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
    | Click _|Double_click _|Hover _|Drag_and_drop _|Mouse_click _|Mouse_move _|Mouse_wheel _
    | Fill _|Press _|Focus _|Reload|Keyboard_type _|Keyboard_insert_text _|Keyboard_paste _|Keyboard_press _
    | Select_option _|Goto _|Wait_for_url _|Wait_for_selector _|Wait_for_load_state _
    | Evaluate _|Wait_for_function _|Fetch _ -> true in
  if valid then Ok () else Error ("invalid native " ^ W.method_name step.action ^ " observation receipt")
let decode (request : Browser_lane.Native_workflow.t) receipt =
  let* fields=object_fields ["completed";"effectStarted";"completedEffect";"inputReleased";"failure";"urlBefore";"url";"title";"snapshot";"truncated";"chars"] receipt in
  let* started=bool "effectStarted" fields in let* completed_effect=bool "completedEffect" fields in
  let* input_released=bool "inputReleased" fields in
  let* ()=if input_released || (started && List.exists (fun (step : Browser_lane.Native_workflow.step) ->
      Browser_lane.Native_workflow.holds_input step.action) request.steps) then Ok ()
    else Error "workflow claims a held input without a input-holding effect" in
  let* raw=get "completed" fields in
  let* completed=match raw with `List values -> Ok values | _ -> Error "workflow completed is not an array" in
  let methods=List.map (fun (step : Browser_lane.Native_workflow.step) ->
    Browser_lane.Native_workflow.method_name step.action) request.steps in
  let method_at index = Option.to_result ~none:"workflow step index is outside the request" (List.nth_opt methods index) in
  let rec progress index has_effect steps = function
    | [] -> Ok (index,has_effect,steps)
    | value::rest ->
      let* row=object_fields ["index";"method";"receipt"] value in
      let* observed=integer "index" row in let* method_=text "method" row in let* receipt=get "receipt" row in
      let* expected=method_at index in
      if observed<>index || method_<>expected then Error "workflow completed steps do not match the request"
      else match steps with
        | [] -> Error "workflow completed more steps than requested"
        | (step : Browser_lane.Native_workflow.step)::steps ->
          let* ()=observation_receipt step receipt in
          progress (index+1) (has_effect || Browser_lane.Native_workflow.is_effect step.action) steps rest in
  let* count,has_effect,remaining=progress 0 false request.steps completed in
  let* ()=if completed_effect=has_effect && (not has_effect || started) then Ok ()
    else Error "workflow effect flags do not match completed steps" in
  let* failure=get "failure" fields in
  match failure with
  | `Null ->
    let* ()=if remaining=[] && started=has_effect && input_released then Ok () else Error "workflow success omitted requested steps or input release" in
    let* url_before=text "urlBefore" fields in
    let* ()=if url_before=request.expected_url then Ok () else Error "workflow starting URL does not match request" in
    let* _=text "url" fields in let* _=text "title" fields in let* _=text "snapshot" fields in
    let* truncated=bool "truncated" fields in let* chars=integer "chars" fields in
    let* ()=if truncated=(chars>request.max_chars) then Ok () else Error "workflow snapshot cut flags disagree" in
    Ok (Completed receipt)
  | `Assoc _ ->
    let* failed=object_fields ["index";"method";"message";"dialog"] failure in
    let* index=integer "index" failed in let* method_=text "method" failed in let* message=text "message" failed in
    let* expected_started=match method_ with
      | "initialUrl" when index=0 && count=0 -> Ok false
      | "inputPreflight" when index=count ->
        (match remaining with
         | [] -> Error "workflow input preflight is outside the request"
         | step :: _ ->
           match step.action with
           | Browser_lane.Native_workflow.Press _ -> Ok has_effect
           | Click _ | Double_click _ | Hover _ | Drag_and_drop _ | Mouse_click _
           | Mouse_move _ | Mouse_wheel _ | Fill _ | Focus _ | Reload
           | Keyboard_type _ | Keyboard_insert_text _ | Keyboard_paste _ | Keyboard_press _
           | Select_option _ | Goto _ | Wait_for_url _ | Wait_for_selector _
           | Wait_for_load_state _ | Evaluate _ | Wait_for_function _ | Fetch _
           | Url | Title | Info | Snapshot | Events | Wait_for_timeout _ ->
             Error "workflow input preflight does not match a pending press")
      | "observation" when index=count && count>0 -> Ok has_effect
      | "snapshot" when index=count && remaining=[] -> Ok has_effect
      | _ ->
        let* expected=method_at index in
        if expected<>method_ then Error "workflow failed method does not match its step"
        else if index=count then
          (match remaining with step::_ -> Ok (has_effect || Browser_lane.Native_workflow.is_effect step.action)
           | [] -> Error "workflow failed step is outside request")
        else if index+1=count && List.mem_assoc "dialog" failed then Ok has_effect
        else Error "workflow failure index does not match progress" in
    let* ()=if started=expected_started then Ok () else Error "workflow failed-step effect flag disagrees" in
    Ok (Stopped {receipt;message;effect_started=started;completed_effect;input_released})
  | _ -> Error "workflow failure must be null or an object"

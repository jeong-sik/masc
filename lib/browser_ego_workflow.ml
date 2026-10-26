let script = {js|async function nativeWorkflow(page, args) {
  const completed = [];
  // These strings are evaluated only by the SDK's browser Page channel.
  // Never eval, import, or compile a caller's source in this Node process.
  const pageExpression = step => step.argumentJson === undefined ? step.source
    : '(' + step.source + ')(JSON.parse(' + JSON.stringify(step.argumentJson) + '))';
  let effectStarted = false, completedEffect = false;
  let inputReleased = true, heldButton = null;
  const failure = (index, method, error, extra = {}) => ({
    completed, effectStarted, completedEffect, inputReleased,
    failure: {index, method, message: String(error?.message ?? error), ...extra}
  });
  let initialUrl;
  try { initialUrl = await page.url(); }
  catch (error) { return failure(0, 'initialUrl', error); }
  if (initialUrl !== args.expectedUrl)
    return failure(0, 'initialUrl', 'the tab is at ' + initialUrl + ', not at expectedUrl; read it again');
  for (let index = 0; index < args.steps.length; index++) {
    const step = args.steps[index];
    const options = step.options ?? {};
    const pointerOptions = {...options, label: args.cursor + (options.label ? ' · ' + options.label : '')};
    heldButton = null;
    let receipt = null, effect = false, pageResult = false, holdingInput = false;
    try {
      switch (step.method) {
        case 'click':
          holdingInput = effect = effectStarted = true; inputReleased = false; heldButton = options.button ?? 'left';
          receipt = await page.click(step.selector, pointerOptions); inputReleased = !receipt?.dialog; break;
        case 'dblclick':
          holdingInput = effect = effectStarted = true; inputReleased = false; heldButton = options.button ?? 'left';
          receipt = await page.dblclick(step.selector, pointerOptions); inputReleased = !receipt?.dialog; break;
        case 'hover': effect = effectStarted = true; receipt = await page.hover(step.selector, pointerOptions); break;
        case 'dragAndDrop':
          holdingInput = effect = effectStarted = true; inputReleased = false; heldButton = options.button ?? 'left';
          receipt = await page.dragAndDrop(step.selector, step.destination, pointerOptions);
          inputReleased = !receipt?.dialog; break;
        case 'mouse.click':
          holdingInput = effect = effectStarted = true; inputReleased = false; heldButton = options.button ?? 'left';
          receipt = await page.mouse.click(step.x, step.y, pointerOptions); inputReleased = !receipt?.dialog; break;
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
          receipt = await page.press(step.selector, step.key, options); inputReleased = !receipt?.dialog; break;
        case 'focus': effect = effectStarted = true; receipt = await page.focus(step.selector, options); break;
        case 'reload': effect = effectStarted = true; receipt = await page.reload(options); break;
        case 'keyboard.type':
          holdingInput = effect = effectStarted = true; inputReleased = false;
          receipt = await page.keyboard.type(step.text, options); inputReleased = !receipt?.dialog; break;
        case 'keyboard.insertText': effect = effectStarted = true; receipt = await page.keyboard.insertText(step.text); break;
        case 'keyboard.paste':
          effect = effectStarted = true;
          receipt = await page.keyboard.paste(step.html === undefined ? step.text : {text: step.text, html: step.html}); break;
        case 'keyboard.press':
          holdingInput = effect = effectStarted = true; inputReleased = false;
          receipt = await page.keyboard.press(step.key, options); inputReleased = !receipt?.dialog; break;
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
        case 'fetch':
          effect = effectStarted = pageResult = true;
          receipt = await page.fetch(step.url, options); break;
        default: return failure(index, step.method, 'unsupported native Page method');
      }
    } catch (error) {
      if (!inputReleased && heldButton !== null) {
        try { await page.mouse.up({button:heldButton}); inputReleased = true; }
        catch (releaseError) { return failure(index, step.method,
          String(error?.message ?? error) + '; input release unconfirmed: ' + String(releaseError?.message ?? releaseError)); }
      }
      return failure(index, step.method, error);
    }
    completedEffect ||= effect;
    completed.push({index, method: step.method, receipt: receipt ?? null});
    // Keyboard methods return no action receipt. Their input handlers can still
    // open a dialog, so observe it before dispatching the next operation.
    let dialog = pageResult ? null : receipt?.dialog;
    if (effect && (receipt == null || pageResult)) {
      if (holdingInput) inputReleased = false;
      try { dialog = (await page.info()).dialog; if (holdingInput) inputReleased = !dialog; }
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
      effect_started : bool; completed_effect : bool; input_released : bool;
      pending_pointer_release : Browser_lane.Native_workflow.pointer_button option }
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
      let* observed=integer "index" row in let* method_=text "method" row in let* _=get "receipt" row in
      let* expected=method_at index in
      if observed<>index || method_<>expected then Error "workflow completed steps do not match the request"
      else match steps with
        | [] -> Error "workflow completed more steps than requested"
        | (step : Browser_lane.Native_workflow.step)::steps -> progress (index+1) (has_effect || Browser_lane.Native_workflow.is_effect step.action) steps rest in
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
           | Wait_for_load_state _ | Evaluate _ | Wait_for_function _ | Fetch _ ->
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
    let pending_pointer_release =
      if input_released || index+1<>count then None
      else match List.assoc_opt "dialog" failed, List.nth_opt request.steps index with
        | Some (`Assoc _), Some step -> Browser_lane.Native_workflow.pointer_button step
        | (None|Some (`Null|`Bool _|`Int _|`Intlit _|`Float _|`String _|`List _)), _
        | Some (`Assoc _), None -> None in
    Ok (Stopped {receipt;message;effect_started=started;completed_effect;input_released;pending_pointer_release})
  | _ -> Error "workflow failure must be null or an object"

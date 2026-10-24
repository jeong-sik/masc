let script = {js|async function nativeWorkflow(page, args) {
  const completed = [];
  let effectStarted = false, completedEffect = false;
  const failure = (index, method, error, extra = {}) => ({
    completed, effectStarted, completedEffect,
    failure: {index, method, message: String(error?.message ?? error), ...extra}
  });
  let initialUrl;
  try { initialUrl = await page.url(); }
  catch (error) { return failure(0, 'initialUrl', error); }
  if (initialUrl !== args.expectedUrl)
    return failure(0, 'initialUrl', 'the tab is at ' + initialUrl + ', not at expectedUrl; read it again');
  for (let index = 0; index < args.steps.length; index++) {
    const step = args.steps[index];
    const options = step.timeoutMs === undefined ? {} : {timeout: step.timeoutMs};
    let receipt = null, effect = false;
    try {
      switch (step.method) {
        case 'click': effect = effectStarted = true; receipt = await page.click(step.selector, {...options, label: args.cursor}); break;
        case 'dblclick': effect = effectStarted = true; receipt = await page.dblclick(step.selector, {...options, label: args.cursor}); break;
        case 'hover': effect = effectStarted = true; receipt = await page.hover(step.selector, {...options, label: args.cursor}); break;
        case 'fill': effect = effectStarted = true; receipt = await page.fill(step.selector, step.text, options); break;
        case 'press': effect = effectStarted = true; receipt = await page.press(step.selector, step.key, options); break;
        case 'selectOption': {
          const selection = step.values === undefined ? {value: step.value} : step.values.map(value => ({value}));
          effect = effectStarted = true;
          receipt = await page.selectOption(step.selector, selection, options); break;
        }
        case 'goto': effect = effectStarted = true; receipt = await page.goto(step.url, options); break;
        case 'waitForURL': await page.waitForURL(step.url, options); break;
        case 'waitForSelector': await page.waitForSelector(step.selector, {...options, state: step.state}); break;
        case 'waitForLoadState': await page.waitForLoadState(step.state, options); break;
        default: return failure(index, step.method, 'unsupported native Page method');
      }
    } catch (error) { return failure(index, step.method, error); }
    completedEffect ||= effect;
    completed.push({index, method: step.method, receipt: receipt ?? null});
    // Do not run another Page method while a synchronous dialog blocks it.
    if (receipt?.dialog) return failure(index, step.method, 'answer the JavaScript dialog before continuing', {dialog: receipt.dialog});
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
    return {completed, effectStarted, completedEffect, failure: null, urlBefore: initialUrl, url, title,
      snapshot: snapshot.slice(0, end), truncated: end < snapshot.length, chars: snapshot.length};
  } catch (error) { return failure(args.steps.length, 'snapshot', error); }
}|js}

type outcome = Completed of Yojson.Safe.t
  | Stopped of { receipt : Yojson.Safe.t; message : string;
      effect_started : bool; completed_effect : bool }
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
  let* fields=object_fields ["completed";"effectStarted";"completedEffect";"failure";"urlBefore";"url";"title";"snapshot";"truncated";"chars"] receipt in
  let* started=bool "effectStarted" fields in let* completed_effect=bool "completedEffect" fields in
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
    let* ()=if remaining=[] && started=has_effect then Ok () else Error "workflow success omitted requested steps" in
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
    Ok (Stopped {receipt;message;effect_started=started;completed_effect})
  | _ -> Error "workflow failure must be null or an object"

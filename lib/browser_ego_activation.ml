let script = {js|async function activateNativeTab(task, args) {
  const states = ['normal', 'minimized', 'maximized', 'fullscreen'];
  // CDP Browser.Bounds.windowState is optional and documented as "Default to
  // normal"; only an absent field reads as normal.
  const stateOf = value => value.bounds.windowState === undefined ? 'normal' : value.bounds.windowState;
  const validWindow = value => value && Number.isSafeInteger(value.windowId) && value.windowId >= 0
    && value.bounds && states.includes(stateOf(value));
  let tab, before, origin;
  try {
    tab = (await task.tabs()).find(item => item.label === args.label);
    if (!tab) return {before:true, error:'browser tab is no longer present'};
    if (typeof tab.label !== 'string' || tab.label.trim() === ''
        || (tab.openedBy !== 'agent' && tab.openedBy !== 'unknown'))
      return {before:true, error:'activation requires a native managed Page'};
    if (tab.url !== args.expectedUrl) return {before:true, error:'the tab moved from expectedUrl; read it again'};
    if (typeof tab.targetId !== 'string' || !tab.targetId)
      return {before:true, error:'the native tab has no target identity'};
    const targetId = tab.targetId;
    origin = tab.openedBy;
    before = await task.cdp('Browser.getWindowForTarget', {targetId});
    if (!validWindow(before)) return {before:true, error:'invalid native window observation'};
    const currentWindow = await task.cdp('Browser.getWindowForTarget', {targetId});
    if (!validWindow(currentWindow)) return {before:true, error:'invalid current native window observation'};
    if (currentWindow.windowId !== before.windowId)
      return {before:true, error:'the native tab changed windows; read it again'};
    const currentTab = (await task.tabs()).find(item => item.label === args.label);
    if (!currentTab || currentTab.targetId !== targetId)
      return {before:true, error:'the native Page identity changed; read it again'};
    if (currentTab.openedBy !== origin)
      return {before:true, error:'the native Page origin changed; read it again'};
    if (currentTab.url !== args.expectedUrl)
      return {before:true, error:'the tab moved from expectedUrl; read it again'};
    tab = currentTab;
    before = currentWindow;
  } catch (error) {
    return {before:true, error:String(error && error.message || error)};
  }
  const restored = stateOf(before) === 'minimized';
  if (restored) await task.cdp('Browser.setWindowBounds', {
    windowId:before.windowId, bounds:{windowState:'normal'}});
  await task.cdp('Target.activateTarget', {targetId:tab.targetId});
  const after = await task.cdp('Browser.getWindowForTarget', {targetId:tab.targetId});
  const active = (await task.tabs()).find(item => item.targetId === tab.targetId);
  if (!validWindow(after) || after.windowId !== before.windowId
      || stateOf(after) === 'minimized' || !active || active.active !== true
      || active.label !== args.label || active.openedBy !== origin || active.url !== args.expectedUrl)
    throw new Error('native tab activation is unconfirmed; observe the same Space before another command');
  return {spaceId:task.spaceId, label:active.label, targetId:active.targetId,
    urlBefore:tab.url, url:active.url, title:active.title, active:true,
    window:{windowId:after.windowId, stateBefore:stateOf(before),
      stateAfter:stateOf(after), restored}};
}|js}

open Result.Syntax
(* JavaScript's Number.MAX_SAFE_INTEGER, the bound the script's
   Number.isSafeInteger check applies to the window id. *)
let max_safe_integer = 9007199254740991L
let exact names = function
  | `Assoc fields when List.sort String.compare (List.map fst fields) = List.sort String.compare names -> Ok fields
  | _ -> Error "invalid native activation observation fields"
let receipt ~space_id ~tab_id ~label ~expected_url value =
  let* fields=exact ["spaceId";"label";"targetId";"urlBefore";"url";"title";"active";"window"] value in
  let field key=List.assoc key fields in
  let* ()=if field "spaceId"=`Int space_id && field "label"=`String label
      && field "urlBefore"=`String expected_url && field "url"=`String expected_url
      && field "active"=`Bool true then Ok () else Error "native activation does not match the requested Page" in
  let* target_id=match field "targetId" with
    | `String id when String.trim id<>"" -> Ok id | _ -> Error "activation lacks native target identity" in
  let* title=match field "title" with `String title -> Ok title | _ -> Error "activation lacks page title" in
  let* window=exact ["windowId";"stateBefore";"stateAfter";"restored"] (field "window") in
  let* ()=match List.assoc "windowId" window with
    | `Int id when id>=0 && Int64.of_int id<=max_safe_integer -> Ok ()
    | _ -> Error "activation lacks native window identity" in
  let state = function
    | `String "normal" -> Ok `Normal | `String "minimized" -> Ok `Minimized
    | `String "maximized" -> Ok `Maximized | `String "fullscreen" -> Ok `Fullscreen
    | _ -> Error "invalid native window state" in
  let* before=state (List.assoc "stateBefore" window) in
  let* after=state (List.assoc "stateAfter" window) in
  let* ()=match before,after,List.assoc "restored" window with
    | `Minimized,(`Normal|`Maximized|`Fullscreen),`Bool true
    | (`Normal|`Maximized|`Fullscreen),(`Normal|`Maximized|`Fullscreen),`Bool false -> Ok ()
    | _ -> Error "native window restoration is unconfirmed" in
  Ok (`Assoc ["tabId",`Int tab_id;"action",`String "activate_tab";"spaceId",`Int space_id;
    "urlBefore",`String expected_url;"url",`String expected_url;"title",`String title;
    "active",`Bool true;"targetId",`String target_id;"window",`Assoc window])

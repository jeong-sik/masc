let script = {js|async function stopNativeLoading(task, args) {
  // Loading can prevent every Page observation. Only the Space inventory and
  // native managed Page identity are used before the recovery command.
  const tab = (await task.tabs()).find(row => row.label === args.label);
  if (!tab || typeof tab.targetId !== 'string' || tab.targetId === ''
      || (tab.openedBy !== 'agent' && tab.openedBy !== 'unknown'))
    return {ok:false,before:true,error:'the managed Page is no longer present; inspect the same Space'};
  const page = task.page(args.label);
  if (page.spaceId !== task.spaceId || page.label !== tab.label
      || page.targetId !== tab.targetId || page.openedBy !== tab.openedBy)
    return {ok:false,before:true,error:'native managed Page identity changed before recovery'};
  await page.cdp('Page.stopLoading');
  return {ok:true,value:{spaceId:task.spaceId,label:tab.label,targetId:tab.targetId,
    openedBy:tab.openedBy,method:'Page.stopLoading',returned:true}};
}|js}

open Result.Syntax
let receipt ~space_id ~tab_id ~label value =
  let* fields = match value with
    | `Assoc fields when List.sort String.compare (List.map fst fields) =
        List.sort String.compare ["spaceId";"label";"targetId";"openedBy";"method";"returned"] -> Ok fields
    | _ -> Error "invalid native loading recovery fields" in
  let field key = List.assoc key fields in
  let* () = if field "spaceId" = `Int space_id && field "label" = `String label
      && field "method" = `String "Page.stopLoading" && field "returned" = `Bool true
    then Ok () else Error "native loading recovery does not match the requested Page" in
  let* page = Browser_surface.ego_page_of_json (`Assoc [
      "label",field "label";"targetId",field "targetId";"openedBy",field "openedBy"])
    |> Result.map_error (fun detail -> "invalid native recovery Page identity: " ^ detail) in
  Ok (`Assoc ["action",`String "stop_loading";"tabId",`Int tab_id;
    "spaceId",`Int space_id;"egoPage",Browser_surface.ego_page_to_json page;
    "method",`String "Page.stopLoading";"returned",`Bool true])

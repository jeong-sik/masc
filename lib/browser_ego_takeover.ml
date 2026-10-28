let script = {js|
    if (task.spaceId !== args.spaceId) {
      emit({ok: false, before: true, error: 'the original Ego Space handle changed before takeover'});
    } else {
      const back = await takeOverTaskSpace(args.spaceId);
      if (back.spaceId !== args.spaceId || back.ownership !== 'agent'
          || typeof back.name !== 'string' || back.name.trim() === '')
        throw new Error('Ego returned a foreign or unreadable takeover Space');
      const boundary = back.userPage();
      let page = null;
      if (boundary !== undefined) {
        // Freeze the native user boundary before any later inventory read.
        const spaceId = boundary?.spaceId, targetId = boundary?.targetId;
        const label = boundary?.label ?? null, openedBy = boundary?.openedBy;
        if (spaceId !== args.spaceId || typeof targetId !== 'string' || targetId.trim() === ''
            || (label !== null && (typeof label !== 'string' || label.trim() === ''))
            || (openedBy !== 'agent' && openedBy !== 'unknown'))
          throw new Error('Ego returned an unreadable user-boundary Page');
        const tabs = await back.tabs();
        if (!Array.isArray(tabs)) throw new Error('Ego returned an unreadable takeover inventory');
        const matches = tabs.filter(row => row !== null && typeof row === 'object'
          && row.targetId === targetId);
        if (matches.length !== 1 || (matches[0].label ?? null) !== label
            || matches[0].openedBy !== openedBy)
          throw new Error('the user-boundary Page changed or disappeared; no replacement was selected');
        page = {label, targetId, openedBy};
      }
      emit({ok: true, value: {spaceId: back.spaceId, spaceName: back.name, page}});
    }
|js}

type t = { space : Browser_lane.ego_space; page : Browser_surface.ego_page option }
open Result.Syntax
let decode ~expected_id = function
  | `Assoc fields when List.sort String.compare (List.map fst fields)=["page";"spaceId";"spaceName"] ->
      let get key=Option.to_result ~none:("takeover receipt lacks " ^ key) (List.assoc_opt key fields) in
      let* id=get "spaceId" in let* name=get "spaceName" in
      let* space=Browser_lane.ego_space_of_json (`Assoc ["id",id;"name",name]) in
      let* ()=if space.id=expected_id then Ok () else Error "takeover receipt names a different Space" in
      let* value=get "page" in
      let* page=match value with
        | `Null -> Ok None
        | `Assoc _ -> Browser_surface.ego_page_of_json value |> Result.map Option.some
        | `Bool _|`Int _|`Intlit _|`Float _|`String _|`List _ -> Error "invalid takeover Page identity" in
      Ok {space;page}
  | `Null|`Bool _|`Int _|`Intlit _|`Float _|`String _|`List _|`Assoc _ ->
      Error "invalid or duplicate native takeover fields"

module Window = Browser_ego_native_window
open Result.Syntax
let ( >>= ) = Result.bind
type slot = {index:int;nonce:string;world_name:string;binding_name:string}
type context = {command_id:string;generation:string;original:Window.page;slots:slot list}
type cleanup = Not_attempted | Returned | Unconfirmed
type failure = {index:int;reason:Window.unconfirmed}
type outcome = Not_entered of failure | Entered_unconfirmed of failure
  | Completed of {expected:Window.expected;completion:Window.completion;cleanup:cleanup}
let source context = context.original
let expected context ~index ~current =
  let* slot = Option.to_result ~none:"native typing step is outside its fixed context"
    (List.find_opt (fun (slot:slot) -> slot.index=index) context.slots) in
  Window.prepare ~command_id:context.command_id ~generation:context.generation ~step_index:index
    ~source:context.original ~current ~nonce:slot.nonce ~world_name:slot.world_name ~binding_name:slot.binding_name
let prepare ~command_id ~generation ~source ~indices =
  match indices with
  | [] -> Error "invalid native typing step context"
  | first::_ ->
    if List.exists (fun index -> index<0) indices
        || List.length indices<>List.length (List.sort_uniq Int.compare indices)
    then Error "invalid native typing step context" else
    let slots=List.map (fun index ->
      let nonce=Random_id.hex ~bytes:16 in
      {index;nonce;world_name="masc.native.window." ^ nonce;binding_name="__mascNativeWindow_" ^ nonce}) indices in
    let context={command_id;generation;original=source;slots} in
    let* _=expected context ~index:first ~current:source in Ok context
let page_json (page:Window.page) = `Assoc (("spaceId",`Int page.space_id)::Browser_surface.ego_page_fields page.native)
let invocation context (slot:slot) = `Assoc ["commandId",`String context.command_id;
  "generation",`String context.generation;"stepIndex",`Int slot.index;"nonce",`String slot.nonce;
  "worldName",`String slot.world_name;"bindingName",`String slot.binding_name]
let arguments context =
  let contract=match context.slots with
    | [] -> `Null
    | first::_ -> (match expected context ~index:first.index ~current:context.original with
        | Ok expected -> Window.producer_contract expected | Error _ -> `Null) in
  `Assoc ["commandId",`String context.command_id;"generation",`String context.generation;
    "sourcePage",page_json context.original;"contract",contract;
    "slots",`List (List.map (fun (slot:slot) -> `Assoc ["index",`Int slot.index;"nonce",`String slot.nonce;
      "worldName",`String slot.world_name;"bindingName",`String slot.binding_name]) context.slots)]

let script = {js|async function nativeTypeWindow(task, page, binding, index, text, options, sourceIdentity, currentIdentity, guard) {
  const capture = {entered:false,phase:'page_identity',sourcePage:sourceIdentity,currentPage:currentIdentity,setup:{},cleanup:{kind:'not_attempted'}};
  const plain = value => value !== null && typeof value === 'object' && !Array.isArray(value);
  const nonblank = value => typeof value === 'string' && value.trim() !== '';
  const positive = value => Number.isInteger(value) && value > 0;
  const need = condition => { if (!condition) throw new Error('native input window is unconfirmed'); };
  let slot, contract, frame, context, session;
  const samePage = (one,two) => plain(one) && plain(two)
    && ['spaceId','label','targetId','openedBy'].every(key => one[key] === two[key]);
  const policy = event => contract.eventPolicies.find(row => row.method === event.method)?.kind ?? 'other';
  const nativeEvents = values => {
    need(Array.isArray(values));
    for (const event of values) need(plain(event) && nonblank(event.method)
      && Object.keys(event).every(key => ['method','params','sessionId'].includes(key))
      && (!Object.hasOwn(event,'sessionId') || nonblank(event.sessionId))
      && (!Object.hasOwn(event,'params') || plain(event.params)));
    return values;
  };
  const nativeContext = value => {
    need(plain(value) && positive(value.id) && nonblank(value.uniqueId)
      && typeof value.name === 'string' && typeof value.origin === 'string'
      && (!Object.hasOwn(value,'auxData') || plain(value.auxData)));
    if (value.auxData && Object.hasOwn(value.auxData,'frameId')) need(nonblank(value.auxData.frameId));
    return value;
  };
  const observed = event => {
    const kind=policy(event), params=event.params ?? {};
    if (!['target_destroyed','session_detached','other'].includes(kind)) need(nonblank(event.sessionId));
    switch (kind) {
      case 'binding': need(nonblank(params.name) && typeof params.payload === 'string' && positive(params.executionContextId)); break;
      case 'context_created': nativeContext(params.context); break;
      case 'context_destroyed': need(positive(params.executionContextId) && nonblank(params.executionContextUniqueId)); break;
      case 'nested_frame': need(plain(params.frame) && nonblank(params.frame.id)); break;
      case 'frame': need(nonblank(params.frameId)); break;
      case 'target_destroyed': need(nonblank(params.targetId)); break;
      case 'session_detached': need(nonblank(params.sessionId)); break;
    }
    return kind;
  };
  const invalidates = event => {
    const kind=observed(event), params=event.params ?? {}, same=event.sessionId === session;
    switch (kind) {
      case 'contexts_cleared': case 'dialog': case 'transport_lost': return same;
      case 'context_created': return same && (params.context.id === context.id
        || params.context.uniqueId === context.uniqueId || params.context.name === slot.worldName);
      case 'context_destroyed': return same && (params.executionContextId === context.id
        || params.executionContextUniqueId === context.uniqueId);
      case 'nested_frame': return same && params.frame.id === frame.id;
      case 'frame': return same && params.frameId === frame.id;
      case 'target_destroyed': return params.targetId === capture.currentPage.targetId;
      case 'session_detached': return params.sessionId === session;
      default: return false;
    }
  };
  const documentOf = value => {
    need(plain(value) && plain(value.frameTree) && plain(value.frameTree.frame));
    const root=value.frameTree.frame;
    need(nonblank(root.id) && nonblank(root.loaderId) && !Object.hasOwn(root,'parentId'));
    return {id:root.id,loaderId:root.loaderId};
  };
  const cdp = async (phase,key,method,params={}) => {
    capture.phase=phase;
    const reply=await page.cdp(method,params);
    need(plain(reply) && !Object.hasOwn(reply,'error'));
    capture.setup[key]=reply;
    return reply;
  };
  try {
    need(binding && plain(binding.contract) && Array.isArray(binding.slots));
    contract=binding.contract;
    const slots=binding.slots.filter(candidate => candidate.index === index);
    need(slots.length === 1); slot=slots[0];
    capture.invocation={commandId:binding.commandId,generation:binding.generation,stepIndex:index,
      nonce:slot.nonce,worldName:slot.worldName,bindingName:slot.bindingName};
    need(nonblank(slot.nonce) && nonblank(slot.worldName) && nonblank(slot.bindingName)
      && nonblank(binding.commandId) && nonblank(binding.generation)
      && samePage(sourceIdentity,binding.sourcePage) && sourceIdentity.spaceId === task.spaceId
      && currentIdentity.spaceId === task.spaceId && task.ownership === 'agent');
    const matches=(await task.tabs()).filter(row => row.label === currentIdentity.label);
    need(matches.length === 1);
    const row=matches[0], canonical=row.page;
    need(nonblank(row.targetId) && ['agent','unknown'].includes(row.openedBy) && canonical
      && canonical.spaceId === task.spaceId && canonical.label === row.label
      && canonical.targetId === row.targetId && canonical.openedBy === row.openedBy);
    const current={spaceId:task.spaceId,label:row.label,targetId:row.targetId,openedBy:row.openedBy};
    need(samePage(current,currentIdentity)); page=canonical;capture.currentPage=current;
    if (guard) {capture.phase='input_guard';await guard(page);}
    need(Object.keys(await cdp('page_enable','pageEnable','Page.enable')).length === 0);
    need(Object.keys(await cdp('runtime_enable','runtimeEnable','Runtime.enable')).length === 0);
    frame=documentOf(await cdp('frame_tree','frameTree','Page.getFrameTree'));
    const world=await cdp('isolated_world','isolatedWorld','Page.createIsolatedWorld',{frameId:frame.id,worldName:slot.worldName});
    need(positive(world.executionContextId));
    need(Object.keys(await cdp('add_binding','addBinding','Runtime.addBinding',
      {name:slot.bindingName,executionContextName:slot.worldName})).length === 0);
    capture.phase='bootstrap_events';
    const bootstrap=nativeEvents(await page.events());capture.setup.events=bootstrap;
    const contexts=[];
    for (let position=0;position<bootstrap.length;position++) {
      const event=bootstrap[position];
      if (policy(event) !== 'context_created') continue;
      const candidate=nativeContext(event.params?.context);
      if (candidate.id === world.executionContextId || candidate.name === slot.worldName) contexts.push({position,event,candidate});
    }
    need(contexts.length === 1);
    const selected=contexts[0];context=selected.candidate;session=selected.event.sessionId;
    need(context.id === world.executionContextId && context.name === slot.worldName && nonblank(session)
      && context.auxData?.frameId === frame.id && context.auxData?.isDefault === false && context.auxData?.type === 'isolated');
    for (let position=selected.position+1;position<bootstrap.length;position++) need(!invalidates(bootstrap[position]));
    const before=documentOf(await cdp('before_start','beforeStartFrameTree','Page.getFrameTree'));
    need(before.id === frame.id && before.loaderId === frame.loaderId);
    const canonicalPage = identity => Object.fromEntries(contract.pageMembers.map(key => [key,identity[key]]));
    const payload = bound => {
      const values={commandId:binding.commandId,generation:binding.generation,stepIndex:index,nonce:slot.nonce,
        sourcePage:canonicalPage(sourceIdentity),currentPage:canonicalPage(current),bound};
      return JSON.stringify(Object.fromEntries(contract.markerMembers.map(key => [key,values[key]])));
    };
    const start=payload('start'), end=payload('end');
    const marker = async (phase,key,value) => {
      capture.phase=phase;
      const expression='(()=>{globalThis['+JSON.stringify(slot.bindingName)+']('+JSON.stringify(value)+');return '+JSON.stringify(value)+';})()';
      const reply=await page.cdp('Runtime.evaluate',{expression,uniqueContextId:context.uniqueId,returnByValue:true,awaitPromise:false});
      capture[key]=reply;
      need(plain(reply) && Object.keys(reply).length === 1 && plain(reply.result)
        && Object.keys(reply.result).length === 2 && reply.result.type === 'string' && reply.result.value === value);
    };
    await marker('start_marker','startReply',start);
    capture.phase='raw_call';capture.entered=true;
    const answer=options === undefined ? await page.keyboard.type(text) : await page.keyboard.type(text,options);
    capture.returned=answer === undefined ? {returnKind:'void'} : {returnKind:'value',value:answer};
    need(answer === undefined);
    await marker('end_marker','endReply',end);
    capture.phase='interval_events';
    const interval=nativeEvents(await page.events());capture.events=interval;
    const starts=[],ends=[];
    for (let position=0;position<interval.length;position++) {
      const event=interval[position];
      if (policy(event) !== 'binding') continue;
      observed(event);
      const params=event.params;
      if (params.name !== slot.bindingName) continue;
      need(event.sessionId === session && params.executionContextId === context.id);
      if (params.payload === start) starts.push(position);
      else if (params.payload === end) ends.push(position);
      else need(false);
    }
    need(starts.length === 1 && ends.length === 1 && starts[0]<ends[0]);
    for (let position=starts[0]+1;position<ends[0];position++) need(!invalidates(interval[position]));
    capture.phase='captured';
  } catch (error) {return {status:'stopped',capture,error};}
  try {
    const reply=await page.cdp('Runtime.removeBinding',{name:slot.bindingName});
    capture.cleanup={kind:'returned',reply};
    if (!plain(reply) || Object.keys(reply).length !== 0) capture.cleanup={kind:'unconfirmed'};
  } catch (error) {capture.cleanup={kind:'unconfirmed'};return {status:'completed',capture,error};}
  return {status:'completed',capture};
}|js}

let fields allowed = function
  | `Assoc values when List.for_all (fun (name,_) -> List.mem name allowed) values
      && List.length values=List.length (List.sort_uniq String.compare (List.map fst values)) -> Ok values
  | _ -> Error "invalid private native typing capture"
let get name values = Option.to_result ~none:"incomplete private native typing capture" (List.assoc_opt name values)
let page value =
  let* values=fields ["spaceId";"label";"targetId";"openedBy"] value in
  let* space_id=match List.assoc_opt "spaceId" values with Some (`Int id) when id>0 -> Ok id
    | _ -> Error "invalid private native typing Page" in
  let* native=Browser_surface.ego_page_of_json (`Assoc (List.remove_assoc "spaceId" values)) in
  Ok {Window.space_id;native}
let pre_raw = function
  | "page_identity"|"input_guard"|"page_enable"|"runtime_enable"|"frame_tree"|"isolated_world"
  | "add_binding"|"bootstrap_events"|"before_start"|"start_marker" -> true
  | _ -> false
let cleanup values = match List.assoc_opt "cleanup" values with
  | Some (`Assoc ["kind",`String "not_attempted"]) -> Not_attempted
  | Some (`Assoc pairs) when List.sort String.compare (List.map fst pairs)=["kind";"reply"]
      && List.assoc_opt "kind" pairs=Some (`String "returned") && List.assoc_opt "reply" pairs=Some (`Assoc []) -> Returned
  | None | Some _ -> Unconfirmed
let decode context ~index ~current value =
  let invalid="invalid private native typing capture" in
  let* values=fields ["invocation";"entered";"phase";"sourcePage";"currentPage";"setup";"returned";"startReply";"endReply";"events";"cleanup"] value in
  let* slot=Option.to_result ~none:invalid (List.find_opt (fun (slot:slot) -> slot.index=index) context.slots) in
  let* observed_invocation=get "invocation" values >>= fields ["commandId";"generation";"stepIndex";"nonce";"worldName";"bindingName"] in
  let* ()=match invocation context slot with
    | `Assoc expected when List.sort compare observed_invocation=List.sort compare expected -> Ok ()
    | `Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _ | `List _ | `Assoc _ -> Error invalid in
  let* actual_source=get "sourcePage" values >>= page in
  let* actual_current=get "currentPage" values >>= page in
  let* expected=expected context ~index ~current in
  let* ()=if actual_source=context.original && actual_current=current then Ok () else Error invalid in
  let* entered=match List.assoc_opt "entered" values with Some (`Bool entered)->Ok entered|_ -> Error invalid in
  let* phase=match List.assoc_opt "phase" values with Some (`String phase)->Ok phase|_ -> Error invalid in
  if not entered then
    if pre_raw phase && not (List.exists (fun key -> List.mem_assoc key values) ["returned";"endReply";"events"])
    then Ok (Not_entered {index;reason=Window.Native_failure}) else Error invalid
  else if not (List.mem phase ["raw_call";"end_marker";"interval_events";"captured"]) then Error invalid
  else
    let classify () =
      let field key values=Result.map_error (fun _ -> `Missing) (get key values) in
      let object_ keys value=Result.map_error (fun _ -> `Missing) (fields keys value) in
      let* setup=field "setup" values >>= object_ ["pageEnable";"runtimeEnable";"frameTree";"isolatedWorld";"addBinding";"events";"beforeStartFrameTree"] in
      let* page_enable=field "pageEnable" setup in let* runtime_enable=field "runtimeEnable" setup in
      let* frame_tree=field "frameTree" setup in let* isolated_world=field "isolatedWorld" setup in
      let* add_binding=field "addBinding" setup in let* bootstrap_events=field "events" setup in
      let* before_start_frame_tree=field "beforeStartFrameTree" setup in
      let* bootstrap=Window.bootstrap ~expected ~page_enable ~runtime_enable ~frame_tree ~isolated_world
        ~add_binding ~events:bootstrap_events ~before_start_frame_tree |> Result.map_error (fun reason -> `Reason reason) in
      let* returned=field "returned" values in
      let* returned=match returned with
        | `Assoc ["returnKind",`String "void"] -> Ok Window.Void_return
        | `Assoc pairs when List.sort String.compare (List.map fst pairs)=["returnKind";"value"]
            && List.assoc_opt "returnKind" pairs=Some (`String "value") ->
          Result.map (fun value -> Window.Value_return value) (field "value" pairs)
        | _ -> Error `Missing in
      let* start_reply=field "startReply" values in let* end_reply=field "endReply" values in
      let* events=field "events" values in
      Window.classify bootstrap ~current ~returned ~start_reply ~end_reply ~events |> Result.map_error (fun reason -> `Reason reason) in
    (* Missing native observations after entry cannot prove no effect. Later
       cleanup is deliberately not part of the native classifier above. *)
    match classify () with
    | Ok completion -> Ok (Completed {expected;completion;cleanup=cleanup values})
    | Error (`Reason reason) -> Ok (Entered_unconfirmed {index;reason})
    | Error `Missing -> Ok (Entered_unconfirmed {index;reason=Window.Native_failure})
let public_failure (failure:failure) = Window.public_unconfirmed ~index:failure.index failure.reason

let failure_reason (failure:failure) = failure.reason

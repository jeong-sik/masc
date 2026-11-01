type page = { space_id : int; native : Browser_surface.ego_page }
type expected = {
  command_id : string; generation : string; step_index : int;
  source : page; current : page; nonce : string;
  world_name : string; binding_name : string;
}
type marker = Start | End
type phase = Page_enable | Runtime_enable | Frame_tree | Isolated_world
  | Add_binding | Bootstrap_events | Before_start | Start_marker | End_marker
  | Interval_events
type unconfirmed =
  | Malformed_native of { phase : phase; detail : string }
  | Context_or_session_changed | Document_changed
  | Bounds_missing_or_duplicated | Bounds_out_of_order | Dialog_opened
  | Unexpected_return | No_raw_call | Native_failure | Control_unavailable
  | Transport_unconfirmed | Cancelled | Page_binding_changed
type context = {
  id : int; unique_id : string; name : string;
  frame_id : string option; isolated : bool;
}
type event_kind =
  | Binding of { name : string; payload : string; context_id : int }
  | Context_created of context
  | Context_destroyed of { id : int; unique_id : string }
  | Contexts_cleared | Dialog | Frame_changed of string
  | Target_destroyed of string | Session_detached of string | Transport_lost
  | Other
type event = { session_id : string option; method_ : string; params : (string * Yojson.Safe.t) list }
type document = { frame_id : string; loader_id : string }
type bootstrap = {
  expected : expected; context : context; session_id : string;
  document : document; setup : Yojson.Safe.t;
}
type native_return = Void_return | Value_return of Yojson.Safe.t | Did_not_return of unconfirmed | Not_invoked
type completion = { expected : expected; observation : Yojson.Safe.t }

open Result.Syntax
let ( >>= ) = Result.bind

let nonblank text = String.trim text <> ""
let page_valid page = page.space_id > 0 && nonblank page.native.target_id
  && match page.native.label with Some label -> nonblank label | None -> false
let prepare ~command_id ~generation ~step_index ~source ~current ~nonce ~world_name ~binding_name =
  if List.for_all nonblank [command_id;generation;nonce;world_name;binding_name]
      && step_index >= 0 && page_valid source && page_valid current
      && source.space_id = current.space_id
  then Ok {command_id;generation;step_index;source;current;nonce;world_name;binding_name}
  else Error "invalid native input window command/Page binding"

let page_json page = `Assoc (("spaceId",`Int page.space_id)::Browser_surface.ego_page_fields page.native)
let marker_payload expected marker = Yojson.Safe.to_string (`Assoc [
  "commandId",`String expected.command_id; "generation",`String expected.generation;
  "stepIndex",`Int expected.step_index; "nonce",`String expected.nonce;
  "sourcePage",page_json expected.source; "currentPage",page_json expected.current;
  "bound",`String (match marker with Start -> "start" | End -> "end")])

let malformed phase detail = Error (Malformed_native {phase;detail})
let rec distinct_json = function
  | `Assoc fields ->
    let names = List.map fst fields in
    List.length names = List.length (List.sort_uniq String.compare names)
    && List.for_all (fun (_,value) -> distinct_json value) fields
  | `List values -> List.for_all distinct_json values
  | `Float value -> Float.is_finite value
  | `Null | `Bool _ | `Int _ | `Intlit _ | `String _ -> true
let object_ phase = function
  | `Assoc fields as value when distinct_json value -> Ok fields
  | `Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _ | `List _ | `Assoc _ ->
    malformed phase "expected an object without duplicate fields"
let get phase key fields = match List.assoc_opt key fields with
  | Some value -> Ok value | None -> malformed phase ("missing " ^ key)
let text phase key fields = match List.assoc_opt key fields with
  | Some (`String value) when nonblank value -> Ok value
  | None | Some _ -> malformed phase ("invalid " ^ key)
let integer phase key fields = match List.assoc_opt key fields with
  | Some (`Int value) when value > 0 -> Ok value
  | None | Some _ -> malformed phase ("invalid " ^ key)
let optional_text phase key fields = match List.assoc_opt key fields with
  | None -> Ok None
  | Some (`String value) when nonblank value -> Ok (Some value)
  | Some _ -> malformed phase ("invalid " ^ key)
let empty_response phase value =
  let* fields = object_ phase value in
  if fields = [] then Ok () else malformed phase "unexpected native response fields"
let root_document phase value =
  let* fields = object_ phase value in
  let* tree = get phase "frameTree" fields >>= object_ phase in
  let* frame = get phase "frame" tree >>= object_ phase in
  let* frame_id = text phase "id" frame in
  let* loader_id = text phase "loaderId" frame in
  if List.mem_assoc "parentId" frame then malformed phase "frame tree root is not a root frame"
  else Ok {frame_id;loader_id}
let context_of_json phase value =
  let* fields = object_ phase value in
  let* id = integer phase "id" fields in
  let* unique_id = text phase "uniqueId" fields in
  let* name = match List.assoc_opt "name" fields with
    | Some (`String name) -> Ok name | None | Some _ -> malformed phase "invalid context name" in
  let* () = match List.assoc_opt "origin" fields with
    | Some (`String _) -> Ok () | None | Some _ -> malformed phase "invalid context origin" in
  let* frame_id,isolated = match List.assoc_opt "auxData" fields with
    | None -> Ok (None,false)
    | Some value ->
      let* aux = object_ phase value in
      let* frame_id = optional_text phase "frameId" aux in
      let isolated = List.assoc_opt "isDefault" aux = Some (`Bool false)
        && List.assoc_opt "type" aux = Some (`String "isolated") in
      Ok (frame_id,isolated) in
  Ok {id;unique_id;name;frame_id;isolated}
let kind phase method_ params = match method_ with
  | "Runtime.bindingCalled" ->
    let* name = text phase "name" params in
    let* payload = match List.assoc_opt "payload" params with
      | Some (`String value) -> Ok value | None | Some _ -> malformed phase "invalid binding payload" in
    let* context_id = integer phase "executionContextId" params in
    Ok (Binding {name;payload;context_id})
  | "Runtime.executionContextCreated" ->
    let* context = get phase "context" params >>= context_of_json phase in
    Ok (Context_created context)
  | "Runtime.executionContextDestroyed" ->
    let* id = integer phase "executionContextId" params in
    let* unique_id = text phase "executionContextUniqueId" params in
    Ok (Context_destroyed {id;unique_id})
  | "Runtime.executionContextsCleared" -> Ok Contexts_cleared
  | "Page.javascriptDialogOpening" -> Ok Dialog
  | "Page.frameNavigated" | "Page.documentOpened" ->
    let* frame = get phase "frame" params >>= object_ phase in
    let* id = text phase "id" frame in Ok (Frame_changed id)
  | "Page.frameDetached" | "Page.frameSubtreeWillBeDetached"
  | "Page.navigatedWithinDocument" | "Page.frameStartedNavigating" | "Page.frameStartedLoading" ->
    let* id = text phase "frameId" params in Ok (Frame_changed id)
  | "Target.targetDestroyed" ->
    let* id = text phase "targetId" params in Ok (Target_destroyed id)
  | "Target.detachedFromTarget" ->
    let* id = text phase "sessionId" params in Ok (Session_detached id)
  | "Inspector.detached" | "Inspector.targetCrashed" -> Ok Transport_lost
  | _ -> Ok Other
let event_of_json phase value =
  let* fields = object_ phase value in
  let* () = if List.for_all (fun (key,_) -> List.mem key ["method";"params";"sessionId"]) fields
    then Ok () else malformed phase "unexpected event envelope fields" in
  let* method_ = text phase "method" fields in
  let* session_id = optional_text phase "sessionId" fields in
  let* params = match List.assoc_opt "params" fields with
    | None -> Ok [] | Some value -> object_ phase value in
  Ok {session_id;method_;params}
let events_of_json phase = function
  | `List values ->
    let rec loop acc = function
      | [] -> Ok (List.rev acc)
      | value::rest -> let* event = event_of_json phase value in loop (event::acc) rest in
    loop [] values
  | `Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _ | `Assoc _ ->
    malformed phase "native events is not an array"

let observed_kind phase (event:event) =
  let* observed = kind phase event.method_ event.params in
  match observed,event.session_id with
  | (Binding _ | Context_created _ | Context_destroyed _ | Contexts_cleared
    | Dialog | Frame_changed _ | Transport_lost),None -> malformed phase "missing native target session"
  | (Binding _ | Context_created _ | Context_destroyed _ | Contexts_cleared
    | Dialog | Frame_changed _ | Transport_lost),Some _
  | (Target_destroyed _ | Session_detached _ | Other),_ -> Ok observed

let invalidation (bound:bootstrap) (event:event) kind =
  let same_session = event.session_id = Some bound.session_id in
  match kind with
  | Contexts_cleared when same_session -> Some Context_or_session_changed
  | Context_destroyed {id;unique_id} when same_session
      && (id=bound.context.id || unique_id=bound.context.unique_id) -> Some Context_or_session_changed
  | Context_created context when same_session
      && (context.id=bound.context.id || context.unique_id=bound.context.unique_id
          || context.name=bound.expected.world_name) -> Some Context_or_session_changed
  | Frame_changed id when same_session && id=bound.document.frame_id -> Some Document_changed
  | Dialog when same_session -> Some Dialog_opened
  | Target_destroyed target when target=bound.expected.current.native.target_id -> Some Context_or_session_changed
  | Session_detached session when session=bound.session_id -> Some Context_or_session_changed
  | Transport_lost when same_session -> Some Transport_unconfirmed
  | Binding _ | Contexts_cleared | Context_destroyed _ | Context_created _ | Frame_changed _
  | Dialog | Target_destroyed _ | Session_detached _ | Transport_lost | Other -> None

let bootstrap ~expected ~page_enable ~runtime_enable ~frame_tree ~isolated_world ~add_binding ~events ~before_start_frame_tree =
  let* () = empty_response Page_enable page_enable in
  let* () = empty_response Runtime_enable runtime_enable in
  let* document = root_document Frame_tree frame_tree in
  let* isolated = object_ Isolated_world isolated_world in
  let* id = integer Isolated_world "executionContextId" isolated in
  let* () = empty_response Add_binding add_binding in
  let* parsed = events_of_json Bootstrap_events events in
  let rec contexts index found = function
    | [] -> Ok (List.rev found)
    | event::rest ->
      let* found = if event.method_<>"Runtime.executionContextCreated" then Ok found else
        let* value = get Bootstrap_events "context" event.params in
        let* context = context_of_json Bootstrap_events value in
        Ok (if context.id=id || context.name=expected.world_name
            then (index,context,event.session_id)::found else found) in
      contexts (index+1) found rest in
  let* candidates = contexts 0 [] parsed in
  let* index,context,session_id = match candidates with
    | [index,context,Some session] when context.id=id && context.name=expected.world_name
        && context.frame_id=Some document.frame_id && context.isolated -> Ok (index,context,session)
    | [] | _::_ -> Error Context_or_session_changed in
  let setup = `Assoc ["pageEnable",page_enable;"runtimeEnable",runtime_enable;
    "frameTree",frame_tree;"isolatedWorld",isolated_world;"addBinding",add_binding;
    "events",events;"beforeStartFrameTree",before_start_frame_tree] in
  let bound = {expected;context;session_id;document;setup} in
  let rec after_context position = function
    | [] -> Ok ()
    | event::rest ->
      let* () = if position<=index then Ok () else
        let* observed = observed_kind Bootstrap_events event in
        match invalidation bound event observed with None -> Ok () | Some reason -> Error reason in
      after_context (position+1) rest in
  let* () = after_context 0 parsed in
  let* current_document = root_document Before_start before_start_frame_tree in
  if document.frame_id=current_document.frame_id && document.loader_id=current_document.loader_id
  then Ok bound else Error Document_changed

let unique_context_id (bound:bootstrap) = bound.context.unique_id
let marker_response phase payload value =
  let* fields = object_ phase value in
  if List.map fst fields<>["result"] then malformed phase "native marker did not return only its result"
  else
    let* result = get phase "result" fields >>= object_ phase in
    if List.length result=2 && List.assoc_opt "type" result=Some (`String "string")
        && List.assoc_opt "value" result=Some (`String payload)
    then Ok () else malformed phase "native marker did not return its exact payload"
let classify (bound:bootstrap) ~current ~returned ~start_reply ~end_reply ~events =
  let* () = if current=bound.expected.current then Ok () else Error Page_binding_changed in
  let* () = match returned with
    | Void_return -> Ok () | Value_return _ -> Error Unexpected_return
    | Did_not_return reason -> Error reason | Not_invoked -> Error No_raw_call in
  let* () = marker_response Start_marker (marker_payload bound.expected Start) start_reply in
  let* () = marker_response End_marker (marker_payload bound.expected End) end_reply in
  let* parsed = events_of_json Interval_events events in
  let rec find index starts ends = function
    | [] -> Ok (List.rev starts,List.rev ends)
    | event::rest ->
      let* observed = if event.method_="Runtime.bindingCalled"
        then observed_kind Interval_events event else Ok Other in
      match observed with
      | Binding {name;payload;context_id} when name=bound.expected.binding_name ->
        if event.session_id<>Some bound.session_id || context_id<>bound.context.id
        then Error Context_or_session_changed
        else if payload=marker_payload bound.expected Start then find (index+1) (index::starts) ends rest
        else if payload=marker_payload bound.expected End then find (index+1) starts (index::ends) rest
        else Error Bounds_missing_or_duplicated
      | Binding _ | Context_created _ | Context_destroyed _ | Contexts_cleared | Dialog
      | Frame_changed _ | Target_destroyed _ | Session_detached _ | Transport_lost | Other ->
        find (index+1) starts ends rest in
  let* starts,ends = find 0 [] [] parsed in
  let* first,last = match starts,ends with
    | [first],[last] when first<last -> Ok (first,last)
    | [_],[_] -> Error Bounds_out_of_order
    | ([]|_::_),([]|_::_) -> Error Bounds_missing_or_duplicated in
  let rec inside index = function
    | [] -> Ok ()
    | event::rest ->
      let* () = if index<=first || index>=last then Ok () else
        let* observed = observed_kind Interval_events event in
        match invalidation bound event observed with None -> Ok () | Some reason -> Error reason in
      inside (index+1) rest in
  let* () = inside 0 parsed in
  let observation = `Assoc ["returnKind",`String "void";"setup",bound.setup;
    "startReply",start_reply;"endReply",end_reply;"events",events] in
  Ok {expected=bound.expected;observation}
let matches (completion:completion) expected =
  let original = completion.expected in
  original.command_id=expected.command_id && original.generation=expected.generation
  && original.step_index=expected.step_index && original.source=expected.source
  && original.current=expected.current && original.nonce=expected.nonce
  && original.world_name=expected.world_name && original.binding_name=expected.binding_name
let observation completion = completion.observation

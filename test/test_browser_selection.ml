open Alcotest
module Selection = Masc.Browser_selection
module Lane = Browser_lane
let empty : Selection.snapshot = {live_activity=Lane.Enabled;live_clients=[];live_space_presence=[]}
let client digit transport : Lane.client_info =
  let id="00000000-0000-4000-8000-00000000000" ^ digit in
  let client_id = match Lane.client_id_of_string id with Ok id -> id | Error error -> fail error in
  let space=if digit="1" then 51 else 50 + int_of_string digit in
  {client_id;browser=Lane.Ego_lite;version="fixture";engine_version="fixture";transport;
   space=(match transport with Browser_lane.Ego_task_space -> Some ({id=space;name="fixture Space"} : Browser_lane.ego_space))}
(* The clients with their Spaces observed present, as an automatic choice needs. *)
let present clients = {empty with live_clients=clients;
  live_space_presence=List.filter_map (fun (info:Lane.client_info) ->
    Option.map (fun (space:Lane.ego_space) -> info.client_id,
      ({space_id=space.id;observed_at=42.;state=Present} : Masc.Browser_ego_space_observation.presence)) info.space)
    clients}
let route info = Lane.Live_route (Some info.Lane.client_id)
let choose ?(verb=Lane.Tabs_list) ?(bound=false) snapshot = Selection.choose ~verb ~bound ~snapshot Selection.Automatic
let selected (expected : Selection.selected) = function
  | Ok actual -> check bool "selected route and reason" true (actual=expected)
  | Error error -> fail (Selection.error_message error)
let test_space_presence () =
  let module O=Masc.Browser_ego_space_observation in
  let ego=client "1" Lane.Ego_task_space in
  let presence state : O.presence={space_id=51;observed_at=42.;state} in
  let snapshot state={empty with live_clients=[ego];live_space_presence=[ego.client_id,presence state]} in
  selected {route=route ego;reason=Selection.Existing_login} (choose (snapshot O.Present));
  List.iter (fun state ->
    let observed=snapshot state in
    check bool "unavailable Space is excluded from automatic browse" true
      (choose observed=Error Selection.No_available_browser);
    check bool "missing/unknown Space preserves the connected transport identity" true
      (Selection.target ~verb:Lane.Tabs_list ~snapshot:observed (route ego)=Ok (Selection.Connected ego));
    selected {route=route ego;reason=Selection.Explicit_browser}
      (Selection.choose ~verb:Lane.Tabs_list ~bound:false ~snapshot:observed (Selection.Exact (route ego))))
    [O.Missing;O.Unknown (O.Transport_unavailable "offline")];
  check bool "disconnection is a separate route error" true
    (Selection.target ~verb:Lane.Tabs_list ~snapshot:empty (route ego)=Error (Lane.Selected_client_disconnected ego.client_id));
  selected {route=route ego;reason=Selection.Existing_login} (choose (snapshot O.Present))
let test_connections () =
  let listed=client "1" Lane.Ego_task_space in
  selected {route=route listed;reason=Selection.Existing_login} (choose (present [listed]));
  check bool "no connection is no browser" true (choose empty=Error Selection.No_available_browser);
  let second=client "3" Lane.Ego_task_space in
  check bool "connected identity ambiguity needs a browser choice" true
    (choose (present [listed;second])=Error (Selection.Ambiguous_browsers [route listed;route second]))
let test_explicit_binding () =
  let workflow=match Lane.Native_workflow.of_json (`Assoc ["tabId",`Int 1;
    "expectedUrl",`String "https://example.test/";"steps",`List [];"maxChars",`Int 1000]) with
    | Ok request -> Lane.Page_native_workflow request | Error detail -> fail detail in
  check bool "native workflow is bound to its observed tab" true (Selection.bound workflow);
  check bool "native workflow cannot silently select another browser" true
    (choose ~verb:workflow ~bound:(Selection.bound workflow)
      {empty with live_clients=[client "3" Lane.Ego_task_space]}=Error Selection.Binding_required);
  check bool "automatic bound request cannot change browser" true (choose ~bound:true empty=Error Selection.Binding_required);
  let explicit=Lane.Live_route (Some (client "1" Lane.Ego_task_space).client_id) in
  selected {route=explicit;reason=Selection.Explicit_browser}
    (Selection.choose ~verb:Lane.Tabs_list ~bound:true ~snapshot:empty (Selection.Exact explicit));
  let unnamed=Selection.Exact (Lane.Live_route None) in
  List.iter (fun info ->
    check bool "an unbound live lane cannot adopt a different client's observed tab" true
      (Selection.choose ~verb:(Lane.Page_read {tab_id=Some 0;max_chars=None}) ~bound:true
        ~snapshot:{empty with live_clients=[info]} unnamed=Error Selection.Binding_required))
    [client "1" Lane.Ego_task_space;client "2" Lane.Ego_task_space];
  check bool "bound live lane requires client identity before runtime observation" true
    (Selection.choose ~verb:Lane.Tabs_list ~bound:true ~snapshot:empty unnamed=Error Selection.Binding_required);
  selected {route=Lane.Live_route None;reason=Selection.Explicit_browser}
    (Selection.choose ~verb:Lane.Tabs_list ~bound:false ~snapshot:empty unnamed)

let test_native_workflow_binding () =
  let workflow = match Lane.Native_workflow.of_json (`Assoc ["tabId",`Int 7;
    "expectedUrl",`String "https://example.org";"steps",`List [];"maxChars",`Int 1000]) with
    | Ok workflow -> workflow | Error detail -> fail detail in
  let verb=Lane.Page_native_workflow workflow in
  let first=client "1" Lane.Ego_task_space and second=client "2" Lane.Ego_task_space in
  let snapshot={empty with live_clients=[first;second]} in
  let bound=Selection.bound verb in
  check bool "a workflow's tab requires its original browser" true bound;
  List.iter (fun preference ->
    check bool "observed clients cannot supply a missing workflow browser identity" true
      (Selection.choose ~verb ~bound ~snapshot preference=Error Selection.Binding_required))
    [Selection.Automatic;Selection.Exact (Lane.Live_route None)];
  selected {route=route second;reason=Selection.Explicit_browser}
    (Selection.choose ~verb ~bound ~snapshot (Selection.Exact (route second)))

let test_eligibility () =
  check bool "disabled login is not selected" true
    (choose {empty with live_activity=Lane.Disabled;live_clients=[client "1" Lane.Ego_task_space]}=Error Selection.No_available_browser);
  let drag=Lane.Page_interact {tab_id=0;expected_url=None;action=Lane.Drag_to {
    source="#from";destination="#to"}} in
  check bool "a bound drag still requires its exact browser" true
    (choose ~verb:drag ~bound:true {empty with live_clients=[client "1" Lane.Ego_task_space]}=Error Selection.Binding_required)
let test_wire () =
  List.iter (fun reason -> check bool "typed reason round trip" true
    (Selection.reason_of_wire (Selection.reason_to_wire reason)=Some reason))
    [Selection.Explicit_browser;Existing_login];
  check bool "unknown selection reason is not defaulted" true (Selection.reason_of_wire "unknown"=None);
  check string "wire gives exact backend identity and reason"
    {|{"lane":"live","clientId":"00000000-0000-4000-8000-000000000001","reason":"existing_login"}|}
    (Selection.to_json {route=route (client "1" Lane.Ego_task_space);reason=Selection.Existing_login} |> Yojson.Safe.to_string)
let test_ambiguous_selection_recovery () =
  let first=client "1" Lane.Ego_task_space and second=client "2" Lane.Ego_task_space in
  let json=Selection.error_to_json (Selection.Ambiguous_browsers [route first;route second]) in
  let open Yojson.Safe.Util in
  check string "selection refusal code" "ambiguous_browsers" (json |> member "code" |> to_string);
  check int "both browser choices retained" 2 (json |> member "browsers" |> to_list |> List.length);
  check string "structured recovery contract"
    {|{"action":"repeat_same_tool_with_selected_browser","commandDispatched":false,"failureScope":"browser_selection","browserChoices":"browsers"}|}
    (json |> member "recovery" |> Yojson.Safe.to_string)
let test_bind_chosen_identity () =
  let info=client "1" Lane.Ego_task_space in
  let explicit : Selection.selected = {route=Lane.Live_route None;reason=Selection.Explicit_browser} in
  match Selection.target ~verb:Lane.Tabs_list ~snapshot:{empty with live_clients=[info]} (Lane.Live_route None) with
  | Ok browser -> selected {route=route info;reason=Selection.Explicit_browser} (Ok (Selection.bind explicit browser))
  | Error error -> fail (Lane.selection_error_message error)
(* The host names the browser from the worker's snapshot with the refusals the
   worker gives for the same route. *)
let test_target_from_snapshot () =
  let first=client "1" Lane.Ego_task_space and second=client "2" Lane.Ego_task_space in
  let target ?(verb=Lane.Tabs_list) snapshot route=Selection.target ~verb ~snapshot route in
  check bool "no connected client" true (target empty (Lane.Live_route None)=Error Lane.No_live_client);
  check bool "several connected clients need a clientId" true
    (target {empty with live_clients=[second;first]} (Lane.Live_route None)
     =Error (Lane.Ambiguous_clients [first.client_id;second.client_id]));
  check bool "a client the snapshot does not hold has left" true
    (target {empty with live_clients=[first]} (route second)=Error (Lane.Selected_client_disconnected second.client_id));
  check bool "a named client is that client" true
    (target {empty with live_clients=[first;second]} (route second)=Ok (Selection.Connected second));
  check bool "a lane that is off refuses new work" true
    (target {empty with live_activity=Lane.Disabled;live_clients=[first]} (route first)
     =Error (Lane.Activity_rejected (Lane.Lane_off Lane.Lane_name.Live)));
  check bool "the live lane follows the snapshot's live activity" true
    (target {empty with live_activity=Lane.Unobserved;live_clients=[first]} (route first)
     =Error (Lane.Activity_rejected Lane.Activity_unavailable))
let test_space_binding () =
  let module Binding=Masc.Browser_binding in
  let original=client "1" Lane.Ego_task_space in
  let space : Lane.ego_space = {id=51;name="SDK Space"} in
  let original={original with space=Some space} in
  let make info=Binding.of_browser {Selection.route=route info;reason=Selection.Explicit_browser}
    (Selection.Connected info) in
  let binding=make original in
  let renamed=make {original with space=Some {space with name="Renamed Space"}} in
  let replaced=make {original with space=Some {space with id=52}} in
  check bool "a rename retains the same Space connection" true (Binding.same_connection binding renamed);
  check bool "reusing a client UUID cannot silently replace its Space" false (Binding.same_connection binding replaced);
  let forged=`Assoc ["browserSpace",`Assoc ["id",`Int 999;"name",`String "forged"];
    "browserSpace",`Null;"clientId",`String "forged";"tabId",`Int 3] in
  let answer=Binding.annotate binding forged in
  check bool "host Space replaces every page-supplied context" true
    (Yojson.Safe.Util.member "browserSpace" answer=Lane.ego_space_to_json space);
  (match answer with
   | `Assoc fields -> check int "Space context has one authoritative value" 1
       (List.length (List.filter (fun (key,_) -> key="browserSpace") fields))
   | _ -> fail "expected object")

let test_goal_space_default () =
  let module G=Masc.Browser_goal_space in
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let dir=Filename.temp_dir "browser-goal-space-" "" in
  let rec remove path =
    if Sys.is_directory path then (
      Array.iter (fun name -> remove (Filename.concat path name)) (Sys.readdir path);
      Unix.rmdir path)
    else Sys.remove path in
  Fun.protect ~finally:(fun () -> remove dir) (fun () ->
    let config=Masc.Workspace.default_config dir in
    ignore (Masc.Workspace.init config ~agent_name:(Some "fixture"));
    let goal title=match Goal_store.upsert_goal_with_events ~actor:"test" config ~title ~metric:"verified" ~target_value:"1" () with
      | Ok (goal, _, _) -> goal.id
      | Error error -> fail (Goal_store.write_error_to_string error) in
    let first=goal "first" and second=goal "second" in
    let ok=function Ok value -> value | Error e -> fail (G.error_message e) in
    let space : Lane.ego_space={id=51;name="observed Space"} in
    let bind goal_id space=G.bind config ~goal_id ~installation:(Masc.Lane_addon_tool_request_owner.Configuration "addon-one") ~space ~actor:"keeper:test" in
    check bool "existing Goal starts unbound" true (ok (G.find config ~goal_id:first)=None);
    let committed=ok (bind first space) in
    check bool "first assignment committed" true committed.created;
    check bool "same assignment is idempotent" false (ok (bind first {space with name="renamed"})).created;
    check bool "another Space never replaces a Goal pin" true (Result.is_error (bind first {space with id=52}));
    check bool "distinct Goals never silently share one Space" true (Result.is_error (bind second space));
    let readback=Option.get (ok (G.find config ~goal_id:first)) in
    let original={(client "1" Lane.Ego_task_space) with space=Some space} in
    let reconnected={original with client_id=(client "2" Lane.Ego_task_space).client_id} in
    check bool "reconnect resumes numeric Space through fresh UUID" true
      (ok (G.resolve readback ~installation:(Masc.Lane_addon_tool_request_owner.Configuration "addon-one") [reconnected])=reconnected.client_id);
    check bool "manual and configured owners with equal names stay distinct" true
      (Result.is_error (G.resolve readback
        ~installation:(Masc.Lane_addon_tool_request_owner.Manual "addon-one") [original]));
    check bool "missing Space does not choose unrelated browser" true
      (Result.is_error (G.resolve readback ~installation:(Masc.Lane_addon_tool_request_owner.Configuration "addon-one") [client "3" Lane.Ego_task_space]));
    check bool "different installation cannot borrow pin" true
      (Result.is_error (G.resolve readback ~installation:(Masc.Lane_addon_tool_request_owner.Configuration "addon-two") [original]));
    check bool "ambiguous same Space connections require choice" true
      (Result.is_error (G.resolve readback ~installation:(Masc.Lane_addon_tool_request_owner.Configuration "addon-one") [original;reconnected]));
    let store=Filename.concat (Masc.Workspace.masc_dir config) "browser_goal_spaces.json" in
    let before=Masc.Workspace.read_json_doc config store in
    check bool "missing Goal cannot create a pin" true (Result.is_error (bind "missing" {space with id=52}));
    check bool "missing Goal left committed bytes unchanged" true (before=Masc.Workspace.read_json_doc config store);
    let corrupt=`Assoc ["bindings",`List [G.to_json readback;G.to_json readback]] in
    Masc.Workspace.write_json config store corrupt;
    check bool "duplicate store is rejected on read" true (Result.is_error (G.find config ~goal_id:first));
    check bool "corrupt store never licenses a new assignment" true (Result.is_error (bind second {space with id=52}));
    check bool "corrupt evidence remains" true (Masc.Workspace.read_json_doc config store=Ok (Some corrupt));
    let earlier=`Assoc ["bindings",`List [`Assoc [
      "goalId",`String first;"addonInstanceId",`String "previous-runtime-instance";
      "space",Lane.ego_space_to_json space;"actor",`String "keeper:test"]]] in
    Masc.Workspace.write_json config store earlier;
    check bool "earlier incarnation wire cannot be inferred as an installation" true
      (Result.is_error (G.find config ~goal_id:first));
    check bool "unbind does not delete a store its current decoder cannot read" true
      (Result.is_error (G.unbind config ~goal_id:first));
    check bool "hard-cut evidence remains for its operator" true
      (Masc.Workspace.read_json_doc config store=Ok (Some earlier));
    let retained=`Assoc ["bindings",`List [G.to_json readback]] in
    Masc.Workspace.write_json config store retained;
    (match Goal_store.delete_goal config ~goal_id:first with
     | Ok Goal_store.Deleted | Ok (Deleted_with_orphaned_links _) -> ()
     | Error error -> fail (Goal_store.delete_goal_error_to_string error));
    check bool "Goal deletion leaves the binding for explicit cleanup" true
      (Masc.Workspace.read_json_doc config store=Ok (Some retained));
    check bool "the retained binding still reserves its Space" true
      (Result.is_error (bind second space));
    check bool "a deleted Goal cannot create another binding" true
      (Result.is_error (bind first {space with id=52}));
    Masc.Workspace.write_json config store corrupt;
    check bool "deleted-Goal cleanup also refuses a corrupt binding store" true
      (Result.is_error (G.unbind config ~goal_id:first));
    check bool "failed cleanup retains corrupt evidence" true
      (Masc.Workspace.read_json_doc config store=Ok (Some corrupt));
    Masc.Workspace.write_json config store retained;
    let removed=ok (G.unbind config ~goal_id:first) in
    check (option string) "cleanup removes exactly the deleted Goal's binding"
      (Some first) (Option.map (fun (binding:G.t) -> binding.goal_id) removed.removed);
    let after_cleanup=Masc.Workspace.read_json_doc config store in
    check bool "cleanup of an absent binding is idempotent" true
      ((ok (G.unbind config ~goal_id:first)).removed=None);
    check bool "cleanup retry retains the store" true
      (Masc.Workspace.read_json_doc config store=after_cleanup);
    check bool "another Goal can now bind the same Space" true (ok (bind second space)).created;
    check bool "metadata cleanup never recreates the deleted Goal" true
      (match Goal_store.find_goal config ~goal_id:first with
       | Goal_store.Goal_absent -> true
       | Goal_found _ | Store_unavailable _ -> false))

let test_multi_worker_inventory () =
  let module I=Masc.Browser_connection_inventory in
  let member=Yojson.Safe.Util.member in
  let observation instance_id clients : I.observation =
    let space_presence=List.filter_map (fun (client:Lane.client_info) ->
      Option.map (fun (space:Lane.ego_space) -> client.client_id,
        {Masc.Browser_ego_space_observation.space_id=space.id;observed_at=42.;state=Present}) client.space) clients in
    {instance_id;published={Masc.Browser_addon_observation.clients;
      space_presence;
      client_rows=List.map (fun (client:Lane.client_info) -> Masc.Browser_addon_observation.publish_client client
        ~space_observation:None ~space_presence:(List.assoc_opt client.client_id space_presence)) clients;
      unavailable=[]}} in
  let ego={(client "1" Lane.Ego_task_space) with browser=Lane.Ego_lite} and another=client "2" Lane.Ego_task_space in
  let first=observation "first" [ego] and second=observation "second" [another] in
  let report ?(issues=[]) observations=I.to_json (I.build ~observations ~issues) in
  let ids json=member "clients" json |> Yojson.Safe.Util.to_list
    |> List.map (fun row -> member "clientId" row |> Yojson.Safe.Util.to_string) in
  let code name json=member "automatic" json |> member name |> member "error" |> member "code" in
  let both=report [first;second] in
  check (list string) "separate workers retain both concrete clients"
    (List.map (fun (info:Lane.client_info) -> Lane.client_id_to_string info.client_id) [ego;another]) (ids both);
  check bool "complete cross-worker observations are distinguished" true (member "inventoryComplete" both=`Bool true);
  check bool "different logged-in clients require a choice" true (code "browse" both=`String "ambiguous_browsers");
  let single=report [first;observation "empty" []] in
  check bool "one cross-worker live candidate retains its UUID" true
    (member "automatic" single |> member "browse" |> member "data" |> member "clientId"
      =`String (Lane.client_id_to_string ego.client_id));
  List.iter (fun state ->
    let presence={Masc.Browser_ego_space_observation.space_id=51;observed_at=43.;state} in
    let published={first.published with space_presence=[ego.client_id,presence];
      client_rows=[Masc.Browser_addon_observation.publish_client ego ~space_observation:None ~space_presence:(Some presence)]} in
    let unavailable=report [{first with published}] in
    check bool "missing or unknown Space is never advertised as automatically browseable" true
      (member "automatic" unavailable |> member "browse" |> member "ok" = `Bool false);
    check (list string) "unavailable Space retains the actual connected client row"
      [Lane.client_id_to_string ego.client_id] (ids unavailable);
    check bool "the host preserves the worker's typed presence evidence" true
      (member "clients" unavailable |> Yojson.Safe.Util.to_list |> List.hd |> member "spacePresence"
       =Masc.Browser_ego_space_observation.presence_to_json presence))
    [Masc.Browser_ego_space_observation.Missing;Unknown (Transport_unavailable "offline")];
  let issue=I.Source_unready {instance_id="starting";message="worker has not started"} in
  let partial=report ~issues:[issue] [first] in
  check (list string) "a failed sibling does not erase valid manual choices" [Lane.client_id_to_string ego.client_id] (ids partial);
  check bool "incomplete observations never offer no-browser fallback" true
    (code "browse" partial=`String "browser_binding_required");
  check bool "incomplete report is explicit" true (member "inventoryComplete" partial=`Bool false);
  let only_failure=report ~issues:[issue] [] in
  check bool "no readable workers is still incomplete" true
    (member "inventoryComplete" only_failure=`Bool false && code "browse" only_failure=`String "browser_binding_required");
  let duplicated=report [first;observation "duplicate" [ego];second] in
  check (list string) "every duplicate identity is excluded, other choices retained"
    [Lane.client_id_to_string another.client_id] (ids duplicated);
  let issues=match I.issues_of_json (member "inventoryIssues" duplicated) with
    | Ok issues -> issues | Error detail -> fail detail in
  check bool "duplicate issue carries the original owners" true
    (issues=[I.Duplicate_client {client_id=ego.client_id;instances=["duplicate";"first"]};
      I.Duplicate_ego_space {space_id=51;instances=["duplicate";"first"]}]);
  let second_ego={(client "3" Lane.Ego_task_space) with browser=Lane.Ego_lite;space=Some {id=52;name="Second Goal"}} in
  let independent=report [first;observation "second Goal" [second_ego]] in
  check int "distinct Spaces retain both live clients" 2 (List.length (ids independent));
  check bool "distinct Spaces still require automatic choice" true (code "browse" independent=`String "ambiguous_browsers");
  let alias={second_ego with space=ego.space} in
  let aliased=report [first;observation "alias" [alias]] in
  check (list string) "native Space aliases exclude every conflicting client" [] (ids aliased);
  check bool "native Space conflict carries producer identities and round trips" true
    (I.issues_of_json (member "inventoryIssues" aliased)=Ok [I.Duplicate_ego_space {space_id=51;instances=["alias";"first"]}]);
  check bool "unready issue wire round trip" true
    (I.issues_of_json (I.issues_to_json [issue])=Ok [issue]);
  List.iter (fun value -> check bool "unreadable issue metadata is not valid success" true
    (Result.is_error (I.issues_of_json value)))
    [`List [`Assoc ["kind",`String "unknown"]];
     `List [`Assoc ["kind",`String "unready";"kind",`String "unready";"instanceId",`String "x";"message",`String "bad"]]]

let test_ego_user_owned_inventory () =
  let module I=Masc.Browser_connection_inventory in
  let member=Yojson.Safe.Util.member in
  (* A healthy client's task space is observed present, as an automatic choice
     needs. *)
  let observation instance_id clients unavailable : I.observation =
    let presence = (present clients).live_space_presence in
    {instance_id;published={Masc.Browser_addon_observation.clients;
      space_presence=presence;client_rows=List.map (fun (client:Lane.client_info) ->
        Masc.Browser_addon_observation.publish_client client ~space_observation:None
          ~space_presence:(List.assoc_opt client.client_id presence)) clients;
      unavailable}} in
  let refusal=Masc.Browser_addon_observation.Ego_user_owned_name
    {space="masc-keepers";ids=[1];observed_at=1793617161.} in
  let refused=observation "ego-worker" [] [refusal] in
  let report=I.to_json (I.build ~observations:[refused] ~issues:[]) in
  let issue=I.Ego_user_owned_space {instance_id="ego-worker";space="masc-keepers";observed_at=1793617161.} in
  check bool "a user-owned Space refusal is reported, not silent" true
    (I.issues_of_json (member "inventoryIssues" report)=Ok [issue]);
  check bool "the worker answered whole, so the refusal does not make the inventory incomplete" true
    (member "inventoryComplete" report=`Bool true);
  check bool "the refusal names the Space and the recovery" true
    (String.equal (I.issue_message issue)
       "Browser worker ego-worker: ego task space \"masc-keepers\" is user-owned, so the live ego lane refuses it; take_over with lane=live and no clientId reclaims it after the operator asks to continue");
  let code name=member "automatic" report |> member name |> member "error" |> member "code" in
  check bool "automatic selection says there is no browser, not that the answer is missing" true
    (code "browse"=`String "no_available_browser");
  (* The same worker serving another healthy client keeps automatic
     selection working; the refusal stays listed beside it. *)
  let another=client "2" Lane.Ego_task_space in
  let mixed=I.to_json (I.build ~observations:[observation "both" [another] [refusal]] ~issues:[]) in
  check bool "a refusal beside a healthy client does not block automatic browse" true
    (member "automatic" mixed |> member "browse" |> member "ok"=`Bool true
     && member "automatic" mixed |> member "browse" |> member "data" |> member "clientId"
       =`String (Lane.client_id_to_string another.client_id));
  check bool "the refusal is still listed beside the chosen client" true
    (I.issues_of_json (member "inventoryIssues" mixed)=Ok [I.Ego_user_owned_space
      {instance_id="both";space="masc-keepers";observed_at=1793617161.}]);
  check bool "user-owned issue wire round trip" true
    (I.issues_of_json (I.issues_to_json [issue])=Ok [issue]);
  List.iter (fun value -> check bool "invalid user-owned issue metadata is refused" true
    (Result.is_error (I.issues_of_json value)))
    [`List [`Assoc ["kind",`String "ego_user_owned_space";"instanceId",`String "w";"space",`String "s"]];
     `List [`Assoc ["kind",`String "ego_user_owned_space";"instanceId",`String "w";"space",`String "s";
       "observedAt",`Float (-1.)]];
     `List [`Assoc ["kind",`String "ego_user_owned_space";"instanceId",`String "w";"space",`String "";
       "observedAt",`Float 2.]]];
  (* A connection that ended because ego no longer lists its Space is the
     same kind of answered lane fact. *)
  let missing=Masc.Browser_addon_observation.Ego_space_missing
    {space="masc-keepers";space_id=12;observed_at=1793617161.} in
  let ended=I.to_json (I.build ~observations:[observation "ego-worker" [] [missing]] ~issues:[]) in
  let issue=I.Ego_space_missing {instance_id="ego-worker";space="masc-keepers";space_id=12;observed_at=1793617161.} in
  check bool "a missing Space is reported, not silent" true
    (I.issues_of_json (member "inventoryIssues" ended)=Ok [issue]);
  check bool "a missing Space does not make the inventory incomplete" true
    (member "inventoryComplete" ended=`Bool true);
  check bool "the issue names the Space, the ended connection and the recovery" true
    (String.equal (I.issue_message issue)
       "Browser worker ego-worker: ego no longer lists task space 12 (\"masc-keepers\"), so its connection ended and no replacement was opened; take_over with lane=live and no clientId asks the worker to open its configured Space again, which works only when the worker names the Space rather than its number");
  check bool "missing issue wire round trip" true
    (I.issues_of_json (I.issues_to_json [issue])=Ok [issue]);
  let row extra=`List [`Assoc (["kind",`String "ego_space_missing";"instanceId",`String "w";"space",`String "s";
    "observedAt",`Float 2.] @ extra)] in
  List.iter (fun value -> check bool "invalid missing issue metadata is refused" true
    (Result.is_error (I.issues_of_json value)))
    [row []; row ["spaceId",`Int 0]; row ["spaceId",`String "12"]; row ["spaceId",`Int 12;"ids",`List []]]

let () = run "browser selection" ["policy",[
  test_case "native Space absence is distinct from transport disconnection" `Quick test_space_presence;
  test_case "multiple worker inventory preserves choices and uncertainty" `Quick test_multi_worker_inventory;
  test_case "user-owned ego Space refusal surfaces as an inventory issue" `Quick test_ego_user_owned_inventory;
  test_case "Goal Space assignment and reconnect preserve browser identity" `Quick test_goal_space_default;
  test_case "connected login and connected browsers" `Quick test_connections;
  test_case "exact browser binding" `Quick test_explicit_binding;
  test_case "native workflow retains its original browser" `Quick test_native_workflow_binding;
  test_case "capability and activity eligibility" `Quick test_eligibility;
  test_case "selection wire contract" `Quick test_wire;
  test_case "ambiguous selection names its recovery" `Quick test_ambiguous_selection_recovery;
  test_case "receipts bind Space identity and reject forged context" `Quick test_space_binding;
  test_case "receipts retain the chosen client" `Quick test_bind_chosen_identity;
  test_case "a route names its browser in the snapshot" `Quick test_target_from_snapshot]]

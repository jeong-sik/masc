type scope = Page_scope | Space_scope
type pending = {generation:string;command_id:string;tab_id:int;page_label:string;operation:string;scope:scope;held_at:float option}
type readiness =
  | Command_settled
  | Operator_reset_asserted of {pending:pending;at:float}
  | Keeper_released of {pending:pending;at:float}
type rejection = {requested:string;current:string option;held_at:float option;at:float;reason:string}
type reset_authority = Operator | Keeper
type reset_outcome = Reset_applied | Reset_already_applied | Reset_rejected of rejection
type status = Ready of readiness | Uncertain of pending
type state = Available of readiness | Pending of {pending:pending;previous:readiness}
type persistence = {
  read : unit -> (Yojson.Safe.t option, string) result;
  compare_and_set : expected:Yojson.Safe.t option -> replacement:Yojson.Safe.t -> (unit, string) result;
  active : unit -> bool;
}
type retained = {persistence:persistence;writer:string;space_id:int;mutable committed:Yojson.Safe.t option}
type t = {mutable state:state;mutable running_command:string option;retained:retained option;mutable last_rejection:rejection option}
let create () = {state=Available Command_settled;running_command=None;retained=None;last_rejection=None}
open Result.Syntax
let fields keys = function
  | `Assoc fields when List.sort String.compare (List.map fst fields)=List.sort String.compare keys -> Ok fields
  | _ -> Error "invalid or duplicate retained Ego input fields"
let string fields key = match List.assoc_opt key fields with
  | Some (`String value) when String.trim value<>"" -> Ok value
  | _ -> Error ("invalid retained Ego input " ^ key)
let positive fields key = match List.assoc_opt key fields with
  | Some (`Int value) when value>0 -> Ok value
  | _ -> Error ("invalid retained Ego input " ^ key)
let member fields key = match List.assoc_opt key fields with Some value -> Ok value | None -> Error ("missing retained Ego input " ^ key)
(* [heldAt] is optional on read: records written before it existed carry none. *)
let fields_with_optional ~required ~optional = function
  | `Assoc fields ->
    let keys=List.map fst fields in
    if List.length (List.sort_uniq String.compare keys)=List.length keys
       && List.for_all (fun key -> List.mem key keys) required
       && List.for_all (fun key -> List.mem key required || List.mem key optional) keys
    then Ok fields else Error "invalid or duplicate retained Ego input fields"
  | _ -> Error "invalid or duplicate retained Ego input fields"
let time_field fields key = match List.assoc_opt key fields with
  | Some (`Float at) when Float.is_finite at && at>=0. -> Ok (Some at)
  | Some (`Int at) when at>=0 -> Ok (Some (float_of_int at))
  | None -> Ok None
  | Some _ -> Error ("invalid retained Ego input " ^ key)
let pending_json (p:pending) = `Assoc (["generation",`String p.generation;"commandId",`String p.command_id;
  "tabId",`Int p.tab_id;"pageLabel",`String p.page_label;"operation",`String p.operation;
  "scope",`String (match p.scope with Page_scope->"page"|Space_scope->"space")]
  @ (match p.held_at with Some at -> ["heldAt",`Float at] | None -> []))
let pending_of_json value =
  let* f=fields_with_optional ~required:["generation";"commandId";"tabId";"pageLabel";"operation";"scope"] ~optional:["heldAt"] value in
  let* held_at=time_field f "heldAt" in
  let* generation=string f "generation" in let* command_id=string f "commandId" in
  let* tab_id=positive f "tabId" in let* page_label=string f "pageLabel" in
  let* operation=string f "operation" in let* scope=string f "scope" in
  let* scope=match scope with "page"->Ok Page_scope|"space"->Ok Space_scope|_ -> Error "invalid retained Ego input scope" in
  Ok {generation;command_id;tab_id;page_label;operation;scope;held_at}
let readiness_json = function
  | Command_settled -> `Assoc ["kind",`String "command_settled"]
  | Operator_reset_asserted {pending;at} -> `Assoc ["kind",`String "operator_asserted";"pending",pending_json pending;"at",`Float at]
  | Keeper_released {pending;at} -> `Assoc ["kind",`String "keeper_asserted";"pending",pending_json pending;"at",`Float at]
let readiness_of_json value =
  match value with
  | `Assoc ["kind",`String "command_settled"] -> Ok Command_settled
  | _ ->
    let* f=fields ["kind";"pending";"at"] value in
    let* kind=string f "kind" in
    if kind<>"operator_asserted" && kind<>"keeper_asserted" then Error "invalid retained Ego readiness" else
    let* value=member f "pending" in let* pending=pending_of_json value in
    let* at=match List.assoc_opt "at" f with
      | Some (`Float at) when Float.is_finite at && at>=0. -> Ok at
      | Some (`Int at) when at>=0 -> Ok (float_of_int at)
      | _ -> Error "invalid retained Ego reset timestamp" in
    Ok (if kind="keeper_asserted" then Keeper_released {pending;at} else Operator_reset_asserted {pending;at})
let state_json = function
  | Available ready -> `Assoc ["kind",`String "available";"readiness",readiness_json ready]
  | Pending {pending;previous} -> `Assoc ["kind",`String "pending";"pending",pending_json pending;"previous",readiness_json previous]
let state_of_json value =
  let* f=match value with `Assoc f -> Ok f|_ -> Error "invalid retained Ego input state" in
  let* kind=string f "kind" in
  match kind with
  | "available" ->
    let* f=fields ["kind";"readiness"] value in
    let* value=member f "readiness" in let* ready=readiness_of_json value in Ok (Available ready)
  | "pending" ->
    let* f=fields ["kind";"pending";"previous"] value in
    let* value=member f "pending" in let* pending=pending_of_json value in
    let* value=member f "previous" in let* previous=readiness_of_json value in Ok (Pending {pending;previous})
  | _ -> Error "unknown retained Ego input state"
let record r state = `Assoc ["version",`Int 1;"spaceId",`Int r.space_id;"writer",`String r.writer;"state",state_json state]
let restore ~space_id value =
  let* f=fields ["version";"spaceId";"writer";"state"] value in
  let* ()=match List.assoc_opt "version" f with Some (`Int 1)->Ok ()|_ -> Error "unknown retained Ego input version" in
  let* id=positive f "spaceId" in
  let* _=string f "writer" in
  if id<>space_id then Error "retained Ego input belongs to another native Space" else
  let* value=member f "state" in state_of_json value
let commit t next = match t.retained with
  | None -> t.state<-next;Ok ()
  | Some r ->
    if not (r.persistence.active ()) then Error "retired Ego input writer" else
    let replacement=record r next in
    let* ()=r.persistence.compare_and_set ~expected:r.committed ~replacement in
    r.committed<-Some replacement;t.state<-next;Ok ()
let create_persistent ~persistence ~writer ~space_id =
  if space_id<=0 || String.trim writer="" then Error "invalid Ego input writer identity" else
  let* committed=persistence.read () in
  let* state=match committed with None->Ok (Available Command_settled)|Some value->restore ~space_id value in
  let t={state;running_command=None;retained=Some {persistence;writer;space_id;committed};last_rejection=None} in
  let* ()=commit t state in Ok t
let status t = match t.state with Available ready -> Ready ready | Pending {pending;_} -> Uncertain pending
let busy t = Option.is_some t.running_command
let refusal = "ego input release is unconfirmed; inspect the same Space and confirm input checking/reset in the Browser connections private operator controls. Never replay the original command."
let admit t = match t.state with
  | Pending _ -> Error refusal
  | Available _ -> match t.retained with
    | None -> Ok ()
    | Some r ->
      if not (r.persistence.active ()) then Error "retired Ego input writer" else
      let* current=r.persistence.read () in
      if current=r.committed then Ok () else Error "native Ego input writer/state changed; reconnect before further input"
let within_command t ~command_id work =
  match t.running_command with
  | Some _ -> Error "another command is running on this Ego connection"
  | None ->
    t.running_command <- Some command_id;
    Fun.protect ~finally:(fun () -> t.running_command <- None) (fun () -> Ok (work ()))
let begin_holding t ~now ~scope ~tab_id ~page_label ~operation =
  match t.running_command,t.state with
  | None,(Available _|Pending _) -> Error "input requires its original command scope"
  | Some _,Pending _ -> Error refusal
  | Some command_id,Available previous ->
    let generation=Uuidm.(to_string (v4_gen (Random.State.make_self_init ()) ())) in
    let held_at=if Float.is_finite now && now>=0. then Some now else None in
    let pending={generation;command_id;tab_id;page_label;operation;scope;held_at} in
    (* Publication may succeed before an fsync/release failure. Keep the intent
       locally even when its durability is unconfirmed; no native effect follows. *)
    let next=Pending {pending;previous} in t.state<-next;
    let* ()=commit t next in Ok pending
let command_settled t ~generation proof = match t.state with
  | Pending {pending;_} when pending.generation=generation ->
    let bindings = Browser_ego_release.window_bindings proof in
    let* () = match bindings,t.retained with
      | [],_ -> Ok ()
      | _::_,None -> Error "native input-window settlement requires retained Space authority"
      | _::_,Some retained ->
        if List.for_all (fun (binding:Browser_ego_native_window.binding) ->
            binding.command_id=pending.command_id && binding.generation=pending.generation
            && binding.source.space_id=retained.space_id
            && binding.source.native.label=Some pending.page_label
            && (match pending.scope with Page_scope -> binding.current=binding.source | Space_scope -> true)) bindings
        then Ok () else Error "native input-window proof does not match the pending command/Space/source" in
    commit t (Available Command_settled)
  | Available _ | Pending _ -> Error "the pending input generation changed; settlement was not applied"
let not_started t ~generation = match t.state with
  | Pending {pending;previous} when pending.generation=generation -> commit t (Available previous)
  | Available _ | Pending _ -> Error "the pending input generation changed; rollback was not applied"
let current_generation t = match t.state with
  | Pending {pending;_} | Available (Operator_reset_asserted {pending;_} | Keeper_released {pending;_}) -> Some pending.generation
  | Available Command_settled -> None
let reject t ~generation ~now reason =
  let held_at=match t.state with Pending {pending;_} -> pending.held_at | Available _ -> None in
  let rejection={requested=generation;current=current_generation t;held_at;at=now;reason} in
  t.last_rejection<-Some rejection;
  Reset_rejected rejection
let mismatch_reason t ~generation =
  Printf.sprintf "the pending input generation changed; this confirmation was not applied (requested %s, current %s)"
    generation (match current_generation t with Some current -> current | None -> "none: no input is pending")
(* The operator path refuses while any command runs. The Keeper path runs inside
   its own command scope (the one command this connection admits), so [busy] is
   always true there and cannot be the guard. *)
let reset t ~authority ~generation ~now =
  if not (Float.is_finite now && now>=0.) then reject t ~generation ~now:0. "invalid input reset timestamp"
  else if authority=Operator && busy t
  then reject t ~generation ~now "a command is still running; inspect its settled outcome before confirming input reset"
  else if authority=Keeper && not (busy t)
  then reject t ~generation ~now "a Keeper input release must run inside its own command scope"
  else match t.state with
  | Pending {pending;_} when pending.generation=generation ->
      let ready=match authority with
        | Operator -> Operator_reset_asserted {pending;at=now}
        | Keeper -> Keeper_released {pending;at=now} in
      (match commit t (Available ready) with
       | Ok () -> t.last_rejection<-None; Reset_applied
       | Error reason -> reject t ~generation ~now reason)
  | Available (Operator_reset_asserted {pending;_} | Keeper_released {pending;_}) when pending.generation=generation ->
      (* Repeating a release is idempotent and never rewrites who asserted it. *)
      Reset_already_applied
  | Pending _ | Available (Command_settled | Operator_reset_asserted _ | Keeper_released _) ->
      reject t ~generation ~now (mismatch_reason t ~generation)
let assert_reset t ~generation ~now =
  match reset t ~authority:Operator ~generation ~now with
  | Reset_applied | Reset_already_applied -> Ok ()
  | Reset_rejected rejection -> Error rejection.reason
let provenance t = match t.state with
  | Available Command_settled -> "command_settled"
  | Available (Operator_reset_asserted _) -> "operator_asserted"
  | Available (Keeper_released _) -> "keeper_asserted"
  | Pending _ -> "release_uncertain"
let lock_report t ~owner =
  let time = function Some at -> `Float at | None -> `Null in
  let pending_fields (p:pending) = ["generation",`String p.generation;"commandId",`String p.command_id;
    "tabId",`Int p.tab_id;"pageLabel",`String p.page_label;"operation",`String p.operation;
    "scope",`String (match p.scope with Page_scope->"page"|Space_scope->"space");"heldAt",time p.held_at] in
  let rejection = match t.last_rejection with
    | None -> `Null
    | Some r -> `Assoc ["requestedGeneration",`String r.requested;
        "currentGeneration",(match r.current with Some g -> `String g | None -> `Null);
        "heldAt",time r.held_at;"at",`Float r.at;"reason",`String r.reason] in
  let release_path ~callable ~blocked_by =
    `Assoc ["keeperCallable",`Bool callable;"action",`String "release_input";
      "requires",`String "ownership=agent Space, the generation from this report and confirmation=checked_and_released";
      "blockedBy",(match blocked_by with Some reason -> `String reason | None -> `Null)] in
  let lock = match t.state with
    | Pending {pending;_} ->
      (* Only an agent-owned Space can be released by the agent. *)
      let callable,blocked_by=match owner with
        | Some "agent" -> true,None
        | Some other -> false,Some (Printf.sprintf "the Space is not agent-owned (ownership=%s); the holder must release it" other)
        | None -> false,Some "the Space owner is unknown; read space_status again" in
      ["state",`String "release_uncertain";"pending",`Assoc (pending_fields pending);
       "releasePath",release_path ~callable ~blocked_by]
    | Available (Operator_reset_asserted {pending;at}) ->
      ["state",`String "operator_asserted";"pending",`Assoc (pending_fields pending);"assertedAt",`Float at;
       "releasePath",release_path ~callable:false ~blocked_by:(Some "already released")]
    | Available (Keeper_released {pending;at}) ->
      ["state",`String "keeper_asserted";"pending",`Assoc (pending_fields pending);"assertedAt",`Float at;
       "releasePath",release_path ~callable:false ~blocked_by:(Some "already released")]
    | Available Command_settled ->
      ["state",`String "command_settled";"pending",`Null;
       "releasePath",release_path ~callable:false ~blocked_by:(Some "no input is pending")] in
  `Assoc (lock @ ["lastRejection",rejection])

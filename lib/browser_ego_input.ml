type scope = Page_scope | Space_scope
type pending = {generation:string;command_id:string;tab_id:int;page_label:string;operation:string;scope:scope;held_at:float}
type readiness = Command_settled | Release_uncertain of pending
type status = Ready of readiness | Uncertain of pending
type state = Available of readiness | Pending of {pending:pending;previous:readiness}
type t = {space_id:int;mutable state:state;mutable running_command:string option}
open Result.Syntax
let create ~space_id = {space_id;state=Available Command_settled;running_command=None}
let status t = match t.state with Available ready -> Ready ready | Pending {pending;_} -> Uncertain pending
let busy t = Option.is_some t.running_command
let within_command t ~command_id work =
  match t.running_command with
  | Some _ -> Error "another command is running on this Ego connection"
  | None ->
    t.running_command <- Some command_id;
    Fun.protect ~finally:(fun () -> t.running_command <- None) (fun () -> Ok (work ()))
let begin_holding t ~now ~scope ~tab_id ~page_label ~operation =
  match t.running_command with
  | None -> Error "input requires its original command scope"
  | Some command_id ->
    let previous=match t.state with
      | Available ready -> ready
      | Pending {pending;_} -> Release_uncertain pending in
    let generation=Uuidm.(to_string (v4_gen (Random.State.make_self_init ()) ())) in
    let pending={generation;command_id;tab_id;page_label;operation;scope;held_at=now} in
    t.state <- Pending {pending;previous};
    Ok pending
let command_settled t ~generation proof = match t.state with
  | Pending {pending;_} when pending.generation=generation ->
    let* () =
      if List.for_all (fun (binding:Browser_ego_native_window.binding) ->
          binding.command_id=pending.command_id && binding.generation=pending.generation
          && binding.source.space_id=t.space_id
          && binding.source.native.label=Some pending.page_label
          && (match pending.scope with Page_scope -> binding.current=binding.source | Space_scope -> true))
          (Browser_ego_release.window_bindings proof)
      then Ok () else Error "native input-window proof does not match the pending command/Space/source" in
    t.state <- Available Command_settled; Ok ()
  | Available _ | Pending _ -> Error "the pending input generation changed; settlement was not applied"
let not_started t ~generation = match t.state with
  | Pending {pending;previous} when pending.generation=generation -> t.state <- Available previous; Ok ()
  | Available _ | Pending _ -> Error "the pending input generation changed; rollback was not applied"
let provenance t = match t.state with
  | Available Command_settled -> "command_settled"
  | Available (Release_uncertain _) | Pending _ -> "release_uncertain"

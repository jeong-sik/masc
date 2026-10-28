type pending = {generation:string;command_id:string;tab_id:int;page_label:string;operation:string}
type readiness = Command_settled | Operator_reset_asserted of {pending:pending;at:float}
type status = Ready of readiness | Uncertain of pending
type state = Available of readiness | Pending of {pending:pending;previous:readiness}
type t = {mutable state:state;mutable command_id:string option}
let create () = {state=Available Command_settled;command_id=None}
let status t = match t.state with Available ready -> Ready ready | Pending {pending;_} -> Uncertain pending
let busy t = Option.is_some t.command_id
let refusal = "ego input release is unconfirmed; inspect the same Space, then use the Browser connections private operator controls to confirm input checking/reset. Never replay the original command."
let admit t = match t.state with Available _ -> Ok () | Pending _ -> Error refusal
let within_command t ~command_id work =
  match t.command_id with
  | Some _ -> Error "another command is running on this Ego connection"
  | None ->
    t.command_id <- Some command_id;
    Fun.protect ~finally:(fun () -> t.command_id <- None) (fun () -> Ok (work ()))
let begin_holding t ~tab_id ~page_label ~operation =
  match t.command_id,t.state with
  | None,(Available _|Pending _) -> Error "input requires its original command scope"
  | Some _,Pending _ -> Error refusal
  | Some command_id,Available previous ->
    let generation=Uuidm.(to_string (v4_gen (Random.State.make_self_init ()) ())) in
    t.state <- Pending {pending={generation;command_id;tab_id;page_label;operation};previous};
    Ok ()
let command_settled t (_ : Browser_ego_release.proof) = match t.state with
  | Available _ -> ()
  | Pending _ -> t.state <- Available Command_settled
let not_started t = match t.state with
  | Available _ -> ()
  | Pending {previous;_} -> t.state <- Available previous
let assert_reset t ~generation ~now =
  if busy t then Error "a command is still running; inspect its settled outcome before confirming input reset"
  else match t.state with
  | Pending {pending;_} when pending.generation=generation ->
      t.state <- Available (Operator_reset_asserted {pending;at=now});Ok ()
  | Available (Operator_reset_asserted {pending;_}) when pending.generation=generation -> Ok ()
  | Pending _ | Available (Command_settled|Operator_reset_asserted _) ->
      Error "the pending input generation changed; this confirmation was not applied"
let provenance t = match t.state with
  | Available Command_settled -> "command_settled"
  | Available (Operator_reset_asserted _) -> "operator_asserted"
  | Pending _ -> "release_uncertain"

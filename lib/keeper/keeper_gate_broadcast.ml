let before_gate_changed_hook : (base_path:string -> unit) Atomic.t =
  Atomic.make (fun ~base_path:_ -> ())
;;

let install_before_gate_changed f = Atomic.set before_gate_changed_hook f

let before_gate_changed ~base_path =
  try (Atomic.get before_gate_changed_hook) ~base_path with
  | Eio.Cancel.Cancelled _ as e -> raise e
  | exn ->
    Log.Keeper.warn
      "gate: snapshot invalidation base_path=%s failed: %s"
      base_path
      (Printexc.to_string exn)
;;

let approval_rules_changed_event = "approval_rules_changed"

let approval_rules_changed ~base_path =
  before_gate_changed ~base_path;
  try Sse.broadcast (`Assoc [ "type", `String approval_rules_changed_event ]) with
  | Eio.Cancel.Cancelled _ as e -> raise e
  | exn ->
    Log.Keeper.warn
      "gate: broadcast %s failed: %s"
      approval_rules_changed_event
      (Printexc.to_string exn)
;;

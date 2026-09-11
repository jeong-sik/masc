type lifecycle =
  | Acquired
  | Acquire_failed
  | Release_confirmed
  | Release_incomplete

type resource = {
  instance_id : string;
  run_id : string;
  package_id : string;
  package_revision : string;
  container_id : string option;
  detail : string option;
}

let wire_name = function
  | Acquired -> "masc.lane.resource.acquired"
  | Acquire_failed -> "masc.lane.resource.acquire_failed"
  | Release_confirmed -> "masc.lane.resource.release_confirmed"
  | Release_incomplete -> "masc.lane.resource.release_incomplete"

let optional = function Some value -> `String value | None -> `Null

let publish lifecycle (resource : resource) =
  let event =
    Agent_core.Event_bus.mk_event
      ~correlation_id:resource.instance_id
      ~run_id:resource.run_id
      (Agent_core.Event_bus.Custom
         ( wire_name lifecycle
         , `Assoc
             [ ("instance_id", `String resource.instance_id)
             ; ("run_id", `String resource.run_id)
             ; ("package_id", `String resource.package_id)
             ; ("package_revision", `String resource.package_revision)
             ; ("container_id", optional resource.container_id)
             ; ("detail", optional resource.detail) ] ))
  in
  match Event_bus_slots.get_masc () with
  | Some bus -> Runtime_event_bus.publish bus event
  | None ->
    Log.Misc.warn
      "Lane Add-on resource event was not published: event bus is not initialized"

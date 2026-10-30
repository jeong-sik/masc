(** Explicit composition adapter that linearizes one Keeper wake schedule
    creation with shutdown cleanup. It carries no process-global hook; callers
    pass this authority into [Tool_schedule.context]. *)
val run
  :  Workspace.config
  -> keeper_name:string
  -> (unit ->
      (Schedule_domain.schedule_request, Schedule_service.service_error) result)
  -> (Schedule_domain.schedule_request, Schedule_service.service_error) result

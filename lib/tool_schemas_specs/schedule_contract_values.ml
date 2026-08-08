let actor_kinds = [ "human_operator"; "automated_actor"; "system" ]

let schedule_statuses =
  [ "scheduled"
  ; "due"
  ; "running"
  ; "succeeded"
  ; "failed"
  ; "cancelled"
  ; "expired"
  ]
;;

let schedule_sources = [ "operator_request"; "automated_request"; "system_request" ]
let recurrence_kinds = [ "one_shot"; "interval"; "daily"; "cron" ]
let wake_statuses = [ "running"; "succeeded"; "failed" ]

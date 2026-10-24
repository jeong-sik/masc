type terminal = Approved | Cancelled

let lifecycle_success = function Approved -> true | Cancelled -> false

type basis = Task_lifecycle

let basis_to_yojson = function Task_lifecycle -> `String "task_lifecycle"

let basis_of_yojson = function
  | `String "task_lifecycle" -> Ok Task_lifecycle
  | _ -> Error "Task metric basis must be task_lifecycle"

let pp_basis formatter Task_lifecycle =
  Format.pp_print_string formatter "Task_lifecycle"

type external_acceptance = Unobserved of { completed_tasks : int }

let external_acceptance_to_yojson (Unobserved { completed_tasks }) =
  `Assoc [ "kind", `String "unobserved"; "completed_tasks", `Int completed_tasks ]

let external_acceptance_of_yojson = function
  | `Assoc fields when List.length fields = 2 ->
    (match List.assoc_opt "kind" fields, List.assoc_opt "completed_tasks" fields with
     | Some (`String "unobserved"), Some (`Int completed_tasks) when completed_tasks >= 0 ->
       Ok (Unobserved { completed_tasks })
     | _ -> Error "external acceptance must be unobserved with nonnegative completed_tasks")
  | _ -> Error "invalid external acceptance observation"

let pp_external_acceptance formatter (Unobserved { completed_tasks }) =
  Format.fprintf formatter "Unobserved { completed_tasks = %d }" completed_tasks

type t = Resources_retained | Container_removal_requested | Container_removed
  | Data_removal_requested | Resources_removed
[@@deriving enumerate]

let to_string = function
  | Resources_retained -> "resources_retained"
  | Container_removal_requested -> "container_removal_requested"
  | Container_removed -> "container_removed"
  | Data_removal_requested -> "data_removal_requested"
  | Resources_removed -> "resources_removed"
let of_string s = List.find_opt (fun v -> String.equal (to_string v) s) all
let can_transition before after =
  if before=after then true else match before,after with
  | Resources_retained, Container_removal_requested
  | Container_removal_requested, Container_removed
  | Container_removed, Data_removal_requested
  | Data_removal_requested, Resources_removed -> true
  | (Resources_retained | Container_removal_requested | Container_removed
    | Data_removal_requested | Resources_removed), _ -> false

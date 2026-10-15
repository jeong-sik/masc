type t = Resources_retained | Container_removal_requested | Container_removed
  | Data_removal_requested | Resources_removed

let all = [Resources_retained;Container_removal_requested;Container_removed;
  Data_removal_requested;Resources_removed]
let to_string = function
  | Resources_retained -> "resources_retained"
  | Container_removal_requested -> "container_removal_requested"
  | Container_removed -> "container_removed"
  | Data_removal_requested -> "data_removal_requested"
  | Resources_removed -> "resources_removed"
let of_string = function
  | "resources_retained" -> Some Resources_retained
  | "container_removal_requested" -> Some Container_removal_requested
  | "container_removed" -> Some Container_removed
  | "data_removal_requested" -> Some Data_removal_requested
  | "resources_removed" -> Some Resources_removed
  | _ -> None
let can_transition before after =
  if before=after then true else match before,after with
  | Resources_retained, Container_removal_requested
  | Container_removal_requested, Container_removed
  | Container_removed, Data_removal_requested
  | Data_removal_requested, Resources_removed -> true
  | (Resources_retained | Container_removal_requested | Container_removed
    | Data_removal_requested | Resources_removed), _ -> false

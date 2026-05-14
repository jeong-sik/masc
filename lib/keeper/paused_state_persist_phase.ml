type t =
  | Boot_resume_persist
  | Boot_resume_check
  | Directive

let to_label = function
  | Boot_resume_persist -> "boot_resume_persist"
  | Boot_resume_check -> "boot_resume_check"
  | Directive -> "directive"
;;

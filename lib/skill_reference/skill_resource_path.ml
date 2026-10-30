type t = string list

type error =
  | Empty
  | Absolute
  | Contains_nul
  | Contains_backslash
  | Empty_segment
  | Current_directory_segment
  | Parent_directory_segment

let of_string value =
  if String.equal value ""
  then Error Empty
  else if not (Filename.is_relative value)
  then Error Absolute
  else if String.contains value '\000'
  then Error Contains_nul
  else if String.contains value '\\'
  then Error Contains_backslash
  else
    let segments = String.split_on_char '/' value in
    if List.exists (String.equal "") segments
    then Error Empty_segment
    else if List.exists (String.equal Filename.current_dir_name) segments
    then Error Current_directory_segment
    else if List.exists (String.equal Filename.parent_dir_name) segments
    then Error Parent_directory_segment
    else Ok segments
;;

let to_string segments = String.concat "/" segments
let append_to ~root segments = List.fold_left Filename.concat root segments

let error_to_string = function
  | Empty -> "resource path is empty"
  | Absolute -> "resource path must be relative to the Skill root"
  | Contains_nul -> "resource path contains NUL"
  | Contains_backslash -> "resource path must use slash separators"
  | Empty_segment -> "resource path contains an empty segment"
  | Current_directory_segment -> "resource path contains a current-directory segment"
  | Parent_directory_segment -> "resource path contains a parent-directory segment"
;;

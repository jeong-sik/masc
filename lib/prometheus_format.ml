let labels_to_string = function
  | [] -> ""
  | labels ->
    let pairs =
      List.map (fun (k, v) -> Printf.sprintf "%s=\"%s\"" k (String.escaped v)) labels
    in
    "{" ^ String.concat "," pairs ^ "}"
;;

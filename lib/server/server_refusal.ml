let json ?code ?(fields = []) sentence =
  let code_field =
    match code with
    | None -> []
    | Some code -> [ ("code", `String code) ]
  in
  `Assoc ((("error", `String sentence) :: code_field) @ fields)

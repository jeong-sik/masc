let validate_name name =
  let length = String.length name in
  length > 0
  && length <= 128
  && String.to_seq name
     |> Seq.for_all (fun character ->
       (character >= 'a' && character <= 'z')
       || (character >= 'A' && character <= 'Z')
       || (character >= '0' && character <= '9')
       || character = '_'
       || character = '-')
;;

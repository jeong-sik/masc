let fence_char trimmed =
  if String.starts_with ~prefix:"```" trimmed then Some '`'
  else if String.starts_with ~prefix:"~~~" trimmed then Some '~'
  else None

let is_alphatex_info info =
  let first_word =
    match String.split_on_char ' ' (String.lowercase_ascii (String.trim info)) with
    | word :: _ -> word
    | [] -> ""
  in
  String.equal first_word "alphatex" || String.equal first_word "atex"

let of_text text =
  (* [opened] is the fence char and whether its body is alphaTex. [body] holds
     the lines of the open alphaTex block, newest first. *)
  let rec walk opened body found = function
    | [] -> List.rev found
    | line :: rest -> (
        let trimmed = String.trim line in
        match opened with
        | Some (fence, wanted) ->
            if String.starts_with ~prefix:(String.make 3 fence) trimmed then
              let found =
                if wanted then String.concat "\n" (List.rev body) :: found
                else found
              in
              walk None [] found rest
            else walk opened (if wanted then line :: body else body) found rest
        | None -> (
            match fence_char trimmed with
            | Some fence ->
                let info = String.sub trimmed 3 (String.length trimmed - 3) in
                walk (Some (fence, is_alphatex_info info)) [] found rest
            | None -> walk None [] found rest))
  in
  walk None [] [] (String.split_on_char '\n' text)

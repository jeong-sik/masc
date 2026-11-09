type t = string

let of_raw raw = raw

let fold_lexical_segments ~drop_leading_dotdot path =
  let parts = String.split_on_char '/' path in
  let stack =
    List.fold_left
      (fun stack part ->
        match part, stack with
        | ("" | "."), _ -> stack
        | "..", [] when drop_leading_dotdot -> []
        | "..", top :: rest when top <> ".." -> rest
        | part, _ -> part :: stack)
      [] parts
  in
  List.rev stack

let lexical_normalize_abs abs =
  "/" ^ String.concat "/" (fold_lexical_segments ~drop_leading_dotdot:true abs)

let lexical_normalize_relative path =
  String.concat "/" (fold_lexical_segments ~drop_leading_dotdot:false path)

let raw t = t
let is_discard_sink t = String.equal t "/dev/null"
let pp fmt t = Format.pp_print_string fmt t

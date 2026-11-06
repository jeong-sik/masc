type t = string

let of_raw raw = raw

let lexical_normalize_abs abs =
  let parts = String.split_on_char '/' abs in
  let stack = ref [] in
  List.iter
    (function
      | "" | "." -> ()
      | ".." ->
          (match !stack with
           | _ :: rest -> stack := rest
           | [] -> ())
      | part -> stack := part :: !stack)
    parts;
  "/" ^ String.concat "/" (List.rev !stack)

let raw t = t
let is_discard_sink t = String.equal t "/dev/null"
let pp fmt t = Format.pp_print_string fmt t

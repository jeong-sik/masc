type t = {
  run : string;
  number : int;
}

let separator = '-'

let to_string { run; number } = Printf.sprintf "%s%c%d" run separator number

let of_string text =
  (* The run is read back from the last separator rather than the first, so a
     run whose own name contains one still round-trips. *)
  match String.rindex_opt text separator with
  | None -> None
  | Some at ->
    let run = String.sub text 0 at in
    let suffix = String.sub text (at + 1) (String.length text - at - 1) in
    if String.equal run ""
    then None
    else (
      match int_of_string_opt suffix with
      | Some number when number > 0 -> Some { run; number }
      | Some _ | None -> None)
;;

let equal a b = String.equal a.run b.run && a.number = b.number
let run { run; number = _ } = run

type issuer = {
  issuer_run : string;
  issued : int ref;
}

let issuer ~run = if String.equal run "" then None else Some { issuer_run = run; issued = ref 0 }

let issue { issuer_run; issued } =
  incr issued;
  { run = issuer_run; number = !issued }
;;

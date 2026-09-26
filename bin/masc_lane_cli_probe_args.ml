(** Argument parsing for masc-lane-cli-probe, split from the executable so
    tests can pin it. Every rejection returns [Error]; the executable prints
    {!usage} and exits 2 for all of them. *)

let usage = "masc-lane-cli-probe --lane <librarian|hitl> --runtime <id> [--trials N]"

type args =
  { lane : string
  ; runtime : string
  ; trials : int
  }

let default_trials = 3

let parse_args argv =
  let rec loop lane runtime trials = function
    | "--lane" :: value :: rest -> loop value runtime trials rest
    | "--runtime" :: value :: rest -> loop lane value trials rest
    | "--trials" :: value :: rest ->
      (match int_of_string_opt (String.trim value) with
       | Some n when n > 0 -> loop lane runtime n rest
       | _ -> Error (Printf.sprintf "invalid --trials %S: expected a positive integer" value))
    | [] -> Ok { lane; runtime; trials }
    | other :: _ -> Error ("unexpected argument: " ^ other)
  in
  loop "" "" default_trials argv
;;

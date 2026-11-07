(** Argument parsing for masc-lane-cli-probe, split from the executable so
    tests can pin it. Every rejection returns [Error]; the executable prints
    {!usage} and exits 2 for all of them. *)

let usage =
  "masc-lane-cli-probe --lane <librarian|hitl> --runtime <id> [--trials N] \
   [--vibe-acp PATH]"

type args =
  { lane : string
  ; runtime : string
  ; trials : int
  ; vibe_acp : string option
        (** The [vibe-acp] binary to ask whether Vibe can take the call,
            once before the trials. [None]: no readiness check. *)
  }

let default_trials = 3

let parse_args argv =
  let rec loop lane runtime trials vibe_acp = function
    | "--lane" :: value :: rest -> loop value runtime trials vibe_acp rest
    | "--runtime" :: value :: rest -> loop lane value trials vibe_acp rest
    | "--trials" :: value :: rest ->
      (match int_of_string_opt (String.trim value) with
       | Some n when n > 0 -> loop lane runtime n vibe_acp rest
       | _ -> Error (Printf.sprintf "invalid --trials %S: expected a positive integer" value))
    | "--vibe-acp" :: "" :: _ -> Error "invalid --vibe-acp \"\": expected the vibe-acp path"
    | "--vibe-acp" :: value :: rest -> loop lane runtime trials (Some value) rest
    | [] -> Ok { lane; runtime; trials; vibe_acp }
    | other :: _ -> Error ("unexpected argument: " ^ other)
  in
  loop "" "" default_trials None argv
;;

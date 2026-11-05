type ('bidi, 'ego) written =
  { bidi : 'bidi option
  ; ego : 'ego option
  }

type ('bidi, 'ego) outcome =
  { written : ('bidi, 'ego) written
  ; refusal : string option
  }

type 'a step = after_write:bool -> ('a, string) result

let run step ~after_write =
  match step with
  | None -> Ok None
  | Some step -> Result.map Option.some (step ~after_write)

let write ~bidi ~ego =
  let nothing = { bidi = None; ego = None } in
  match run (Option.map (fun step ~after_write:_ -> step ()) bidi) ~after_write:false with
  | Error refusal -> { written = nothing; refusal = Some refusal }
  | Ok bidi ->
    let written = { nothing with bidi } in
    (match run ego ~after_write:(Option.is_some bidi) with
     | Error refusal -> { written; refusal = Some refusal }
     | Ok ego -> { written = { written with ego }; refusal = None })

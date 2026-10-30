type ('bidi, 'automation, 'ego) written =
  { bidi : 'bidi option
  ; automation : 'automation option
  ; ego : 'ego option
  }

type ('bidi, 'automation, 'ego) outcome =
  { written : ('bidi, 'automation, 'ego) written
  ; refusal : string option
  }

type 'a step = after_write:bool -> ('a, string) result

let run step ~after_write =
  match step with
  | None -> Ok None
  | Some step -> Result.map Option.some (step ~after_write)

let write ~bidi ~automation ~ego =
  let nothing = { bidi = None; automation = None; ego = None } in
  match run (Option.map (fun step ~after_write:_ -> step ()) bidi) ~after_write:false with
  | Error refusal -> { written = nothing; refusal = Some refusal }
  | Ok bidi ->
    let written = { nothing with bidi } in
    (match run automation ~after_write:(Option.is_some bidi) with
     | Error refusal -> { written; refusal = Some refusal }
     | Ok automation ->
       let written = { written with automation } in
       (match run ego ~after_write:(Option.is_some bidi || Option.is_some automation) with
        | Error refusal -> { written; refusal = Some refusal }
        | Ok ego -> { written = { written with ego }; refusal = None }))

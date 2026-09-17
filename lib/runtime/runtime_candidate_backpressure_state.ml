type candidate_backpressure =
  | Unknown_scope_rate_limit of { noted_at : float; retry_after : float option }

let note_rate_limit ~noted_at ~retry_after current =
  let retry_after = Option.bind retry_after (fun seconds ->
    if Float.is_finite seconds && seconds >= 0. then Some seconds else None) in
  match current with
  | Some (Unknown_scope_rate_limit existing) when existing.noted_at > noted_at -> current
  | Some (Unknown_scope_rate_limit _) | None ->
      Some (Unknown_scope_rate_limit { noted_at; retry_after })

let observe_rate_limit ~now = function
  | None -> None
  | Some (Unknown_scope_rate_limit { noted_at; retry_after } as observation) ->
      (match retry_after with
       | Some seconds when now -. noted_at >= seconds -> None
       | Some _ | None -> Some observation)

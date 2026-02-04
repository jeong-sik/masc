(** Lodge Atmosphere — lightweight mood signal for prompts

    Provides a stable, low-cost signal to guide tone.
    Default is neutral; can be overridden by env var. *)

let parse_float_opt s =
  try Some (float_of_string s) with Failure _ -> None

let get_value () =
  match Sys.getenv_opt "MASC_LODGE_ATMOSPHERE" with
  | Some v -> (match parse_float_opt v with Some f -> f | None -> 0.5)
  | None -> 0.5

let get_description () =
  let v = get_value () in
  if v >= 0.8 then "energetic"
  else if v >= 0.6 then "positive"
  else if v >= 0.4 then "neutral"
  else if v >= 0.2 then "low"
  else "quiet"

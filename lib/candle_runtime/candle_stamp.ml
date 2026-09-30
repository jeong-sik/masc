(* See candle_stamp.mli. *)

let at ~now =
  match Ptime.of_float_s (now ()) with
  | Some instant -> Ok (Candle_time.of_ptime instant)
  | None -> Error "the clock gave a time outside the calendar"
;;

let copied ~what text =
  Result.map_error
    (fun detail -> Printf.sprintf "%s: %s" what detail)
    (Candle_time.of_rfc3339 text)
;;

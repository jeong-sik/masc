(* JSONL event type for fusion run registry persistence (RFC-0266 §7 Phase D).
   Each [register_running] / [mark_completed] appends one line so run history
   survives server restart. The event type is intentionally minimal and stable;
   adding new fields is safe because replay ignores unknown JSON keys. *)

type t =
  | Register of
      { run_id : string
      ; keeper : string
      ; preset : string
      ; started_at : float
      }
  | Complete of
      { run_id : string
      ; ok : bool
      ; failure : string option
      ; failure_code : string option
      }

let to_yojson = function
  | Register { run_id; keeper; preset; started_at } ->
    `Assoc
      [ ("event", `String "register")
      ; ("run_id", `String run_id)
      ; ("keeper", `String keeper)
      ; ("preset", `String preset)
      ; ("started_at", `Float started_at)
      ]
  | Complete { run_id; ok; failure; failure_code } ->
    `Assoc
      (List.filter_map
         (fun (k, v) -> Option.map (fun value -> (k, value)) v)
         [ "event", Some (`String "complete")
         ; "run_id", Some (`String run_id)
         ; "ok", Some (`Bool ok)
         ; "failure", Option.map (fun s -> `String s) failure
         ; "failure_code", Option.map (fun s -> `String s) failure_code
         ])
;;

let of_yojson json =
  let open Yojson.Safe.Util in
  match member "event" json |> to_string_option with
  | Some "register" ->
    Ok
      (Register
         { run_id = member "run_id" json |> to_string
         ; keeper = member "keeper" json |> to_string
         ; preset = member "preset" json |> to_string
         ; started_at = member "started_at" json |> to_float
         })
  | Some "complete" ->
    Ok
      (Complete
         { run_id = member "run_id" json |> to_string
         ; ok = member "ok" json |> to_bool
         ; failure = member "failure" json |> to_string_option
         ; failure_code = member "failure_code" json |> to_string_option
         })
  | _ -> Error "unknown fusion registry event"
;;

let to_jsonl t = Yojson.Safe.to_string (to_yojson t) ^ "\n"

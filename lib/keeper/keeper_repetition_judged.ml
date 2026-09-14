(* The loop guard's seed from checkpoint history stops where the guard has
   already judged. See the .mli. *)

type error = Invalid_record of string

let error_to_string = function
  | Invalid_record detail -> "keeper repetition judged record: " ^ detail
;;

let context_key = "keeper_repetition_judged"

let decode = function
  | `Assoc fields ->
    (match List.assoc_opt "history_pairs" fields with
     | Some (`Int pairs) when pairs >= 0 -> Ok pairs
     | Some (`Int pairs) ->
       Error (Invalid_record (Printf.sprintf "history_pairs is negative: %d" pairs))
     | Some _ -> Error (Invalid_record "history_pairs is not an integer")
     | None -> Error (Invalid_record "history_pairs is missing"))
  | _ -> Error (Invalid_record "not an object")
;;

let encode pairs = `Assoc [ "history_pairs", `Int pairs ]

let restore ~source ~target =
  match Agent_core.Context.get_scoped source Agent_core.Context.Session context_key with
  | None ->
    Agent_core.Context.delete_scoped target Agent_core.Context.Session context_key;
    Ok 0
  | Some json ->
    (match decode json with
     | Ok pairs ->
       Agent_core.Context.set_scoped target Agent_core.Context.Session context_key json;
       Ok pairs
     | Error _ as error -> error)
;;

let record context pairs =
  Agent_core.Context.set_scoped context Agent_core.Context.Session context_key (encode pairs)
;;

let seed_beyond ~judged pairs =
  let total = List.length pairs in
  let keep = max 0 (total - judged) in
  List.filteri (fun index _ -> index < keep) pairs
;;

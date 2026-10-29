let rec after_seed seed messages =
  match seed, messages with
  | [], suffix -> Some suffix
  | expected :: rest, actual :: tail when expected = actual -> after_seed rest tail
  | _ :: _, ([] | _ :: _) -> None

let remove_once expected blocks =
  let rec loop earlier = function
    | [] -> None
    | actual :: rest when expected = actual -> Some (List.rev_append earlier rest)
    | actual :: rest -> loop (actual :: earlier) rest
  in
  loop [] blocks

let retains ~media_store ~seed ~messages ~results =
  match results, after_seed seed messages with
  | [], _ -> true
  | _ :: _, None -> false
  | _ :: _, Some suffix ->
    let blocks = List.concat_map
        (fun (message : Agent_core.Types.message) -> message.content) suffix in
    (* The journal records provider blocks; the transcript is compared in that
       form. A transcript whose media cannot be read back proves nothing. *)
    match Agent_core.History.to_wire_blocks media_store blocks with
    | Error _ -> false
    | Ok blocks ->
    let rec consume remaining = function
      | [] -> true
      | result :: rest ->
        match remove_once result remaining with
        | None -> false
        | Some remaining -> consume remaining rest
    in
    consume blocks results

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

let retains ~seed ~messages ~results =
  match results, after_seed seed messages with
  | [], _ -> Ok true
  | _ :: _, None -> Ok false
  | _ :: _, Some suffix ->
    let blocks = List.concat_map
        (fun (message : Agent_core.Types.message) -> message.content) suffix in
    (* The journal records provider blocks. In history form they name their
       media by digest, as the transcript does, so the comparison reads no
       store and does not depend on how the base64 was written. *)
    Result.map
      (fun results ->
         let rec consume remaining = function
           | [] -> true
           | result :: rest ->
             (match remove_once result remaining with
              | None -> false
              | Some remaining -> consume remaining rest)
         in
         consume blocks results)
      (Agent_core.History.reference_of_wire_blocks results)

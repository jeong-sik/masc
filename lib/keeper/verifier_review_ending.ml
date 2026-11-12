type t =
  | Succeeded
  | Failed
  | Cancelled
  | Owner_lost

let cancelled_fact = "cancelled"
let ended_without_verdict_fact = "ended_without_verdict"

(* [Cancelled] has no label: its observation predates the others and carries
   no ending field. *)
let label = function
  | Succeeded -> Some "succeeded"
  | Failed -> Some "failed"
  | Owner_lost -> Some "owner_lost"
  | Cancelled -> None

let of_label text =
  List.find_opt
    (fun ending -> Option.equal String.equal (label ending) (Some text))
    [ Succeeded; Failed; Owner_lost ]

let observation ~runtime_id ending =
  match label ending with
  | None -> `Assoc [ "fact", `String cancelled_fact; "runtime_id", `String runtime_id ]
  | Some label ->
    `Assoc
      [ "fact", `String ended_without_verdict_fact
      ; "runtime_id", `String runtime_id
      ; "ending", `String label
      ]

let of_observation = function
  | `Assoc fields ->
    let text key =
      match List.assoc_opt key fields with
      | Some (`String value) -> Some value
      | Some _ | None -> None
    in
    (match List.sort String.compare (List.map fst fields), text "fact", text "runtime_id" with
     | [ "fact"; "runtime_id" ], Some fact, Some runtime_id
       when String.equal fact cancelled_fact && String.trim runtime_id <> "" ->
       Some (runtime_id, Cancelled)
     | [ "ending"; "fact"; "runtime_id" ], Some fact, Some runtime_id
       when String.equal fact ended_without_verdict_fact && String.trim runtime_id <> "" ->
       Option.bind (text "ending") of_label
       |> Option.map (fun ending -> runtime_id, ending)
     | _, _, _ -> None)
  | `Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _ | `List _ -> None

type t =
  { trace_id : Keeper_id.Trace_id.t
  ; generation : int
  ; turn_count : int
  ; sha256 : string
  }

type create_error =
  | Negative_generation of int
  | Negative_turn_count of int
  | Invalid_sha256 of string

let validate_coordinates ~generation ~turn_count =
  if generation < 0
  then Error (Negative_generation generation)
  else if turn_count < 0
  then Error (Negative_turn_count turn_count)
  else Ok ()
;;

let create ~trace_id ~generation ~turn_count ~canonical_checkpoint_bytes =
  match validate_coordinates ~generation ~turn_count with
  | Error _ as error -> error
  | Ok () ->
    Ok
      { trace_id
      ; generation
      ; turn_count
      ; sha256 = Digestif.SHA256.(digest_string canonical_checkpoint_bytes |> to_hex)
      }
;;

let of_persisted ~trace_id ~generation ~turn_count ~sha256 =
  match validate_coordinates ~generation ~turn_count with
  | Error _ as error -> error
  | Ok () ->
    (match Digestif.SHA256.consistent_of_hex_opt sha256 with
     | Some digest when String.equal sha256 (Digestif.SHA256.to_hex digest) ->
       Ok { trace_id; generation; turn_count; sha256 }
     | Some _ | None -> Error (Invalid_sha256 sha256))
;;

let equal left right =
  Keeper_id.Trace_id.equal left.trace_id right.trace_id
  && Int.equal left.generation right.generation
  && Int.equal left.turn_count right.turn_count
  && String.equal left.sha256 right.sha256
;;

let to_yojson checkpoint =
  `Assoc
    [ "trace_id", `String (Keeper_id.Trace_id.to_string checkpoint.trace_id)
    ; "generation", `Int checkpoint.generation
    ; "turn_count", `Int checkpoint.turn_count
    ; "sha256", `String checkpoint.sha256
    ]
;;

let of_yojson = function
  | `Assoc fields ->
    let expected = [ "generation"; "sha256"; "trace_id"; "turn_count" ] in
    let actual = List.map fst fields |> List.sort String.compare in
    if not (List.equal String.equal expected actual)
    then
      Error
        "checkpoint identity must contain exactly trace_id, generation, turn_count, sha256"
    else (
      let required_string key =
        match List.assoc_opt key fields with
        | Some (`String value) -> Ok value
        | Some _ -> Error (Printf.sprintf "checkpoint field %s must be a string" key)
        | None -> Error (Printf.sprintf "checkpoint field %s is missing" key)
      in
      let required_int key =
        match List.assoc_opt key fields with
        | Some (`Int value) -> Ok value
        | Some _ -> Error (Printf.sprintf "checkpoint field %s must be an int" key)
        | None -> Error (Printf.sprintf "checkpoint field %s is missing" key)
      in
      let ( let* ) = Result.bind in
      let* trace_id_raw = required_string "trace_id" in
      let* trace_id = Keeper_id.Trace_id.of_string trace_id_raw in
      let* generation = required_int "generation" in
      let* turn_count = required_int "turn_count" in
      let* sha256 = required_string "sha256" in
      of_persisted ~trace_id ~generation ~turn_count ~sha256
      |> Result.map_error (function
        | Negative_generation value ->
          Printf.sprintf "checkpoint generation is negative: %d" value
        | Negative_turn_count value ->
          Printf.sprintf "checkpoint turn count is negative: %d" value
        | Invalid_sha256 value ->
          Printf.sprintf "checkpoint digest is invalid: %s" value))
  | json ->
    Error
      (Printf.sprintf
         "checkpoint identity must be an object (received %s)"
         (Yojson.Safe.to_string json))
;;

module type Error = sig
  type t

  val protocol : stage:string -> detail:string -> t
end

module Make (E : Error) = struct
  let protocol_error stage detail = Error (E.protocol ~stage ~detail)
  let ( let* ) result f = Result.bind result f
  exception Idle_timeout of float

  let with_optional_timeout clock timeout_s f =
    match timeout_s with
    | None -> f ()
    | Some seconds ->
      (match Eio.Time.with_timeout clock seconds (fun () -> Ok (f ())) with
       | Ok value -> value
       | Error `Timeout -> raise (Idle_timeout seconds))
  ;;

  let rec validate_unique_object_keys ~stage ~path = function
    | `Assoc fields ->
      let rec loop seen = function
        | [] -> Ok ()
        | (name, value) :: rest ->
          if List.mem name seen
          then
            protocol_error
              stage
              (Printf.sprintf "duplicate object key %S at %s" name path)
          else
            let* () =
              validate_unique_object_keys
                ~stage
                ~path:(path ^ "." ^ name)
                value
            in
            loop (name :: seen) rest
      in
      loop [] fields
    | `List values ->
      let rec loop index = function
        | [] -> Ok ()
        | value :: rest ->
          let* () =
            validate_unique_object_keys
              ~stage
              ~path:(Printf.sprintf "%s[%d]" path index)
              value
          in
          loop (index + 1) rest
      in
      loop 0 values
    | `Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _ -> Ok ()
  ;;

  let assoc_at stage = function
    | `Assoc fields -> Ok fields
    | _ -> protocol_error stage "expected a JSON object"
  ;;

  let required_member stage name fields =
    match List.assoc_opt name fields with
    | Some value -> Ok value
    | None -> protocol_error stage (Printf.sprintf "missing field %S" name)
  ;;

  let required_string stage name fields =
    match List.assoc_opt name fields with
    | Some (`String value) when String.trim value <> "" -> Ok value
    | Some _ ->
      protocol_error stage (Printf.sprintf "field %S must be a non-empty string" name)
    | None -> protocol_error stage (Printf.sprintf "missing field %S" name)
  ;;

  let optional_string stage name fields =
    match List.assoc_opt name fields with
    | None | Some `Null -> Ok None
    | Some (`String value) -> Ok (Some value)
    | Some _ ->
      protocol_error stage (Printf.sprintf "field %S must be a string or null" name)
  ;;

  let required_bool stage name fields =
    match List.assoc_opt name fields with
    | Some (`Bool value) -> Ok value
    | Some _ -> protocol_error stage (Printf.sprintf "field %S must be a boolean" name)
    | None -> protocol_error stage (Printf.sprintf "missing field %S" name)
  ;;

  let invoke_state_callback ~stage callback =
    try
      match callback () with
      | Ok () -> Ok ()
      | Error detail -> protocol_error stage detail
    with
    | Eio.Cancel.Cancelled _ as exn -> raise exn
    | Idle_timeout _ as exn -> raise exn
    | Eio.Time.Timeout as exn -> raise exn
    | exn -> protocol_error stage (Printexc.to_string exn)
  ;;

end

let bounded_tail ~limit current addition =
  let combined = current ^ addition in
  let length = String.length combined in
  if length <= limit then combined else String.sub combined (length - limit) limit
;;

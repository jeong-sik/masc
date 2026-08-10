type token =
  { mutable active : bool
  ; mutable validator : (unit -> (unit, string) result) option
  }

let run f =
  let token = { active = true; validator = None } in
  let invalidate () = token.active <- false in
  match f token with
  | value ->
    invalidate ();
    value
  | exception exn ->
    invalidate ();
    raise exn
;;

let install token validator =
  if not token.active
  then Error "keeper turn dispatch authority is no longer active"
  else
    match token.validator with
    | Some _ -> Error "keeper turn dispatch authority is already installed"
    | None ->
      token.validator <- Some validator;
      Ok ()
;;

let validate token =
  if not token.active
  then Error "keeper turn dispatch authority is no longer active"
  else
    match token.validator with
    | None -> Error "keeper turn dispatch authority is not installed"
    | Some validator -> validator ()
;;

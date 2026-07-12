(** Typed input contract shared by keeper sandbox schemas and handlers. *)

type bounded_float =
  { minimum : float
  ; maximum : float
  ; default : float
  }

let managed_ttl_sec =
  { minimum = 1.0; maximum = 86_400.0; default = 1_800.0 }
;;

let operation_timeout_sec =
  { minimum = 1.0; maximum = 30.0; default = 10.0 }
;;

let clamp bounds value =
  Stdlib.Float.min bounds.maximum (Stdlib.Float.max bounds.minimum value)
;;

type stop_scope =
  | Stop_managed
  | Stop_turn
  | Stop_all

let all_stop_scopes = [ Stop_managed; Stop_turn; Stop_all ]
let default_stop_scope = Stop_managed

let stop_scope_to_string = function
  | Stop_managed -> "managed"
  | Stop_turn -> "turn"
  | Stop_all -> "all"
;;

let stop_scope_strings = List.map stop_scope_to_string all_stop_scopes

let parse_stop_scope raw =
  let normalized = String.lowercase_ascii (String.trim raw) in
  if String.equal normalized ""
  then Ok default_stop_scope
  else
    match
      List.find_opt
        (fun scope -> String.equal normalized (stop_scope_to_string scope))
        all_stop_scopes
    with
    | Some scope -> Ok scope
    | None ->
      Error
        (Printf.sprintf
           "invalid container_kind %S; expected %s"
           normalized
           (String.concat ", " stop_scope_strings))
;;

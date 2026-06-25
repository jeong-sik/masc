(** Shared env parsing helpers for memory-related keeper knobs. *)

type invalid_bool_policy =
  | Default
  | Fail_closed

let accepted_true_bool_tokens = [ "1"; "true"; "yes"; "on"; "enabled" ]
let accepted_false_bool_tokens = [ "0"; "false"; "no"; "off"; "disabled" ]

let parse_bool_token raw =
  let token = String.lowercase_ascii raw in
  if List.exists (String.equal token) accepted_true_bool_tokens
  then Some true
  else if List.exists (String.equal token) accepted_false_bool_tokens
  then Some false
  else None
;;

let env_opt name =
  match Env_config_core.raw_value_opt name with
  | None -> None
  | Some raw ->
      let value = String.trim raw in
      if String.equal value "" then None else Some value
;;

let get_int_logged name ~default =
  match env_opt name with
  | None -> default
  | Some raw ->
      (match int_of_string_opt raw with
       | Some value -> value
       | None ->
           Log.Keeper.warn "invalid %s=%S; using default %d" name raw default;
           default)
;;

let get_float_positive_logged name ~default =
  match env_opt name with
  | None -> default
  | Some raw ->
      (match float_of_string_opt raw with
       | Some value when Float.is_finite value && value > 0.0 -> value
       | _ ->
           Log.Keeper.warn "invalid %s=%S; using default %.3f" name raw default;
           default)
;;

let get_bool_logged ?(invalid = Default) name ~default =
  match env_opt name with
  | None -> default
  | Some raw ->
      (match parse_bool_token raw with
       | Some value -> value
       | None ->
         (match invalid with
          | Default ->
              Log.Keeper.warn "invalid %s=%S; using default %b" name raw default;
              default
          | Fail_closed ->
              Log.Keeper.warn
                "invalid %s=%S; using fail-closed false (default would be %b)"
                name
                raw
                default;
              false))
;;

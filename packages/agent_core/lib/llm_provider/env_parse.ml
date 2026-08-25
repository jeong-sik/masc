let bool_of_string ?(default = false) raw =
  match String.lowercase_ascii (String.trim raw) with
  | "1" | "true" | "yes" | "on" -> true
  | "0" | "false" | "no" | "off" -> false
  | "" -> default
  | _ -> default
;;

let bool_env ?(default = false) name =
  match Sys.getenv_opt name with
  | None -> default
  | Some raw -> bool_of_string ~default raw
;;

let with_env name value f =
  let original = Sys.getenv_opt name in
  let restore () =
    match original with
    (* OCaml 5.5 adds Unix.unsetenv, but this library still supports the 5.4
       floor. All readers in this module treat the empty string as unset/default,
       so tests can safely restore absent variables to an empty value. *)
    | None -> Unix.putenv name ""
    | Some v -> Unix.putenv name v
  in
  Fun.protect ~finally:restore (fun () ->
    Unix.putenv name value;
    f ())
;;

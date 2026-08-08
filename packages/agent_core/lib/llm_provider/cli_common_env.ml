let trim_non_empty s =
  let trimmed = String.trim s in
  if trimmed = "" then None else Some trimmed
;;

let trim_non_empty_opt = function
  | None -> None
  | Some s -> trim_non_empty s
;;

let default_getenv = Sys.getenv_opt

(* [get ?getenv name] is the canonical env-read primitive. The optional
   [getenv] argument (default [Sys.getenv_opt]) is a dependency-injection
   seam so callers and tests can resolve the environment without touching
   the process env (RFC-OAS-024 §6 cut 5). The pure core never calls this
   directly — it receives resolved config values as arguments. *)
let get ?(getenv = default_getenv) name = trim_non_empty_opt (getenv name)

let split_on_char_trim sep s =
  String.split_on_char sep s |> List.filter_map (fun item -> trim_non_empty item)
;;

[@@@coverage off]

(* RFC-OAS-024 §6 cut 5: the ?getenv seam lets tests/callers resolve the
   environment deterministically without mutating process-global state. *)
let%test "get honors injected getenv (RFC-OAS-024 seam)" =
  let never _ = None in
  let always_yes _ = Some "yes" in
  get ~getenv:never "OAS_UNSET_VAR_ZZZ" = None
  && get ~getenv:always_yes "OAS_ANY_VAR_ZZZ" = Some "yes"
;;

let%test "split_on_char_trim drops empty fragments" =
  split_on_char_trim ',' "a, b, ,c" = [ "a"; "b"; "c" ]
;;

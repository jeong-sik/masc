type 'a t =
  | Present of 'a
  | Missing
  | Type_mismatch of {
      path : string list;
      expected : string;
      message : string;
    }

let path_to_string path = String.concat "." path

(* [resolve_with accessor expected toml path] applies [accessor] to
   the value at [path]. Three outcomes:
   - the key is not present in the TOML object → [Missing];
   - the key is present and the accessor returns cleanly → [Present];
   - the key is present and the accessor raises [Otoml.Type_error] →
     [Type_mismatch].

   Otoml's [find_opt] returns [None] only for key-absence; type
   errors come from the accessor itself. Using [Fun.id] as the
   accessor in [find_opt] guarantees the [Otoml.Type_error] is
   raised at the call to [accessor], not inside [find_opt], so the
   two outcomes stay separable. *)
let resolve_with
  (accessor : Otoml.t -> 'a)
  (expected : string)
  (toml : Otoml.t)
  (path : string list)
  : 'a t
  =
  match Otoml.find_opt toml Fun.id path with
  | None -> Missing
  | Some raw ->
    (try Present (accessor raw)
     with Otoml.Type_error message -> Type_mismatch { path; expected; message })
;;

let resolve_string toml path =
  resolve_with Otoml.get_string "string" toml path
;;

let resolve_bool toml path = resolve_with Otoml.get_boolean "bool" toml path

let resolve_int toml path = resolve_with Otoml.get_integer "int" toml path

(* TOML string-array: get_array applied with get_string on each
   element. Both raise [Otoml.Type_error] on shape mismatch, so the
   wrapper picks them up uniformly. *)
let resolve_strings toml path =
  resolve_with (Otoml.get_array Otoml.get_string) "string list" toml path
;;

let or_default ~default = function
  | Present v -> Ok v
  | Missing -> Ok default
  | Type_mismatch { path; expected; message } ->
    Error
      (Printf.sprintf
         "field_resolution: %s has wrong type (expected %s): %s"
         (path_to_string path)
         expected
         message)
;;

let require = function
  | Present v -> Ok v
  | Missing -> Error "field_resolution: required field is absent"
  | Type_mismatch { path; expected; message } ->
    Error
      (Printf.sprintf
         "field_resolution: required %s has wrong type (expected %s): %s"
         (path_to_string path)
         expected
         message)
;;

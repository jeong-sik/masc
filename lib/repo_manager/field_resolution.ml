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

   Otoml's [find_opt] also returns [None] when an intermediate path
   component is not a table. Traverse the path explicitly so that
   only a genuinely absent key becomes [Missing]; a scalar parent is
   a schema [Type_mismatch]. *)
let resolve_with
  (accessor : Otoml.t -> 'a)
  (expected : string)
  (toml : Otoml.t)
  (path : string list)
  : 'a t
  =
  let rec descend traversed value remaining =
    match remaining with
    | [] ->
      (try Present (accessor value)
       with Otoml.Type_error message -> Type_mismatch { path; expected; message })
    | key :: rest ->
      (match Otoml.get_table value with
       | exception Otoml.Type_error message ->
         Type_mismatch
           { path = List.rev traversed
           ; expected = "table"
           ; message
           }
       | fields ->
         (match List.assoc_opt key fields with
          | None -> Missing
          | Some child -> descend (key :: traversed) child rest))
  in
  descend [] toml path
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

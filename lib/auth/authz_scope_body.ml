(* HIGH-RISK-UNREVIEWED: see the interface. *)

open Authz_types

let ( let* ) = Result.bind
let all_label = "all"

(* What a member holds before its labels are read. *)
type shape =
  | All_of
  | Labels of string list

(* The first error, from the left. *)
let map_in_order f items =
  let rec go acc = function
    | [] -> Ok (List.rev acc)
    | item :: rest ->
      let* mapped = f item in
      go (mapped :: acc) rest
  in
  go [] items
;;

let shape_to_body = function
  | All_of -> Authz_body.string all_label
  | Labels labels ->
    let* items = map_in_order Authz_body.string labels in
    Ok (Authz_body.list items)
;;

(* The elements of a set come in the order of its compare, which is the byte
   order of the labels for all three (see [Authz_types]). *)
let runtimes_shape = function
  | Runtime_scope.All -> All_of
  | Runtime_scope.Empty -> Labels []
  | Runtime_scope.Only set -> Labels (List.map Runtime_id.to_string (Runtime_id.Set.elements set))
;;

let channels_shape = function
  | Channel_scope.All -> All_of
  | Channel_scope.Empty -> Labels []
  | Channel_scope.Only set -> Labels (List.map Channel.to_string (Channel.Set.elements set))
;;

let effect_labels set = List.map Effect.to_string (Effect.Set.elements set)

let effects_shape = function
  | Effect_scope.All -> All_of
  | Effect_scope.Empty -> Labels []
  | Effect_scope.Only set -> Labels (effect_labels set)
;;

let to_body (scope : Authorization_scope.t) =
  let* runtimes = shape_to_body (runtimes_shape scope.runtimes) in
  let* channels = shape_to_body (channels_shape scope.channels) in
  let* allowed_effects = shape_to_body (effects_shape scope.allowed_effects) in
  Authz_body.object_
    [ "runtimes", runtimes; "channels", channels; "allowed_effects", allowed_effects ]
;;

type dimension =
  | Runtimes
  | Channels
  | Allowed_effects

type error =
  | Not_an_object
  | Wrong_members
  | Not_a_scope of dimension
  | Not_ascending of dimension
  | Invalid_runtime_id of Authz_id.error
  | Unknown_channel of string
  | Unknown_effect of string

let dimension_to_string = function
  | Runtimes -> "runtimes"
  | Channels -> "channels"
  | Allowed_effects -> "allowed_effects"
;;

let error_to_string = function
  | Not_an_object -> "a scope is an object"
  | Wrong_members ->
    "a scope has the members runtimes, channels, and allowed_effects, in this order"
  | Not_a_scope dimension ->
    Printf.sprintf "%s is neither \"all\" nor a list of strings" (dimension_to_string dimension)
  | Not_ascending dimension ->
    Printf.sprintf
      "the labels of %s are not in strictly ascending order"
      (dimension_to_string dimension)
  | Invalid_runtime_id error -> "a runtime id is not valid: " ^ Authz_id.error_to_string error
  | Unknown_channel label -> Printf.sprintf "%S is not a channel" label
  | Unknown_effect label -> Printf.sprintf "%S is not an effect" label
;;

let rec strictly_ascending = function
  | first :: (second :: _ as rest) -> String.compare first second < 0 && strictly_ascending rest
  | [ _ ] | [] -> true
;;

let string_of_item item =
  match Authz_body.string_value item with
  | Some text -> Ok text
  | None -> Error ()
;;

let shape_of dimension (body : Authz_body.t) =
  match body with
  | Authz_body.String text when String.equal text all_label -> Ok All_of
  | Authz_body.List items ->
    (match map_in_order string_of_item items with
     | Error () -> Error (Not_a_scope dimension)
     | Ok labels ->
       if strictly_ascending labels then Ok (Labels labels) else Error (Not_ascending dimension))
  | Authz_body.String _
  | Authz_body.Null
  | Authz_body.Bool _
  | Authz_body.Int _
  | Authz_body.Object _ -> Error (Not_a_scope dimension)
;;

let runtimes_of = function
  | All_of -> Ok Runtime_scope.all
  | Labels labels ->
    let* ids =
      map_in_order
        (fun label ->
           Result.map_error (fun error -> Invalid_runtime_id error) (Runtime_id.of_string label))
        labels
    in
    Ok (Runtime_scope.only (Runtime_id.Set.of_list ids))
;;

let channels_of = function
  | All_of -> Ok Channel_scope.all
  | Labels labels ->
    let* channels =
      map_in_order
        (fun label -> Option.to_result ~none:(Unknown_channel label) (Channel.of_string label))
        labels
    in
    Ok (Channel_scope.only (Channel.Set.of_list channels))
;;

let effect_set_of_labels labels =
  let* effects =
    map_in_order
      (fun label -> Option.to_result ~none:(Unknown_effect label) (Effect.of_string label))
      labels
  in
  Ok (Effect.Set.of_list effects)
;;

let effects_of = function
  | All_of -> Ok Effect_scope.all
  | Labels labels ->
    let* effects = effect_set_of_labels labels in
    Ok (Effect_scope.only effects)
;;

let of_body (body : Authz_body.t) =
  match body with
  | Authz_body.Object
      [ ("runtimes", runtimes); ("channels", channels); ("allowed_effects", allowed_effects) ] ->
    let* runtimes = Result.bind (shape_of Runtimes runtimes) runtimes_of in
    let* channels = Result.bind (shape_of Channels channels) channels_of in
    let* allowed_effects = Result.bind (shape_of Allowed_effects allowed_effects) effects_of in
    Ok { Authorization_scope.runtimes; channels; allowed_effects }
  | Authz_body.Object _ -> Error Wrong_members
  | Authz_body.Null
  | Authz_body.Bool _
  | Authz_body.Int _
  | Authz_body.String _
  | Authz_body.List _ -> Error Not_an_object
;;

let effect_set_to_body set = shape_to_body (Labels (effect_labels set))

let effect_set_of_body body =
  let* shape = shape_of Allowed_effects body in
  match shape with
  | All_of -> Error (Not_a_scope Allowed_effects)
  | Labels labels -> effect_set_of_labels labels
;;

(** JSON helpers + projection-diagnostic field readers + operator
    cache JSON wrapper, extracted from server_dashboard_http_core.ml. *)

let json_assoc_int_opt key json =
  match Json_util.assoc_member_opt key json with
  | Some (`Int value) -> Some value
  | Some (`Float value) -> Some (int_of_float value)
  | _ -> None
;;

let projection_diagnostics_fields json =
  match Json_util.assoc_member_opt "projection_diagnostics" json with
  | Some (`Assoc fields) -> fields
  | _ -> []
;;

let projection_diagnostics_field json key =
  List.assoc_opt key (projection_diagnostics_fields json)
;;

let operator_generated_at_iso json =
  match projection_diagnostics_field json "generated_at" with
  | Some (`String value) -> value
  | _ ->
    (match Json_util.assoc_string_opt "generated_at" json with
     | Some value -> value
     | None -> Masc_domain.now_iso ())
;;

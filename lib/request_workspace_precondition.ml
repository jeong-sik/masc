let expected_base_path_header = "x-masc-expected-base-path"
let expected_masc_root_header = "x-masc-expected-masc-root"

type identity =
  { base_path : string
  ; masc_root : string
  }

type refusal =
  | Invalid_precondition of string
  | Workspace_mismatch
  | Server_booting

type decision =
  | No_precondition
  | Precondition_met
  | Refused of refusal

let check_path ~header value =
  if String.equal value ""
  then Error (header ^ " is empty")
  else if Filename.is_relative value
  then Error (header ^ " is not an absolute path")
  else Ok value
;;

let decide ~identity ~ready ~expected_base_path ~expected_masc_root =
  match expected_base_path, expected_masc_root with
  | [], [] -> No_precondition
  | [ base_path ], [ masc_root ] ->
    (match
       ( check_path ~header:expected_base_path_header base_path
       , check_path ~header:expected_masc_root_header masc_root )
     with
     | Error why, (Ok _ | Error _) | Ok _, Error why ->
       Refused (Invalid_precondition why)
     | Ok base_path, Ok masc_root ->
       (match identity with
        | None -> Refused Server_booting
        | Some served ->
          if not
               (String.equal base_path served.base_path
                && String.equal masc_root served.masc_root)
          then Refused Workspace_mismatch
          else if ready
          then Precondition_met
          else Refused Server_booting))
  | [], _ :: _ | _ :: _, [] ->
    Refused
      (Invalid_precondition
         (Printf.sprintf "%s and %s go together" expected_base_path_header
            expected_masc_root_header))
  | _ :: _ :: _, _ :: _ | _ :: _, _ :: _ :: _ ->
    Refused (Invalid_precondition "a workspace precondition header is given more than once")
;;

let refusal_code = function
  | Invalid_precondition _ -> "invalid_workspace_precondition"
  | Workspace_mismatch -> "workspace_precondition_failed"
  | Server_booting -> "server_booting"
;;

let refusal_message = function
  | Invalid_precondition why -> "invalid workspace precondition: " ^ why
  | Workspace_mismatch -> "workspace precondition failed"
  | Server_booting -> "server is starting and has not confirmed its workspace"
;;

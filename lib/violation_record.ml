(** Violation_record — Typed violation records + constraint algebra.

    @since CDAL eval content-based redesign *)

type violation_kind =
  | Mutating_in_diagnose
  | External_in_draft
  | Scope_violation
  | Unknown of string

type t = {
  ts : float;
  tool_name : string;
  input_summary : string;
  effective_mode : Agent_sdk.Execution_mode.t;
  violation_kind : violation_kind;
}

let violation_kind_of_string = function
  | "mutating_in_diagnose" -> Mutating_in_diagnose
  | "external_in_draft" -> External_in_draft
  | "scope_violation" -> Scope_violation
  | s -> Unknown s

let violation_kind_to_string = function
  | Mutating_in_diagnose -> "mutating_in_diagnose"
  | External_in_draft -> "external_in_draft"
  | Scope_violation -> "scope_violation"
  | Unknown s -> s

let effective_mode_of_string = function
  | "diagnose" -> Agent_sdk.Execution_mode.Diagnose
  | "draft" -> Agent_sdk.Execution_mode.Draft
  | "execute" -> Agent_sdk.Execution_mode.Execute
  | _ -> Agent_sdk.Execution_mode.Diagnose

let of_json (json : Yojson.Safe.t) : (t, string) result =
  match json with
  | `Assoc fields ->
    let get key = List.assoc_opt key fields in
    (match get "ts", get "tool_name", get "violation_kind", get "effective_mode" with
     | Some (`Float ts), Some (`String tool_name),
       Some (`String vk), Some (`String em) ->
       let input_summary = match get "input_summary" with
         | Some (`String s) -> s
         | _ -> ""
       in
       Ok {
         ts;
         tool_name;
         input_summary;
         effective_mode = effective_mode_of_string em;
         violation_kind = violation_kind_of_string vk;
       }
     | _ -> Error "missing required fields in violation record")
  | _ -> Error "violation record must be a JSON object"

let of_json_list (json : Yojson.Safe.t) : (t list, string) result =
  match json with
  | `List items ->
    let rec parse acc = function
      | [] -> Ok (List.rev acc)
      | item :: rest ->
        (match of_json item with
         | Ok v -> parse (v :: acc) rest
         | Error e -> Error e)
    in
    parse [] items
  | _ -> Error "expected JSON array of violation records"

let minimum_required_mode (v : t) : Agent_sdk.Execution_mode.t =
  match v.violation_kind with
  | Mutating_in_diagnose -> Agent_sdk.Execution_mode.Draft
  | External_in_draft -> Agent_sdk.Execution_mode.Execute
  | Scope_violation -> Agent_sdk.Execution_mode.Execute
  | Unknown _ -> v.effective_mode

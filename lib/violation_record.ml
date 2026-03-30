(** Violation_record — Typed violation records + constraint algebra.

    Delegates JSON serialization to Agent_sdk.Mode_enforcer canonical types.
    MASC consumers use this module for backward-compatible access.

    @since CDAL eval content-based redesign
    @see Agent_sdk.Mode_enforcer for canonical serializers *)

(** Re-export OAS canonical violation_kind. *)
type violation_kind = Agent_sdk.Mode_enforcer.violation_kind =
  | Mutating_in_diagnose
  | External_in_draft
  | Scope_violation

(** Re-export OAS canonical violation record. *)
type t = Agent_sdk.Mode_enforcer.violation = {
  ts : float;
  tool_name : string;
  input_summary : string;
  effective_mode : Agent_sdk.Execution_mode.t;
  violation_kind : violation_kind;
}

let violation_kind_of_string s =
  Agent_sdk.Mode_enforcer.violation_kind_of_string s

let violation_kind_to_string v =
  Agent_sdk.Mode_enforcer.violation_kind_to_string v

let of_json json = Agent_sdk.Mode_enforcer.violation_of_yojson json

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

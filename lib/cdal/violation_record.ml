(** Violation_record — Typed violation records + constraint algebra.

    Delegates JSON serialization to Masc_mcp_cdal_runtime.Mode_enforcer canonical types.
    MASC consumers use this module for backward-compatible access.

    @since CDAL eval content-based redesign
    @see Masc_mcp_cdal_runtime.Mode_enforcer for canonical serializers *)

(** Re-export OAS canonical violation_kind. *)
type violation_kind = Masc_mcp_cdal_runtime.Mode_enforcer.violation_kind =
  | Mutating_in_diagnose
  | External_in_draft
  | Scope_violation

(** Re-export OAS canonical violation record. *)
type t = Masc_mcp_cdal_runtime.Mode_enforcer.violation =
  { ts : float
  ; tool_name : string
  ; input_summary : string
  ; effective_mode : Masc_mcp_cdal_runtime.Execution_mode.t
  ; violation_kind : violation_kind
  }

let violation_kind_of_string s =
  match String.lowercase_ascii s with
  | "mutating_in_diagnose" -> Ok Masc_mcp_cdal_runtime.Mode_enforcer.Mutating_in_diagnose
  | "external_in_draft" -> Ok Masc_mcp_cdal_runtime.Mode_enforcer.External_in_draft
  | "scope_violation" -> Ok Masc_mcp_cdal_runtime.Mode_enforcer.Scope_violation
  | other -> Error (Printf.sprintf "unknown violation_kind: %s" other)
;;

let violation_kind_to_string v =
  Masc_mcp_cdal_runtime.Mode_enforcer.violation_kind_to_string v
;;

let of_json (json : Yojson.Safe.t) : (t, string) result =
  let open Yojson.Safe.Util in
  try
    let ts = json |> member "ts" |> to_float in
    let tool_name = json |> member "tool_name" |> to_string in
    let input_summary = json |> member "input_summary" |> to_string in
    match
      Masc_mcp_cdal_runtime.Execution_mode.of_yojson (json |> member "effective_mode")
    with
    | Error e -> Error (Printf.sprintf "effective_mode parse: %s" e)
    | Ok effective_mode ->
      (match violation_kind_of_string (json |> member "violation_kind" |> to_string) with
       | Ok violation_kind ->
         Ok { ts; tool_name; input_summary; effective_mode; violation_kind }
       | Error e -> Error e)
  with
  | Eio.Cancel.Cancelled _ as e -> raise e
  | exn -> Error (Printexc.to_string exn)
;;

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
;;

let minimum_required_mode (v : t) : Masc_mcp_cdal_runtime.Execution_mode.t =
  match v.violation_kind with
  | Mutating_in_diagnose -> Masc_mcp_cdal_runtime.Execution_mode.Draft
  | External_in_draft -> Masc_mcp_cdal_runtime.Execution_mode.Execute
  | Scope_violation -> Masc_mcp_cdal_runtime.Execution_mode.Execute
;;

(** Routing-affecting pre-dispatch skip reasons.

    Each variant captures the structured evidence needed for fleet
    diagnostics and runtime manifest emission.  The [to_manifest_tag]
    and [to_yojson] functions produce stable, lowercase-underscore
    labels so that downstream dashboards and log parsers do not break
    when new variants are added. *)

type t =
  | Required_tool_unsupported of { missing : string list }
  | Capacity_constrained of { provider_key : string }
  | Health_cooldown_active of { provider_key : string; cooldown_reason : string }
  | Capacity_full of
      { capacity_key : string
      ; capacity_kind : [ `Client | `Admission ]
      ; retry_after_sec : float option
      }
  | Accept_rejected of { reason : string }

let to_manifest_tag = function
  | Required_tool_unsupported _ -> "required_tool_unsupported"
  | Capacity_constrained _ -> "capacity_constrained"
  | Health_cooldown_active _ -> "health_cooldown_active"
  | Capacity_full { capacity_kind = `Client; _ } -> "client_capacity_full"
  | Capacity_full { capacity_kind = `Admission; _ } -> "admission_full"
  | Accept_rejected _ -> "accept_rejected"

let to_yojson ~candidate reason =
  match reason with
  | Required_tool_unsupported { missing } ->
    `Assoc
      [
        ("kind", `String (to_manifest_tag reason));
        ("candidate", `String candidate);
        ("missing", `List (List.map (fun tool -> `String tool) missing));
      ]
  | Capacity_constrained { provider_key } ->
    `Assoc
      [
        ("kind", `String (to_manifest_tag reason));
        ("candidate", `String candidate);
        ("provider_key", `String provider_key);
      ]
  | Health_cooldown_active { provider_key; cooldown_reason } ->
    `Assoc
      [
        ("kind", `String (to_manifest_tag reason));
        ("candidate", `String candidate);
        ("provider_key", `String provider_key);
        ("cooldown_reason", `String cooldown_reason);
      ]
  | Capacity_full { capacity_key; capacity_kind; retry_after_sec } ->
    let kind_label =
      match capacity_kind with `Client -> "client" | `Admission -> "admission"
    in
    let fields =
      [
        ("kind", `String (to_manifest_tag reason));
        ("candidate", `String candidate);
        ("capacity_key", `String capacity_key);
        ("capacity_kind", `String kind_label);
      ]
    in
    let fields =
      match retry_after_sec with
      | Some sec -> ("retry_after_sec", `Float sec) :: fields
      | None -> fields
    in
    `Assoc (List.rev fields)
  | Accept_rejected { reason = reject_reason } ->
    `Assoc
      [
        ("kind", `String (to_manifest_tag reason));
        ("candidate", `String candidate);
        ("reason", `String reject_reason);
      ]

(* Approval_config — pure data.  No I/O.  *)

type trust_level =
  | Observe      (* Allow all, log telemetry *)
  | Suggest      (* Auto-allow with confirmation suggestion telemetry *)
  | Auto_safe    (* Auto-allow for the given risk class *)
  | Enforced     (* Strict ask/deny — fail-closed default *)

let trust_level_to_string = function
  | Observe -> "observe"
  | Suggest -> "suggest"
  | Auto_safe -> "auto_safe"
  | Enforced -> "enforced"

type agent_overlay = {
  safe_trust : trust_level;
  audited_trust : trust_level;
  privileged_trust : trust_level;
}

type shell_ir_overlay_source =
  | Default_autonomous
  | Configured_overlay of string
  | Invalid_overlay_fail_closed of string

type shell_ir_overlay_resolution = {
  effective : agent_overlay;
  source : shell_ir_overlay_source;
}

type t = {
  defaults : agent_overlay;
  per_agent : (Agent_id.t * agent_overlay) list;
}

let normalize_level_token (raw : string) : string =
  String.lowercase_ascii (String.trim raw)

let trust_level_of_string (raw : string) : trust_level option =
  match normalize_level_token raw with
  | "observe"
  | "obs" ->
    Some Observe
  | "suggest"
  | "s" ->
    Some Suggest
  | "auto_safe"
  | "auto-safe"
  | "autosafe"
  | "allow" ->
    Some Auto_safe
  | "enforced"
  | "ask"
  | "strict"
  | "deny" ->
    Some Enforced
  | _ -> None

let agent_overlay_of_profile (raw : string) : agent_overlay option =
  match normalize_level_token raw with
  | "autonomous"
  | "observe" ->
    Some
      {
        safe_trust = Observe;
        audited_trust = Observe;
        privileged_trust = Observe;
      }
  | "enforced"
  | "enforced_all"
  | "strict"
  | "deny_all"
  | "all_enforced" ->
    Some
      {
        safe_trust = Enforced;
        audited_trust = Enforced;
        privileged_trust = Enforced;
      }
  | "permissive"
  | "permissive_default"
  | "perm" ->
    Some
      {
        safe_trust = Auto_safe;
        audited_trust = Enforced;
        privileged_trust = Enforced;
      }
  | "suggest" ->
    Some
      {
        safe_trust = Suggest;
        audited_trust = Suggest;
        privileged_trust = Suggest;
      }
  | "auto_safe"
  | "auto-safe"
  | "autosafe" ->
    Some
      {
        safe_trust = Auto_safe;
        audited_trust = Auto_safe;
        privileged_trust = Auto_safe;
      }
  | _ -> None

let shell_ir_approval_overlay_of_string (raw : string) : agent_overlay option =
  let raw = normalize_level_token raw in
  if raw = "" then
    None
  else
    let parse_entry entry =
      let entry = String.trim entry in
      if entry = "" then
        None
      else
        match String.index_opt entry '=' with
        | None -> Some (`Profile entry)
        | Some eq_pos ->
          if eq_pos = 0 || eq_pos = String.length entry - 1 then
            None
          else
            let key = String.sub entry 0 eq_pos |> normalize_level_token in
            let value =
              String.sub entry (eq_pos + 1) (String.length entry - eq_pos - 1)
              |> normalize_level_token
            in
            Some (`Pair (key, value))
    in
    let rec parse_entries entries ~profile ~safe ~audited ~privileged =
      match entries with
      | [] ->
        Option.map
          (fun base ->
            {
              safe_trust = Option.value safe ~default:base.safe_trust
            ; audited_trust = Option.value audited ~default:base.audited_trust
            ; privileged_trust =
                Option.value privileged ~default:base.privileged_trust
            })
          profile
      | entry :: rest ->
        (match parse_entry entry with
         | None -> None
         | Some (`Profile profile_token) ->
           (match profile with
            | Some _ -> None
            | None ->
              (match agent_overlay_of_profile profile_token with
               | Some overlay ->
                 parse_entries
                   rest
                   ~profile:(Some overlay)
                   ~safe
                   ~audited
                   ~privileged
               | None -> None))
         | Some (`Pair ("profile", value)) ->
           (match agent_overlay_of_profile value with
            | Some overlay ->
              parse_entries
                rest
                ~profile:(Some overlay)
                ~safe
                ~audited
                ~privileged
            | None -> None)
         | Some (`Pair ("safe", value)) ->
           (match trust_level_of_string value with
            | Some level ->
              parse_entries
                rest
                ~profile
                ~safe:(Some level)
                ~audited
                ~privileged
            | None -> None)
         | Some (`Pair ("audited", value)) ->
           (match trust_level_of_string value with
            | Some level ->
              parse_entries
                rest
                ~profile
                ~safe
                ~audited:(Some level)
                ~privileged
            | None -> None)
         | Some (`Pair ("privileged", value)) ->
           (match trust_level_of_string value with
            | Some level ->
              parse_entries
                rest
                ~profile
                ~safe
                ~audited
                ~privileged:(Some level)
            | None -> None)
         | Some (`Pair _) -> None)
    in
    parse_entries
      (String.split_on_char ',' raw)
      ~profile:None
      ~safe:None
      ~audited:None
      ~privileged:None

let enforced_all : agent_overlay =
  {
    safe_trust = Enforced;
    audited_trust = Enforced;
    privileged_trust = Enforced;
  }

let permissive_default : agent_overlay =
  {
    safe_trust = Auto_safe;
    audited_trust = Enforced;
    privileged_trust = Enforced;
  }

(* RFC-0254 §5.5: the overlay for an autonomous keeper lane.  Every risk
   class is [Observe] (allow + telemetry) because there is no human or
   resolver in the loop to answer an [Ask].  This does NOT loosen the
   catastrophic floor: [Approval_policy.decide] checks the trust-independent
   floor (destructive git, write-escape, catastrophic program) before
   consulting any trust level, so [Observe] here never re-enables a floor
   case. *)
let autonomous : agent_overlay =
  {
    safe_trust = Observe;
    audited_trust = Observe;
    privileged_trust = Observe;
  }

let resolve_shell_ir_approval_overlay = function
  | None -> { effective = autonomous; source = Default_autonomous }
  | Some raw ->
    (match shell_ir_approval_overlay_of_string raw with
     | Some effective -> { effective; source = Configured_overlay raw }
     | None ->
       { effective = enforced_all; source = Invalid_overlay_fail_closed raw })

let empty : t = { defaults = enforced_all; per_agent = [] }

let lookup t ~actor =
  match List.assoc_opt actor t.per_agent with
  | Some overlay -> overlay
  | None -> t.defaults

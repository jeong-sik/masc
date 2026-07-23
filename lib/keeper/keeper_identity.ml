(** Keeper_identity — centralized keeper identity helpers. *)

let trace_counter = Atomic.make 0

let generate_trace_id ?(now = Time_compat.now ()) () : string =
  let ts = int_of_float (now *. 1000.0) in
  let seq = Atomic.fetch_and_add trace_counter 1 land 0xFFFFF in
  Printf.sprintf "trace-%d-%05x" ts seq

let parse_keeper_agent_name ~prefix ~suffix agent_name =
  let plen = String.length prefix and slen = String.length suffix in
  let alen = String.length agent_name in
  if alen > plen + slen
     && String.sub agent_name 0 plen = prefix
     && String.sub agent_name (alen - slen) slen = suffix
  then
    let keeper_name = String.sub agent_name plen (alen - plen - slen) in
    if Keeper_config.validate_name keeper_name then Some keeper_name else None
  else
    None

let keeper_name_from_agent_name agent_name =
  match
    parse_keeper_agent_name ~prefix:"keeper-" ~suffix:"-agent" agent_name
  with
  | Some keeper_name -> Some keeper_name
  | None -> (
      match
        parse_keeper_agent_name ~prefix:"keeper_" ~suffix:"_agent" agent_name
      with
      | Some keeper_name -> Some keeper_name
      | None -> (
          match
            parse_keeper_agent_name ~prefix:"keeper-" ~suffix:"_agent" agent_name
          with
          | Some keeper_name -> Some keeper_name
          | None -> (
              match
                parse_keeper_agent_name ~prefix:"keeper_" ~suffix:"-agent" agent_name
              with
              | Some keeper_name -> Some keeper_name
              | None ->
                  if Nickname.is_generated_nickname agent_name
                     && Keeper_config.validate_name agent_name
                  then
                    Some agent_name
                  else
                    None)))

let is_keeper_agent_alias agent_name =
  Option.is_some
    (parse_keeper_agent_name ~prefix:"keeper-" ~suffix:"-agent" agent_name)
  || Option.is_some
       (parse_keeper_agent_name ~prefix:"keeper_" ~suffix:"_agent" agent_name)
  || Option.is_some
       (parse_keeper_agent_name ~prefix:"keeper-" ~suffix:"_agent" agent_name)
  || Option.is_some
       (parse_keeper_agent_name ~prefix:"keeper_" ~suffix:"-agent" agent_name)

let canonical_keeper_name_from_agent_name agent_name =
  let trimmed = String.trim agent_name in
  match keeper_name_from_agent_name trimmed with
  | Some keeper_name when is_keeper_agent_alias trimmed -> Some keeper_name
  | Some _ when Nickname.is_generated_nickname trimmed -> (
      match Nickname.extract_agent_type trimmed with
      | Some candidate when Keeper_config.validate_name candidate -> Some candidate
      | Some _ | None -> None)
  | Some keeper_name -> Some keeper_name
  | None ->
      if Nickname.is_generated_nickname trimmed
      then
        match Nickname.extract_agent_type trimmed with
        | Some candidate when Keeper_config.validate_name candidate -> Some candidate
        | Some _ | None -> None
      else
        None

let is_keeper_principal_agent_name agent_name =
  let trimmed = String.trim agent_name in
  is_keeper_agent_alias trimmed
  || (Nickname.is_dictionary_generated_nickname trimmed
      && Option.is_some (canonical_keeper_name_from_agent_name trimmed))

(** Phase A F5 (2026-04-27): single source of truth for the
    ["keeper-<name>"] prefix pattern.  Two call sites used to embed
    [String.sub trimmed 0 7 = "keeper-"] manually; both now go through
    this helper. *)
let strip_keeper_prefix (s : string) : string option =
  let prefix = "keeper-" in
  let plen = String.length prefix in
  let slen = String.length s in
  if slen > plen && String.starts_with s ~prefix then
    Some (String.sub s plen (slen - plen))
  else None

let keeper_agent_name name =
  let stable =
    match strip_keeper_prefix name with
    | Some stripped -> stripped
    | None -> name
  in
  Printf.sprintf "keeper-%s-agent" stable

let canonical_keeper_name raw_name =
  let trimmed = String.trim raw_name in
  if trimmed = "" then None
  else if is_keeper_agent_alias trimmed then
    canonical_keeper_name_from_agent_name trimmed
  else
    match strip_keeper_prefix trimmed with
    | Some candidate when Keeper_config.validate_name candidate ->
      Some candidate
    | Some _ -> None
    | None ->
      if Keeper_config.validate_name trimmed then Some trimmed
      else canonical_keeper_name_from_agent_name trimmed

let explicit_keeper_name raw_name =
  let trimmed = String.trim raw_name in
  if trimmed = "" then None
  else
    match strip_keeper_prefix trimmed with
    | Some candidate when Keeper_config.validate_name candidate ->
      Some candidate
    | Some _ -> None
    | None ->
      if Keeper_config.validate_name trimmed then Some trimmed else None

(* RFC-0232 §3.4 — structural keeper identity.  [of_string] is the single
   parse boundary: it folds case, then runs the same canonicalizers the
   legacy token-set expansion used, with [canonical_keeper_name_from_agent_name]
   first because it is the more specific form (wrapper unwrap, nickname →
   agent type) and [canonical_keeper_name] as the broad fallback.  Inputs
   that no canonicalizer recognizes keep their case-folded raw form so
   non-keeper authors (humans, external bots) still mint comparable ids. *)
module Keeper_id = struct
  type t = string

  let of_string value =
    let folded = String.lowercase_ascii (String.trim value) in
    if folded = "" then None
    else (
      let canonical =
        match canonical_keeper_name_from_agent_name folded with
        | Some c -> Some c
        | None -> canonical_keeper_name folded
      in
      (* DET-OK: the raw fallback is the contract, not a permissive
         default — authors that are not keepers (humans, external bots)
         must still mint a comparable id, and their canonical form IS
         the case-folded raw string.  Keeper-shaped inputs never reach
         the fallback. *)
      match String.trim (Option.value canonical ~default:folded) with
      | "" -> None
      | id -> Some (String.lowercase_ascii id))

  let to_string id = id
  let equal = String.equal
  let compare = String.compare
end

type name_bundle = {
  persona_name : string;
  keeper_name : string;
  agent_name : string;
}

type validation_error =
  | Empty_input
  | Persona_not_found of {
      input : string;
      resolved : string;
      searched : string;
    }
  | Name_ambiguous of { input : string; candidates : string list }
  | Ephemeral_suffix_rejected of { input : string; stripped : string }

let pp_validation_error fmt = function
  | Empty_input -> Format.fprintf fmt "Empty_input"
  | Persona_not_found { input; resolved; searched } ->
      Format.fprintf fmt
        "Persona_not_found { input=%S; resolved=%S; searched=%S }" input
        resolved searched
  | Name_ambiguous { input; candidates } ->
      Format.fprintf fmt "Name_ambiguous { input=%S; candidates=[%s] }" input
        (String.concat "; " (List.map (Printf.sprintf "%S") candidates))
  | Ephemeral_suffix_rejected { input; stripped } ->
      Format.fprintf fmt
        "Ephemeral_suffix_rejected { input=%S; stripped=%S }" input stripped

let show_validation_error err =
  let buf = Buffer.create 64 in
  let fmt = Format.formatter_of_buffer buf in
  pp_validation_error fmt err;
  Format.pp_print_flush fmt ();
  Buffer.contents buf

(* Stable snake_case label for Otel_metric_store metric outcome labels. Keep
   exhaustive — adding a new variant must require updating this match
   so no telemetry path silently aggregates to a generic bucket. *)
let validation_error_outcome_label = function
  | Empty_input -> "empty_input"
  | Persona_not_found _ -> "persona_not_found"
  | Name_ambiguous _ -> "name_ambiguous"
  | Ephemeral_suffix_rejected _ -> "ephemeral_suffix_rejected"

(* Strip a generated nickname suffix (adj-animal[-hex4]) once if present.
   Returns the canonical agent prefix when applicable, else the input. *)
let strip_nickname_once name =
  if Nickname.is_generated_nickname name then
    match Nickname.extract_agent_type name with
    | Some prefix when Keeper_config.validate_name prefix -> prefix
    | _ -> name
  else name

(* #10692: persona search must consult [Config_dir_resolver] (the SSOT
   that already handles [MASC_PERSONAS_DIR] env override + resolved
   config root).  The legacy hardcoded path [<base_path>/.masc/personas]
   does not exist in production deployments — personas live under the
   repo's [config/personas/] which the resolver finds, but the legacy
   path silently fails [check_persona] and triggers logging-only
   fallback at every workspace_bind_normalize call.

   Design: prefer the resolver result; fall back to the legacy path
   only when the resolver yields no candidate (preserves test
   ergonomics where [~base_path] is set explicitly without spinning up
   the full resolver chain). *)
let persona_path_for ~base_path persona_name =
  match Config_dir_resolver.personas_dir_opt () with
  | Some dir -> Filename.concat dir persona_name
  | None ->
      Filename.concat
        (Filename.concat (Common.masc_dir_from_base_path ~base_path) "personas")
        persona_name

let normalize_all_names ~input_agent_name ?(base_path = "")
    ?(check_persona = false) () :
    (name_bundle, validation_error) result =
  let trimmed = String.trim input_agent_name in
  if trimmed = "" then Error Empty_input
  else
    match canonical_keeper_name trimmed with
    | None ->
        Error
          (Persona_not_found
             {
               input = input_agent_name;
               resolved = trimmed;
               searched = persona_path_for ~base_path trimmed;
             })
    | Some keeper_first_pass ->
        let keeper_name = strip_nickname_once keeper_first_pass in
        let persona_name = keeper_name in
        let bundle =
          {
            persona_name;
            keeper_name;
            agent_name = input_agent_name;
          }
        in
        let persona_check () =
          if not check_persona then Ok ()
          else
            let path = persona_path_for ~base_path persona_name in
            if Sys.file_exists path then Ok ()
            else
              Error
                (Persona_not_found
                   { input = input_agent_name; resolved = persona_name; searched = path })
        in
        Result.bind (persona_check ()) (fun () -> Ok bundle)

type parsed_identity = {
  keeper_name : string;
  agent_name : string;
  trace_id : string option;
}

let parse_json_identity json =
  let agent_name = Safe_ops.json_string ~default:"" "agent_name" json in
  let trace_id = Safe_ops.json_string_opt "trace_id" json in
  let raw_keeper_name =
    match Safe_ops.json_string_opt "keeper_name" json with
    | Some v when String.trim v <> "" -> Some v
    | _ -> Safe_ops.json_string_opt "name" json
  in
  let keeper_name =
    match raw_keeper_name with
    | Some value when String.trim value <> "" ->
        (match explicit_keeper_name value with
         | Some name -> name
         | None -> String.trim value)
    | _ ->
        (match canonical_keeper_name_from_agent_name agent_name with
         | Some name -> name
         | None -> String.trim agent_name)
  in
  { keeper_name; agent_name; trace_id }

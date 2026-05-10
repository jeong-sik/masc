(** Flat cascade.toml → 5-layer declarative TOML migration tool (RFC-0058 Phase 4).

    Thin CLI wrapper — all conversion logic lives in
    [Cascade_flat_conversion] (lib/cascade_decl/).

    Usage:
      cascade_flat_to_declarative <flat.toml>           # emit 5-layer to stdout
      cascade_flat_to_declarative --validate <5l.toml>  # validate roundtrip
      cascade_flat_to_declarative --write <flat.toml> <output.toml>

    @stability Internal *)

open Cascade_declarative_types
open Cascade_declarative_parser

let validate_file (path : string) : bool =
  match parse_file path with
  | Ok cfg ->
    Printf.printf "OK: parsed %d providers, %d models, %d bindings, %d tiers, %d tier-groups, %d routes\n"
      (List.length cfg.providers)
      (List.length cfg.models)
      (List.length cfg.bindings)
      (List.length cfg.tiers)
      (List.length cfg.tier_groups)
      (List.length cfg.routes);
    true
  | Error errs ->
    Printf.eprintf "VALIDATION FAILED:\n";
    List.iter (fun (e : parse_error) ->
      Printf.eprintf "  %s: %s\n" e.path e.message
    ) errs;
    false

let () =
  let args = Array.to_list Sys.argv in
  match List.tl args with
  | [] ->
    Printf.eprintf "Usage: cascade_flat_to_declarative <flat.toml>\n";
    Printf.eprintf "       cascade_flat_to_declarative --validate <5l.toml>\n";
    Printf.eprintf "       cascade_flat_to_declarative --write <flat.toml> <output.toml>\n";
    exit 1
  | [ "--validate"; path ] ->
    if not (validate_file path) then exit 1
  | [ "--write"; input_path; output_path ] ->
    let toml = Otoml.Parser.from_file input_path in
    let output = Cascade_flat_conversion.convert_and_emit toml in
    let oc = open_out output_path in
    output_string oc output;
    close_out oc;
    Printf.printf "Written to %s\n" output_path;
    if not (validate_file output_path) then exit 1
  | [ path ] ->
    let toml = Otoml.Parser.from_file path in
    let output = Cascade_flat_conversion.convert_and_emit toml in
    print_string output
  | _ ->
    Printf.eprintf "Unexpected arguments\n";
    exit 1

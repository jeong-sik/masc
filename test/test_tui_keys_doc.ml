(** The committed key reference must agree with the binding registry.
    docs/guides/TUI-KEYS.md is generated from [Masc_tui_keys]; a registry
    change that does not regenerate the document fails here rather than
    shipping a stale guide. The committed path arrives as argv because the
    document lives outside the test directory.

    A failed run names the lines that differ. Regenerating takes a Dune run,
    which a session that builds only in CI cannot make, so the failure has to
    say which rows of the table moved. *)

let read_file path =
  let ic = open_in_bin path in
  Fun.protect
    ~finally:(fun () -> close_in_noerr ic)
    (fun () -> really_input_string ic (in_channel_length ic))

(* A table row is one line, so a changed row shows as one line on each side. *)
let lines_only_in ~from ~other =
  let known = Hashtbl.create 1024 in
  List.iter (fun line -> Hashtbl.replace known line ()) other;
  List.mapi (fun index line -> (index + 1, line)) from
  |> List.filter (fun (_, line) -> not (Hashtbl.mem known line))

let max_lines_shown = 40

let print_lines ~heading found =
  Printf.eprintf "%s\n" heading;
  List.iteri
    (fun index (number, line) ->
      if index < max_lines_shown then Printf.eprintf "  line %d: %s\n" number line)
    found;
  let hidden = List.length found - max_lines_shown in
  if hidden > 0 then Printf.eprintf "  ... and %d more\n" hidden

let report ~committed ~generated =
  let committed = String.split_on_char '\n' committed
  and generated = String.split_on_char '\n' generated in
  let only_committed = lines_only_in ~from:committed ~other:generated
  and only_generated = lines_only_in ~from:generated ~other:committed in
  match only_committed, only_generated with
  | [], [] ->
    Printf.eprintf
      "The two documents hold the same lines in a different order.\n"
  | _ ->
    print_lines ~heading:"Lines only in the committed document:" only_committed;
    print_lines ~heading:"Lines only in the generated document:" only_generated

let () =
  match Sys.argv with
  | [| _; path |] ->
    let committed = read_file path in
    let generated = Masc_tui_keys_doc.markdown () in
    if not (String.equal committed generated) then begin
      Printf.eprintf
        "docs/guides/TUI-KEYS.md disagrees with bin/masc_tui_keys.ml.\n\
         Regenerate: dune exec bin/masc_tui_keys_doc_cli.exe > docs/guides/TUI-KEYS.md\n";
      report ~committed ~generated;
      exit 1
    end
  | _ ->
    Printf.eprintf "usage: test_tui_keys_doc <committed doc path>\n";
    exit 2

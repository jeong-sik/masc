(** Every descriptor's description is a sentence authored in config/tools.

    The model reads [Keeper_tool_descriptor.t.description]
    ([Keeper_tools_agent_core_bundle]). The sentences a Keeper may read are
    authored in config/tools/*.toml: a file's top-level [description] (the
    catalog row, [Config.raw_all_tool_schemas]) or its [keeper_projection]
    description (the deliberately narrower Keeper shape, RFC
    prompts-and-tool-definitions-outside-ocaml §2.2). A descriptor may read a
    public-name file (tools/Read.toml) while the catalog row of its internal
    name (tools/tool_read_file.toml) says something else, and the board
    descriptors read the projection rather than the row, so the check is
    membership in the whole authored set, not equality with the same-named
    row.

    A descriptor carrying its own literal is the defect this pins:
    keeper_time_now and five keeper_* tools (#32494, #32525, #32528), then
    Execute, whose literal still said a script line is not handed to a shell
    after #32087 made it one (#32546, #32555). The per-tool TOML parity suites
    compare the TOML with the decoded record and never reach the descriptor.

    Walks the descriptor list instead of pinning names, so a descriptor added
    later with a literal fails here without anyone listing it. *)

open Alcotest
module Descriptor = Masc.Keeper_tool_descriptor

let embedded_tool_files =
  List.filter
    (fun rel ->
       String.equal (Filename.dirname rel) "tools" && Filename.check_suffix rel ".toml")
    Embedded_config.file_list
;;

let load_embedded rel =
  let name = Filename.remove_extension (Filename.basename rel) in
  match Embedded_config.read rel with
  | None -> failwith ("embedded tool definition unreadable: " ^ rel)
  | Some contents ->
    (match Tool_definition_toml.load ~name ~contents with
     | Ok (loaded : Tool_definition_toml.loaded) -> loaded
     | Error message -> failwith (rel ^ ": " ^ message))
;;

(* Every sentence authored in config/tools: each file's top-level description
   and, when the file declares one, its keeper_projection description. *)
let authored_descriptions () =
  List.concat_map
    (fun rel ->
       let loaded = load_embedded rel in
       loaded.schema.description
       :: Option.to_list
            (Option.map
               (fun (projection : Masc_domain.tool_schema) -> projection.description)
               loaded.keeper_projection))
    embedded_tool_files
;;

let catalog_descriptions () =
  List.map
    (fun (row : Masc_domain.tool_schema) -> row.description)
    Masc.Config.raw_all_tool_schemas
;;

let head_of text =
  let cut = 72 in
  if String.length text <= cut then text else String.sub text 0 cut ^ "…"
;;

let test_every_descriptor_reads_an_authored_sentence () =
  let authored = authored_descriptions () @ catalog_descriptions () in
  let offenders =
    List.filter_map
      (fun (descriptor : Descriptor.t) ->
         if List.exists (String.equal descriptor.description) authored
         then None
         else
           Some
             (Printf.sprintf
                "%s: %S"
                descriptor.internal_name
                (head_of descriptor.description)))
      (Descriptor.all_descriptors ())
  in
  check
    (list string)
    "descriptors whose description is not a config/tools sentence"
    []
    offenders
;;

(* The two past offenders, pinned against their own file. An empty authored
   set or an empty descriptor list would let the walk above pass for nothing;
   these two cannot. *)
let test_execute_and_time_now_read_their_own_file () =
  List.iter
    (fun name ->
       let expected = (load_embedded ("tools/" ^ name ^ ".toml")).schema.description in
       match Descriptor.descriptors_for_internal name with
       | [] -> fail (name ^ " has no descriptor")
       | descriptors ->
         List.iter
           (fun (descriptor : Descriptor.t) ->
              check string (name ^ " description") expected descriptor.description)
           descriptors)
    [ "tool_execute"; "keeper_time_now" ]
;;

let () =
  run
    "descriptor description from catalog"
    [ ( "descriptor prose"
      , [ test_case
            "every descriptor reads an authored sentence"
            `Quick
            test_every_descriptor_reads_an_authored_sentence
        ; test_case
            "execute and time_now read their own file"
            `Quick
            test_execute_and_time_now_read_their_own_file
        ] )
    ]
;;

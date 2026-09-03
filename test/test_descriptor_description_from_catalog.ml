(** Every descriptor's description is a sentence authored in config/tools for
    a tool of that descriptor's name.

    The model reads [Keeper_tool_descriptor.t.description]
    ([Keeper_tools_agent_core_bundle]). The sentences a Keeper may read are
    authored in config/tools/*.toml: a file's top-level [description] (the
    catalog row, [Config.raw_all_tool_schemas]) or its [keeper_projection]
    description (the deliberately narrower Keeper shape, RFC
    prompts-and-tool-definitions-outside-ocaml §2.2). A descriptor may read
    the file of its public name (tools/Read.toml) rather than of its internal
    name (tools/tool_read_file.toml), and a few catalog rows are still OCaml
    records with no file, so the sentences a descriptor may carry are those of
    both its names: each name's file (top level and projection) and each
    name's catalog rows. Membership in the whole authored set would also
    accept a descriptor reading some other tool's file; this does not.

    A descriptor carrying its own literal is the defect this pins:
    keeper_time_now and five keeper_* tools (#32494, #32525, #32528), Execute,
    whose literal still said a script line is not handed to a shell after
    #32087 made it one (#32546, #32555), and masc_library_list, whose literal
    named its siblings by the keeper_* names while the row named the masc_*
    ones — now the file's [keeper_projection]. The per-tool TOML parity suites
    compare the TOML with the decoded record and never reach the descriptor.

    Walks the descriptor list instead of pinning names, so a descriptor added
    later with a literal fails here without anyone listing it. *)

open Alcotest
module Descriptor = Masc.Keeper_tool_descriptor

let load_embedded_opt name =
  let rel = "tools/" ^ name ^ ".toml" in
  match Embedded_config.read rel with
  | None -> None
  | Some contents ->
    (match Tool_definition_toml.load ~name ~contents with
     | Ok (loaded : Tool_definition_toml.loaded) -> Some loaded
     | Error message -> failwith (rel ^ ": " ^ message))
;;

let load_embedded name =
  match load_embedded_opt name with
  | Some loaded -> loaded
  | None -> failwith ("embedded tool definition missing: tools/" ^ name ^ ".toml")
;;

(* The sentences one file authors: its top-level description and, when the
   file declares one, its keeper_projection description. *)
let file_sentences (loaded : Tool_definition_toml.loaded) =
  loaded.schema.description
  :: Option.to_list
       (Option.map
          (fun (projection : Masc_domain.tool_schema) -> projection.description)
          loaded.keeper_projection)
;;

let catalog_sentences name =
  List.filter_map
    (fun (row : Masc_domain.tool_schema) ->
       if String.equal row.name name then Some row.description else None)
    Masc.Config.raw_all_tool_schemas
;;

(* The sentences a descriptor may carry: those authored for either of its
   names. *)
let own_sentences (descriptor : Descriptor.t) =
  List.concat_map
    (fun name ->
       (match load_embedded_opt name with
        | Some loaded -> file_sentences loaded
        | None -> [])
       @ catalog_sentences name)
    (List.sort_uniq String.compare [ descriptor.internal_name; descriptor.public_name ])
;;

let test_every_descriptor_reads_its_own_authored_sentence () =
  let offenders =
    List.filter_map
      (fun (descriptor : Descriptor.t) ->
         if List.exists (String.equal descriptor.description) (own_sentences descriptor)
         then None
         else
           Some
             (Printf.sprintf
                "%s (%s): %S"
                descriptor.internal_name
                descriptor.public_name
                descriptor.description))
      (Descriptor.all_descriptors ())
  in
  check
    (list string)
    "descriptors whose description is not a config/tools sentence of their name"
    []
    offenders
;;

type authored_slot =
  | Top_level
  | Projection

(* The past offenders, pinned against the slot of their own file. An empty
   descriptor list would let the walk above pass for nothing; these cannot. *)
let pinned = [ "tool_execute", Top_level; "keeper_time_now", Top_level; "masc_library_list", Projection ]

let test_past_offenders_read_their_own_file () =
  List.iter
    (fun (name, slot) ->
       let loaded = load_embedded name in
       let expected =
         match slot with
         | Top_level -> loaded.schema.description
         | Projection ->
           (match loaded.keeper_projection with
            | Some (projection : Masc_domain.tool_schema) -> projection.description
            | None -> fail ("tools/" ^ name ^ ".toml declares no keeper_projection table"))
       in
       match Descriptor.descriptors_for_internal name with
       | [] -> fail (name ^ " has no descriptor")
       | descriptors ->
         List.iter
           (fun (descriptor : Descriptor.t) ->
              check string (name ^ " description") expected descriptor.description)
           descriptors)
    pinned
;;

let () =
  run
    "descriptor description from catalog"
    [ ( "descriptor prose"
      , [ test_case
            "every descriptor reads a sentence authored for its name"
            `Quick
            test_every_descriptor_reads_its_own_authored_sentence
        ; test_case
            "past offenders read their own file"
            `Quick
            test_past_offenders_read_their_own_file
        ] )
    ]
;;

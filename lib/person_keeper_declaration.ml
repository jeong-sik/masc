(* The declaration of a person's Keeper (RFC a-persons-keeper-runs-on-the-
   engine, S2 / stack A3-2). The .mli says what each value is for; this file
   only spells them and renders them. *)

let activation_mode = "on_demand"
let sandbox_profile = "docker"
let sandbox_image = "base"
let network_mode = "inherit"

let instructions =
  {|너는 이 사람의 Keeper 다. 주인이 보낸 메시지에 답한다.
주인은 너를 자기 계정의 Runtime 으로 돌린다. 너는 그 Runtime 의 대화 하나에서만 답한다.
MASC 도구도, 파일·명령·웹 도구도 없다. 주인이 묻지 않은 일을 스스로 시작하지 않는다.
답할 수 없으면 답할 수 없다고 말한다. 없는 근거를 지어내지 않는다.|}
;;

let content () =
  Otoml.Printer.to_string
    (Otoml.TomlTable
       [ ( "keeper"
         , Otoml.TomlTable
             [ "activation_mode", Otoml.TomlString activation_mode
             ; "sandbox_profile", Otoml.TomlString sandbox_profile
             ; "sandbox_image", Otoml.TomlString sandbox_image
             ; "network_mode", Otoml.TomlString network_mode
             ; "instructions", Otoml.TomlString instructions
             (* The subtable goes last: a TOML key printed after a subtable
                header belongs to that subtable, so [instructions] above would
                otherwise be read as [keeper.tools.instructions]. *)
             ; "tools", Otoml.TomlTable [ "masc_enabled", Otoml.TomlBoolean false ]
             ] ) ])
;;

(* --- writing it ------------------------------------------------------- *)

type outcome =
  | Created
  | Already_present
  | Replaced

type error =
  | Name_not_a_file_component of string
  | Path_unreadable of { path : string; reason : string }
  | Path_escapes_base_path of { path : string; base_path : string }
  | Declaration_refused of { path : string; reason : string }
  | Read_failed of { path : string; reason : string }
  | Different_declaration_present of { path : string; sha256 : string }
  | Write_failed of { path : string; reason : string }
  | Read_back_mismatch of
      { path : string
      ; expected_sha256 : string
      ; observed_sha256 : string
      }

let sha256 bytes = Agent_core_sha256.(digest_string bytes |> to_hex)

let name_is_a_component name =
  String.trim name = name
  && (not (String.equal name ""))
  && (not (String.equal name "."))
  && (not (String.equal name ".."))
  && (not (String.contains name '/'))
  && not (String.contains name '\\')
  && not (String.contains name '\000')
;;

let path_for ~base_path ~engine_name =
  if not (name_is_a_component engine_name)
  then Error (Name_not_a_file_component engine_name)
  else Ok (Config_dir_resolver.keeper_toml_path_for_base_path ~base_path engine_name)
;;

(* The resolved directory must be [base_path] itself or a directory below it.
   [Unix.realpath] is what makes this a check on the file system rather than on
   the string: a [keepers] directory that is a symlink out of the base path is
   refused here. *)
let resolve_dir ~base_path path =
  try
    let base = Unix.realpath base_path in
    let dir = Unix.realpath (Filename.dirname path) in
    let base_len = String.length base in
    let inside =
      String.equal dir base
      || (String.length dir > base_len
          && String.equal (String.sub dir 0 base_len) base
          && Char.equal dir.[base_len] '/')
    in
    Ok inside
  with
  | Unix.Unix_error (error, _, _) ->
    Error
      (Path_unreadable
         { path; reason = Unix.error_message error })
  | Sys_error reason -> Error (Path_unreadable { path; reason })
;;

let commit ~base_path ~engine_name ~content ~replace =
  match path_for ~base_path ~engine_name with
  | Error _ as error -> error
  | Ok path ->
    (match
       Keeper_types_profile_toml.inspect_keeper_toml_content ~path content
     with
     | Error error ->
       Error
         (Declaration_refused
            { path
            ; reason =
                Keeper_types_profile_toml.keeper_toml_load_error_to_string
                  error
            })
     | Ok (declared_name, _) when not (String.equal declared_name engine_name)
       ->
       Error
         (Declaration_refused
            { path; reason = "the declaration names another Keeper" })
     | Ok _ ->
       Fs_compat.mkdir_p (Filename.dirname path);
       (match resolve_dir ~base_path path with
        | Error error -> Error error
        | Ok false -> Error (Path_escapes_base_path { path; base_path })
        | Ok true ->
          (* The observed revision is both the answer to "is it already
             there?" and the compare-and-swap the commit below is given. One
             read, one lock, no window between them. *)
          (match
             Keeper_turn_up_config_persistence
             .current_config_revision_at_base_path
               ~base_path
               ~keeper_name:engine_name
           with
           | Error reason -> Error (Read_failed { path; reason })
           | Ok observed ->
             let wanted_sha256 = sha256 content in
             (match observed.Keeper_turn_up_config_persistence.manifest with
              | Keeper_turn_up_config_persistence.Sha256 held
                when String.equal held wanted_sha256 ->
                Ok Already_present
              | Keeper_turn_up_config_persistence.Sha256 held when not replace
                ->
                Error (Different_declaration_present { path; sha256 = held })
              | Keeper_turn_up_config_persistence.Sha256 _
              | Keeper_turn_up_config_persistence.Missing ->
                (match
                   Keeper_turn_up_config_persistence
                   .commit_declaration_at_base_path
                     ~expected_revision:observed
                     ~base_path
                     ~keeper_name:engine_name
                     ~content
                     ~publish:(fun _ revision -> revision)
                     ()
                 with
                 | Error error ->
                   Error
                     (Write_failed
                        { path
                        ; reason =
                            Keeper_turn_up_config_persistence
                            .declaration_error_to_string
                              error
                        })
                 | Ok _ ->
                   (* The commit's own journal path reads the revision back;
                      this reads the bytes, so "written" is the file's content
                      and not the write call's return value. *)
                   (match Fs_compat.load_file_opt path with
                    | None ->
                      Error
                        (Read_back_mismatch
                           { path; expected_sha256 = wanted_sha256
                           ; observed_sha256 = ""
                           })
                    | Some written when String.equal written content ->
                      Ok
                        (match observed.manifest with
                         | Keeper_turn_up_config_persistence.Missing -> Created
                         | Keeper_turn_up_config_persistence.Sha256 _ -> Replaced)
                    | Some written ->
                      Error
                        (Read_back_mismatch
                           { path
                           ; expected_sha256 = wanted_sha256
                           ; observed_sha256 = sha256 written
                           })))))))
;;

let error_message = function
  | Name_not_a_file_component name ->
    Printf.sprintf "%S is not a single path component" name
  | Path_unreadable { path; reason } ->
    Printf.sprintf "cannot resolve %s: %s" path reason
  | Path_escapes_base_path { path; base_path } ->
    Printf.sprintf "%s is outside %s" path base_path
  | Declaration_refused { path; reason } ->
    Printf.sprintf "%s would not load: %s" path reason
  | Read_failed { path; reason } ->
    Printf.sprintf "cannot read %s: %s" path reason
  | Different_declaration_present { path; sha256 } ->
    Printf.sprintf "%s already holds a different declaration (%s)" path sha256
  | Write_failed { path; reason } -> Printf.sprintf "writing %s failed: %s" path reason
  | Read_back_mismatch { path; expected_sha256; observed_sha256 } ->
    Printf.sprintf
      "%s reads back as %s, not the written %s"
      path
      (if String.equal observed_sha256 "" then "nothing" else observed_sha256)
      expected_sha256
;;


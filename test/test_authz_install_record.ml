(* Checks for the install record: which file a base path gets, what a write
   leaves behind, and which files a read refuses. Every case runs on real
   files in a fresh temporary directory, through the production path of
   [Fs_compat]. *)

module I = Authz_install_record

(* ---- fixtures ---- *)

let rec remove_tree path =
  match Unix.lstat path with
  | exception Unix.Unix_error (Unix.ENOENT, _, _) -> ()
  | { Unix.st_kind = Unix.S_DIR; _ } ->
    Unix.chmod path 0o700;
    Array.iter (fun name -> remove_tree (Filename.concat path name)) (Sys.readdir path);
    Unix.rmdir path
  | { Unix.st_kind = Unix.S_REG | Unix.S_CHR | Unix.S_BLK | Unix.S_LNK | Unix.S_FIFO | Unix.S_SOCK; _ }
    -> Sys.remove path
;;

type dirs =
  { root : string
  ; config : string  (** The [masc] config directory, not created. *)
  ; base : string  (** A base path that exists. *)
  }

(* Temporary directories are made 0700, which the owner check of the reader
   needs of every directory above the record. *)
let with_dirs f =
  let root = Filename.temp_dir "authz-install-record-" "" in
  Fun.protect
    ~finally:(fun () -> remove_tree root)
    (fun () ->
      let base = Filename.concat root "base" in
      Unix.mkdir base 0o700;
      f { root; config = Filename.concat root "config"; base })
;;

let get_located = function
  | Ok located -> located
  | Error error -> Alcotest.fail (I.locate_error_to_string error)
;;

let locate_in dirs ~base_path = get_located (I.locate ~config_dir:(Some dirs.config) ~base_path)

let record_of = function
  | I.Located t -> t
  | I.No_config_dir -> Alcotest.fail "expected a located record"
;;

let write_ok located ~external_store =
  match I.write located ~external_store with
  | Ok () -> ()
  | Error error -> Alcotest.fail (I.write_error_to_string error)
;;

let read_ok located =
  match I.read located with
  | Ok value -> value
  | Error error -> Alcotest.fail (I.read_error_to_string error)
;;

let describe_corruption = function
  | I.Not_json -> "not_json"
  | I.Wrong_members -> "wrong_members"
  | I.Base_path_differs _ -> "base_path_differs"
  | I.Store_path_not_absolute -> "store_path_not_absolute"
;;

let describe_read_error = function
  | I.Unreadable _ -> "unreadable"
  | I.Corrupt { reason; _ } -> "corrupt:" ^ describe_corruption reason
;;

let describe_write_error = function
  | I.No_config_dir_to_write -> "no_config_dir_to_write"
  | I.Store_path_invalid _ -> "store_path_invalid"
  | I.Config_dir_unusable _ -> "config_dir_unusable"
  | I.Not_replaced _ -> "not_replaced"
  | I.Replaced_but_not_durable _ -> "replaced_but_not_durable"
;;

let check_read_error label expected located =
  match I.read located with
  | Ok _ -> Alcotest.failf "%s: the read succeeded" label
  | Error error -> Alcotest.(check string) label expected (describe_read_error error)
;;

let check_write_error label expected located ~external_store =
  match I.write located ~external_store with
  | Ok () -> Alcotest.failf "%s: the write succeeded" label
  | Error error -> Alcotest.(check string) label expected (describe_write_error error)
;;

let read_file path = In_channel.with_open_bin path In_channel.input_all

let write_file path text =
  Out_channel.with_open_bin path (fun channel -> Out_channel.output_string channel text)
;;

let permissions path = (Unix.stat path).Unix.st_perm land 0o777

(* A file the process cannot touch is not refused for the superuser. *)
let skip_for_superuser () = if Unix.geteuid () = 0 then Alcotest.skip ()

let mkdir_config dirs = Unix.mkdir dirs.config 0o700

(* ---- which file a base path gets ---- *)

let no_config_dir_means_no_record () =
  with_dirs (fun dirs ->
    let located = get_located (I.locate ~config_dir:None ~base_path:dirs.base) in
    (match located with
     | I.No_config_dir -> ()
     | I.Located _ -> Alcotest.fail "a record was located without a config directory");
    Alcotest.(check (option string)) "nothing to read" None (read_ok located);
    check_write_error "nothing to write" "no_config_dir_to_write" located ~external_store:"/stores/one")
;;

let unresolvable_base_path () =
  with_dirs (fun dirs ->
    match I.locate ~config_dir:(Some dirs.config) ~base_path:(Filename.concat dirs.root "absent") with
    | Error (I.Base_path_unresolved _) -> ()
    | Error (I.Base_path_not_utf8 _ | I.Config_dir_not_absolute _) -> Alcotest.fail "wrong error"
    | Ok _ -> Alcotest.fail "a base path that is not there was located")
;;

let relative_config_dir_is_refused () =
  with_dirs (fun dirs ->
    List.iter
      (fun (label, config_dir) ->
        match I.locate ~config_dir:(Some config_dir) ~base_path:dirs.base with
        | Error (I.Config_dir_not_absolute _) -> ()
        | Error (I.Base_path_unresolved _ | I.Base_path_not_utf8 _) ->
          Alcotest.failf "%s: wrong error" label
        | Ok _ -> Alcotest.failf "%s: a relative config directory was located" label)
      [ "name", "masc"; "dot", "./masc"; "empty", "" ])
;;

let file_name_follows_the_canonical_base_path () =
  with_dirs (fun dirs ->
    let first = record_of (locate_in dirs ~base_path:dirs.base) in
    let name = Filename.basename (I.file_path first) in
    Alcotest.(check bool) "prefix" true (String.starts_with ~prefix:"authz-install-" name);
    Alcotest.(check bool) "suffix" true (String.ends_with ~suffix:".json" name);
    Alcotest.(check int) "length" (String.length "authz-install-" + 16 + String.length ".json") (String.length name);
    Alcotest.(check string) "inside the config directory" dirs.config (Filename.dirname (I.file_path first));
    let other = Filename.concat dirs.root "other" in
    Unix.mkdir other 0o700;
    let second = record_of (locate_in dirs ~base_path:other) in
    Alcotest.(check bool) "another base path, another file" false
      (String.equal (I.file_path first) (I.file_path second));
    let spelled = Filename.concat dirs.root "link" in
    Unix.symlink dirs.base spelled;
    let through_link = record_of (locate_in dirs ~base_path:spelled) in
    Alcotest.(check string) "a symbolic link to the base path, the same file" (I.file_path first)
      (I.file_path through_link))
;;

let same_directory_name_under_two_parents () =
  with_dirs (fun dirs ->
    let under parent =
      let dir = Filename.concat dirs.root parent in
      Unix.mkdir dir 0o700;
      let base = Filename.concat dir "workspace" in
      Unix.mkdir base 0o700;
      locate_in dirs ~base_path:base
    in
    let first = under "one"
    and second = under "two" in
    Alcotest.(check bool) "different files" false
      (String.equal (I.file_path (record_of first)) (I.file_path (record_of second)));
    write_ok first ~external_store:"/stores/one";
    Alcotest.(check (option string)) "the other has no record" None (read_ok second))
;;

let two_base_paths_have_two_records () =
  with_dirs (fun dirs ->
    let other = Filename.concat dirs.root "other" in
    Unix.mkdir other 0o700;
    let first = locate_in dirs ~base_path:dirs.base
    and second = locate_in dirs ~base_path:other in
    write_ok first ~external_store:"/stores/one";
    write_ok second ~external_store:"/stores/two";
    Alcotest.(check (option string)) "first" (Some "/stores/one") (read_ok first);
    Alcotest.(check (option string)) "second" (Some "/stores/two") (read_ok second))
;;

(* ---- reading and writing ---- *)

let missing_record () =
  with_dirs (fun dirs ->
    let located = locate_in dirs ~base_path:dirs.base in
    Alcotest.(check (option string)) "no config directory" None (read_ok located);
    mkdir_config dirs;
    Alcotest.(check (option string)) "no file" None (read_ok located))
;;

let write_then_read () =
  with_dirs (fun dirs ->
    let located = locate_in dirs ~base_path:dirs.base in
    write_ok located ~external_store:"/stores/one";
    Alcotest.(check (option string)) "read back" (Some "/stores/one") (read_ok located);
    let path = I.file_path (record_of located) in
    Alcotest.(check string)
      "the bytes of the file"
      (Printf.sprintf
         "{\"base_path\":\"%s\",\"external_store\":\"/stores/one\"}\n"
         (Unix.realpath dirs.base))
      (read_file path);
    Alcotest.(check int) "mode of the file" 0o600 (permissions path);
    Alcotest.(check int) "mode of the directory" 0o700 (permissions dirs.config);
    Alcotest.(check (list string)) "only the record" [ Filename.basename path ]
      (Array.to_list (Sys.readdir dirs.config)))
;;

let rewrite_replaces () =
  with_dirs (fun dirs ->
    let located = locate_in dirs ~base_path:dirs.base in
    write_ok located ~external_store:"/stores/one";
    write_ok located ~external_store:"/stores/two";
    Alcotest.(check (option string)) "the new path" (Some "/stores/two") (read_ok located);
    write_ok located ~external_store:"/stores/two";
    Alcotest.(check (option string)) "the same path again" (Some "/stores/two") (read_ok located);
    Alcotest.(check int) "no temporary file is left" 1 (Array.length (Sys.readdir dirs.config)))
;;

let missing_parents_are_created_private () =
  with_dirs (fun dirs ->
    let nested = Filename.concat (Filename.concat dirs.root "a") "b" in
    let located =
      get_located (I.locate ~config_dir:(Some (Filename.concat nested "masc")) ~base_path:dirs.base)
    in
    write_ok located ~external_store:"/stores/one";
    List.iter
      (fun dir -> Alcotest.(check int) dir 0o700 (permissions dir))
      [ Filename.concat dirs.root "a"; nested; Filename.concat nested "masc" ];
    Alcotest.(check (option string)) "read back" (Some "/stores/one") (read_ok located))
;;

let config_dir_through_a_symbolic_link () =
  with_dirs (fun dirs ->
    let real = Filename.concat dirs.root "dotfiles" in
    Unix.mkdir real 0o700;
    Unix.symlink real dirs.config;
    let located = locate_in dirs ~base_path:dirs.base in
    write_ok located ~external_store:"/stores/one";
    Alcotest.(check (option string)) "read back" (Some "/stores/one") (read_ok located);
    Alcotest.(check int) "the record is in the directory the link points to" 1
      (Array.length (Sys.readdir real)))
;;

(* ---- files that a read refuses ---- *)

let record_text dirs ~external_store =
  Printf.sprintf
    "{\"base_path\":\"%s\",\"external_store\":\"%s\"}\n"
    (Unix.realpath dirs.base)
    external_store
;;

let symbolic_link_record_is_refused () =
  with_dirs (fun dirs ->
    let located = locate_in dirs ~base_path:dirs.base in
    mkdir_config dirs;
    let target = Filename.concat dirs.root "target.json" in
    write_file target (record_text dirs ~external_store:"/stores/one");
    Unix.symlink target (I.file_path (record_of located));
    check_read_error "a symbolic link" "unreadable" located)
;;

let directory_record_is_refused () =
  with_dirs (fun dirs ->
    let located = locate_in dirs ~base_path:dirs.base in
    mkdir_config dirs;
    Unix.mkdir (I.file_path (record_of located)) 0o700;
    check_read_error "a directory" "unreadable" located;
    check_write_error "a directory is not replaced" "not_replaced" located ~external_store:"/stores/one")
;;

let record_with_two_names_is_refused () =
  with_dirs (fun dirs ->
    let located = locate_in dirs ~base_path:dirs.base in
    write_ok located ~external_store:"/stores/one";
    Unix.link (I.file_path (record_of located)) (Filename.concat dirs.root "alias.json");
    check_read_error "a second link" "unreadable" located)
;;

let directory_others_can_write_is_refused () =
  with_dirs (fun dirs ->
    let located = locate_in dirs ~base_path:dirs.base in
    write_ok located ~external_store:"/stores/one";
    Unix.chmod dirs.config 0o777;
    check_read_error "a directory that others can write" "unreadable" located)
;;

(* ---- the config directory ---- *)

let group_or_others_can_write mode = mode land 0o022 <> 0

(* Both calls apply one test to the config directory. Whatever the mode, a
   directory that takes a record is a directory the record is read from, and
   a directory that refuses a record has nothing written into it. *)
let config_dir_modes_decide_write_and_read_alike () =
  List.iter
    (fun mode ->
      with_dirs (fun dirs ->
        let label = Printf.sprintf "mode %04o" mode in
        mkdir_config dirs;
        Unix.chmod dirs.config mode;
        let located = locate_in dirs ~base_path:dirs.base in
        if group_or_others_can_write mode
        then (
          check_write_error label "config_dir_unusable" located ~external_store:"/stores/one";
          check_read_error label "unreadable" located;
          Alcotest.(check (list string))
            (label ^ ": nothing was written")
            []
            (Array.to_list (Sys.readdir dirs.config)))
        else (
          write_ok located ~external_store:"/stores/one";
          Alcotest.(check (option string)) label (Some "/stores/one") (read_ok located))))
    [ 0o700; 0o750; 0o755; 0o705; 0o720; 0o702; 0o770; 0o707; 0o775; 0o757; 0o777 ]
;;

(* [/] belongs to the superuser. The case is skipped when this process owns it,
   so that a refused write is all the case can cause. *)
let config_dir_of_another_user_is_refused () =
  if (Unix.stat "/").Unix.st_uid = Unix.geteuid () then Alcotest.skip ();
  with_dirs (fun dirs ->
    let located = get_located (I.locate ~config_dir:(Some "/") ~base_path:dirs.base) in
    check_read_error "a directory of another user" "unreadable" located;
    check_write_error "nothing is written in it" "config_dir_unusable" located
      ~external_store:"/stores/one")
;;

let absent_config_dir_below_a_resolving_link () =
  with_dirs (fun dirs ->
    let real = Filename.concat dirs.root "dotfiles" in
    Unix.mkdir real 0o700;
    let home = Filename.concat dirs.root "home" in
    Unix.symlink real home;
    let located =
      get_located (I.locate ~config_dir:(Some (Filename.concat home "masc")) ~base_path:dirs.base)
    in
    Alcotest.(check (option string)) "no record yet" None (read_ok located);
    write_ok located ~external_store:"/stores/one";
    Alcotest.(check (option string)) "read back" (Some "/stores/one") (read_ok located))
;;

(* A dangling link is not an absent directory: the record may be behind it.
   The write side is closed too. *)
let dangling_config_dir_link_is_unreadable () =
  with_dirs (fun dirs ->
    let gone = Filename.concat dirs.root "gone" in
    Unix.symlink gone dirs.config;
    let located = locate_in dirs ~base_path:dirs.base in
    check_read_error "a dangling config directory link" "unreadable" located;
    check_write_error "nothing is written behind it" "config_dir_unusable" located
      ~external_store:"/stores/one";
    Alcotest.(check bool) "the target was not created" false (Sys.file_exists gone))
;;

let dangling_ancestor_link_is_unreadable () =
  with_dirs (fun dirs ->
    let gone = Filename.concat dirs.root "gone" in
    let home = Filename.concat dirs.root "home" in
    Unix.symlink gone home;
    let located =
      get_located (I.locate ~config_dir:(Some (Filename.concat home "masc")) ~base_path:dirs.base)
    in
    check_read_error "a dangling link on the way" "unreadable" located;
    check_write_error "nothing is written behind it" "config_dir_unusable" located
      ~external_store:"/stores/one";
    Alcotest.(check bool) "the target was not created" false (Sys.file_exists gone))
;;

let unreadable_file () =
  skip_for_superuser ();
  with_dirs (fun dirs ->
    let located = locate_in dirs ~base_path:dirs.base in
    write_ok located ~external_store:"/stores/one";
    Unix.chmod (I.file_path (record_of located)) 0o000;
    check_read_error "a file nobody can read" "unreadable" located)
;;

let config_dir_that_is_a_file () =
  with_dirs (fun dirs ->
    let located = locate_in dirs ~base_path:dirs.base in
    write_file dirs.config "not a directory";
    check_read_error "a file in place of the directory" "unreadable" located;
    check_write_error "nothing is written under a file" "config_dir_unusable" located
      ~external_store:"/stores/one")
;;

let corrupt_records () =
  with_dirs (fun dirs ->
    let located = locate_in dirs ~base_path:dirs.base in
    let canonical = Unix.realpath dirs.base in
    let member name value = Printf.sprintf "\"%s\":%s" name value in
    let base_path = member "base_path" (Printf.sprintf "%S" canonical) in
    let store = member "external_store" "\"/stores/one\"" in
    let object_of members = "{" ^ String.concat "," members ^ "}\n" in
    mkdir_config dirs;
    let path = I.file_path (record_of located) in
    List.iter
      (fun (label, text, expected) ->
        write_file path text;
        check_read_error label expected located)
      [ "empty file", "", "corrupt:not_json"
      ; "text", "not json\n", "corrupt:not_json"
      ; "text after the object", object_of [ base_path; store ] ^ "x\n", "corrupt:not_json"
      ; "an array", "[]\n", "corrupt:wrong_members"
      ; "null", "null\n", "corrupt:wrong_members"
      ; "one member", object_of [ base_path ], "corrupt:wrong_members"
      ; "three members", object_of [ base_path; store; member "extra" "1" ], "corrupt:wrong_members"
      ; "a member twice", object_of [ base_path; base_path ], "corrupt:wrong_members"
      ; "other names", object_of [ member "base" "\"/b\""; member "store" "\"/s\"" ], "corrupt:wrong_members"
      ; "a number", object_of [ member "base_path" "1"; store ], "corrupt:wrong_members"
      ; "null store", object_of [ base_path; member "external_store" "null" ], "corrupt:wrong_members"
      ; "relative store", object_of [ base_path; member "external_store" "\"stores/one\"" ], "corrupt:store_path_not_absolute"
      ; "empty store", object_of [ base_path; member "external_store" "\"\"" ], "corrupt:store_path_not_absolute"
      ; ( "another base path"
        , object_of [ member "base_path" "\"/somewhere/else\""; store ]
        , "corrupt:base_path_differs" )
      ];
    write_file path (object_of [ store; base_path ]);
    Alcotest.(check (option string)) "the members in the other order" (Some "/stores/one") (read_ok located))
;;

let leftover_temporary_file_is_not_a_record () =
  with_dirs (fun dirs ->
    let located = locate_in dirs ~base_path:dirs.base in
    mkdir_config dirs;
    write_file (Filename.concat dirs.config ".atomic_leftover.tmp") "{\"base_path\":";
    Alcotest.(check (option string)) "no record" None (read_ok located);
    write_ok located ~external_store:"/stores/one";
    Alcotest.(check (option string)) "the record" (Some "/stores/one") (read_ok located))
;;

(* ---- writes that fail ---- *)

let store_path_must_be_absolute_utf8 () =
  with_dirs (fun dirs ->
    let located = locate_in dirs ~base_path:dirs.base in
    List.iter
      (fun (label, external_store) ->
        check_write_error label "store_path_invalid" located ~external_store)
      [ "relative", "stores/one"; "empty", ""; "not UTF-8", "/stores/\xff" ];
    Alcotest.(check bool) "nothing was created" false (Sys.file_exists dirs.config))
;;

let failed_write_leaves_the_old_record () =
  skip_for_superuser ();
  with_dirs (fun dirs ->
    let located = locate_in dirs ~base_path:dirs.base in
    write_ok located ~external_store:"/stores/one";
    Unix.chmod dirs.config 0o500;
    Fun.protect
      ~finally:(fun () -> Unix.chmod dirs.config 0o700)
      (fun () ->
        check_write_error "a directory that cannot be written" "not_replaced" located
          ~external_store:"/stores/two";
        Alcotest.(check (option string)) "the old record" (Some "/stores/one") (read_ok located)))
;;

let contains ~sub text =
  let sub_length = String.length sub
  and length = String.length text in
  let rec at index =
    index + sub_length <= length && (String.equal (String.sub text index sub_length) sub || at (index + 1))
  in
  at 0
;;

let error_texts_name_the_file () =
  with_dirs (fun dirs ->
    let located = locate_in dirs ~base_path:dirs.base in
    mkdir_config dirs;
    let path = I.file_path (record_of located) in
    write_file path "not json\n";
    (match I.read located with
     | Error error ->
       Alcotest.(check bool)
         "the text of a corrupt record names the file"
         true
         (contains ~sub:(Filename.basename path) (I.read_error_to_string error))
     | Ok _ -> Alcotest.fail "a corrupt record was read");
    Unix.chmod dirs.config 0o777;
    (match I.read located with
     | Error error ->
       Alcotest.(check bool)
         "the text of an unreadable record names the file"
         true
         (contains ~sub:(Filename.basename path) (I.read_error_to_string error))
     | Ok _ -> Alcotest.fail "a record in a directory others can write was read"))
;;

let () =
  Alcotest.run
    "authz_install_record"
    [ ( "which file"
      , [ Alcotest.test_case "no config directory" `Quick no_config_dir_means_no_record
        ; Alcotest.test_case "base path that is not there" `Quick unresolvable_base_path
        ; Alcotest.test_case "file name" `Quick file_name_follows_the_canonical_base_path
        ; Alcotest.test_case "two base paths" `Quick two_base_paths_have_two_records
        ; Alcotest.test_case "same directory name" `Quick same_directory_name_under_two_parents
        ; Alcotest.test_case "relative config directory" `Quick relative_config_dir_is_refused
        ] )
    ; ( "read and write"
      , [ Alcotest.test_case "missing record" `Quick missing_record
        ; Alcotest.test_case "write then read" `Quick write_then_read
        ; Alcotest.test_case "rewrite" `Quick rewrite_replaces
        ; Alcotest.test_case "missing parents" `Quick missing_parents_are_created_private
        ; Alcotest.test_case "config directory behind a link" `Quick config_dir_through_a_symbolic_link
        ] )
    ; ( "refused on read"
      , [ Alcotest.test_case "symbolic link" `Quick symbolic_link_record_is_refused
        ; Alcotest.test_case "directory" `Quick directory_record_is_refused
        ; Alcotest.test_case "second link" `Quick record_with_two_names_is_refused
        ; Alcotest.test_case "directory others can write" `Quick directory_others_can_write_is_refused
        ; Alcotest.test_case "unreadable file" `Quick unreadable_file
        ; Alcotest.test_case "config directory is a file" `Quick config_dir_that_is_a_file
        ; Alcotest.test_case "corrupt records" `Quick corrupt_records
        ; Alcotest.test_case "leftover temporary file" `Quick leftover_temporary_file_is_not_a_record
        ] )
    ; ( "config directory"
      , [ Alcotest.test_case "modes" `Quick config_dir_modes_decide_write_and_read_alike
        ; Alcotest.test_case "another user" `Quick config_dir_of_another_user_is_refused
        ; Alcotest.test_case
            "below a resolving link"
            `Quick
            absent_config_dir_below_a_resolving_link
        ; Alcotest.test_case "dangling link" `Quick dangling_config_dir_link_is_unreadable
        ; Alcotest.test_case
            "dangling link on the way"
            `Quick
            dangling_ancestor_link_is_unreadable
        ] )
    ; ( "writes that fail"
      , [ Alcotest.test_case "store path" `Quick store_path_must_be_absolute_utf8
        ; Alcotest.test_case "old record stays" `Quick failed_write_leaves_the_old_record
        ; Alcotest.test_case "error text" `Quick error_texts_name_the_file
        ] )
    ]
;;

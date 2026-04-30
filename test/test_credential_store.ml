(** Tests for Credential_store module *)

open Repo_manager_types

let contains_substring s needle =
  let s_len = String.length s in
  let n_len = String.length needle in
  let rec loop i =
    if i + n_len > s_len then false
    else if String.sub s i n_len = needle then true
    else loop (i + 1)
  in
  if n_len = 0 then true else loop 0

let with_temp_base_path f =
  let dir = Filename.temp_file "cred_store_test" "" in
  Sys.remove dir;
  Unix.mkdir dir 0o755;
  let config_dir = Filename.concat dir ".masc" in
  Unix.mkdir config_dir 0o755;
  let config_subdir = Filename.concat config_dir "config" in
  Unix.mkdir config_subdir 0o755;
  Fun.protect
    ~finally:(fun () ->
      let rec rm_rf path =
        if Sys.file_exists path then
          if Sys.is_directory path then begin
            Sys.readdir path |> Array.iter (fun name -> rm_rf (Filename.concat path name));
            Unix.rmdir path
          end else
            Sys.remove path
      in
      rm_rf dir)
    (fun () -> f dir)

let sample_credential id cred_type =
  {
    id;
    cred_type;
    username = "user-" ^ id;
    gh_config_dir = Some ("/home/user/.config/gh-" ^ id);
    ssh_key_path = Some ("/home/user/.ssh/id_" ^ id);
    gpg_key_id = None;
  }

let test_load_all_empty () =
  with_temp_base_path (fun base_path ->
      match Credential_store.load_all ~base_path with
      | Ok creds -> Alcotest.(check int) "empty list" 0 (List.length creds)
      | Error e -> Alcotest.fail ("unexpected error: " ^ e))

let test_save_and_load_roundtrip () =
  with_temp_base_path (fun base_path ->
      let creds =
        [
          sample_credential "c1" Github;
          sample_credential "c2" Gitlab;
          sample_credential "c3" Local;
        ]
      in
      match Credential_store.save_all ~base_path creds with
      | Error e -> Alcotest.fail ("save failed: " ^ e)
      | Ok () -> (
          match Credential_store.load_all ~base_path with
          | Error e -> Alcotest.fail ("load failed: " ^ e)
          | Ok loaded ->
              Alcotest.(check int) "count" 3 (List.length loaded);
              let ids = List.map (fun (c : credential) -> c.id) loaded in
              Alcotest.(check bool) "has c1" true (List.mem "c1" ids);
              Alcotest.(check bool) "has c2" true (List.mem "c2" ids);
              Alcotest.(check bool) "has c3" true (List.mem "c3" ids)))

let test_credential_type_roundtrip () =
  with_temp_base_path (fun base_path ->
      let creds =
        [
          sample_credential "gh" Github;
          sample_credential "gl" Gitlab;
          sample_credential "loc" Local;
        ]
      in
      match Credential_store.save_all ~base_path creds with
      | Error e -> Alcotest.fail ("save failed: " ^ e)
      | Ok () -> (
          match Credential_store.load_all ~base_path with
          | Error e -> Alcotest.fail ("load failed: " ^ e)
          | Ok loaded ->
              let find id = List.find (fun (c : credential) -> String.equal c.id id) loaded in
              Alcotest.(check bool) "github type"
                true
                (match (find "gh").cred_type with Github -> true | _ -> false);
              Alcotest.(check bool) "gitlab type"
                true
                (match (find "gl").cred_type with Gitlab -> true | _ -> false);
              Alcotest.(check bool) "local type"
                true
                (match (find "loc").cred_type with Local -> true | _ -> false)))

let test_optional_fields_roundtrip () =
  with_temp_base_path (fun base_path ->
      let cred =
        {
          id = "minimal";
          cred_type = Local;
          username = "min-user";
          gh_config_dir = None;
          ssh_key_path = None;
          gpg_key_id = Some "ABC123";
        }
      in
      match Credential_store.save_all ~base_path [ cred ] with
      | Error e -> Alcotest.fail ("save failed: " ^ e)
      | Ok () -> (
          match Credential_store.load_all ~base_path with
          | Error e -> Alcotest.fail ("load failed: " ^ e)
          | Ok loaded ->
              Alcotest.(check int) "count" 1 (List.length loaded);
              let found = List.hd loaded in
              Alcotest.(check (option string)) "gh_config_dir None" None found.gh_config_dir;
              Alcotest.(check (option string)) "ssh_key_path None" None found.ssh_key_path;
              Alcotest.(check (option string)) "gpg_key_id Some" (Some "ABC123") found.gpg_key_id))

let test_add_new_credential () =
  with_temp_base_path (fun base_path ->
      let cred = sample_credential "new-cred" Github in
      match Credential_store.add ~base_path cred with
      | Error e -> Alcotest.fail ("add failed: " ^ e)
      | Ok added ->
          Alcotest.(check string) "id" "new-cred" added.id;
          match Credential_store.load_all ~base_path with
          | Ok loaded -> Alcotest.(check int) "count after add" 1 (List.length loaded)
          | Error e -> Alcotest.fail ("load after add failed: " ^ e))

let test_add_duplicate_fails () =
  with_temp_base_path (fun base_path ->
      let cred = sample_credential "dup-cred" Github in
      match Credential_store.add ~base_path cred with
      | Error e -> Alcotest.fail ("first add failed: " ^ e)
      | Ok _ -> (
          match Credential_store.add ~base_path cred with
          | Ok _ -> Alcotest.fail "expected error for duplicate"
          | Error msg ->
              Alcotest.(check bool) "mentions already exists" true
                (contains_substring msg "already exists")))

let test_find_existing () =
  with_temp_base_path (fun base_path ->
      let cred = sample_credential "find-me" Gitlab in
      match Credential_store.add ~base_path cred with
      | Error e -> Alcotest.fail ("add failed: " ^ e)
      | Ok _ -> (
          match Credential_store.find ~base_path "find-me" with
          | Error e -> Alcotest.fail ("find failed: " ^ e)
          | Ok found -> Alcotest.(check string) "username" "user-find-me" found.username))

let test_find_missing () =
  with_temp_base_path (fun base_path ->
      match Credential_store.find ~base_path "missing" with
      | Ok _ -> Alcotest.fail "expected error for missing credential"
      | Error msg ->
          Alcotest.(check bool) "mentions not found" true (contains_substring msg "not found"))

let test_find_default_without_config () =
  with_temp_base_path (fun base_path ->
      match Credential_store.find ~base_path "default" with
      | Error e -> Alcotest.fail ("default credential missing: " ^ e)
      | Ok cred ->
          Alcotest.(check string) "id" "default" cred.id;
          Alcotest.(check bool) "local credential"
            true
            (match cred.cred_type with Local -> true | _ -> false))

let test_remove_existing () =
  with_temp_base_path (fun base_path ->
      let cred = sample_credential "to-remove" Local in
      match Credential_store.add ~base_path cred with
      | Error e -> Alcotest.fail ("add failed: " ^ e)
      | Ok _ -> (
          match Credential_store.remove ~base_path "to-remove" with
          | Error e -> Alcotest.fail ("remove failed: " ^ e)
          | Ok () -> (
              match Credential_store.load_all ~base_path with
              | Ok loaded -> Alcotest.(check int) "count after remove" 0 (List.length loaded)
              | Error e -> Alcotest.fail ("load after remove failed: " ^ e))))

let test_remove_missing () =
  with_temp_base_path (fun base_path ->
      match Credential_store.remove ~base_path "missing" with
      | Ok _ -> Alcotest.fail "expected error for missing credential"
      | Error msg ->
          Alcotest.(check bool) "mentions not found" true (contains_substring msg "not found"))

let test_credential_type_roundtrip () =
  let types = [ Github; Gitlab; Local ] in
  List.iter
    (fun t ->
      let json = credential_type_to_yojson t in
      match credential_type_of_yojson json with
      | Ok parsed -> Alcotest.(check bool) "roundtrip" true (equal_credential_type t parsed)
      | Error e -> Alcotest.fail e)
    types

let () =
  Alcotest.run "Credential_store"
    [
      ( "roundtrip",
        [
          Alcotest.test_case "load_all empty" `Quick test_load_all_empty;
          Alcotest.test_case "save and load roundtrip" `Quick test_save_and_load_roundtrip;
          Alcotest.test_case "credential type roundtrip" `Quick test_credential_type_roundtrip;
          Alcotest.test_case "optional fields roundtrip" `Quick test_optional_fields_roundtrip;
        ] );
      ( "add",
        [
          Alcotest.test_case "add new credential" `Quick test_add_new_credential;
          Alcotest.test_case "add duplicate fails" `Quick test_add_duplicate_fails;
        ] );
      ( "find",
        [
          Alcotest.test_case "find existing" `Quick test_find_existing;
          Alcotest.test_case "find missing" `Quick test_find_missing;
          Alcotest.test_case "default without config" `Quick
            test_find_default_without_config;
        ] );
      ( "remove",
        [
          Alcotest.test_case "remove existing" `Quick test_remove_existing;
          Alcotest.test_case "remove missing" `Quick test_remove_missing;
        ] );
      ( "credential_type",
        [
          Alcotest.test_case "yojson roundtrip" `Quick test_credential_type_roundtrip;
        ] );
    ]

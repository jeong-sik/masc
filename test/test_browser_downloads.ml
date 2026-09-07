open Alcotest
module D = Masc.Browser_downloads
let ok = function Ok value -> value | Error detail -> fail detail
let params id context = ["download",`String id;"context",`String context;
  "url",`String "https://example.org/file";"navigation",`Null]
let begin_ model id context =
  D.event model ~method_:"browsingContext.downloadWillBegin"
    (`Assoc (("suggestedFilename",`String "same.bin") :: params id context)) |> ok
let end_ model id context fields =
  D.event model ~method_:"browsingContext.downloadEnd" (`Assoc (fields @ params id context)) |> ok
let test_download_identity_and_frames () =
  let model = D.create () in
  D.add_tree model (`Assoc ["contexts",`List [`Assoc ["context",`String "tab";
    "children",`List [`Assoc ["context",`String "frame";"children",`Null]]]]]) |> ok;
  begin_ model "first" "frame";
  begin_ model "second" "frame";
  begin_ model "other" "another-tab";
  end_ model "second" "frame" ["status",`String "complete";"filepath",`Null];
  end_ model "first" "frame" ["status",`String "canceled"];
  (match D.for_context model "tab" with
   | [{id="first";status=D.Canceled;_};{id="second";status=D.Completed D.Path_unavailable;_}] -> ()
   | _ -> fail "download UUIDs must distinguish identical filenames and null navigation IDs, including frames");
  D.interrupt model "disconnected";
  (match D.for_context model "another-tab" with
   | [{status=D.Interrupted "disconnected";_}] -> ()
   | _ -> fail "disconnect must preserve unresolved evidence");
  (match D.for_context model "tab" with
   | [{status=D.Canceled;_};{status=D.Completed D.Path_unavailable;_}] -> ()
   | _ -> fail "disconnect must preserve terminal evidence")
let test_malformed_completion () =
  let model = D.create () in
  begin_ model "id" "tab";
  check bool "missing filepath is not explicit unavailable completion" true
    (Result.is_error (D.event model ~method_:"browsingContext.downloadEnd"
      (`Assoc (("status",`String "complete") :: params "id" "tab"))));
  check bool "missing download ID cannot fall back to null navigation" true
    (Result.is_error (D.event model ~method_:"browsingContext.downloadWillBegin"
      (`Assoc ["context",`String "tab";"navigation",`Null])))
let with_dir f =
  let root = Filename.temp_file "masc-download-test" "" in
  Sys.remove root; Unix.mkdir root 0o700;
  let rec remove path =
    if (Unix.lstat path).Unix.st_kind = Unix.S_DIR then (
      Array.iter (fun name -> remove (Filename.concat path name)) (Sys.readdir path);
      Unix.rmdir path)
    else Unix.unlink path in
  Fun.protect ~finally:(fun () -> remove root) (fun () -> f root)
let test_download_artifact_reader () =
  with_dir (fun root ->
    let staging = Filename.concat root "session-owned" in Unix.mkdir staging 0o700;
    let path = Filename.concat staging "download.bin" in
    let bytes = String.init 40000 (fun i -> Char.chr (i mod 256)) in
    Out_channel.with_open_bin path (fun oc -> output_string oc bytes);
    let verified, size = Masc.Browser_bidi_downloads.verify_file ~root:staging path |> ok in
    check int "verified size" (String.length bytes) size;
    let published = Masc.Browser_download_artifact.publish ~base_path:root verified |> ok in
    let open Yojson.Safe.Util in
    let args = member "arguments" published in
    check string "actual model-visible reader name" "keeper_artifact_read" (member "reader" published |> to_string);
    let sha256 = member "sha256" args in
    let rec read offset acc =
      let result = Masc.Keeper_artifact_read.handle ~base_path:root
        ~args:(`Assoc ["sha256",sha256;"offset",`Int offset]) in
      let page = match result.data with Some page -> page | None -> fail result.raw_output in
      let content = member "content" page |> to_string in
      let part = match member "encoding" page |> to_string with
        | "base64" -> (match Base64.decode content with Ok bytes -> bytes | Error (`Msg e) -> fail e)
        | "utf-8" -> content
        | encoding -> fail ("unexpected encoding " ^ encoding) in
      let next = member "next_offset" page |> to_int in
      if member "eof" page |> to_bool then String.concat "" (List.rev (part :: acc))
      else (check bool "pagination advances" true (next > offset); read next (part :: acc)) in
    check string "completed download bytes survive actual durable store and paged reader" bytes (read 0 []);
    let symlink = Filename.concat staging "symlink" in Unix.symlink path symlink;
    check bool "symlink cannot become authoritative download path" true
      (Result.is_error (Masc.Browser_bidi_downloads.verify_file ~root:staging symlink));
    check bool "outside file cannot become authoritative download path" true
      (Result.is_error (Masc.Browser_bidi_downloads.verify_file ~root:(Filename.concat root "other") path)))
let () = run "browser downloads" ["evidence",[
  test_case "download UUID and descendant frame correlation" `Quick test_download_identity_and_frames;
  test_case "malformed completion remains unresolved" `Quick test_malformed_completion;
  test_case "download reaches the real paged artifact reader" `Quick test_download_artifact_reader]]

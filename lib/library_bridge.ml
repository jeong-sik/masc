(** Library_bridge — Thin adapter for writing to Agent Knowledge Library.

    Decouples library writes from Room.config dependency.
    Used by lodge_heartbeat.ml to auto-record learnings.

    Library structure:
    - ~/me/docs/library/           → verified docs (confidence >= 0.5)
    - ~/me/docs/library/candidates/ → pending verification (< 0.5)

    @since 2.60.0
*)

let library_root () =
  let home = Sys.getenv_opt "HOME" |> Option.value ~default:"/tmp" in
  Filename.concat home "me/docs/library"

let candidates_dir () =
  Filename.concat (library_root ()) "candidates"

(** Ensure candidates directory exists *)
let ensure_candidates_dir () =
  let dir = candidates_dir () in
  Fs_compat.mkdir_p dir

(** Record a document to the Library.
    confidence < 0.5 → candidates/, >= 0.5 → library root. *)
let record_to_library
    ~agent_name ~title ~source ~confidence ~tags ~content =
  let dest_dir =
    if confidence < 0.5 then begin
      ensure_candidates_dir ();
      candidates_dir ()
    end else
      library_root ()
  in
  let now = Unix.localtime (Time_compat.now ()) in
  let date_str = Printf.sprintf "%04d%02d%02d"
    (now.Unix.tm_year + 1900) (now.Unix.tm_mon + 1) now.Unix.tm_mday in
  let iso_date = Printf.sprintf "%04d-%02d-%02d"
    (now.Unix.tm_year + 1900) (now.Unix.tm_mon + 1) now.Unix.tm_mday in
  let topic_slug =
    String.lowercase_ascii title
    |> String.map (fun c -> if c = ' ' then '-' else c)
    |> String.to_seq
    |> Seq.filter (fun c ->
        (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') || c = '-')
    |> String.of_seq
  in
  let filename = Printf.sprintf "%s-%s.md" topic_slug date_str in
  let filepath = Filename.concat dest_dir filename in
  (* Skip if file already exists (idempotency within same day) *)
  if Sys.file_exists filepath then ()
  else begin
    let tags_str = Printf.sprintf "[%s]" (String.concat ", " tags) in
    let full_content = Printf.sprintf {|---
title: %s
source: %s
confidence: %.2f
author: %s
created: %s
updated: %s
tags: %s
verified_by: []
---

%s
|} title source confidence agent_name iso_date iso_date tags_str content in
    Out_channel.with_open_text filepath (fun oc ->
      Out_channel.output_string oc full_content)
  end

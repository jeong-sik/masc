(* Compiled CI scenario: publish actual Firefox bytes through the production
   durable store, then recover every byte through the model's paged reader. *)
let publish_download path =
  let base_path = Sys.getenv "MASC_PROBE_ARTIFACT_BASE" in
  Result.map (fun artifact ->
    let open Yojson.Safe.Util in
    let sha256 = artifact |> member "arguments" |> member "sha256" in
    let rec pages offset accumulated =
      let execution = Masc.Keeper_artifact_read.handle ~base_path
        ~args:(`Assoc ["sha256",sha256;"offset",`Int offset]) in
      let page = match execution.data with
        | Some page -> page | None -> failwith execution.raw_output in
      let content = page |> member "content" |> to_string in
      let bytes = match page |> member "encoding" |> to_string with
        | "utf-8" -> content
        | "base64" -> (match Base64.decode content with Ok s -> s | Error (`Msg e) -> failwith e)
        | _ -> failwith "unknown artifact encoding" in
      if page |> member "eof" |> to_bool then String.concat "" (List.rev (bytes :: accumulated))
      else
        let next = page |> member "next_offset" |> to_int in
        if next <= offset then failwith "artifact page did not advance";
        pages next (bytes :: accumulated) in
    let actual = pages 0 [] in
    if actual <> In_channel.with_open_bin path In_channel.input_all
    then failwith "artifact reader changed downloaded bytes";
    Printf.printf "PASS real download durable artifact and paged reader (%d bytes)\n%!" (String.length actual);
    artifact)
    (Masc.Browser_download_artifact.publish ~base_path path)

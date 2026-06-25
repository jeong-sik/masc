let store_dir ~keeper_name =
  (* MUST match Keeper_vision_tool's vision store dir so analyze_image resolves
     the handle this ingestion stores. *)
  Filename.concat (Config_dir_resolver.keepers_dir ()) (keeper_name ^ ".vision")

let should_delegate policy_opt =
  Keeper_multimodal_policy.delegates
    (Keeper_multimodal_policy.resolve_optional policy_opt)

let intercept_image_blocks ~store blocks =
  List.map
    (fun (block : Agent_sdk.Types.content_block) ->
       match block with
       | Agent_sdk.Types.Image { media_type = _; data; source_type = _ } ->
         (match Base64.decode data with
          | Error _ ->
            Log.Keeper.warn
              "vision ingest: base64 decode failed; leaving image inline";
            block
          | Ok bytes ->
            (match store bytes with
             | Ok handle ->
               Agent_sdk.Types.text_block
                 (Printf.sprintf
                    "[image artifact:%s — call analyze_image with this artifact \
                     to read it]"
                    handle)
             | Error e ->
               Log.Keeper.warn
                 "vision ingest: store failed (%s); leaving image inline"
                 e;
               block))
       (* Only Image is intercepted; every other block (incl. any future variant)
          passes through — this is a filter, not an exhaustive FSM transition. *)
       | _ -> block)
    blocks

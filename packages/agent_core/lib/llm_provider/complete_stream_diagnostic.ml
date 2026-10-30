(* The optional dump keeps the full refused frame; the operator-facing error
   has a bounded excerpt. Redaction changes byte offsets, so record both the
   original byte count and whether the dumped payload is still verbatim.

   This sink reads its environment locally: Agent Core does not depend on
   coordinator configuration. Only Sys_error is ignored, so diagnostic file
   failures do not replace the provider error. *)
let dump_refused_frame
      ({ wire_format; reason; raw } : Complete_stream_error.refused_frame)
  =
  match Sys.getenv_opt "MASC_WIRE_PARSE_DUMP" with
  | None | Some "" -> ()
  | Some path ->
    (try
       let label =
         Http_client.provider_wire_format_to_string wire_format |> String.uppercase_ascii
       in
       let scrubbed = Secret_redactor.redact_string raw in
       let verbatim = String.equal scrubbed raw in
       let oc = open_out_gen [ Open_append; Open_creat ] 0o600 path in
       Fun.protect
         ~finally:(fun () -> close_out_noerr oc)
         (fun () ->
            Printf.fprintf
              oc
              "%s\t%s\t%d\tverbatim=%b\t%s\n"
              label
              reason
              (String.length raw)
              verbatim
              (String.escaped scrubbed))
     with
     | Sys_error _ -> ())
;;

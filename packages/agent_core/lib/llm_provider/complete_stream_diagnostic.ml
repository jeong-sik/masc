(* The optional dump keeps the full refused frame; the operator-facing error
   has a bounded excerpt. Redaction changes byte offsets, so record both the
   original byte count and whether the dumped payload is still verbatim.

   Agent Core does not read MASC environment variables directly: the host
   installs a sink explicitly (e.g. wiring a configured dump path via
   [append_refused_frame_to_path]). Only [Sys_error] is ignored in the file
   helper, so diagnostic file failures do not replace the provider error. *)

type refused_frame =
  { wire_format : Http_client.provider_wire_format
  ; reason : string
  ; raw : string
  }

let process_sink : (refused_frame -> unit) option Atomic.t = Atomic.make None
let fiber_sink_key : (refused_frame -> unit) option Eio.Fiber.key = Eio.Fiber.create_key ()

let set_refused_frame_sink sink = Atomic.set process_sink sink

let with_refused_frame_sink sink fn =
  match Eio.Fiber.with_binding fiber_sink_key sink fn with
  | result -> result
  | exception Effect.Unhandled _ ->
    let previous = Atomic.exchange process_sink sink in
    Fun.protect ~finally:(fun () -> Atomic.set process_sink previous) fn
;;

let active_sink () =
  match Eio.Fiber.get fiber_sink_key with
  | Some sink -> sink
  | None -> Atomic.get process_sink
  | exception Effect.Unhandled _ -> Atomic.get process_sink
;;

let append_refused_frame_to_path ~path ({ wire_format; reason; raw } : refused_frame) =
  match path with
  | "" -> ()
  | path ->
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

let dump_refused_frame frame =
  match active_sink () with
  | None -> ()
  | Some sink -> sink frame
;;

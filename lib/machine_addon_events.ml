type batch = { author : string; relay : author:string -> string -> unit; ready : bool Atomic.t }
type notice = { batch : batch; content : string }
let pending : notice Queue.t = Queue.create ()
let lock = Mutex.create ()
let posting = Eio.Mutex.create ()
let create ~author ~relay = {author;relay;ready=Atomic.make false}
let ready batch = Atomic.set batch.ready true
let preview_json json =
  let text = Yojson.Safe.to_string json in
  if String.length text > 200 then String.sub text 0 200 ^ "..." else text

let record batch (result : Mcp_protocol.Mcp_types.tool_result) =
  let contents = match result._meta with
    | Some (`Assoc fields) ->
        (match List.assoc_opt "io.github.jeong-sik/masc.machine.events" fields with
         | Some (`List events) -> List.filter_map (function
             | (`Assoc fields as event) when List.sort String.compare (List.map fst fields) = ["author";"content"] ->
                 (match List.assoc "content" fields with
                  | `String content -> Some content
                  | _ ->
                    Log.Misc.warn "Machine worker %s returned an invalid event body: %s"
                      batch.author (preview_json event);
                    None)
             | event ->
               Log.Misc.warn "Machine worker %s returned an invalid event envelope: %s"
                 batch.author (preview_json event);
               None) events
         | None -> []
         | Some other ->
           Log.Misc.warn "Machine worker %s returned an invalid event list: %s"
             batch.author (preview_json other);
           [])
    | None | Some _ -> [] in
  Mutex.protect lock (fun () -> List.iter (fun content -> Queue.push {batch;content} pending) contents)
let drain () =
  Eio.Mutex.use_ro posting (fun () ->
    let rec loop () =
      let next = Mutex.protect lock (fun () ->
        match Queue.peek_opt pending with
        | Some notice when Atomic.get notice.batch.ready -> Queue.take_opt pending
        | Some _ | None -> None) in
      match next with
      | None -> ()
      | Some {batch;content} -> batch.relay ~author:batch.author content; loop () in
    loop ())

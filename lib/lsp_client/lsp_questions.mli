(** The three questions a caller can ask a language server about a position.

    Not a protocol client. Completion, formatting and code actions belong to an
    editor; rename writes files. What is left is: where is this used, where
    does it come from, what is it (RFC a-language-server-the-keeper-can-ask
    §3.1). *)

type question =
  | References
      (** Measured on this tree as answering only the opened file's own
          occurrences — one item where [rg] finds five. Kept in the type
          because the parser reads its answers and the tests pin them, and
          left out of the Keeper surface until #30504 says it answers. *)
  | Definition
  | Hover

val question_of_string : string -> question option
val string_of_question : question -> string

val reference_index_ready
  :  question:question
  -> language:Lsp_process_manager.language
  -> project_root:string
  -> (unit, string) result
(** [Ok ()] unless [question] is {!References} and the project has no
    reference index, in which case the error is the sentence a caller shows:
    where this looked, what to run, and why a short list would have been
    worse than a refusal.

    Asked before the question rather than after the answer, because a server
    with no index does not say so -- it answers with the occurrences in the
    file it was given, which was one where the truth was three (#30504).

    Here rather than in each surface: the Keeper tool and the REST question
    route already share {!Lsp_position}'s arithmetic so they cannot disagree
    about where a name sits, and they should not be able to disagree about
    whether an answer is worth asking for. *)

type location =
  { path : string
  ; line : int
  ; character : int
  }

type answer =
  | Locations of location list
      (** [[]] means the language server looked and found nothing. That is a
          different fact from "no server for this language" and from "the
          server is not installed", which is why neither of those is spelled
          this way. *)
  | Hover_text of string option
      (** [None] where the server has nothing to say at that position. *)

type error =
  | Server of Lsp_workspace_pool.error
  | Unreadable_file of
      { path : string
      ; reason : string
      }
  | Unparsed_answer of
      { method_ : string
      ; reason : string
      }
      (** The server answered in a shape this module does not read. Reported
          rather than dropped: a silently skipped element would answer
          [Locations []] for a file that has references. *)

val pp_error : Format.formatter -> error -> unit

(** Read a server's answer to [question]. Separate from {!ask} because this is
    where servers differ: [textDocument/definition] may answer one [Location],
    a list of them, a list of [LocationLink], or [null], and hover contents may
    be markup, a bare string, or a list. *)
val answer_of_json : question -> Yojson.Safe.t -> (answer, string) result

(** [ask pool ~language ~workspace_root ~path ~line ~character ~question]
    opens the document, asks, and closes it again.

    Opening every time rather than tracking which documents a server holds:
    the file on disk is the truth here — nothing edits a buffer in memory —
    and a document left open would go stale the moment a tool wrote to it. *)
val ask
  :  Lsp_workspace_pool.t
  -> language:Lsp_process_manager.language
  -> workspace_root:string
  -> path:string
  -> line:int
  -> character:int
  -> question:question
  -> (answer, error) result

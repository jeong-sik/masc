### Fixed

- Your Recent Actions no longer replays a refused call whose input carried
  the reserved `_blob` key of a stored-artifact reference. The refusal row
  and the rejected-call digest name the tool and say the input carried that
  key, without the input and without the refusal text that prints it back. A
  keeper that copied a `_blob` object from its request history is no longer
  shown that object again as the shape of its own call. The tool-call log
  records the form on every row as `input_form` (`arguments` or
  `artifact_reference`), decided on the raw input, because an oversized input
  is persisted as a preview string whose shape cannot be read back
  (#47642, #PENDING).

### Upgrade notes

- Tool-call log rows an earlier build wrote carry no `input_form`. Your
  Recent Actions still lists those calls, but a refusal among them shows
  neither its input nor its refusal text and says its record does not state
  the input's form. Nothing needs deleting; rows this build logs show their
  input as before (#47642, #PENDING).

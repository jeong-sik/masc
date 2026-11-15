### Fixed

- The Keeper config prompt preview names the constitution ledger lines that
  decoded but were written under a name the Keeper roster does not hold,
  beside the lines that did not decode. A turn already left the articles
  those lines touch out of the prompt; the preview now says so. The `read`
  state of `prompt.system_prompt.constitution_ledger` always carries
  `isolated_lines` (`line`, `subject`, `article_ids`), and the web dashboard
  reads a response without it as a decode failure, not as no lines left out
  (#52169, #PENDING).

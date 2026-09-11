(** Same-document source snapshot. Paired with the existing scene runtime in
    both browser backends; the package, not this hook, interprets revision. *)
let runtime = {js|function browserDocument() {
  if (window !== window.top) throw new Error('document_observation_requires_top_document');
  const identity = browserScene({mode:'viewport'});
  const page = {documentId:identity.documentId,url:location.href,title:document.title,
    observedAt:Date.now()/1000,html:document.documentElement?.outerHTML ?? null,
    htmlComplete:document.documentElement !== null,htmlUnavailableReason:null};
  // The observation is optional. Keep identity and report incomplete coverage
  // rather than returning a truncated document as if it were complete HTML.
  if (page.html === null) {
    page.htmlComplete = false;
    page.htmlUnavailableReason = 'document_has_no_root';
  } else if (new TextEncoder().encode(JSON.stringify(page)).byteLength > 1024 * 1024) {
    page.html = null;
    page.htmlComplete = false;
    page.htmlUnavailableReason = 'document_html_exceeds_1_mib';
  }
  return page;
}|js}

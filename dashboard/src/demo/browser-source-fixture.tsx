import { html } from 'htm/preact'
import { render } from 'preact'
import { useState } from 'preact/hooks'

function NestedButton() {
  const [count,setCount] = useState(0)
  return html`<button data-proof="nested" onClick=${() => setCount(count+1)}>Nested ${count}</button>`
}
function Lab() {
  const [count,setCount] = useState(0)
  const [open,setOpen] = useState(false)
  const [reverse,setReverse] = useState(false)
  const [value,setValue] = useState('')
  const items = reverse ? [3,2,1] : [1,2,3]
  return html`<main>
    <h1 data-proof="heading">Point at a page. Find its source.</h1>
    <p data-proof="unicode">한글과 별빛🙂 — real browser, original source.</p>
    <section data-proof="actions">
      <button data-proof="counter" onClick=${() => setCount(count+1)}>Count ${count}</button>
      <${NestedButton} />
      <button data-proof="open" onClick=${() => setOpen(true)}>Open dialog</button>
      <button data-proof="reverse" onClick=${() => setReverse(!reverse)}>Reverse list</button>
      <input data-proof="input" aria-label="Message" value=${value} onInput=${(event: Event) => setValue((event.target as HTMLInputElement).value)} />
      <output data-proof="output">${value || 'Type a message'}</output>
    </section>
    <section data-proof="list">${items.map(item => html`<button key=${item} data-proof=${'row-'+item} onClick=${() => setValue('Row '+item)}>Row ${item}</button>`)}</section>
    <section data-proof="details">
      <a data-proof="link" href="#details">Jump to details</a>
      <label data-proof="label">Selection <select data-proof="select"><option>One</option><option>Two</option></select></label>
      <textarea data-proof="textarea" aria-label="Notes"></textarea>
      <button data-proof="disabled" disabled>Disabled action</button>
      <span data-proof="status">Ready</span>
      <img data-proof="image" width="24" height="24" alt="Sample dot" src="data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' width='24' height='24'%3E%3Ccircle cx='12' cy='12' r='10' fill='teal'/%3E%3C/svg%3E" />
    </section>
    ${open ? html`<dialog open data-proof="dialog"><p>Same state, observable source.</p><button data-proof="close" onClick=${() => setOpen(false)}>Close dialog</button></dialog>` : null}
    ${<button data-proof="jsx" onClick={() => setCount(count+1)}>JSX action</button>}
  </main>`
}
const style = document.createElement('style')
style.textContent = 'body{margin:24px;background:#13232d;color:#dbe7eb;font:18px system-ui}main{max-width:1000px;margin:auto}h1{font-size:32px}section{display:flex;align-items:center;flex-wrap:wrap;gap:12px;padding:20px 0;border-bottom:1px solid #536574}button,input,select,textarea{font:inherit;padding:8px}button{cursor:pointer}dialog{top:160px;background:#f5f5ef;border:2px solid #648579}img{vertical-align:middle}'
document.head.append(style)
const root = document.getElementById('source-lab')
if (root) render(html`<${Lab} />`,root)

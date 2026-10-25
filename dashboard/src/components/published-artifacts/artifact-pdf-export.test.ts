import { html } from 'htm/preact'
import { act,cleanup,fireEvent,render,screen,waitFor } from '@testing-library/preact'
import { expect,it,vi,beforeEach,afterEach } from 'vitest'
import { setStoredToken,clearStoredToken,currentStoredTokenRevision } from '../../api/core'
import { artifactPdfFile,type ArtifactPdfFile } from '../../lib/artifact-pdf-export'
import type { ArtifactDocument } from '../../api/published-artifacts'
import { ArtifactPdfExport } from './artifact-pdf-export'
vi.mock('../../lib/artifact-pdf-export',()=>({artifactPdfFile:vi.fn()}))
vi.mock('../../lib/artifact-pdf-fonts',()=>({loadArtifactPdfFonts:vi.fn()}))
import {loadArtifactPdfFonts} from '../../lib/artifact-pdf-fonts'
const fonts={regular:new Uint8Array([1]),bold:new Uint8Array([2]),emoji:new Uint8Array([3])}
const doc:ArtifactDocument={content:'# 원본',revisions:[],artifact:{id:`artifact-${'a'.repeat(32)}`,revision:3,title:'문서',summary:'요약',format:'markdown',author:'keeper',created_at:'now',task_id:null,goal_id:null,url:'/',body:{_blob:{sha256:'f'.repeat(64)}}}}
const file:ArtifactPdfFile={data:new Uint8Array([1,2,3]).buffer,notices:['외부 그림을 링크로 바꿨습니다.']}
function deferred(){let resolve!:(value:ArtifactPdfFile)=>void;const promise=new Promise<ArtifactPdfFile>(ok=>{resolve=ok});return {promise,resolve}}
beforeEach(()=>{vi.mocked(loadArtifactPdfFonts).mockReset().mockResolvedValue(fonts);setStoredToken('pdf-export-user');vi.mocked(artifactPdfFile).mockReset();vi.spyOn(URL,'createObjectURL').mockReturnValue('blob:pdf-export');vi.spyOn(URL,'revokeObjectURL').mockImplementation(()=>{});vi.spyOn(HTMLAnchorElement.prototype,'click').mockImplementation(()=>{})})
afterEach(()=>{cleanup();clearStoredToken();vi.restoreAllMocks()})
function open(isCurrent=()=>true){return render(html`<${ArtifactPdfExport} doc=${doc} authRevision=${currentStoredTokenRevision()} isCurrent=${isCurrent} disabled=${false} />`)}
it('downloads the captured publication revision once and reports conversion notices',async()=>{
  const pending=deferred();vi.mocked(artifactPdfFile).mockReturnValue(pending.promise)
  open();fireEvent.click(screen.getByRole('button',{name:'PDF 파일 다운로드'}))
  await waitFor(()=>expect(artifactPdfFile).toHaveBeenCalledTimes(1))
  fireEvent.click(screen.getByRole('button',{name:'PDF 파일을 만들고 있습니다.'}))
  expect(artifactPdfFile).toHaveBeenCalledWith(doc,fonts);expect(URL.createObjectURL).not.toHaveBeenCalled()
  await act(async()=>pending.resolve(file))
  await screen.findByText('PDF 파일 다운로드를 요청했습니다. 외부 그림을 링크로 바꿨습니다.')
  expect(artifactPdfFile).toHaveBeenCalledTimes(1)
  expect(URL.createObjectURL).toHaveBeenCalledTimes(1)
  expect(vi.mocked(HTMLAnchorElement.prototype.click).mock.instances[0]).toMatchObject({download:`${doc.artifact.id}-v3.pdf`,href:'blob:pdf-export'})
  expect(URL.revokeObjectURL).toHaveBeenCalledWith('blob:pdf-export')
})
it('does not download an old export after credential or reader ownership changes',async()=>{
  const pending=deferred();vi.mocked(artifactPdfFile).mockReturnValue(pending.promise)
  const first=open();fireEvent.click(screen.getByRole('button',{name:'PDF 파일 다운로드'}))
  await waitFor(()=>expect(artifactPdfFile).toHaveBeenCalledTimes(1))
  await act(async()=>setStoredToken('another-user'));await act(async()=>pending.resolve(file))
  expect(URL.createObjectURL).not.toHaveBeenCalled();first.unmount()
  const secondPending=deferred();vi.mocked(artifactPdfFile).mockReturnValue(secondPending.promise)
  let current=true
  open(()=>current);fireEvent.click(screen.getByRole('button',{name:'PDF 파일 다운로드'}))
  await waitFor(()=>expect(artifactPdfFile).toHaveBeenCalledTimes(2))
  current=false;await act(async()=>secondPending.resolve(file))
  expect(URL.createObjectURL).not.toHaveBeenCalled()
})
it('keeps source after conversion failure and retries only on another explicit click',async()=>{
  vi.mocked(artifactPdfFile).mockRejectedValueOnce(new Error('conversion failed')).mockResolvedValueOnce(file)
  open();fireEvent.click(screen.getByRole('button',{name:'PDF 파일 다운로드'}))
  await screen.findByRole('alert');expect(doc.content).toBe('# 원본');expect(URL.createObjectURL).not.toHaveBeenCalled()
  expect(artifactPdfFile).toHaveBeenCalledTimes(1)
  fireEvent.click(screen.getByRole('button',{name:'PDF 파일 다운로드'}))
  await screen.findByRole('status');expect(artifactPdfFile).toHaveBeenCalledTimes(2)
  expect(URL.createObjectURL).toHaveBeenCalledTimes(1)
})

it('does not convert or download after authority changes during font loading',async()=>{
 let resolve!:(value:typeof fonts)=>void
 vi.mocked(loadArtifactPdfFonts).mockReturnValue(new Promise(ok=>{resolve=ok}))
 open();fireEvent.click(screen.getByRole('button',{name:'PDF 파일 다운로드'}))
 await waitFor(()=>expect(loadArtifactPdfFonts).toHaveBeenCalledTimes(1))
 await act(async()=>setStoredToken('retired-user'));await act(async()=>resolve(fonts))
 expect(artifactPdfFile).not.toHaveBeenCalled();expect(URL.createObjectURL).not.toHaveBeenCalled()
})

import { createCanvas } from '@napi-rs/canvas'
import { html } from 'htm/preact'
import { act,cleanup,fireEvent,render,screen,waitFor } from '@testing-library/preact'
import { expect,it,vi,beforeEach,afterEach } from 'vitest'
import { setStoredToken,clearStoredToken,currentStoredTokenRevision } from '../../api/core'
import { artifactPptxFile,type ArtifactPptxFile } from '../../lib/artifact-pptx-export'
import type { ArtifactDocument } from '../../api/published-artifacts'
import { ArtifactPptxExport } from './artifact-pptx-export'
vi.mock('../../lib/artifact-pptx-export',()=>({artifactPptxFile:vi.fn()}))
const doc:ArtifactDocument={content:'# 원본',revisions:[],artifact:{id:`artifact-${'a'.repeat(32)}`,revision:3,title:'문서',summary:'요약',format:'markdown',author:'keeper',created_at:'now',task_id:null,goal_id:null,url:'/',body:{_blob:{sha256:'f'.repeat(64)}}}}
const file:ArtifactPptxFile={slides:3,data:new Uint8Array([1,2,3]).buffer,notices:['외부 그림을 링크로 바꿨습니다.']}
function deferred(){let resolve!:(value:ArtifactPptxFile)=>void;const promise=new Promise<ArtifactPptxFile>(ok=>{resolve=ok});return {promise,resolve}}
beforeEach(()=>{vi.spyOn(HTMLCanvasElement.prototype,'getContext').mockReturnValue(createCanvas(1,1).getContext('2d') as unknown as CanvasRenderingContext2D);Object.defineProperty(document,'fonts',{configurable:true,value:{ready:Promise.resolve()}});setStoredToken('pptx-export-user');vi.mocked(artifactPptxFile).mockReset();vi.spyOn(URL,'createObjectURL').mockReturnValue('blob:pptx-export');vi.spyOn(URL,'revokeObjectURL').mockImplementation(()=>{});vi.spyOn(HTMLAnchorElement.prototype,'click').mockImplementation(()=>{})})
afterEach(()=>{cleanup();clearStoredToken();vi.restoreAllMocks()})
function open(isCurrent=()=>true){return render(html`<${ArtifactPptxExport} doc=${doc} authRevision=${currentStoredTokenRevision()} isCurrent=${isCurrent} disabled=${false} />`)}
it('downloads the captured publication revision once and reports conversion notices',async()=>{
  const pending=deferred();vi.mocked(artifactPptxFile).mockReturnValue(pending.promise)
  open();fireEvent.click(screen.getByRole('button',{name:'PPT 파일 다운로드'}))
  await waitFor(()=>expect(artifactPptxFile).toHaveBeenCalledTimes(1))
  fireEvent.click(screen.getByRole('button',{name:'PPT 파일을 만들고 있습니다.'}))
  expect(artifactPptxFile).toHaveBeenCalledWith(doc,expect.any(Function));expect(URL.createObjectURL).not.toHaveBeenCalled()
  await act(async()=>pending.resolve(file))
  await screen.findByText('PPT 파일 다운로드를 요청했습니다. 외부 그림을 링크로 바꿨습니다.')
  expect(artifactPptxFile).toHaveBeenCalledTimes(1)
  expect(URL.createObjectURL).toHaveBeenCalledTimes(1)
  expect(vi.mocked(HTMLAnchorElement.prototype.click).mock.instances[0]).toMatchObject({download:`${doc.artifact.id}-v3.pptx`,href:'blob:pptx-export'})
  expect(URL.revokeObjectURL).toHaveBeenCalledWith('blob:pptx-export')
})
it('does not download an old export after credential or reader ownership changes',async()=>{
  const pending=deferred();vi.mocked(artifactPptxFile).mockReturnValue(pending.promise)
  const first=open();fireEvent.click(screen.getByRole('button',{name:'PPT 파일 다운로드'}))
  await waitFor(()=>expect(artifactPptxFile).toHaveBeenCalledTimes(1))
  await act(async()=>setStoredToken('another-user'));await act(async()=>pending.resolve(file))
  expect(URL.createObjectURL).not.toHaveBeenCalled();first.unmount()
  const secondPending=deferred();vi.mocked(artifactPptxFile).mockReturnValue(secondPending.promise)
  let current=true
  open(()=>current);fireEvent.click(screen.getByRole('button',{name:'PPT 파일 다운로드'}))
  await waitFor(()=>expect(artifactPptxFile).toHaveBeenCalledTimes(2))
  current=false;await act(async()=>secondPending.resolve(file))
  expect(URL.createObjectURL).not.toHaveBeenCalled()
})
it('keeps source after conversion failure and retries only on another explicit click',async()=>{
  vi.mocked(artifactPptxFile).mockRejectedValueOnce(new Error('conversion failed')).mockResolvedValueOnce(file)
  open();fireEvent.click(screen.getByRole('button',{name:'PPT 파일 다운로드'}))
  await screen.findByRole('alert');expect(doc.content).toBe('# 원본');expect(URL.createObjectURL).not.toHaveBeenCalled()
  expect(artifactPptxFile).toHaveBeenCalledTimes(1)
  fireEvent.click(screen.getByRole('button',{name:'PPT 파일 다운로드'}))
  await screen.findByRole('status');expect(artifactPptxFile).toHaveBeenCalledTimes(2)
  expect(URL.createObjectURL).toHaveBeenCalledTimes(1)
})

it('retires a pending download when its reader unmounts',async()=>{
  const pending=deferred();vi.mocked(artifactPptxFile).mockReturnValue(pending.promise)
  const reader=open();fireEvent.click(screen.getByRole('button',{name:'PPT 파일 다운로드'}))
  await waitFor(()=>expect(artifactPptxFile).toHaveBeenCalledTimes(1))
  reader.unmount();await act(async()=>pending.resolve(file))
  expect(URL.createObjectURL).not.toHaveBeenCalled()
})

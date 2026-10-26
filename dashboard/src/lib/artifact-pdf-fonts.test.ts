import { afterEach,expect,it,vi } from 'vitest'
import { loadArtifactPdfFonts } from './artifact-pdf-fonts'
afterEach(()=>vi.unstubAllGlobals())
it('reads only bundled font URLs without credentials or redirects',async()=>{
 const fetch=vi.fn().mockResolvedValue({ok:true,arrayBuffer:async()=>new Uint8Array([1,2,3]).buffer});vi.stubGlobal('fetch',fetch)
 const fonts=await loadArtifactPdfFonts()
 expect(fetch).toHaveBeenCalledTimes(3)
 for(const [url,options]of fetch.mock.calls){expect(String(url)).not.toMatch(/^https?:/);expect(options).toEqual({credentials:'omit',mode:'same-origin',redirect:'error'})}
 expect([...fonts.regular]).toEqual([1,2,3]);expect([...fonts.emoji]).toEqual([1,2,3])
})
it('reports an unavailable bundled font instead of silently using a system font or retrying',async()=>{
 const fetch=vi.fn().mockResolvedValue({ok:false});vi.stubGlobal('fetch',fetch)
 await expect(loadArtifactPdfFonts()).rejects.toThrow('PDF 글꼴을 읽지 못했습니다.')
 expect(fetch).toHaveBeenCalledTimes(3)
})

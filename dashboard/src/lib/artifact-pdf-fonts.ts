import regular from '../assets/pdf-fonts/NotoSansKR-Regular.otf?url'
import bold from '../assets/pdf-fonts/NotoSansKR-Bold.otf?url'
import emoji from '../assets/pdf-fonts/NotoEmoji.ttf?url'
export type ArtifactPdfFonts={regular:Uint8Array;bold:Uint8Array;emoji:Uint8Array}
export async function loadArtifactPdfFonts():Promise<ArtifactPdfFonts> {
  const read=async(url:string)=>{
    const response=await fetch(url,{credentials:'omit',mode:'same-origin',redirect:'error'})
    if(!response.ok)throw new Error('PDF 글꼴을 읽지 못했습니다.')
    return new Uint8Array(await response.arrayBuffer())
  }
  const [normal,strong,symbols]=await Promise.all([read(regular),read(bold),read(emoji)])
  return {regular:normal,bold:strong,emoji:symbols}
}

import { officeXmlText } from './artifact-office-text'

export const hwpxNs = {
  paragraph: 'http://www.hancom.co.kr/hwpml/2011/paragraph',
  core: 'http://www.hancom.co.kr/hwpml/2011/core',
  head: 'http://www.hancom.co.kr/hwpml/2011/head',
  section: 'http://www.hancom.co.kr/hwpml/2011/section',
  package: 'http://www.idpf.org/2007/opf/',
  container: 'urn:oasis:names:tc:opendocument:xmlns:container',
} as const
export const hwpxXmlDeclaration = '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
export const hwpxPage = { width: 59530, height: 84190, margin: 7200, fontHeight: 1100, cellHeight: 2200 } as const
export const hwpUnitsPerCssPixel = 75
// Both OWPML's unsignedShort fields and HTML's cell-span bounds must be representable.
export const hwpxTableLimits = { columns: 1000, rows: 65534 } as const
export type HwpxCharacterStyle = { readonly bold: boolean; readonly italic: boolean; readonly height: number }
export type HwpxManifestItem = { readonly id: string; readonly path: string; readonly mime: string }
const languages = ['hangul', 'latin', 'hanja', 'japanese', 'other', 'symbol', 'user']
const namespaceAttributes = Object.entries(hwpxNs).filter(([name]) => ['paragraph', 'core', 'head', 'section'].includes(name))
  .map(([name, uri]) => `xmlns:${({ paragraph: 'hp', core: 'hc', head: 'hh', section: 'hs' } as const)[name as 'paragraph' | 'core' | 'head' | 'section']}="${uri}"`).join(' ')
const repeated = (value: number) => languages.map(language => `${language}="${value}"`).join(' ')

/** Required OWPML attributes and child order follow Hancom's model and rhwp's serializers. */
export function hwpxHeader(styles: readonly HwpxCharacterStyle[]): string {
  const fonts = ['HANGUL', 'LATIN', 'HANJA', 'JAPANESE', 'OTHER', 'SYMBOL', 'USER'].map(language =>
    `<hh:fontface lang="${language}" fontCnt="1"><hh:font id="0" face="맑은 고딕" type="TTF" isEmbedded="0"/></hh:fontface>`).join('')
  const borders = [false, true].map((solid, index) => `<hh:borderFill id="${index + 1}" threeD="0" shadow="0" centerLine="NONE" breakCellSeparateLine="0"><hh:slash type="NONE" Crooked="0" isCounter="0"/><hh:backSlash type="NONE" Crooked="0" isCounter="0"/>${['left', 'right', 'top', 'bottom'].map(side => `<hh:${side}Border type="${solid ? 'SOLID' : 'NONE'}" width="0.12 mm" color="#000000"/>`).join('')}<hh:diagonal type="NONE" width="0.12 mm" color="#000000"/></hh:borderFill>`).join('')
  const chars = styles.map((style, id) => `<hh:charPr id="${id}" height="${style.height}" textColor="#000000" shadeColor="none" useFontSpace="0" useKerning="0" symMark="NONE" borderFillIDRef="1"><hh:fontRef ${repeated(0)}/><hh:ratio ${repeated(100)}/><hh:spacing ${repeated(0)}/><hh:relSz ${repeated(100)}/><hh:offset ${repeated(0)}/>${style.italic ? '<hh:italic/>' : ''}${style.bold ? '<hh:bold/>' : ''}<hh:underline type="NONE" shape="SOLID" color="#000000"/><hh:strikeout shape="NONE" color="#000000"/><hh:outline type="NONE"/><hh:shadow type="NONE" color="#C0C0C0" offsetX="10" offsetY="10"/></hh:charPr>`).join('')
  const para = '<hh:paraPr id="0" tabPrIDRef="0" condense="0" fontLineHeight="0" snapToGrid="1" suppressLineNumbers="0" checked="0"><hh:align horizontal="LEFT" vertical="BASELINE"/><hh:heading type="NONE" idRef="0" level="0"/><hh:breakSetting breakLatinWord="KEEP_WORD" breakNonLatinWord="KEEP_WORD" widowOrphan="0" keepWithNext="0" keepLines="0" pageBreakBefore="0" lineWrap="BREAK"/><hh:autoSpacing eAsianEng="0" eAsianNum="0"/><hh:margin><hc:intent value="0" unit="HWPUNIT"/><hc:left value="0" unit="HWPUNIT"/><hc:right value="0" unit="HWPUNIT"/><hc:prev value="0" unit="HWPUNIT"/><hc:next value="0" unit="HWPUNIT"/></hh:margin><hh:lineSpacing type="PERCENT" value="160" unit="HWPUNIT"/><hh:border borderFillIDRef="1" offsetLeft="0" offsetRight="0" offsetTop="0" offsetBottom="0" connect="0" ignoreMargin="0"/></hh:paraPr>'
  return `${hwpxXmlDeclaration}<hh:head ${namespaceAttributes} version="1.2" secCnt="1"><hh:beginNum page="1" footnote="1" endnote="1" pic="1" tbl="1" equation="1"/><hh:refList><hh:fontfaces itemCnt="7">${fonts}</hh:fontfaces><hh:borderFills itemCnt="2">${borders}</hh:borderFills><hh:charProperties itemCnt="${styles.length}">${chars}</hh:charProperties><hh:tabProperties itemCnt="1"><hh:tabPr id="0" autoTabLeft="0" autoTabRight="0"/></hh:tabProperties><hh:paraProperties itemCnt="1">${para}</hh:paraProperties><hh:styles itemCnt="1"><hh:style id="0" type="PARA" name="바탕글" engName="Normal" paraPrIDRef="0" charPrIDRef="0" nextStyleIDRef="0" langID="1042" lockForm="0"/></hh:styles></hh:refList><hh:compatibleDocument targetProgram="HWP201X"><hh:layoutCompatibility/></hh:compatibleDocument><hh:docOption><hh:linkinfo path="" pageInherit="0" footnoteInherit="0"/></hh:docOption></hh:head>`
}

export function hwpxParagraph(content: string, id: number): string {
  return `<hp:p id="${id}" paraPrIDRef="0" styleIDRef="0" pageBreak="0" columnBreak="0" merged="0">${content || '<hp:run charPrIDRef="0"><hp:t/></hp:run>'}</hp:p>`
}

export function hwpxSection(content: string): string {
  const { width, height, margin } = hwpxPage
  const section = `<hp:secPr id="" textDirection="HORIZONTAL" spaceColumns="0" tabStop="8000" tabStopVal="4000" tabStopUnit="HWPUNIT" outlineShapeIDRef="0" memoShapeIDRef="0" textVerticalWidthHead="0" masterPageCnt="0"><hp:grid lineGrid="0" charGrid="0" wonggojiFormat="0"/><hp:startNum pageStartsOn="BOTH" page="0" pic="0" tbl="0" equation="0"/><hp:visibility hideFirstHeader="0" hideFirstFooter="0" hideFirstMasterPage="0" border="SHOW_ALL" fill="SHOW_ALL" hideFirstPageNum="0" hideFirstEmptyLine="0" showLineNumber="0"/><hp:lineNumberShape restartType="0" countBy="0" distance="0" startNumber="0"/><hp:pagePr landscape="WIDELY" width="${width}" height="${height}" gutterType="LEFT_ONLY"><hp:margin header="0" footer="0" gutter="0" left="${margin}" right="${margin}" top="${margin}" bottom="${margin}"/></hp:pagePr></hp:secPr><hp:ctrl><hp:colPr id="" type="NEWSPAPER" layout="LEFT" colCount="1" sameSz="1" sameGap="0"/></hp:ctrl>`
  return `${hwpxXmlDeclaration}<hs:sec ${namespaceAttributes}>${hwpxParagraph(`<hp:run charPrIDRef="0">${section}<hp:t/></hp:run>`, 0)}${content}</hs:sec>`
}

export function hwpxManifest(items: readonly HwpxManifestItem[], title: string, creator: string): string {
  return `${hwpxXmlDeclaration}<opf:package xmlns:opf="${hwpxNs.package}" version="" unique-identifier="" id=""><opf:metadata><opf:title>${officeXmlText(title)}</opf:title><opf:language>ko</opf:language><opf:meta name="creator" content="text">${officeXmlText(creator)}</opf:meta></opf:metadata><opf:manifest>${items.map(item => `<opf:item id="${officeXmlText(item.id)}" href="${officeXmlText(item.path)}" media-type="${officeXmlText(item.mime)}"/>`).join('')}</opf:manifest><opf:spine><opf:itemref idref="header" linear="yes"/><opf:itemref idref="section0" linear="yes"/></opf:spine></opf:package>`
}

export function hwpxGeometry(width: number, height: number): string {
  return `<hp:sz width="${width}" widthRelTo="ABSOLUTE" height="${height}" heightRelTo="ABSOLUTE" protect="0"/><hp:pos treatAsChar="1" affectLSpacing="1" flowWithText="1" allowOverlap="0" holdAnchorAndSO="0" vertRelTo="PARA" horzRelTo="PARA" vertAlign="TOP" horzAlign="LEFT" vertOffset="0" horzOffset="0"/><hp:outMargin left="0" right="0" top="0" bottom="0"/>`
}

export function hwpxObjectAttributes(id: number): string {
  return `id="${id}" zOrder="0" numberingType="NONE" textWrap="TOP_AND_BOTTOM" textFlow="BOTH_SIDES" lock="0" dropcapstyle="None"`
}

export function hwpxPicture(id: number, reference: string, width: number, height: number, description: string): string {
  const matrix = '<hc:transMatrix e1="1" e2="0" e3="0" e4="0" e5="1" e6="0"/><hc:scaMatrix e1="1" e2="0" e3="0" e4="0" e5="1" e6="0"/><hc:rotMatrix e1="1" e2="0" e3="0" e4="0" e5="1" e6="0"/>'
  return `<hp:pic ${hwpxObjectAttributes(id)} href="" groupLevel="0" instid="${id}" reverse="0"><hp:offset x="0" y="0"/><hp:orgSz width="${width}" height="${height}"/><hp:curSz width="${width}" height="${height}"/><hp:flip horizontal="0" vertical="0"/><hp:rotationInfo angle="0" centerX="${Math.round(width / 2)}" centerY="${Math.round(height / 2)}" rotateimage="1"/><hp:renderingInfo>${matrix}</hp:renderingInfo><hp:imgRect><hc:pt0 x="0" y="0"/><hc:pt1 x="${width}" y="0"/><hc:pt2 x="${width}" y="${height}"/><hc:pt3 x="0" y="${height}"/></hp:imgRect><hp:imgClip left="0" right="${width}" top="0" bottom="${height}"/><hp:inMargin left="0" right="0" top="0" bottom="0"/><hp:imgDim dimwidth="${width}" dimheight="${height}"/><hc:img binaryItemIDRef="${officeXmlText(reference)}" bright="0" contrast="0" effect="REAL_PIC" alpha="0"/><hp:effects/>${hwpxGeometry(width, height)}<hp:shapeComment>${officeXmlText(description)}</hp:shapeComment></hp:pic>`
}

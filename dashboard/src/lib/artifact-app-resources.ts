import type { JsonObject } from '../api/artifact-app-data'

// URL parses/canonicalizes the origin. This grammar additionally excludes CSP
// separators and wildcards, which URL accepts in some registered names.
export function resourceOrigin(value:string):string {
  const url=new URL(value.trim())
  if((url.protocol!=='https:'&&url.protocol!=='http:')||url.username||url.password
    ||url.pathname!=='/'||url.search||url.hash
    ||! /^(?:[a-z0-9.-]+|\[[0-9a-f:]+\])$/.test(url.hostname))throw new Error('경로 없이 http 또는 https 출처를 입력해 주세요.')
  return url.origin
}
export function resourceOrigins(data:JsonObject):readonly string[] {
  if(!Object.hasOwn(data,'resource_origins'))return []
  const values=data.resource_origins
  if(!Array.isArray(values)||!values.every(value=>typeof value==='string'&&resourceOrigin(value)===value)
    ||new Set(values).size!==values.length)throw new Error('저장된 외부 연결 설정을 읽을 수 없습니다.')
  return values as string[]
}
export function resourceOriginLines(text:string):readonly string[] {
  return [...new Set(text.split('\n').map(line=>line.trim()).filter(Boolean).map(resourceOrigin))]
}

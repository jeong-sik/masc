export interface JsonSchema {
  type: 'object' | 'string' | 'integer' | 'number' | 'boolean' | 'array'
  properties?: Record<string, JsonSchemaProperty>
  required?: string[]
  description?: string
  additionalProperties?: boolean
}

export interface JsonSchemaProperty {
  type: 'string' | 'integer' | 'number' | 'boolean' | 'array' | 'object'
  description?: string
  enum?: string[]
  default?: unknown
  items?: JsonSchemaProperty
  properties?: Record<string, JsonSchemaProperty>
  required?: string[]
}

export interface McpToolSchema {
  name: string
  description: string
  inputSchema: JsonSchema
  annotations?: {
    readOnlyHint?: boolean
    destructiveHint?: boolean
    idempotentHint?: boolean
    deprecated?: boolean
    [key: string]: unknown
  }
}


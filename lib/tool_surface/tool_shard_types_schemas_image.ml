(** Image tool schemas for keeper agents.
    Three tools: keeper_image_generate (AI generation),
    keeper_image_search (web image search),
    keeper_image_preview (URL/markdown preview). *)

let image_tools : Masc_domain.tool_schema list =
  [ { name = "keeper_image_generate"
    ; description =
        "Generate an image from a text prompt using an AI model. \
         Returns a data URI or file reference for the generated image."
    ; input_schema =
        `Assoc
          [ "type", `String "object"
          ; "properties", `Assoc
              [ "prompt"
              , `Assoc
                  [ "type", `String "string"
                  ; "description", `String "Text description of the image to generate"
                  ]
              ; "size"
              , `Assoc
                  [ "type", `String "string"
                  ; "description", `String "Image size (e.g. 1024x1024, 1792x1024)"
                  ; "enum", `List [`String "1024x1024"; `String "1792x1024"; `String "1024x1792"]
                  ]
              ; "style"
              , `Assoc
                  [ "type", `String "string"
                  ; "description", `String "Visual style (vivid, natural, or abstract)"
                  ; "enum", `List [`String "vivid"; `String "natural"; `String "abstract"]
                  ]
              ]
          ; "required", `List [`String "prompt"]
          ]
    ; output_schema =
        Some
          (`Assoc
            [ "type", `String "object"
            ; "properties", `Assoc
                [ "image_url", `Assoc
                    [ "type", `String "string"
                    ; "description", `String "URL or data URI of the generated image"
                    ]
                ; "revised_prompt", `Assoc
                    [ "type", `String "string"
                    ; "description", `String "The prompt as revised by the model for safety/fidelity"
                    ]
                ; "mime_type", `Assoc
                    [ "type", `String "string"
                    ; "description", `String "MIME type of the image (e.g. image/png, image/webp)"
                    ]
                ]
            ])
    }
  ; { name = "keeper_image_search"
    ; description =
        "Search the web for images matching a query. \
         Returns a list of image URLs, thumbnails, and metadata."
    ; input_schema =
        `Assoc
          [ "type", `String "object"
          ; "properties", `Assoc
              [ "query", `Assoc
                  [ "type", `String "string"
                  ; "description", `String "Search query for finding images"
                  ]
              ; "count", `Assoc
                  [ "type", `String "integer"
                  ; "description", `String "Number of results to return (1-20)"
                  ; "default", `Int 5
                  ]
              ; "safe_search", `Assoc
                  [ "type", `String "boolean"
                  ; "description", `String "Enable safe search filtering"
                  ; "default", `Bool true
                  ]
              ]
          ; "required", `List [`String "query"]
          ]
    ; output_schema =
        Some
          (`Assoc
            [ "type", `String "object"
            ; "properties", `Assoc
                [ "results", `Assoc
                    [ "type", `String "array"
                    ; "items", `Assoc
                        [ "type", `String "object"
                        ; "properties", `Assoc
                            [ "url", `Assoc
                                [ "type", `String "string"
                                ; "description", `String "Direct image URL"
                                ]
                            ; "thumbnail_url", `Assoc
                                [ "type", `String "string"
                                ; "description", `String "Thumbnail URL"
                                ]
                            ; "title", `Assoc
                                [ "type", `String "string"
                                ; "description", `String "Image title or alt text"
                                ]
                            ; "source_url", `Assoc
                                [ "type", `String "string"
                                ; "description", `String "Source webpage URL"
                                ]
                            ; "width", `Assoc
                                [ "type", `String "integer"
                                ; "description", `String "Image width in pixels"
                                ]
                            ; "height", `Assoc
                                [ "type", `String "integer"
                                ; "description", `String "Image height in pixels"
                                ]
                            ; "mime_type", `Assoc
                                [ "type", `String "string"
                                ; "description", `String "Image MIME type"
                                ]
                            ]
                        ]
                    ]
                ]
            ])
    }
  ; { name = "keeper_image_preview"
    ; description =
        "Fetch and return a preview (thumbnail + metadata) for one or more image URLs. \
         Useful for showing inline image previews in agent responses."
    ; input_schema =
        `Assoc
          [ "type", `String "object"
          ; "properties", `Assoc
              [ "urls", `Assoc
                  [ "type", `String "array"
                  ; "items", `Assoc
                      [ "type", `String "string"
                      ; "description", `String "Image URL to preview"
                      ]
                  ; "description", `String "One or more image URLs to fetch previews for"
                  ]
              ; "max_width", `Assoc
                  [ "type", `String "integer"
                  ; "description", `String "Maximum preview width in pixels"
                  ; "default", `Int 512
                  ]
              ]
          ; "required", `List [`String "urls"]
          ]
    ; output_schema =
        Some
          (`Assoc
            [ "type", `String "object"
            ; "properties", `Assoc
                [ "previews", `Assoc
                    [ "type", `String "array"
                    ; "items", `Assoc
                        [ "type", `String "object"
                        ; "properties", `Assoc
                            [ "url", `Assoc
                                [ "type", `String "string"
                                ; "description", `String "Original image URL"
                                ]
                            ; "thumbnail_data_uri", `Assoc
                                [ "type", `String "string"
                                ; "description", `String "Base64-encoded thumbnail as data URI"
                                ]
                            ; "width", `Assoc
                                [ "type", `String "integer"
                                ; "description", `String "Original image width"
                                ]
                            ; "height", `Assoc
                                [ "type", `String "integer"
                                ; "description", `String "Original image height"
                                ]
                            ; "mime_type", `Assoc
                                [ "type", `String "string"
                                ; "description", `String "Detected MIME type"
                                ]
                            ; "file_size_bytes", `Assoc
                                [ "type", `String "integer"
                                ; "description", `String "Image file size in bytes"
                                ]
                            ]
                        ]
                    ]
                ]
            ])
    }
  ]
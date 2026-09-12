; SPDX-License-Identifier: MIT
; A homebrew DOS .COM program. No external game or ROM is required.
; STATE.BIN: "LANE", little-endian uint16 version=1, uint16 counter.
; N increments modulo 65536. Green bar width = 1 + (counter mod 256).
bits 16
org 100h

start:
    push cs
    pop ds
    mov ax, 0013h             ; VGA 320 x 200, 256 colours
    int 10h
    push ds
    pop es
    mov ax, 1012h             ; Set black, green, white palette entries
    xor bx, bx
    mov cx, 3
    mov dx, palette
    int 10h
    call publish
read_key:
    xor ah, ah
    int 16h                  ; Block in BIOS until actual keyboard input
    cmp al, 'n'
    je increment
    cmp al, 'N'
    jne read_key
increment:
    inc word [counter]
    call publish
    jmp read_key

publish:
    ; Close the file before rendering the matching counter's bar.
    ; The package seeds an eight-byte virtual file. Open without truncating so
    ; an observer never sees a temporary empty file between two guest states.
    mov ax, 3d02h
    mov dx, filename
    int 21h
    jc fatal
    mov bx, ax
    mov ah, 40h
    mov cx, 8
    mov dx, state
    int 21h
    jc fatal
    cmp ax, 8
    jne fatal
    mov ah, 3eh
    int 21h
    jc fatal

    mov ax, 0a000h
    mov es, ax
    cld
    xor di, di
    xor al, al
    mov cx, 64000
    rep stosb                ; Black background
    mov di, 32 * 320 + 16
    mov bx, 16
header_row:
    mov al, 2
    mov cx, 288
    rep stosb
    add di, 32
    dec bx
    jnz header_row
    mov di, 80 * 320 + 16
    xor dx, dx
    mov dl, [counter]
    inc dx
    mov bx, 16
bar_row:
    mov al, 1
    mov cx, dx
    rep stosb
    add di, 320
    sub di, dx
    dec bx
    jnz bar_row
    ret

fatal:
    mov ax, 4c01h
    int 21h

palette: db 0,0,0, 0,63,0, 63,63,63
filename: db 'STATE.BIN',0
state: db 'LANE'
       dw 1
counter: dw 0

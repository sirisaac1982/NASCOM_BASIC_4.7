;==============================================================================
; Contents of this file are copyright Phillip Stevens
;
; You have permission to use this for NON COMMERCIAL USE ONLY
; If you wish to use it elsewhere, please include an acknowledgement to myself.
;
; Initialisation routines to suit Z8S180 CPU, with internal USART.
;
; Internal USART interrupt driven serial I/O
; Full input and output buffering.
;
; https://github.com/feilipu/
;
; https://feilipu.me/
;

;==============================================================================
;
; INCLUDES SECTION
;

#include    "d:/yaz180.h"
#include    "d:/z80intr.asm"
#include    "d:/z180intr.asm"

;==============================================================================
;
; DEFINES SECTION
;

; Top of BASIC line input buffer (CURPOS WRKSPC+0ABH)
; so it is "free ram" when BASIC resets
; set BASIC Work space WRKSPC $8000, in CA1 RAM

WRKSPC          .EQU     RAMSTART_CA1 
TEMPSTACK       .EQU     WRKSPC+$AB

;==============================================================================
;
; CODE SECTION
;

        .ORG    0100H

;------------------------------------------------------------------------------
ASCI0_INTERRUPT:
        push af
        push hl
                                    ; start doing the Rx stuff
        in0 a, (STAT0)              ; load the ASCI0 status register
        and SER_RDRF                ; test whether we have received on ASCI0
        jr z, ASCI0_TX_CHECK        ; if not, go check for bytes to transmit

ASCI0_RX_GET:
        in0 l, (RDR0)               ; move Rx byte from the ASCI0 to l

        ld a, (serRx0BufUsed)       ; get the number of bytes in the Rx buffer      
        cp SER_RX0_BUFSIZE          ; check whether there is space in the buffer
        jr nc, ASCI0_RX_CHECK       ; buffer full, check whether we need to drain H/W FIFO

        ld a, l                     ; get Rx byte from l
        ld hl, (serRx0InPtr)        ; get the pointer to where we poke
        ld (hl), a                  ; write the Rx byte to the serRx0InPtr target

        inc l                       ; move the Rx pointer low byte along, 0xFF rollover
        ld (serRx0InPtr), hl        ; write where the next byte should be poked

        ld hl, serRx0BufUsed
        inc (hl)                    ; atomically increment Rx buffer count

ASCI0_RX_CHECK:                     ; Z8S180 has 4 byte Rx H/W FIFO
        in0 a, (STAT0)              ; load the ASCI0 status register
        and SER_RDRF                ; test whether we have received on ASCI0
        jr nz, ASCI0_RX_GET         ; if still more bytes in H/W FIFO, get them

ASCI0_TX_CHECK:                     ; now start doing the Tx stuff
        in0 a, (STAT0)              ; load the ASCI0 status register
        and SER_TDRE                ; test whether we can transmit on ASCI0
        jr z, ASCI0_TX_END          ; if not, then end

        ld a, (serTx0BufUsed)       ; get the number of bytes in the Tx buffer
        or a                        ; check whether it is zero
        jr z, ASCI0_TX_TIE0_CLEAR   ; if the count is zero, then disable the Tx Interrupt

        ld hl, (serTx0OutPtr)       ; get the pointer to place where we pop the Tx byte
        ld a, (hl)                  ; get the Tx byte
        out0 (TDR0), a              ; output the Tx byte to the ASCI0

        inc l                       ; move the Tx pointer low byte along, 0xFF rollover
        ld (serTx0OutPtr), hl       ; write where the next byte should be popped

        ld hl, serTx0BufUsed
        dec (hl)                    ; atomically decrement current Tx count

        jr nz, ASCI0_TX_END         ; if we've more Tx bytes to send, we're done for now

ASCI0_TX_TIE0_CLEAR:
        in0 a, (STAT0)              ; get the ASCI0 status register
        and ~SER_TIE                ; mask out (disable) the Tx Interrupt
        out0 (STAT0), a             ; set the ASCI0 status register

ASCI0_TX_END:
        pop hl
        pop af

        ei
        ret

;------------------------------------------------------------------------------
RX0:
        ld a, (serRx0BufUsed)       ; get the number of bytes in the Rx buffer
        or a                        ; see if there are zero bytes available
        jr z, RX0                   ; wait, if there are no bytes available

        push hl                     ; Store HL so we don't clobber it

        ld hl, (serRx0OutPtr)       ; get the pointer to place where we pop the Rx byte
        ld a, (hl)                  ; get the Rx byte

        inc l                       ; move the Rx pointer low byte along, 0xFF rollover
        ld (serRx0OutPtr), hl       ; write where the next byte should be popped

        ld hl, serRx0BufUsed
        dec (hl)                    ; atomically decrement Rx count

        pop hl                      ; recover HL
        ret                         ; char ready in A

;------------------------------------------------------------------------------
TX0:
        push hl                     ; store HL so we don't clobber it        
        ld l, a                     ; store Tx character 

        ld a, (serTx0BufUsed)       ; get the number of bytes in the Tx buffer
        or a                        ; check whether the buffer is empty
        jr nz, TX0_BUFFER_OUT       ; buffer not empty, so abandon immediate Tx

        in0 a, (STAT0)              ; get the ASCI0 status register
        and SER_TDRE                ; test whether we can transmit on ASCI0
        jr z, TX0_BUFFER_OUT        ; if not, so abandon immediate Tx

        ld a, l                     ; Retrieve Tx character for immediate Tx
        out0 (TDR0), a              ; output the Tx byte to the ASCI0

        pop hl                      ; recover HL
        ret                         ; and just complete

TX0_BUFFER_OUT:
        ld a, (serTx0BufUsed)       ; Get the number of bytes in the Tx buffer
        cp SER_TX0_BUFSIZE          ; check whether there is space in the buffer
        jr nc, TX0_BUFFER_OUT       ; buffer full, so wait for free buffer for Tx

        ld a, l                     ; retrieve Tx character
        ld hl, (serTx0InPtr)        ; get the pointer to where we poke
        ld (hl), a                  ; write the Tx byte to the serTx0InPtr   

        inc l                       ; move the Tx pointer low byte along, 0xFF rollover
        ld (serTx0InPtr), hl        ; write where the next byte should be poked

        ld hl, serTx0BufUsed
        inc (hl)                    ; atomic increment of Tx count

        pop hl                      ; recover HL

        in0 a, (STAT0)              ; load the ASCI0 status register
        tst SER_TIE                 ; test whether ASCI0 interrupt is set        
        ret nz                      ; if so then just return       

        di                          ; critical section begin
        in0 a, (STAT0)              ; get the ASCI status register again
        or SER_TIE                  ; mask in (enable) the Tx Interrupt
        out0 (STAT0), a             ; set the ASCI status register
        ei                          ; critical section end
        ret

;------------------------------------------------------------------------------
RX0_CHK:
        LD      A,(serRx0BufUsed)
        CP      $0
        RET

;------------------------------------------------------------------------------
TX0_PRINT:
        LD      A,(HL)              ; Get a byte
        OR      A                   ; Is it $00 ?
        RET     Z                   ; Then RETurn on terminator
        CALL    TX0                 ; Print it
        INC     HL                  ; Next byte
        JR      TX0_PRINT           ; Continue until $00

;------------------------------------------------------------------------------
HEX_START:
            ld hl, initString
            call TX0_PRINT

            ld c,0                  ; non zero c is our ESA flag

HEX_WAIT_COLON:
            call RX0                ; Rx byte
            cp ':'                  ; wait for ':'
            jr nz, HEX_WAIT_COLON
            ld hl, 0                ; reset hl to compute checksum
            call HEX_READ_BYTE      ; read byte count
            ld b, a                 ; store it in b
            call HEX_READ_BYTE      ; read upper byte of address
            ld d, a                 ; store in d
            call HEX_READ_BYTE      ; read lower byte of address
            ld e, a                 ; store in e
            call HEX_READ_BYTE      ; read record type
            cp 02                   ; check if record type is 02 (ESA)
            jr z, HEX_ESA_DATA
            cp 01                   ; check if record type is 01 (end of file)
            jr z, HEX_END_LOAD
            cp 00                   ; check if record type is 00 (data)
            jr nz, HEX_INVAL_TYPE   ; if not, error
HEX_READ_DATA:
            ld a, '*'               ; "*" per byte loaded  # DEBUG
            call TX0                ; Print it             # DEBUG
            call HEX_READ_BYTE
            ld (de), a              ; write the byte at the RAM address
            inc de
            djnz HEX_READ_DATA      ; if b non zero, loop to get more data
HEX_READ_CHKSUM:
            call HEX_READ_BYTE      ; read checksum, but we don't need to keep it
            ld a, l                 ; lower byte of hl checksum should be 0
            or a
            jr nz, HEX_BAD_CHK      ; non zero, we have an issue
            ld a, '#'               ; "#" per line loaded
            call TX0                ; Print it
            ld a, CR                ; CR                   # DEBUG
            call TX0                ; Print it             # DEBUG
            ld a, LF                ; LF                   # DEBUG
            call TX0                ; Print it             # DEBUG
            jr HEX_WAIT_COLON

HEX_ESA_DATA:
            in0 a, (BBR)            ; grab the current Bank Base Value
            ld c, a                 ; store BBR for later recovery
            call HEX_READ_BYTE      ; get high byte of ESA
            out0 (BBR), a           ; write it to the BBR  
            call HEX_READ_BYTE      ; get low byte of ESA, abandon it, but calc checksum
            jr HEX_READ_CHKSUM      ; calculate checksum

HEX_END_LOAD:
            call HEX_READ_BYTE      ; read checksum, but we don't need to keep it
            ld a, l                 ; lower byte of hl checksum should be 0
            or a
            jr nz, HEX_BAD_CHK      ; non zero, we have an issue
            call HEX_BBR_RESTORE    ; clean up the BBR
            ld hl, LoadOKStr
            call TX0_PRINT
            jp WARMSTART            ; ready to run our loaded program from Basic
            
HEX_INVAL_TYPE:
            call HEX_BBR_RESTORE    ; clean up the BBR
            ld hl, invalidTypeStr
            call TX0_PRINT
            jp START                ; go back to start

HEX_BAD_CHK:
            call HEX_BBR_RESTORE    ; clean up the BBR
            ld hl, badCheckSumStr
            call TX0_PRINT
            jp START                ; go back to start

HEX_BBR_RESTORE:
            ld a, c                 ; get our BBR back
            ret z                   ; if it is zero, chances are we don't need it
            out0 (BBR), a           ; write it to the BBR
            ret

HEX_READ_BYTE:                      ; Returns byte in a, checksum in hl
            push bc
            call RX0                ; Rx byte
            sub '0'
            cp 10
            jr c, HEX_READ_NBL2     ; if a<10 read the second nibble
            sub 7                   ; else subtract 'A'-'0' (17) and add 10
HEX_READ_NBL2:
            rlca                    ; shift accumulator left by 4 bits
            rlca
            rlca
            rlca
            ld c, a                 ; temporarily store the first nibble in c
            call RX0                ; Rx byte
            sub '0'
            cp 10
            jr c, HEX_READ_END      ; if a<10 finalize
            sub 7                   ; else subtract 'A' (17) and add 10
HEX_READ_END:
            or c                    ; assemble two nibbles into one byte in a
            ld b, 0                 ; add the byte read to hl (for checksum)
            ld c, a
            add hl, bc
            pop bc
            ret                     ; return the byte read in a

;------------------------------------------------------------------------------

            .ORG    0300H
INIT:
                                    ; Set I/O Control Reg (ICR)
            LD      A,IO_BASE       ; ICR = $00 [xx00 0000] for I/O Registers at $00 - $3F
            OUT0    (ICR),A         ; Standard I/O Mapping (0 Enabled)

            LD      A,Z180_VECTOR_BASE/$100
            LD      I,A             ; Set interrupt vector address high byte (I)
            
                                    ; Set interrupt vector address low byte (IL)
                                    ; IL = $20 [001x xxxx] for Vectors at $nn20 - $nn2F
            LD      A,Z180_VECTOR_BASE%$100
            OUT0    (IL),A          ; Output to the Interrupt Vector Low reg

            IM      1               ; Interrupt mode 1 for INT0

            XOR     A               ; Zero Accumulator

                                    ; Clear Refresh Control Reg (RCR)
            OUT0    (RCR),A         ; DRAM Refresh Enable (0 Disabled)

            OUT0    (TCR),A         ; Disable PRT downcounting

                                    ; Set Operation Mode Control Reg (OMCR)
                                    ; Disable M1, disable 64180 I/O _RD Mode
            OUT0    (OMCR),A        ; X80 Mode (M1 Disabled, IOC Disabled)

                                    ; Set INT/TRAP Control Register (ITC)             
            OUT0    (ITC),A         ; Disable all external interrupts. 

                                    ; Set internal clock = crystal x 2 = 36.864MHz
                                    ; if using ZS8180 or Z80182 at High-Speed
            LD      A,CMR_X2        ; Set Hi-Speed flag
            OUT0    (CMR),A         ; CPU Clock Multiplier Reg (CMR)

                                    ; DMA/Wait Control Reg Set I/O Wait States
            LD      A,DCNTL_IWI0
            OUT0    (DCNTL),A       ; 0 Memory Wait & 2 I/O Wait

                                    ; Set Logical Addresses
                                    ; $8000-$FFFF RAM CA1 -> 80H
                                    ; $4000-$7FFF RAM BANK -> 04H
                                    ; $2000-$3FFF RAM CA0
                                    ; $0000-$1FFF Flash CA0
            LD      A,84H           ; Set New Common / Bank Areas
            OUT0    (CBAR),A        ; for RAM

                                    ; Physical Addresses
            LD      A,78H           ; Set Common 1 Area Physical $80000 -> 78H
            OUT0    (CBR),A

            LD      A,3CH           ; Set Bank Area Physical $40000 -> 3CH
            OUT0    (BBR),A

                                    ; load the default ASCI configuration
                                    ; 
                                    ; BAUD = 115200 8n1
                                    ; receive enabled
                                    ; transmit enabled
                                    ; receive interrupt enabled
                                    ; transmit interrupt disabled
            LD      A,SER_RE|SER_TE|SER_8N1
            OUT0    (CNTLA0),A      ; output to the ASCI0 control A reg

                                    ; PHI / PS / SS / DR = BAUD Rate
                                    ; PHI = 18.432MHz
                                    ; BAUD = 115200 = 18432000 / 10 / 1 / 16 
                                    ; PS 0, SS_DIV_1 0, DR 0           
            XOR     A               ; BAUD = 115200
            OUT0    (CNTLB0),A      ; output to the ASCI0 control B reg

            LD      A,SER_RIE       ; receive interrupt enabled
            OUT0    (STAT0),A       ; output to the ASCI0 status reg

                                    ; Set up 82C55 PIO in Mode 0 #12
            LD      BC,PIOCNTL      ; 82C55 CNTL address in bc
            LD      A,PIOCNTL12     ; Set Mode 12 ->A, B->, ->CH, CL->
            OUT     (C),A           ; output to the PIO control reg

            LD      BC,PIOB         ; 82C55 IO PORT B address in BC
            LD      A,$01           ; Set Port B TIL311 XXX
            OUT     (C),A           ; put debug HEX Code onto Port B

            LD      SP,RAMSTOP-1    ; Set up a temporary stack at RAMSTOP
            LD      IX,INITIALISE
            JP      MEMTEST         ; do a memory test XXX

INITIALISE:
            LD      SP,TEMPSTACK    ; Set up a temporary stack

            LD      HL,Z80_VECTOR_PROTO ; Establish Z80 RST Vector Table
            LD      DE,Z80_VECTOR_BASE
            LD      BC,Z80_VECTOR_SIZE
            LDIR

            LD      HL,Z180_VECTOR_PROTO ; Establish Z180 Vector Table
            LD      DE,Z180_VECTOR_BASE
            LD      BC,Z180_VECTOR_SIZE
            LDIR

            LD      HL,serRx0Buf    ; Initialise Rx0 Buffer
            LD      (serRx0InPtr),HL
            LD      (serRx0OutPtr),HL

            LD      HL,serTx0Buf    ; Initialise Tx0 Buffer
            LD      (serTx0InPtr),HL
            LD      (serTx0OutPtr),HL              

            XOR     A               ; 0 the Tx0 & Rx0 Buffer Counts
            LD      (serRx0BufUsed),A
            LD      (serTx0BufUsed),A

            EI                      ; enable interrupts

START:
            LD      HL,SIGNON1      ; Sign-on message
            CALL    TX0_PRINT       ; Output string              
            LD      A,(basicStarted); Check the BASIC STARTED flag
            CP      'Y'             ; to see if this is power-up
            JR      NZ,COLDSTART    ; If not BASIC started then always do cold start
            LD      HL,SIGNON2      ; Cold/warm message
            CALL    TX0_PRINT       ; Output string
CORW:
            CALL    RX0
            AND     11011111B       ; lower to uppercase
            CP      'H'             ; are we trying to load an Intel HEX program?
            JP      Z, HEX_START    ; then jump to HexLoadr
            CP      'C'
            JR      NZ, CHECKWARM
            RST     08H
            LD      A,$0D
            RST     08H
            LD      A,$0A
            RST     08H
COLDSTART:
            LD      A,'Y'           ; Set the BASIC STARTED flag
            LD      (basicStarted),A
            JP      START            ; <<<< Start COLD:
CHECKWARM:
            CP      'W'
            JR      NZ, CORW
            RST     08H
            LD      A,$0D
            RST     08H
            LD      A,$0A
            RST     08H
WARMSTART:
            RST     10H          ; wait for a character
            LD      A,$01        ; Set Port B TIL311 XXX
            OUT     (C),A        ; put debug HEX Code onto Port B
            RST     08H          ; echo it back
            LD      A,$10        ; Set Port B TIL311 XXX
            OUT     (C),A        ; put debug HEX Code onto Port B
            JP      START

;------------------------------------------------------------------------------

            .ORG    0400H
MEMTEST:
            LD      HL,RAMSTART
            LD      DE,RAMSTOP-RAMSTART-40H ; make sure the stack has space
            CALL    RAMTST
            JP      C,MEMTEST_HALT
            JP      (IX)            ; return if no error

MEMTEST_HALT:
                                    ; halt if there's an error
            LD      BC,PIOB         ; 82C55 IO PORT B address in BC
            OUT     (C),H           ; put address HEX Code onto Port B
            HALT
;------------------------------------------------------------------------------
; Test a RAM area
;
; if the program finds an error, it exits immediately with the Carry flag set
; and indicates where the error occured and what value it used in the test.
;
; Entry
;       IX = return address
;       HL = base address of test area
;       DE = size of the area to test in bytes
;
; Exit Success
;       Carry flag = 0 and all test RAM is set to 0x00
;
; Exit Failure
;       Carry flag = 1
;       HL = address of error
;       A  = expected value of byte written
;
; Registers used
;       AF, BC, DE, HL, IX
;

RAMTST:
            ; EXIT WITH NO ERRORS IF AREA SIZE IS 0
            LD      A,D         ; TEST AREA SIZE
            OR      E
            RET     Z           ; EXIT WITH NO ERRORS IF SIZE IS ZERO
            LD      B,D         ; BC = AREA SIZE
            LD      C,E

            ; FILL MEMORY WITH 0 AND TEST
            SUB     A
            CALL    RAMTST_FC
            RET     C           ; EXIT IF ERROR FOUND

            ; FILL MEMORY WITH 0xFF AND TEST
            LD      A,0FFH
            CALL    RAMTST_FC
            RET     C           ; EXIT IF ERROR FOUND

            ; FILL MEMORY WITH 0xAA AND TEST
            LD      A,0AAH
            CALL    RAMTST_FC
            RET     C           ; EXIT IF ERROR FOUND

            ; FILL MEMORY WITH 0x55 AND TEST
            LD      A,055H
            CALL    RAMTST_FC
            RET     C           ; EXIT IF ERROR FOUND
            
            ; PERFORM WALKING BIT TEST
RAMTST_WK:
            CALL    RAMTST_IO   ; WRITE PAGE ADDRESS TO PORT B
            LD      A,080H      ; MAKE BIT 7 1, ALL OTHER BITS 0
RAMTST_WK1:
            LD      (HL),A      ; STORE TEST PATTERN IN MEMORY
            CP      (HL)        ; TRY TO READ IT BACK
            SCF                 ; SET CARRY IN CASE OF ERROR
            RET     NZ          ; RETURN IF ERROR
            RRCA                ; ROTATE PATTERN TO MOVE THE 1 RIGHT
            CP      080H        ; CHECK WHETHER WE'RE BACK TO START
            JR      NZ,RAMTST_WK1 ; CONTINUE UNTIL THE 1 IS BACK IN BIT 7
            LD      (HL),0      ; CLEAR BYTE JUST CHECKED
            INC     HL
            DEC     BC          ; DECREMENT AND TEST 16-BIT COUNTER
            LD      A,B
            OR      C
            JR      NZ,RAMTST_WK ; NO ERRORS (NOTE OR C CLEARS CARRY)
            RET

RAMTST_FC:
            PUSH    HL          ; SAVE BASE ADDRESS
            PUSH    BC          ; SAVE SIZE OF AREA
            LD      E,A         ; SAVE TEST VALUE
            LD      (HL),A      ; STORE TEST VALUE IN FIRST BYTE
            DEC     BC          ; REMAINING AREA = SIZE -1
            LD      A,B         ; CHECK IF ANYTHING IN REMAINING AREA
            OR      C
            LD      A,E         ; RESTORE TEST VALUE
            JR      Z,RAMTST_COMP   ; BRANCH IF AREA WAS ONLY 1 BYTE

            ; FILE REST OF AREA WITH BLOCK MOVE
            ; EACH ITERATION MOVES TEST VALUE TO NEXT HIGHER ADDRESS
            LD      D,H         ; DESTINATION IS ALWAYS SOURCE +1
            LD      E,L
            INC     DE
            LDIR                ; FILL MEMORY

            ; NOW THAT EACH LOCATION HAS BEEN FILLED, TEST TO SEE IF
            ; EACH BYTE CAN BE READ BACK CORRECTLY
RAMTST_COMP:
            POP     BC          ; RESTORE SIZE OF AREA
            POP     HL          ; RESTORE BASE ADDRESS
            PUSH    HL          ; SAVE BASE ADDRESS
            PUSH    BC          ; SAVE SIZE OF AREA

            ; RAMTST_COMP MEMORY AND TEST VALUE
RAMTST_CMPLP:
            CPI
            CALL    RAMTST_IO       ; WRITE PAGE ADDRESS TO PORT B
            JR      NZ,RAMTST_CMPER ; JUMP IF NOT EQUAL
            JP      PE,RAMTST_CMPLP ; CONTINUE THROUGH ENTIRE AREA
                                    ; NOTE CPI CLEARS P/V FLAG IF IT
                                    ; DECREMENTS BC TO 0

            ; NO ERRORS FOUND, SO CLEAR CARRY
            POP     BC          ; BC = SIZE OF AREA
            POP     HL          ; HL = BASE ADDRESS
            OR      A           ; CLEAR CARRY, INDICATING NO ERRORS
            RET

            ; ERROR EXIT, SET CARRY
            ; HL = ADDRESS OF ERROR
            ; A  = TEST VALUE
RAMTST_CMPER:
            POP     BC          ; BC = SIZE OF AREA 
            POP     DE          ; DE = BASE ADDRESS
            SCF                 ; SET CARRY, INDICATING AN ERROR
            RET

            ; WRITE BANK (UPPER 8 BITS) TO PIO PORT B TIL311
            ; HL = ADDRESS (OF WHICH ONLY H IS WRITTEN)
RAMTST_IO:
            PUSH    BC
            LD      BC,PIOB      ; 82C55 IO PORT B address in BC
            OUT     (C),H        ; output upper adddress byte to PIO Port B
            POP     BC
            RET

            
;==============================================================================
;
; STRINGS
;
SIGNON1:    .BYTE   "YAZ180 - feilipu",CR,LF,0

SIGNON2:    .BYTE   CR,LF
            .BYTE   "Cold or Warm start, "
            .BYTE   "or HexLoadr (C|W|H) ? ",0

initString: .BYTE CR,LF
            .BYTE "HexLoadr: "
            .BYTE CR,LF,0

invalidTypeStr: .BYTE "Inval Type",CR,LF,0
badCheckSumStr: .BYTE "Chksum Error",CR,LF,0
LoadOKStr:      .BYTE "Done",CR,LF,0

;==============================================================================
;
; Z80 INTERRUPT VECTOR DESTINATION ADDRESS ASSIGNMENTS
;

;RST_08      .EQU    TX0             ; TX a byte over ASCI0
;RST_10      .EQU    RX0             ; RX a byte over ASCI0, loop byte available
;RST_18      .EQU    RX0_CHK         ; Check ASCI0 status, return # bytes available

RST_08      .EQU    NULL_RET        ; RET
RST_10      .EQU    NULL_RET        ; RET
RST_18      .EQU    NULL_RET        ; RET
RST_20      .EQU    NULL_RET        ; RET
RST_28      .EQU    NULL_RET        ; RET
RST_30      .EQU    NULL_RET        ; RET
INT_00      .EQU    NULL_INT        ; EI RETI
INT_NMI     .EQU    NULL_NMI        ; RETN

;==============================================================================
;
; Z180 INTERRUPT VECTOR DESTINATION ADDRESS ASSIGNMENTS
;

INT_ASCI0   .EQU    ASCI0_INTERRUPT ; ASCI0 Interrupt

;==============================================================================
;
            .ORG    $1FFF
            HALT
            .END
;
;==============================================================================



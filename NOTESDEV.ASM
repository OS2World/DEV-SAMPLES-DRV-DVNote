	title	SAMPLE CODE CHUNKS, FROM A DEVICE DRIVER
	page	60,120

;************************************************************************
; The following code sections were pruned from a 2 GIGABYTE
;	VIRTUAL RAM DISK driver	developed by Peter Norberg, Consulting
;	(CID 76260,3355).  The driver allows for 3 sets of memory to be
;	managed:
;		(1) a list of physical memory buffers which are not
;			normally accessed by OS/2,
;		(2) non-swappable memory, managed by OS/2
;		(3) swappable memory, managed by OS/2
;
;	They show some techniques for access of FLAT memory under OS/2
;	2.0; at this point, the comments far from complete!  I recommend
;	careful reading to understand the code.
;
;	I hereby release this set of sample code chunks into the public
;	domain, and I expressly deny any liability for it!  Use this at
;	your own risk -- this is intended for educational and training use.
;
; Initial assumptions:
;	During your INIT phase (or delayed, if you are allocating memory
;	beyond the first 16 meg), allocate your FLAT memory pointer
;	using the VMA_ALLOC command.  This memory may be fixed or movable,
;	non-swapping or swappable.  Place the returned flat address
;	into the global plSwapMem pointer, with the clSwapMem counter
;	describing the size of the buffer.  The following code will then
;	demonstrate read/write access to that buffer.  You must also
;	allocate 2 selectors (selGDT and selGDTUser) for use by this code.
;
;	Some simplifications are possible, depending on your application.
;	This code assumes that you have allocated two selectors (selGDT
;	and selGDTUser) for use by the code for data copies.  You may elect
;	to use the calls which generate results in DS and ES as temporary
;	selectors.  I chose the global selectors so that interrupts could be
;	enabled while accessing the data, and to allow me to keep the buffers
;	addressed for as long as I like.  However, since I am using global
;	selectors, I had to protect the code which filled the selectors from
;	reentrancy during the times the selectors are active.  All of this
;	is managed from the SingleThread/UnSingleThread pair and the
;	higher-order DrvAccessNextBuffer and its associated DrvMapUnlock
;	tool.
;
;	See the "Example" code at the end for a complete access/de-select
;	example
;
;************************************************************************
; Define a structure which stays on the stack, as a way of accessing
; flat memory.  This struction contains the lock mechanism for that memory
;************************************************************************

SWAPACCESS STRUCT 2		; swap
	plLockedRegion	dd	0	; if fLocked is non-0, this is the start of the locked region
	ulOffMem	dd	0	; Offset to memory start
	clTotLeft	dd	0	; Total amount of memory left to transfer
	cSingleThreaded	dw	0		; non-0 means we are single threaded
	idPhysMem	dw	0		; If phys mem access, this is non-0
	flocked		db	0,0		; non-0 means memory is locked by this package
	achLock		db	12 dup (0)	; Lock Handle
SWAPACCESS ENDS

;************************************************************************
; DATA block declarations
;************************************************************************
DGROUP  group   _DATA

        _DATA segment dword public use16 'DATA'

 ... Place you device header here
 ...

plSwapMem	dd	0		; Gets LINEAR address in 2.0, of swap space
cbSwapMem	dd	0		; count of memory in the swap region

sem	dd	0		; Semaphore for serializing access to selectors
selGDT	dw	0		; global selector to use for DISK buffer access
selGDTUser dw	0		; global selector to use for USER buffers

_DATA   ends

_TEXT segment dword public use16 'CODE'
        assume  cs:_TEXT, ds:DGROUP, es:NOTHING

;************************************************************************
; SingleThread: Called with SI referencing the STACK BASED SWAPACCESS
;	structure; which has already been cleared by the caller.
;	Returns carry set if we were not allowed to go single threaded
;************************************************************************

SingleThread	proc
	inc	ss:[si.SWAPACCESS.cSingleThreaded] ; Set for recursive call
	cmp	ss:[si.SWAPACCESS.cSingleThreaded],1 ; See if already here
	je	@F			; nope: do the block
	clc				; else called recursively: ignore
	ret				; and leave
@@:
	PUSHAD
  IFDEF NOSEM
@@:	CLI				; No ints for a while
	clc				; Set no error
	test	byte ptr sem,1		; See if blocked already
	jz	@F			; nope: we now own it
	call	FinishBlock		; else block for a while
	jnc	@B			; if no error, retry
	mov	ss:[si.SWAPACCESS.cSingleThreaded],0 ; Set not blocked
	mov	ax,08103h		; set error
	STC				; force error report
	STI				; re-allow interrupts
	POPAD
	ret				; and return: done

@@:	mov	byte ptr sem,1		; take the semaphore over
	STI				; re-allow interrupts
	POPAD
	ret				; and return
  ELSE
	lea	bx,sem			; get the sem address
	mov	ax,ds			; from our dgroup
	mov	cx,-1			; set
	mov	di,cx			; the timeout
	mov	dl,DevHlp_SemRequest	; request the sem
	call	[fpDevHlp]		; and call the processor
	jnc	@F			; Worked OK
	mov	ss:[si.SWAPACCESS.cSingleThreaded],0 ; Set not blocked
	mov	ax,08103h		; set error
@@:
	POPAD
	ret				; and return: done
  ENDIF
SingleThread	endp

;************************************************************************
; UnSingleThread: Called with SI referencing the STACK BASED SWAPACCESS
;	structure; which has been properlay maintained by caller and by
;	SingleThread.  Concept is: any unlock unlocks all!
;************************************************************************
UnSingleThread	proc
	test	ss:[si.SWAPACCESS.cSingleThreaded],-1 ; Set for recursive call
	jnz	@F			; yep: we have been locked
	clc				; else not locked
	ret				; leave now
@@:
	PUSHAD

  IFDEF NOSEM
	mov	byte ptr sem,0		; set sem is cleared
	call	FinishUnBlock		; and unblock our code
	clc				; no errors
  ELSE
	lea	bx,sem			; get the sem address
	mov	ax,ds			; from our dgroup
	mov	dl, DevHlp_SemClear	; clear it
	call	[fpDevHlp]		; and call the processor
  ENDIF
	mov	ss:[si.SWAPACCESS.cSingleThreaded],0 ; Set no longer locked
	POPAD
	ret				; return; all done
UnSingleThread	endp

;************************************************************************
; V20FlatSS: Converts SS:SI into eax FLAT address.
; dl destroyed, returns Carry SET on error, CLEAR on OK.
;************************************************************************

V20FlatSS proc			; Called with SI ref. SS memory to convert to
				; flat, on ret eax = address
	mov	ax,ss			; Set to access
	movzx	esi, si			; the the memory
	mov	dl, DevHlp_VirtToLin	; then set to perform the Lin To Pagelist action
	call	[fpDevHlp]		; and do the action
	ret				; And return as needed
V20FlatSS endp

;************************************************************************
; On entry, si references the SWAPACCESS structure
;************************************************************************
DrvMapUnlock	proc USES eax edx bx

	mov	bx,ss:[si.SWAPACCESS.idPhysMem] ; get the memory access ID
	or	bx,bx		; See if locked
	jz	@F		; nope
	mov	ss:[si.SWAPACCESS.idPhysMem],0 ; else set no longer locked
	push	si		; save SI for a moment
	mov	si,PDNMEM_UNLOCK ; and
	call	CallPdnMem	; call the routine to unlock
	pop	si		; then
@@:
	push	si		; restore SI
	test	ss:[si.SWAPACCESS.fLocked],-1	; See if locked
	jz	@F		; not locked!
	mov	ss:[si.SWAPACCESS.fLocked],0	; set no longer locked
	lea	si,ss:[si.SWAPACCESS.achLock]	; Get the lock handle
	call	V20FlatSS	; the page list flat address
	jc	@F		; if error, ignore
	mov	esi,eax			; else
	mov	dl,DevHlp_VMUnlock	; and set
	call	[fpDevHlp]		; to unlock the memory
@@:
	pop	si			; restore ref to SWAPACCESS

	call	UnSingleThread		; And turn off single thread, if needed
	ret				; Return: done
DrvMapUnlock	ENDP



;************************************************************************
;DrvAccessNextBuffer: Map the sector passed into a temporary physical pointer
;       in es:di or ds:si:
;
; On entry:
;
;       DH is 0 for mapping into ds:si,
;		1 for mapping into es:di, 0 for ds:si
;		2 means do NOT assign ds or es to resulting selector
;		3 means we will write to the selector, but do not set ES or DS
;
;      	SI = reference to the SWAPACCESS array on entry,
;				in the SS group
;
; On exit,
;	DX is unchanged
;	if DH was 0 or 1, the selected register pair (es:di or ds:si) are updated
;		to ref the selGDT selector
;	else ES, DS, SI, DI are unchanged on exit.
;	ECX is the count you can access this time through.
;
;	Side Effects: SWAPACCESS structure updated to reflect current conditions,
;		if access legal, you will be in SINGLE THREADED mode (i.e.,
;		re-entrancy to the subsystem is blocked), and selGDT will ref
;		the selected memory.
;
;
;       WARNING!  Must be called with DS referencing our data segment!
;************************************************************************
DrvAccessNextBuffer proc near
	LOCAL	fbDH:		WORD,
		cbReq:		WORD,
		ulOldDI:	DWORD,
		npSwpa:		WORD

	mov	fbDH,dx			; Save the storage flag
	mov	npSwpa,si		; save low half of SI; access to SWAPACCESS array
	mov	ulOldDI,edi		; save EDI

	call	DrvMapUnlock		; Unlock prior access

	mov	ecx,ss:[si.SWAPACCESS.clTotLeft] ; 0 extend the count
	cmp	ecx,MAX_BLOCK_XFER 	; see
	jbe	@F			; if at end
	mov	ecx,MAX_BLOCK_XFER 	; nope: set upper limit
@@:
	mov	eax, ss:[si.SWAPACCESS.ulOffMem] ; get the memory ref
	add	eax,plSwapMem		; Here on in the SWAP region:
	cmp	ecx,cbSwapMem		; see if legal
	ja	DrvMapBadReq		; OK
	mov	cbReq,cx		; save count really requested
	mov	ebx,eax			; for later use
	mov	ss:[si.SWAPACCESS.plLockedRegion],eax ; Save for later free

	mov	si,npSwpa		; re-get access to swap info
	lea	si,ss:[si.SWAPACCESS.achLock]		; Set for extract of lock handle
	call	V20FlatSS		; lock page list rel to SS
	jc	DrvMapOops		; FAILED: forget it
	mov	esi,eax			; save the lock handle
	sub	eax,eax			; Lock in place, short term
	mov	edi,-1			; set no page list is to be generated
	test	byte ptr fbDH+1,1	; see if write planned
	jz	@F			; nope
	mov	ax,8			; yep: force "WE ARE WRITING" bit
@@:
	mov	dl,DevHlp_VMLock	; and
	call	[fpDevHlp]		; perform the lock
	jc	DrvMapOops		; FAILED: forget it
	mov	si,npSwpa		; restore ref to info
	mov	ss:[si.SWAPACCESS.fLocked],1 ; Else set LOCKED

	call	SingleThread		; force into single threaded mode
	jc	DrvMapOops		; OOPS: No single thread! forget it
	mov	ax,selGDT		; get the selector
	; EBX is still the linear address of the buffer
	; ECX is the length of the buffer
	mov	dl,DevHlp_LinToGDTSelector ; convert to GDT selector
	call	[fpDevHlp]		 ; do the conversion
	jc	DrvMapOops		; FAILED the mapping
	mov	si,npSwpa		; PHYS! restore ref to info
	mov	edi,ulOldDI		; restore EDI
	mov	dx,fbDH			; restore results flag
	movzx	ecx,cbReq		; and correct the count for excess
	add	ss:[si.SWAPACCESS.ulOffMem],ecx ; calculate the next access offset
	sub	ss:[si.SWAPACCESS.clTotLeft],ecx ; and the total left to transfer

	cmp	dh,2			; are we all done?
	jae	DrvMapOkRet		; yep: so exit

	or	dh,dh			; see who gets what
	jz	@F			; if 0, DS:SI
	sub	di,di			; get the SI
	mov	es,selGDT		; so get it
DrvMapOkRet:
	clc				; set good access
	ret				; and return
@@:	; HERE on results in DS:SI
	sub	si,si			; get the SI
	mov	ds,selGDT		; DESTRY DS
	ret				; and return

DrvMapBadReq:
	mov	eax,0AA55h		; set special error code
	mov	si,npSwpa		; get the handle to the lock info
	call	DrvMapUnlock		; go unlock it

	stc				; FAILED ACTION
	ret				; return quickly

DrvAccessNextBuffer endp

;************************************************************************
; Example code section which accesses some of the above
;	Entered with:
;		dx = Read (0) or write (1) flag
;		eax = PHYSICAL address of user buffer
;		ebx = offset from start of our FLAT buffer to access
;		ecx = count of bytes to access
;************************************************************************
Example proc near
        LOCAL   fReadOrWrite:   WORD,
		fpbfr:		DWORD,
        	swpa:		SWAPACCESS

	mov	fReadOrWrite, dx		; ON ENTRY, dx = READ/WRITE flag
						; 0 read, 1 write
	mov	fpbfr,eax			; eax = pointer to buffer to access
	mov	edx,ecx				; save count of bytes
	lea	di,swpa				; set
	mov	cx, sizeof swpa			; to init
	sub	ax,ax				; the
	cld					; swap info structure
	push	ss				; as
	pop	es				; needed
	rep	stosb				; to all 0

... Now have code calculate where in the buffer it needs to access:
... set swpa.ulOffMem to the offset to the start of the portion of the buffer,
... set swpa.clTotLeft to the total count of bytes left to access

	mov	swpa.clTotLeft,edx		; save the count for access
	mov	swpa.ulOffMem,ebx		; save the memory offset from our flat buffer


DrvRdLp:                                        ; PROCESS LOOP: loop here until transfer is done
	cmp	swpa.clTotLeft,0		; see if any left
	je	DrvRWDone			; if not, leave

	mov	dh,2				; Set do NOT change es/ds
	add	dh,byte ptr fReadOrWrite	; convert to 3, for write
	lea	si,swpa				; get the address of the info
	call	DrvAccessNextBuffer		; do the mapping, LOCK THREAD
	jc	DrvRwBadSec			; could not lock/map!
        mov     ax,word ptr fpbfr+2             ; get the user buffer
        mov     bx,word ptr fpbfr               ; physical address
	mov	si,selGDTUser			; set target GDT
	call	PhysToGDTSel			; into our selector
	jc	DrvRwBadSec			; could not generate the mapping!



        push    ds                              ; Save our current segment
        test    byte ptr fReadOrWrite,-1        ; See if READ or WRITE
        jnz     @F                              ; WRITE: Process as needed

	mov	es,selGDTUser			; USER pointer and
	mov	ds,selGDT			; and the memory base
        jmp     DrvRdWrCpy                      ; go do the copy

@@:     ; HERE for WRITE action set-up
	mov	es,selGDT			; and the memory base
	mov	ds,selGDTUser			; get the USER selector


DrvRdWrCpy:
        assume  DS:NOTHING
	mov	bx,cx				; Save the transfer count
	sub	di,di				; set for target offset and
	sub	si,si				; source offsets of 0.
        cld                                     ; Force correct string direction
        rep     movsb                           ; and transfer the buffer

	; OPTIMIZATION NOTE: The above could have a SHR CX,2 \ REP MOVSD
	;	if it is known that the buffer size is DWORD oriented;
	;	or similar in-line code could detect that condition

        pop     ds                              ; Restore DS
        assume  DS:DGROUP                       ; and


; NOTE: THIS IS WHERE TC_YIELD SHOULD BE, IF USED!

	mov	ax,bx				; calculate
	add	word ptr fpBfr,bx		; to form the
        adc     word ptr fpBfr+2,0              ; next user buffer address to access
	jmp	DrvRdLp				; do next

DrvRWDone:                                      ; HERE on all done
	lea	si,swpa				; get the handle to the lock info
	call	DrvMapUnlock			; unlock the memory


        CLC                                     ; Set OK
        ret                                     ; and report as needed

DrvRWFailed:
	pop	ds				; Restore DS
DrvRWBadSec:
	lea	si,swpa				; get the handle to the lock info
	call	DrvMapUnlock			; unlock the memory

        mov     ax,8103h                ; Set DRIVE NOT READY
        stc                             ; Set ERROR

        ret                             ; and report in

Example endp

_TEXT   ends

        end

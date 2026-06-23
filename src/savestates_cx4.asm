cx4_save_regs:
	lda.b #SS_CX4REGS
	sta SSDATA

	ldx #$0000
-
	txa
	sta SSDATA				;// Store register number in save state

	lda.l SS_CX4_BASE,x	;// Load value from shadow window C0:6300,x

	sta SSDATA				;// Store register value in save state

	cpx #$00BB
	beq cx4_save_regs_end
	inx
	bra -
cx4_save_regs_end:
	lda #$FF				;// Store register end marker
	sta SSDATA

cx4_save_ram:
	lda.b #SS_CX4RAM
	sta SSDATA

	sta SS_EXT_ADDR

	SetupDMA((DMA_DIR_BA | DMA_FIXED_A | DMA_MODE_0), SSDATA, SS_CX4_DATA, 4096)

	lda #$01
	sta $420B

cx4_save_cache:
	lda.b #SS_CX4CACHE		;// program cache block marker
	sta SSDATA

	sta SS_EXT_ADDR			;// reset SS external address counter to 0

	SetupDMA((DMA_DIR_BA | DMA_FIXED_A | DMA_MODE_0), SSDATA, SS_CX4_CACHE_DATA, 1024)

	lda #$01
	sta $420B

	jmp Save_mapper_end

cx4_load_regs:
	lda #$00				;// clear B register
	xba

-
	lda SSDATA				;// Load register index
	tax

	cmp #$FF
	beq cx4_load_ram

	lda SSDATA				;// Load register value from save state

	sta.l SS_CX4_BASE,x

	bra -

cx4_load_ram:
	lda SSDATA				;// consume SS_CX4RAM marker

	sta SS_EXT_ADDR

	SetupDMA((DMA_DIR_AB | DMA_FIXED_A | DMA_MODE_0), SSDATA, SS_CX4_DATA, 4096)

	lda #$01
	sta $420B

cx4_load_cache:
	lda SSDATA				;// consume SS_CX4CACHE marker

	sta SS_EXT_ADDR			;// reset SS external address counter to 0

	SetupDMA((DMA_DIR_AB | DMA_FIXED_A | DMA_MODE_0), SSDATA, SS_CX4_CACHE_DATA, 1024)

	lda #$01
	sta $420B

	jmp Load_other

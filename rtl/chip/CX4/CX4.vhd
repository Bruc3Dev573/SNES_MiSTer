library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
library STD;
use IEEE.NUMERIC_STD.ALL;
library work;

entity CX4 is
	port(
		CLK			: in std_logic;
		CE				: in std_logic;
		RST_N			: in std_logic;
		ENABLE		: in std_logic;
		ADDR   		: in std_logic_vector(23 downto 0);
		DI				: in std_logic_vector(7 downto 0);
		DO				: out std_logic_vector(7 downto 0);
		RD_N			: in std_logic;
		WR_N			: in std_logic;
		
		SYSCLKF_CE	: in std_logic;
		SYSCLKR_CE	: in std_logic;
		
		IRQ_N			: out std_logic;
		
		BUS_A   		: out std_logic_vector(23 downto 0);
		BUS_DI		: in std_logic_vector(7 downto 0);
		BUS_DO		: out std_logic_vector(7 downto 0);
		BUS_OE_N		: out std_logic;
		BUS_WE_N		: out std_logic;
		ROM_CE1_N	: out std_logic;
		ROM_CE2_N	: out std_logic;
		SRAM_CE_N	: out std_logic;
		
		BUS_RD_N		: out std_logic;
		
		MAPPER		: in std_logic;

		SS_BUSY    : in  std_logic;
		SS_WR      : in  std_logic;
		SS_DO      : out std_logic_vector(7 downto 0);
		SS_RAM_A   : in  std_logic_vector(11 downto 0);
		SS_RAM_SEL : in  std_logic;
		SS_RAM_WR  : in  std_logic;
		SS_RAM_DI  : in  std_logic_vector(7 downto 0);
		SS_RAM_DO  : out std_logic_vector(7 downto 0);

		-- Program cache (cx4cache) serialization: 1024 bytes = 512 words x {L,H}.
		-- SS_CACHE_A(0) selects L('0')/H('1); SS_CACHE_A(9:1) is the 9-bit index.
		SS_CACHE_A   : in  std_logic_vector(9 downto 0) := (others => '0');
		SS_CACHE_SEL : in  std_logic := '0';
		SS_CACHE_WR  : in  std_logic := '0';
		SS_CACHE_DI  : in  std_logic_vector(7 downto 0) := (others => '0');
		SS_CACHE_DO  : out std_logic_vector(7 downto 0);

		-- '1' when the CX4 is fully idle (BUSY=0), so the savestate controller
		-- can hold off the snapshot until no CPU/cache/DMA operation is in
		-- flight -- guaranteeing only resumable states are saved.
		SS_IDLE      : out std_logic
	);
end CX4;

architecture rtl of CX4 is

	constant FLAG_Z : integer range 0 to 3 := 0;
	constant FLAG_N : integer range 0 to 3 := 1;
	constant FLAG_T : integer range 0 to 3 := 2;
	constant FLAG_V : integer range 0 to 3 := 3;
	
	type Instr_t is (
		I_NOP,
		I_BR,
		I_SKIP,
		I_BSUB,
		I_MOV,
		I_RTS,
		I_INCEXT,
		I_CMP,
		I_EXTS,
		I_RDROM,
		I_RDRAM,
		I_LDP,
		I_ADDSUB,
		I_MUL,
		I_LOG,
		I_SHIFT,
		I_WRRAM,
		I_ST,
		I_SWAP,
		I_CLR,
		I_FINEXT,
		I_HLT
	);

	--CPU registers
	signal A : std_logic_vector(23 downto 0);
	signal FLAGS : std_logic_vector(3 downto 0);
	signal PC : std_logic_vector(7 downto 0);
	signal BANK : std_logic;
	type StackRam_t is array (0 to 7) of std_logic_vector(8 downto 0);
	signal STACK_RAM	: StackRam_t;
	signal SP : unsigned(2 downto 0);
	type GPR_t is array (0 to 15) of std_logic_vector(23 downto 0);
	signal GPR	: GPR_t;
	signal MACL, MACH : std_logic_vector(23 downto 0);
	signal MAR : std_logic_vector(23 downto 0);
	signal MBR : std_logic_vector(7 downto 0);
	signal ROMB, RAMB : std_logic_vector(23 downto 0);
	signal DPR : std_logic_vector(11 downto 0);
	signal P : std_logic_vector(14 downto 0);
	
	--MMIO registers
	signal DMA_SRC : std_logic_vector(23 downto 0);
	signal DMA_DST : std_logic_vector(23 downto 0);
	signal DMA_LEN : std_logic_vector(15 downto 0);
	signal ROM_BASE : std_logic_vector(23 downto 0);
	signal ROM_PAGE : std_logic_vector(14 downto 0);
	type Vectors_t is array (0 to 31) of std_logic_vector(7 downto 0);
	signal VEC_MEM : Vectors_t;
	signal PAGE_SEL : std_logic;
	signal PAGE_LOCK : std_logic_vector(1 downto 0);
	signal WS1, WS2 : std_logic_vector(2 downto 0);
	signal ROM_MODE : std_logic;
	signal SUSPEND : std_logic;
	signal IRQ_EN : std_logic;
	
	signal IR : std_logic_vector(15 downto 0);
	signal INST : Instr_t;
	signal RDB : std_logic_vector(23 downto 0);
	signal ALUR : std_logic_vector(23 downto 0);
	signal ALUC : std_logic;
	signal SH_A : std_logic_vector(23 downto 0);
	signal MULA, MULB : signed(23 downto 0);
	signal COND : std_logic;
	
	signal EN : std_logic;
	signal CLK_CNT : unsigned(1 downto 0);
	signal CPU_RUN, CACHE_RUN, DMA_RUN : std_logic;
	signal CPU_EN : std_logic;
	signal RD_Nr, WR_Nr : std_logic_vector(3 downto 0);
	signal MMIO_WR, RAMIO_WR : std_logic;
	signal MMIO_SEL, RAMIO_SEL : std_logic;
	signal ROM_SEL, SRAM_SEL, RAM_SEL : std_logic;
	signal BUSY : std_logic;
	signal IRQ, IRQ_FLAG : std_logic;
	signal CACHE_WAIT_CNT, DMA_WAIT_CNT : unsigned(2 downto 0);
	signal CACHE_ADDR : std_logic_vector(8 downto 0);
	signal CACHE_BANK : std_logic;
	type CachePage_t is array (0 to 1) of std_logic_vector(15 downto 0);
	signal CACHE_PAGE : CachePage_t;
	signal CACHE_BUS_ADDR : std_logic_vector(23 downto 0);
	signal SNES_ADDR : std_logic_vector(23 downto 0);
	signal DMA_DST_ADDR : std_logic_vector(23 downto 0);
	signal DMA_SRC_ADDR : std_logic_vector(23 downto 0);
	signal DMA_DAT : std_logic_vector(7 downto 0);
	signal DMA_STATE : std_logic;
	signal DMA_CNT : unsigned(15 downto 0);
	signal ROM_ACCESS, SRAM_ACCESS, SRAM_WR : std_logic;
	signal BUS_ACCESS_CNT : unsigned(2 downto 0);
	signal EXT_BUS_ADDR : std_logic_vector(23 downto 0);
	signal INT_ADDR : std_logic_vector(23 downto 0);
	signal EXTRA_CYCLES : integer range 0 to 2;
	
	--Internal RAM/ROM
	signal CACHE_ADDR_WR : std_logic_vector(9 downto 0);
	signal CACHE_ADDR_RD : std_logic_vector(8 downto 0);
	signal CACHE_DI : std_logic_vector(7 downto 0);
	signal CACHE_Q_L, CACHE_Q_H : std_logic_vector(7 downto 0);
	signal CACHE_WE : std_logic;
	-- Muxed cache ports (normal CPU/fill path vs SS save/restore path)
	signal CACHE_RDADDR, CACHE_WRADDR : std_logic_vector(8 downto 0);
	signal CACHE_WDATA : std_logic_vector(7 downto 0);
	signal CACHEL_WE, CACHEH_WE : std_logic;
	signal DATA_RAM_ADDR_A, DATA_RAM_ADDR_B : std_logic_vector(11 downto 0);
	signal DATA_RAM_DI_A, DATA_RAM_DI_B : std_logic_vector(7 downto 0);
	signal DATA_RAM_Q_A, DATA_RAM_Q_B : std_logic_vector(7 downto 0);
	signal DATA_RAM_WE_A, DATA_RAM_WE_B : std_logic;
	signal DATA_ROM_ADDR : std_logic_vector(9 downto 0);
	signal DATA_ROM_Q : std_logic_vector(23 downto 0);
	
	signal BUS_RD_CNT : unsigned(1 downto 0);

	-- =========================================================================
	-- CX4 CA[7:0] savestate byte map (shared between save mux and restore tails)
	-- Total: 0x00..0xBB = 188 bytes. Indices 0xBC..0xFF unused (return 0x00).
	--
	-- PROCESS: A
	-- 0x00  A[7:0]
	-- 0x01  A[15:8]
	-- 0x02  A[23:16]
	--
	-- PROCESS: FLAGS
	-- 0x03  FLAGS[3:0]  (bit0=Z, bit1=N, bit2=T/carry, bit3=V hardwired 0)
	--
	-- PROCESS: PC/BANK/STACK/SP/CPU_RUN/IRQ
	-- 0x04  PC[7:0]
	-- 0x05  BANK (bit0)
	-- 0x06  STACK_RAM(0)[7:0]
	-- 0x07  STACK_RAM(0)[8]   (bit0 only)
	-- 0x08  STACK_RAM(1)[7:0]
	-- 0x09  STACK_RAM(1)[8]
	-- 0x0A  STACK_RAM(2)[7:0]
	-- 0x0B  STACK_RAM(2)[8]
	-- 0x0C  STACK_RAM(3)[7:0]
	-- 0x0D  STACK_RAM(3)[8]
	-- 0x0E  STACK_RAM(4)[7:0]
	-- 0x0F  STACK_RAM(4)[8]
	-- 0x10  STACK_RAM(5)[7:0]
	-- 0x11  STACK_RAM(5)[8]
	-- 0x12  STACK_RAM(6)[7:0]
	-- 0x13  STACK_RAM(6)[8]
	-- 0x14  STACK_RAM(7)[7:0]
	-- 0x15  STACK_RAM(7)[8]
	-- 0x16  SP[2:0]           (bits 2:0)
	-- 0x17  CPU_RUN (bit0)
	-- 0x18  IRQ (bit0)
	-- 0x19  IRQ_FLAG (bit0)
	--
	-- PROCESS: GPR
	-- 0x1A  GPR(0)[7:0]
	-- 0x1B  GPR(0)[15:8]
	-- 0x1C  GPR(0)[23:16]
	-- 0x1D  GPR(1)[7:0]
	-- 0x1E  GPR(1)[15:8]
	-- 0x1F  GPR(1)[23:16]
	-- 0x20  GPR(2)[7:0]
	-- 0x21  GPR(2)[15:8]
	-- 0x22  GPR(2)[23:16]
	-- 0x23  GPR(3)[7:0]
	-- 0x24  GPR(3)[15:8]
	-- 0x25  GPR(3)[23:16]
	-- 0x26  GPR(4)[7:0]
	-- 0x27  GPR(4)[15:8]
	-- 0x28  GPR(4)[23:16]
	-- 0x29  GPR(5)[7:0]
	-- 0x2A  GPR(5)[15:8]
	-- 0x2B  GPR(5)[23:16]
	-- 0x2C  GPR(6)[7:0]
	-- 0x2D  GPR(6)[15:8]
	-- 0x2E  GPR(6)[23:16]
	-- 0x2F  GPR(7)[7:0]
	-- 0x30  GPR(7)[15:8]
	-- 0x31  GPR(7)[23:16]
	-- 0x32  GPR(8)[7:0]
	-- 0x33  GPR(8)[15:8]
	-- 0x34  GPR(8)[23:16]
	-- 0x35  GPR(9)[7:0]
	-- 0x36  GPR(9)[15:8]
	-- 0x37  GPR(9)[23:16]
	-- 0x38  GPR(10)[7:0]
	-- 0x39  GPR(10)[15:8]
	-- 0x3A  GPR(10)[23:16]
	-- 0x3B  GPR(11)[7:0]
	-- 0x3C  GPR(11)[15:8]
	-- 0x3D  GPR(11)[23:16]
	-- 0x3E  GPR(12)[7:0]
	-- 0x3F  GPR(12)[15:8]
	-- 0x40  GPR(12)[23:16]
	-- 0x41  GPR(13)[7:0]
	-- 0x42  GPR(13)[15:8]
	-- 0x43  GPR(13)[23:16]
	-- 0x44  GPR(14)[7:0]
	-- 0x45  GPR(14)[15:8]
	-- 0x46  GPR(14)[23:16]
	-- 0x47  GPR(15)[7:0]
	-- 0x48  GPR(15)[15:8]
	-- 0x49  GPR(15)[23:16]
	--
	-- PROCESS: MUL/MAC
	-- 0x4A  MACL[7:0]
	-- 0x4B  MACL[15:8]
	-- 0x4C  MACL[23:16]
	-- 0x4D  MACH[7:0]
	-- 0x4E  MACH[15:8]
	-- 0x4F  MACH[23:16]
	-- 0x50  MULA[7:0]         (signed(23:0), stored as std_logic_vector)
	-- 0x51  MULA[15:8]
	-- 0x52  MULA[23:16]
	-- 0x53  MULB[7:0]
	-- 0x54  MULB[15:8]
	-- 0x55  MULB[23:16]
	--
	-- PROCESS: MBR/MAR/bus
	-- 0x56  MAR[7:0]
	-- 0x57  MAR[15:8]
	-- 0x58  MAR[23:16]
	-- 0x59  MBR[7:0]
	-- 0x5A  ROM_ACCESS (bit0)
	-- 0x5B  SRAM_ACCESS (bit0)
	-- 0x5C  SRAM_WR (bit0)
	-- 0x5D  BUS_ACCESS_CNT[2:0]
	-- 0x5E  EXT_BUS_ADDR[7:0]
	-- 0x5F  EXT_BUS_ADDR[15:8]
	-- 0x60  EXT_BUS_ADDR[23:16]
	--
	-- PROCESS: ROMB
	-- 0x61  ROMB[7:0]
	-- 0x62  ROMB[15:8]
	-- 0x63  ROMB[23:16]
	--
	-- PROCESS: RAMB
	-- 0x64  RAMB[7:0]
	-- 0x65  RAMB[15:8]
	-- 0x66  RAMB[23:16]
	--
	-- PROCESS: DPR
	-- 0x67  DPR[7:0]
	-- 0x68  DPR[11:8]         (bits 3:0 of DI)
	--
	-- PROCESS: P
	-- 0x69  P[7:0]
	-- 0x6A  P[14:8]           (bits 6:0 of DI)
	--
	-- PROCESS: MMIO regs
	-- 0x6B  DMA_SRC[7:0]
	-- 0x6C  DMA_SRC[15:8]
	-- 0x6D  DMA_SRC[23:16]
	-- 0x6E  DMA_DST[7:0]
	-- 0x6F  DMA_DST[15:8]
	-- 0x70  DMA_DST[23:16]
	-- 0x71  DMA_LEN[7:0]
	-- 0x72  DMA_LEN[15:8]
	-- 0x73  ROM_BASE[7:0]
	-- 0x74  ROM_BASE[15:8]
	-- 0x75  ROM_BASE[23:16]
	-- 0x76  ROM_PAGE[7:0]
	-- 0x77  ROM_PAGE[14:8]    (bits 6:0 of DI)
	-- 0x78  PAGE_SEL (bit0)
	-- 0x79  PAGE_LOCK[1:0]
	-- 0x7A  WS1[2:0]
	-- 0x7B  WS2[2:0]
	-- 0x7C  ROM_MODE (bit0)
	-- 0x7D  SUSPEND (bit0)
	-- 0x7E  IRQ_EN (bit0)
	-- 0x7F..0x9E  VEC_MEM(0..31)  [32 bytes, indices 0x7F..0x9E]
	--
	-- PROCESS: DMA FSM
	-- 0x9F  DMA_RUN (bit0)
	-- 0xA0  DMA_SRC_ADDR[7:0]
	-- 0xA1  DMA_SRC_ADDR[15:8]
	-- 0xA2  DMA_SRC_ADDR[23:16]
	-- 0xA3  DMA_DST_ADDR[7:0]
	-- 0xA4  DMA_DST_ADDR[15:8]
	-- 0xA5  DMA_DST_ADDR[23:16]
	-- 0xA6  DMA_CNT[7:0]          (unsigned(15:0))
	-- 0xA7  DMA_CNT[15:8]
	-- 0xA8  DMA_WAIT_CNT[2:0]
	-- 0xA9  DMA_DAT[7:0]
	-- 0xAA  DMA_STATE (bit0)
	--
	-- PROCESS: Cache FSM
	-- 0xAB  CACHE_RUN (bit0)
	-- 0xAC  CACHE_BANK (bit0)
	-- 0xAD  CACHE_PAGE(0)[7:0]
	-- 0xAE  CACHE_PAGE(0)[15:8]    (bit7 = valid bit)
	-- 0xAF  CACHE_PAGE(1)[7:0]
	-- 0xB0  CACHE_PAGE(1)[15:8]    (bit7 = valid bit)
	-- 0xB1  CACHE_ADDR[7:0]
	-- 0xB2  CACHE_ADDR[8]          (bit0 only)
	-- 0xB3  CACHE_WAIT_CNT[2:0]
	-- 0xB4  CACHE_BUS_ADDR[7:0]
	-- 0xB5  CACHE_BUS_ADDR[15:8]
	-- 0xB6  CACHE_BUS_ADDR[23:16]
	--
	-- PROCESS: BUS_RD_CNT
	-- 0xB7  BUS_RD_CNT[1:0]
	--
	-- PROCESS: PC FSM -- EXTRA_CYCLES
	-- 0xB8  EXTRA_CYCLES[1:0]  (integer 0..2, serialized as unsigned 2-bit)
	--
	-- PROCESS: SNES_ADDR
	-- 0xB9  SNES_ADDR[7:0]
	-- 0xBA  SNES_ADDR[15:8]
	-- 0xBB  SNES_ADDR[23:16]
	--
	-- 0xBC..0xFF  unused -- save mux returns 0x00
	-- =========================================================================

	impure function BitToInt (v : in std_logic) return integer is
        variable ret : integer range 0 to 1;
    begin   
        if v = '0' then 
				ret := 0;
			else
				ret := 1;
			end if;
        return ret;
    end function; 
	
begin

	EN <= ENABLE and CE and not SS_BUSY;
	CPU_EN <= EN and CPU_RUN and (not CACHE_RUN) and (not DMA_RUN) and (not SUSPEND);
	
	--I/O Ports
	process(ADDR, MAPPER)
	begin
		RAMIO_SEL <= '0';
		MMIO_SEL <= '0';
		if (MAPPER = '0' and ADDR(22) = '0' and ADDR(15 downto 13) = "011") or												--LoROM: 00-3F:6000-7FFF, 80-BF:6000-7FFF 
			(MAPPER = '1' and ADDR(22) = '0' and ADDR(21 downto 20) <= "10" and ADDR(15 downto 13) = "011") then	--HiROM: 00-2F:6000-7FFF, 80-AF:6000-7FFF
			if ADDR(12) = '0' then
				RAMIO_SEL <= '1';
			else
				MMIO_SEL <= '1';
			end if;
		end if;
	end process; 
	
	MMIO_WR  <= not WR_N and MMIO_SEL  and SYSCLKF_CE and not SS_BUSY;
	RAMIO_WR <= not WR_N and RAMIO_SEL and SYSCLKF_CE and not SS_BUSY;
	
	process(CLK, RST_N, WR_Nr, RAMIO_SEL, MMIO_SEL, SYSCLKF_CE)
	begin
		if RST_N = '0' then
			DMA_SRC <= (others => '0');
			DMA_LEN <= (others => '0');
			DMA_DST <= (others => '0');
			PAGE_SEL <= '0';
			ROM_BASE <= (others => '0');
			ROM_PAGE <= (others => '0');
			PAGE_LOCK <= (others => '0');
			VEC_MEM <= (others => (others => '0'));
			WS1 <= "011";
			WS2 <= "011";
			IRQ_EN <= '0';
			ROM_MODE <= '0';
			SUSPEND <= '0';
		elsif rising_edge(CLK) then
			if ENABLE = '1' then
				if MMIO_WR = '1' and ADDR(11 downto 8) = x"F" then
					if ADDR(7 downto 4) = x"4" then
						case ADDR(3 downto 0) is
							when x"0" =>						-- 7F40
								DMA_SRC(7 downto 0) <= DI;
							when x"1" =>						-- 7F41
								DMA_SRC(15 downto 8) <= DI;
							when x"2" =>						-- 7F42
								DMA_SRC(23 downto 16) <= DI;
							when x"3" =>						-- 7F43
								DMA_LEN(7 downto 0) <= DI;
							when x"4" =>						-- 7F44
								DMA_LEN(15 downto 8) <= DI;
							when x"5" =>						-- 7F45
								DMA_DST(7 downto 0) <= DI;
							when x"6" =>						-- 7F46
								DMA_DST(15 downto 8) <= DI;
							when x"7" =>						-- 7F47
								DMA_DST(23 downto 16) <= DI;
							when x"8" =>						-- 7F48
								PAGE_SEL <= DI(0);
							when x"9" =>						-- 7F49
								ROM_BASE(7 downto 0) <= DI;
							when x"A" =>						-- 7F4A
								ROM_BASE(15 downto 8) <= DI;
							when x"B" =>						-- 7F4B
								ROM_BASE(23 downto 16) <= DI;
							when x"C" =>						-- 7F4C
								PAGE_LOCK <= DI(1 downto 0);
							when x"D" =>						-- 7F4D
								ROM_PAGE(7 downto 0) <= DI;
							when x"E" =>						-- 7F4E
								ROM_PAGE(14 downto 8) <= DI(6 downto 0);
							when x"F" =>						-- 7F4F
							
							when others => null;
						end case;
					elsif ADDR(7 downto 4) = x"5" then
						case ADDR(3 downto 0) is
							when x"0" =>						-- 7F50
								WS1 <= DI(6 downto 4);
								WS2 <= DI(2 downto 0);
							when x"1" =>						-- 7F51
								IRQ_EN <= not DI(0);
							when x"2" =>						-- 7F52
								ROM_MODE <= DI(0);
							when x"5" =>						-- 7F55
								SUSPEND <= '1';
							when x"D" =>						-- 7F5D
								SUSPEND <= '0';
							when others => null;
						end case;
					elsif ADDR(7 downto 5) = "011" then	-- 7F60-7F7F
						VEC_MEM(to_integer(unsigned(ADDR(4 downto 0)))) <= DI;
					end if;
				end if;
			end if;
			-- SS restore tail: MMIO regs (0x6B..0x9E)
			if SS_BUSY = '1' and SS_WR = '1' then
				case ADDR(7 downto 0) is
					when x"6B" => DMA_SRC(7 downto 0)   <= DI;
					when x"6C" => DMA_SRC(15 downto 8)  <= DI;
					when x"6D" => DMA_SRC(23 downto 16) <= DI;
					when x"6E" => DMA_DST(7 downto 0)   <= DI;
					when x"6F" => DMA_DST(15 downto 8)  <= DI;
					when x"70" => DMA_DST(23 downto 16) <= DI;
					when x"71" => DMA_LEN(7 downto 0)   <= DI;
					when x"72" => DMA_LEN(15 downto 8)  <= DI;
					when x"73" => ROM_BASE(7 downto 0)  <= DI;
					when x"74" => ROM_BASE(15 downto 8) <= DI;
					when x"75" => ROM_BASE(23 downto 16)<= DI;
					when x"76" => ROM_PAGE(7 downto 0)  <= DI;
					when x"77" => ROM_PAGE(14 downto 8) <= DI(6 downto 0);
					when x"78" => PAGE_SEL              <= DI(0);
					when x"79" => PAGE_LOCK             <= DI(1 downto 0);
					when x"7A" => WS1                   <= DI(2 downto 0);
					when x"7B" => WS2                   <= DI(2 downto 0);
					when x"7C" => ROM_MODE              <= DI(0);
					when x"7D" => SUSPEND               <= DI(0);
					when x"7E" => IRQ_EN                <= DI(0);
					when x"7F" => VEC_MEM(0)  <= DI;
					when x"80" => VEC_MEM(1)  <= DI;
					when x"81" => VEC_MEM(2)  <= DI;
					when x"82" => VEC_MEM(3)  <= DI;
					when x"83" => VEC_MEM(4)  <= DI;
					when x"84" => VEC_MEM(5)  <= DI;
					when x"85" => VEC_MEM(6)  <= DI;
					when x"86" => VEC_MEM(7)  <= DI;
					when x"87" => VEC_MEM(8)  <= DI;
					when x"88" => VEC_MEM(9)  <= DI;
					when x"89" => VEC_MEM(10) <= DI;
					when x"8A" => VEC_MEM(11) <= DI;
					when x"8B" => VEC_MEM(12) <= DI;
					when x"8C" => VEC_MEM(13) <= DI;
					when x"8D" => VEC_MEM(14) <= DI;
					when x"8E" => VEC_MEM(15) <= DI;
					when x"8F" => VEC_MEM(16) <= DI;
					when x"90" => VEC_MEM(17) <= DI;
					when x"91" => VEC_MEM(18) <= DI;
					when x"92" => VEC_MEM(19) <= DI;
					when x"93" => VEC_MEM(20) <= DI;
					when x"94" => VEC_MEM(21) <= DI;
					when x"95" => VEC_MEM(22) <= DI;
					when x"96" => VEC_MEM(23) <= DI;
					when x"97" => VEC_MEM(24) <= DI;
					when x"98" => VEC_MEM(25) <= DI;
					when x"99" => VEC_MEM(26) <= DI;
					when x"9A" => VEC_MEM(27) <= DI;
					when x"9B" => VEC_MEM(28) <= DI;
					when x"9C" => VEC_MEM(29) <= DI;
					when x"9D" => VEC_MEM(30) <= DI;
					when x"9E" => VEC_MEM(31) <= DI;
					when others => null;
				end case;
			end if;
		end if;
	end process;

	BUSY <= CPU_RUN or CACHE_RUN or DMA_RUN;
	SS_IDLE <= not BUSY;

	process( MMIO_SEL, RAMIO_SEL, ADDR, DMA_SRC, DMA_LEN, DMA_DST, PAGE_SEL, PAGE_LOCK, ROM_BASE, ROM_PAGE, WS1, WS2, IRQ_EN, ROM_MODE, 
			   ROM_ACCESS, SRAM_ACCESS, VEC_MEM, GPR, CPU_RUN, DATA_RAM_Q_B, BUS_DI, IRQ_FLAG, SUSPEND, BUSY )
	begin
		DO <= x"00";
		if MMIO_SEL = '1' then
			if ADDR(11 downto 8) = x"F" then
				if ADDR(7 downto 4) = x"4" then
					case ADDR(3 downto 0) is
						when x"0" =>
							DO <= DMA_SRC(7 downto 0);
						when x"1" =>
							DO <= DMA_SRC(15 downto 8);
						when x"2" =>
							DO <= DMA_SRC(23 downto 16);
						when x"3" =>
							DO <= DMA_LEN(7 downto 0);
						when x"4" =>
							DO <= DMA_LEN(15 downto 8);
						when x"5" =>
							DO <= DMA_DST(7 downto 0);
						when x"6" =>
							DO <= DMA_DST(15 downto 8);
						when x"7" =>
							DO <= DMA_DST(23 downto 16);
						when x"8" =>
							DO <= "0000000" & PAGE_SEL;
						when x"9" =>
							DO <= ROM_BASE(7 downto 0);
						when x"A" =>
							DO <= ROM_BASE(15 downto 8);
						when x"B" =>
							DO <= ROM_BASE(23 downto 16);
						when x"C" =>
							DO <= "000000" & PAGE_LOCK;
						when x"D" =>
							DO <= ROM_PAGE(7 downto 0);
						when x"E" =>
							DO <= "0" & ROM_PAGE(14 downto 8);
						when x"F" =>
						
						when others => null;
					end case;
				elsif ADDR(7 downto 4) = x"5" then
					case ADDR(3 downto 0) is
						when x"0" =>																-- 7F50
							DO <= "0" & WS1 & "0" & WS2;
						when x"1" =>																-- 7F51
							DO <= "0000000" & not IRQ_EN;
						when x"2" =>																-- 7F52
							DO <= "0000000" & ROM_MODE;
						when x"E" =>																-- 7F5E
							DO <= (ROM_ACCESS or SRAM_ACCESS) & BUSY & "0000" & IRQ_FLAG & SUSPEND;
						when others => null;
					end case;
				elsif ADDR(7 downto 5) = "011" then											-- 7F60-7F7F
					DO <= VEC_MEM(to_integer(unsigned(ADDR(4 downto 0))));
				elsif ADDR(7 downto 4) >= x"8" and ADDR(7 downto 4) <= x"A" then	-- 7F80-7FAF
					case ADDR(7 downto 0) is
						when x"80" => DO <= GPR(0)(7 downto 0);
						when x"81" => DO <= GPR(0)(15 downto 8);
						when x"82" => DO <= GPR(0)(23 downto 16);
						when x"83" => DO <= GPR(1)(7 downto 0);
						when x"84" => DO <= GPR(1)(15 downto 8);
						when x"85" => DO <= GPR(1)(23 downto 16);
						when x"86" => DO <= GPR(2)(7 downto 0);
						when x"87" => DO <= GPR(2)(15 downto 8);
						when x"88" => DO <= GPR(2)(23 downto 16);
						when x"89" => DO <= GPR(3)(7 downto 0);
						when x"8A" => DO <= GPR(3)(15 downto 8);
						when x"8B" => DO <= GPR(3)(23 downto 16);
						when x"8C" => DO <= GPR(4)(7 downto 0);
						when x"8D" => DO <= GPR(4)(15 downto 8);
						when x"8E" => DO <= GPR(4)(23 downto 16);
						when x"8F" => DO <= GPR(5)(7 downto 0);
						when x"90" => DO <= GPR(5)(15 downto 8);
						when x"91" => DO <= GPR(5)(23 downto 16);
						when x"92" => DO <= GPR(6)(7 downto 0);
						when x"93" => DO <= GPR(6)(15 downto 8);
						when x"94" => DO <= GPR(6)(23 downto 16);
						when x"95" => DO <= GPR(7)(7 downto 0);
						when x"96" => DO <= GPR(7)(15 downto 8);
						when x"97" => DO <= GPR(7)(23 downto 16);
						when x"98" => DO <= GPR(8)(7 downto 0);
						when x"99" => DO <= GPR(8)(15 downto 8);
						when x"9A" => DO <= GPR(8)(23 downto 16);
						when x"9B" => DO <= GPR(9)(7 downto 0);
						when x"9C" => DO <= GPR(9)(15 downto 8);
						when x"9D" => DO <= GPR(9)(23 downto 16);
						when x"9E" => DO <= GPR(10)(7 downto 0);
						when x"9F" => DO <= GPR(10)(15 downto 8);
						when x"A0" => DO <= GPR(10)(23 downto 16);
						when x"A1" => DO <= GPR(11)(7 downto 0);
						when x"A2" => DO <= GPR(11)(15 downto 8);
						when x"A3" => DO <= GPR(11)(23 downto 16);
						when x"A4" => DO <= GPR(12)(7 downto 0);
						when x"A5" => DO <= GPR(12)(15 downto 8);
						when x"A6" => DO <= GPR(12)(23 downto 16);
						when x"A7" => DO <= GPR(13)(7 downto 0);
						when x"A8" => DO <= GPR(13)(15 downto 8);
						when x"A9" => DO <= GPR(13)(23 downto 16);
						when x"AA" => DO <= GPR(14)(7 downto 0);
						when x"AB" => DO <= GPR(14)(15 downto 8);
						when x"AC" => DO <= GPR(14)(23 downto 16);
						when x"AD" => DO <= GPR(15)(7 downto 0);
						when x"AE" => DO <= GPR(15)(15 downto 8);
						when x"AF" => DO <= GPR(15)(23 downto 16);
						when others => null;
					end case;
				end if;
			end if;
		elsif RAMIO_SEL = '1' then											--6000-6FFF
			DO <= DATA_RAM_Q_B;
		elsif ADDR(23 downto 16) = x"00" and ADDR(15 downto 5) = "11111111111" and BUSY = '1' then	--00:FFE0-FFFF
			DO <= VEC_MEM(to_integer(unsigned(ADDR(4 downto 0))));
		else
			DO <= BUS_DI;
		end if;
	end process;
	
	process(CLK)
	begin
		if rising_edge(CLK) then
			if SYSCLKR_CE = '1' then
				SNES_ADDR <= ADDR;
			end if;
			-- SS restore tail: SNES_ADDR (0xB9..0xBB)
			if SS_BUSY = '1' and SS_WR = '1' then
				case ADDR(7 downto 0) is
					when x"B9" => SNES_ADDR(7 downto 0)   <= DI;
					when x"BA" => SNES_ADDR(15 downto 8)  <= DI;
					when x"BB" => SNES_ADDR(23 downto 16) <= DI;
					when others => null;
				end case;
			end if;
		end if;
	end process;
	
	process( SNES_ADDR, CACHE_RUN, CACHE_BUS_ADDR, DMA_RUN, DMA_STATE, DMA_SRC_ADDR, DMA_DST_ADDR, ROM_ACCESS, SRAM_ACCESS, EXT_BUS_ADDR )--ROM_BASE, CACHE_PAGE, CACHE_ADDR, CACHE_BANK
	begin
		if CACHE_RUN = '1' then
			INT_ADDR <= CACHE_BUS_ADDR;--std_logic_vector(unsigned(ROM_BASE) + (unsigned(CACHE_PAGE(BitToInt(CACHE_BANK))(14 downto 0)) & unsigned(CACHE_ADDR)));
		elsif DMA_RUN = '1' then
			if DMA_STATE = '0' then
				INT_ADDR <= DMA_SRC_ADDR;
			else
				INT_ADDR <= DMA_DST_ADDR;
			end if;
		elsif ROM_ACCESS = '1' or SRAM_ACCESS = '1' then
			INT_ADDR <= EXT_BUS_ADDR;
		else
			INT_ADDR <= SNES_ADDR;
		end if;
	end process;

	
	process(INT_ADDR, MAPPER)
	begin
		ROM_SEL <= '0';
		SRAM_SEL <= '0';
		RAM_SEL <= '0';
		if MAPPER = '0' then																										--LoROM
			if INT_ADDR(15) = '1' then																							--00-3F:8000-FFFF, 80-BF:8000-FFFF 
				ROM_SEL <= '1';
			elsif INT_ADDR(23 downto 19) = "01110" and INT_ADDR(15) = '0'	then									--70-77:0000-7FFF 
				SRAM_SEL <= '1';
			elsif INT_ADDR(22) = '0' and INT_ADDR(15 downto 12) = "0110" then										--00-3F:6000-6FFF, 80-BF:6000-6FFF 
				RAM_SEL <= '1';
			end if;
		else																															--HiROM
			if INT_ADDR(23 downto 22) = "11" then																			--C0-FF:0000-FFFF
				ROM_SEL <= '1';
			elsif INT_ADDR(23 downto 20) = "0011" and INT_ADDR(15 downto 13) = "011" then						--30-3F:6000-7FFF, B0-BF:6000-7FFF 
				SRAM_SEL <= '1';
			elsif INT_ADDR(22 downto 20) <= "010" and INT_ADDR(15 downto 12) = "0110" then					--00-2F:6000-6FFF, 80-AF:6000-6FFF 
				RAM_SEL <= '1';
			end if;
		end if;
	end process; 
		
	BUS_A <= INT_ADDR;

	process(SUSPEND, SRAM_SEL, DMA_RUN, DMA_STATE, SRAM_ACCESS, SRAM_WR, ROM_SEL, INT_ADDR, MAPPER, ROM_MODE, WR_N, RD_N)
	begin
		if SUSPEND = '1' then
			ROM_CE1_N <= '1';
			ROM_CE2_N <= '1';
			SRAM_CE_N <= '1';
			BUS_OE_N <= '1';
			BUS_WE_N <= '1';
		elsif SRAM_SEL = '1' and DMA_RUN = '1' then
			ROM_CE1_N <= '1';
			ROM_CE2_N <= '1';
			SRAM_CE_N <= '0';
			BUS_OE_N <= DMA_STATE;
			BUS_WE_N <= not DMA_STATE;
		elsif SRAM_SEL = '1' then
			ROM_CE1_N <= '1';
			ROM_CE2_N <= '1';
			SRAM_CE_N <= '0';
			if SRAM_ACCESS = '1' then
				BUS_OE_N <= SRAM_WR;
				BUS_WE_N <= not SRAM_WR;
			else
				BUS_OE_N <= RD_N;
				BUS_WE_N <= WR_N;
			end if;
		elsif ROM_SEL = '1' then
			if (MAPPER = '0' and ROM_MODE = '0') or (MAPPER = '1' and ROM_MODE = '1') then
				ROM_CE1_N <= INT_ADDR(21);
				ROM_CE2_N <= not INT_ADDR(21);
			elsif MAPPER = '0' and ROM_MODE = '1' then
				ROM_CE1_N <= '0';
				ROM_CE2_N <= '1';
			else
				ROM_CE1_N <= INT_ADDR(20);
				ROM_CE2_N <= not INT_ADDR(20);
			end if;
			SRAM_CE_N <= '1';
			BUS_OE_N <= '1';
			BUS_WE_N <= '1';
		else
			ROM_CE1_N <= '1';
			ROM_CE2_N <= '1';
			SRAM_CE_N <= '1';
			BUS_OE_N <= '1';
			BUS_WE_N <= '1';
		end if;
	end process; 
	
	--for MISTer
	process(CLK, RST_N)
	begin
		if RST_N = '0' then
			BUS_RD_N <= '1';
			BUS_RD_CNT <= (others => '0');
		elsif rising_edge(CLK) then
			BUS_RD_N <= '1';
			if BUSY = '1' then
				BUS_RD_CNT <= BUS_RD_CNT + 1;
				if BUS_RD_CNT = 1 then
					BUS_RD_CNT <= (others => '0');
					BUS_RD_N <= '0';
				end if;
			else
				if SYSCLKR_CE = '1' or SYSCLKF_CE = '1' then
					BUS_RD_N <= '0';
					BUS_RD_CNT <= (others => '0');
				end if;
			end if;
			-- SS restore tail: BUS_RD_CNT only (0xB7); BUS_RD_N excluded (self-rederives)
			if SS_BUSY = '1' and SS_WR = '1' then
				case ADDR(7 downto 0) is
					when x"B7" => BUS_RD_CNT <= unsigned(DI(1 downto 0));
					when others => null;
				end case;
			end if;
		end if;
	end process;

	--CACHE
	process(CLK, RST_N)
	begin
		if RST_N = '0' then
			CACHE_RUN <= '0';
			CACHE_BANK <= '0';
			CACHE_PAGE <= (others => (others => '1'));
			CACHE_ADDR <= (others => '0');
			CACHE_WAIT_CNT <= (others => '0');
		elsif rising_edge(CLK) then
			if ENABLE = '1' then
				if CACHE_RUN = '0' then
					if CPU_RUN = '0' then
						if MMIO_WR = '1' and ADDR(11 downto 0) = x"F48" then	--7F48
							CACHE_RUN <= '1';
							CACHE_BANK <= DI(0);
							CACHE_PAGE(BitToInt(DI(0)))(14 downto 0) <= ROM_PAGE;
							CACHE_ADDR <= (others => '0');

							CACHE_BUS_ADDR <= std_logic_vector(unsigned(ROM_BASE) + (unsigned(ROM_PAGE) & "000000000"));
						elsif MMIO_WR = '1' and ADDR(11 downto 0) = x"F4C" then	--7F4C
							CACHE_PAGE(0)(15) <= DI(0);
							if DI(0) = '1' then
								CACHE_PAGE(0)(14 downto 0) <= ROM_PAGE;
							end if;
							CACHE_PAGE(1)(15) <= DI(1);
							if DI(1) = '1' then
								CACHE_PAGE(1)(14 downto 0) <= ROM_PAGE;
							end if;
						elsif MMIO_WR = '1' and ADDR(11 downto 0) = x"F4F" then	--7F4F
							if CACHE_PAGE(0)(15) = '1' and CACHE_PAGE(0)(14 downto 0) = ROM_PAGE then
								CACHE_BANK <= '0';
							elsif CACHE_PAGE(1)(15) = '1' and CACHE_PAGE(1)(14 downto 0) = ROM_PAGE then
								CACHE_BANK <= '1';
							end if;
						end if;
					elsif CPU_EN = '1' then
						if (INST = I_BR or INST = I_BSUB) and IR(9) = '1' and COND = '1' then
							if CACHE_PAGE(BitToInt(not BANK))(14 downto 0) /= P then
								CACHE_RUN <= '1';
								CACHE_BANK <= not BANK;
								CACHE_PAGE(BitToInt(not BANK))(14 downto 0) <= P;
								CACHE_ADDR <= (others => '0');
								
								CACHE_BUS_ADDR <= std_logic_vector(unsigned(ROM_BASE) + (unsigned(P) & "000000000"));
							end if;
						end if;
					end if;
				elsif SUSPEND = '0' and EN = '1' then
					CACHE_WAIT_CNT <= CACHE_WAIT_CNT + 1;
					if (CACHE_WAIT_CNT = unsigned(WS1) and ROM_SEL = '1') or (CACHE_WAIT_CNT = unsigned(WS2) and SRAM_SEL = '1') then
						CACHE_ADDR <= std_logic_vector(unsigned(CACHE_ADDR) + 1);
						if CACHE_ADDR = "111111111" then
							CACHE_RUN <= '0';
						end if;
						CACHE_WAIT_CNT <= (others => '0');

						CACHE_BUS_ADDR <= std_logic_vector(unsigned(CACHE_BUS_ADDR) + 1);
					end if;
				end if;
			end if;
			-- SS restore tail: Cache FSM state (0xAB..0xB6)
			if SS_BUSY = '1' and SS_WR = '1' then
				case ADDR(7 downto 0) is
					when x"AB" => CACHE_RUN                  <= DI(0);
					when x"AC" => CACHE_BANK                 <= DI(0);
					when x"AD" => CACHE_PAGE(0)(7 downto 0)  <= DI;
					when x"AE" => CACHE_PAGE(0)(15 downto 8) <= DI;
					when x"AF" => CACHE_PAGE(1)(7 downto 0)  <= DI;
					when x"B0" => CACHE_PAGE(1)(15 downto 8) <= DI;
					when x"B1" => CACHE_ADDR(7 downto 0)    <= DI;
					when x"B2" => CACHE_ADDR(8)              <= DI(0);
					when x"B3" => CACHE_WAIT_CNT             <= unsigned(DI(2 downto 0));
					when x"B4" => CACHE_BUS_ADDR(7 downto 0)  <= DI;
					when x"B5" => CACHE_BUS_ADDR(15 downto 8) <= DI;
					when x"B6" => CACHE_BUS_ADDR(23 downto 16)<= DI;
					when others => null;
				end case;
			end if;
		end if;
	end process;

	--DMA
	process(CLK, RST_N)
	begin
		if RST_N = '0' then
			DMA_RUN <= '0';
			DMA_SRC_ADDR <= (others => '0');
			DMA_DST_ADDR <= (others => '0');
			DMA_CNT <= (others => '0');
			DMA_WAIT_CNT <= (others => '0');
			DMA_DAT <= (others => '0');
			DMA_STATE <= '0';
		elsif rising_edge(CLK) then
			if ENABLE = '1' then
				if DMA_RUN = '0' then
					if MMIO_WR = '1' and ADDR(11 downto 0) = x"F47" then	--7F47
						DMA_RUN <= '1';
						DMA_SRC_ADDR <= DMA_SRC;
						DMA_DST_ADDR <= DMA_DST;
						DMA_CNT <= unsigned(DMA_LEN) - 1;
						DMA_STATE <= '0';
					end if;
				elsif SUSPEND = '0' and EN = '1' then
					if DMA_STATE = '0' then
						if DMA_WAIT_CNT = unsigned(WS1) then
							DMA_WAIT_CNT <= (others => '0');
							DMA_SRC_ADDR <= std_logic_vector(unsigned(DMA_SRC_ADDR) + 1);
							DMA_DAT <= BUS_DI;
							DMA_STATE <= not DMA_STATE;
						else
							DMA_WAIT_CNT <= DMA_WAIT_CNT + 1;
						end if;
					else
						if (DMA_WAIT_CNT = unsigned(WS2) and SRAM_SEL = '1') or
							(DMA_WAIT_CNT = 0 and RAM_SEL = '1') then
							DMA_WAIT_CNT <= (others => '0');
							DMA_DST_ADDR <= std_logic_vector(unsigned(DMA_DST_ADDR) + 1);
							DMA_CNT <= DMA_CNT - 1;
							if DMA_CNT = 0 then
								DMA_RUN <= '0';
							end if;
							DMA_STATE <= not DMA_STATE;
						else
							DMA_WAIT_CNT <= DMA_WAIT_CNT + 1;
						end if;
					end if;
				end if;
			end if;
			-- SS restore tail: DMA FSM (0x9F..0xAA)
			if SS_BUSY = '1' and SS_WR = '1' then
				case ADDR(7 downto 0) is
					when x"9F" => DMA_RUN                   <= DI(0);
					when x"A0" => DMA_SRC_ADDR(7 downto 0)  <= DI;
					when x"A1" => DMA_SRC_ADDR(15 downto 8) <= DI;
					when x"A2" => DMA_SRC_ADDR(23 downto 16)<= DI;
					when x"A3" => DMA_DST_ADDR(7 downto 0)  <= DI;
					when x"A4" => DMA_DST_ADDR(15 downto 8) <= DI;
					when x"A5" => DMA_DST_ADDR(23 downto 16)<= DI;
					when x"A6" => DMA_CNT(7 downto 0)       <= unsigned(DI);
					when x"A7" => DMA_CNT(15 downto 8)      <= unsigned(DI);
					when x"A8" => DMA_WAIT_CNT              <= unsigned(DI(2 downto 0));
					when x"A9" => DMA_DAT                   <= DI;
					when x"AA" => DMA_STATE                 <= DI(0);
					when others => null;
				end case;
			end if;
		end if;
	end process;

	BUS_DO <= DMA_DAT when DMA_RUN = '1' else
		  DI when (SRAM_SEL = '1' and SRAM_ACCESS = '0' and WR_n = '0') else
		  MBR;

	IR <= CACHE_Q_H & CACHE_Q_L;
	
	process(IR)
	begin
		INST <= I_NOP;
		if IR(15 downto 10) = "000000" then
			INST <= I_NOP;
		elsif IR(15 downto 14) = "00" and IR(12 downto 10) >= "010" and IR(12 downto 10) <= "110" then
			if IR(13) = '0' then
				INST <= I_BR;
			else
				INST <= I_BSUB;
			end if;
		elsif IR(15 downto 10) = "000111" then
			INST <= I_FINEXT;
		elsif IR(15 downto 10) = "001001" then
			INST <= I_SKIP;
		elsif IR(15 downto 10) = "001111" then
			INST <= I_RTS;
		elsif IR(15 downto 10) = "010000" then
			INST <= I_INCEXT;
		elsif IR(15 downto 11) = "01001" or IR(15 downto 11) = "01010" then
			INST <= I_CMP;
		elsif IR(15 downto 11) = "01011" then
			INST <= I_EXTS;
		elsif IR(15 downto 11) = "01100" then
			INST <= I_MOV;
		elsif IR(15 downto 9) = "0111110" then
			INST <= I_LDP;
		elsif IR(15 downto 11) = "01101" then
			INST <= I_RDRAM;
		elsif IR(15 downto 10) = "011100" then
			INST <= I_RDROM;
		elsif IR(15 downto 13) = "100" and IR(12 downto 10) >= "000" and IR(12 downto 10) <= "101" then
			INST <= I_ADDSUB;
		elsif IR(15 downto 11) = "10011" then
			INST <= I_MUL;
		elsif IR(15 downto 13) = "101" then
			INST <= I_LOG;
		elsif IR(15 downto 13) = "110" then
			INST <= I_SHIFT;
		elsif IR(15 downto 9) = "1110000" then
			INST <= I_ST;
		elsif IR(15 downto 11) = "11101" and IR(9 downto 8) /= "11" then
			INST <= I_WRRAM;
		elsif IR(15 downto 10) = "111100" then
			INST <= I_SWAP;
		elsif IR(15 downto 10) = "111110" then
			INST <= I_CLR;
		elsif IR(15 downto 10) = "111111" then
			INST <= I_HLT;
		end if;
	end process;

	
	RDB <= A when IR(7 downto 0) = x"00" else
			 MACH when IR(7 downto 0) = x"01" else
			 MACL when IR(7 downto 0) = x"02" else
			 x"0000" & MBR when IR(7 downto 0) = x"03" else
			 ROMB when IR(7 downto 0) = x"08" else
			 RAMB when IR(7 downto 0) = x"0C" else
			 MAR when IR(7 downto 0) = x"13" else
			 x"000" & DPR when IR(7 downto 0) = x"1C" else
			 x"00" & "0" & P when IR(7 downto 0) = x"28" else
			 x"0000" & MBR when IR(7 downto 0) = x"2E" else
			 x"000000" when IR(7 downto 0) = x"50" else
			 x"FFFFFF" when IR(7 downto 0) = x"51" else
			 x"00FF00" when IR(7 downto 0) = x"52" else
			 x"FF0000" when IR(7 downto 0) = x"53" else
			 x"00FFFF" when IR(7 downto 0) = x"54" else
			 x"FFFF00" when IR(7 downto 0) = x"55" else
			 x"800000" when IR(7 downto 0) = x"56" else
			 x"7FFFFF" when IR(7 downto 0) = x"57" else
			 x"008000" when IR(7 downto 0) = x"58" else
			 x"007FFF" when IR(7 downto 0) = x"59" else
			 x"FF7FFF" when IR(7 downto 0) = x"5A" else
			 x"FFFF7F" when IR(7 downto 0) = x"5B" else
			 x"010000" when IR(7 downto 0) = x"5C" else
			 x"FEFFFF" when IR(7 downto 0) = x"5D" else
			 x"000100" when IR(7 downto 0) = x"5E" else
			 x"00FEFF" when IR(7 downto 0) = x"5F" else
			 GPR(0) when IR(7 downto 0) = x"60" else
			 GPR(1) when IR(7 downto 0) = x"61" else
			 GPR(2) when IR(7 downto 0) = x"62" else
			 GPR(3) when IR(7 downto 0) = x"63" else
			 GPR(4) when IR(7 downto 0) = x"64" else
			 GPR(5) when IR(7 downto 0) = x"65" else
			 GPR(6) when IR(7 downto 0) = x"66" else
			 GPR(7) when IR(7 downto 0) = x"67" else
			 GPR(8) when IR(7 downto 0) = x"68" else
			 GPR(9) when IR(7 downto 0) = x"69" else
			 GPR(10) when IR(7 downto 0) = x"6A" else
			 GPR(11) when IR(7 downto 0) = x"6B" else
			 GPR(12) when IR(7 downto 0) = x"6C" else
			 GPR(13) when IR(7 downto 0) = x"6D" else
			 GPR(14) when IR(7 downto 0) = x"6E" else
			 GPR(15) when IR(7 downto 0) = x"6F" else
			 x"000000";
			 
	SH_A <= A                    when IR(9 downto 8) = "00" else
			  A(22 downto 0)&"0"   when IR(9 downto 8) = "01" else
			  A(15 downto 0)&x"00" when IR(9 downto 8) = "10" else
			  A(7 downto 0)&x"0000";
	
	--ALU
	process(INST, A, SH_A, RDB, IR)
	variable TEMP : std_logic_vector(24 downto 0);
	begin
		ALUR <= (others => '0');
		ALUC <= '0';
		if INST = I_ADDSUB then
			case IR(12 downto 10) is
				when "000" =>
					TEMP := std_logic_vector(("0" & unsigned(SH_A)) + ("0" & unsigned(RDB)));
				when "001" =>
					TEMP := std_logic_vector(("0" & unsigned(SH_A)) + ("0" & x"0000" & unsigned(IR(7 downto 0))));
				when "010" =>
					TEMP := std_logic_vector(("0" & unsigned(RDB)) - ("0" & unsigned(SH_A)));
				when "011" =>
					TEMP := std_logic_vector(("0" & x"0000" & unsigned(IR(7 downto 0))) - ("0" & unsigned(SH_A)));
				when "100" =>
					TEMP := std_logic_vector(("0" & unsigned(SH_A)) - ("0" & unsigned(RDB)));
				when "101" =>
					TEMP := std_logic_vector(("0" & unsigned(SH_A)) - ("0" & x"0000" & unsigned(IR(7 downto 0))));
				when others => 
					TEMP := (others => '0');
			end case;
			ALUR <= TEMP(23 downto 0);
			ALUC <= TEMP(24);
		elsif INST = I_LOG then
			case IR(12 downto 10) is
				when "000" =>
					ALUR <= SH_A xor (not RDB);
				when "001" =>
					ALUR <= SH_A xor (not (x"0000" & IR(7 downto 0)));
				when "010" =>
					ALUR <= SH_A xor RDB;
				when "011" =>
					ALUR <= SH_A xor (x"0000" & IR(7 downto 0));
				when "100" =>
					ALUR <= SH_A and RDB;
				when "101" =>
					ALUR <= SH_A and (x"0000" & IR(7 downto 0));
				when "110" =>
					ALUR <= SH_A or RDB;
				when "111" =>
					ALUR <= SH_A or (x"0000" & IR(7 downto 0));
				when others => null;
			end case;
		elsif INST = I_SHIFT then
			case IR(12 downto 10) is
				when "000" =>
					ALUR <= std_logic_vector(shift_right(unsigned(A), to_integer(unsigned(RDB(4 downto 0)))));
				when "001" =>
					ALUR <= std_logic_vector(shift_right(unsigned(A), to_integer(unsigned(IR(4 downto 0)))));
				when "010" =>
					ALUR <= std_logic_vector(shift_right(signed(A), to_integer(unsigned(RDB(4 downto 0)))));
				when "011" =>
					ALUR <= std_logic_vector(shift_right(signed(A), to_integer(unsigned(IR(4 downto 0)))));
				when "100" =>
					ALUR <= std_logic_vector(rotate_right(unsigned(A), to_integer(unsigned(RDB(4 downto 0)))));
				when "101" =>
					ALUR <= std_logic_vector(rotate_right(unsigned(A), to_integer(unsigned(IR(4 downto 0)))));
				when "110" =>
					ALUR <= std_logic_vector(shift_left(unsigned(A), to_integer(unsigned(RDB(4 downto 0)))));
				when "111" =>
					ALUR <= std_logic_vector(shift_left(unsigned(A), to_integer(unsigned(IR(4 downto 0)))));
				when others => null;
			end case;
		elsif INST = I_CMP then
			case IR(12 downto 10) is
				when "010" =>
					TEMP := std_logic_vector(("0" & unsigned(RDB)) - ("0" & unsigned(SH_A)));
				when "011" =>
					TEMP := std_logic_vector(("0" & x"0000" & unsigned(IR(7 downto 0))) - ("0" & unsigned(SH_A)));
				when "100" =>
					TEMP := std_logic_vector(("0" & unsigned(SH_A)) - ("0" & unsigned(RDB)));
				when "101" =>
					TEMP := std_logic_vector(("0" & unsigned(SH_A)) - ("0" & x"0000" & unsigned(IR(7 downto 0))));
				when others => 
					TEMP := (others => '0');
			end case;
			ALUR <= TEMP(23 downto 0);
			ALUC <= TEMP(24);
		elsif INST = I_EXTS then
			if IR(9 downto 8) = "01" then
				ALUR <= (0 to 15 => A(7)) & A(7 downto 0);
			elsif IR(9 downto 8) = "10" then
				ALUR <= (0 to 7 => A(15)) & A(15 downto 0);
			end if;
		end if;
	end process;

	--Flags
	process(CLK, RST_N)
	begin
		if RST_N = '0' then
			FLAGS <= (others => '0');
		elsif rising_edge(CLK) then
			if CPU_EN = '1' then
				if INST = I_ADDSUB or INST = I_LOG or INST = I_SHIFT or INST = I_CMP then
					FLAGS(FLAG_N) <= ALUR(23);
					if ALUR = x"000000" then
						FLAGS(FLAG_Z) <= '1';
					else
						FLAGS(FLAG_Z) <= '0';
					end if;
				end if;
				
				if INST = I_ADDSUB then
					case IR(12 downto 11) is
						when "00" =>
							FLAGS(FLAG_T) <= ALUC;
						when "01" | "10" =>
							FLAGS(FLAG_T) <= not ALUC;
						when others => null;
					end case;
				elsif INST = I_CMP then
					FLAGS(FLAG_T) <= not ALUC;
				end if;
				
				FLAGS(FLAG_V) <= '0';-----------------------------------------------
			end if;
			-- SS restore tail: FLAGS (0x03)
			if SS_BUSY = '1' and SS_WR = '1' then
				case ADDR(7 downto 0) is
					when x"03" => FLAGS <= DI(3 downto 0);
					when others => null;
				end case;
			end if;
		end if;
	end process;

	--MUL
	process(CLK, RST_N)
		variable TEMP : signed(47 downto 0);
	begin
		if RST_N = '0' then
			MULA <= (others => '0');
			MULB <= (others => '0');
			MACL <= (others => '0');
			MACH <= (others => '0');
		elsif rising_edge(CLK) then
			if CPU_EN = '1' and INST = I_MUL then
				MULA <= signed(A);
				if IR(10) = '0' then
					MULB <= signed(RDB);
				else
					MULB <= signed(resize(unsigned(IR(7 downto 0)), MULB'length));
				end if;
			end if;
				
			if EN = '1' and SUSPEND = '0' then
				TEMP := MULA * MULB;
				MACL <= std_logic_vector(TEMP(23 downto 0));
				MACH <= std_logic_vector(TEMP(47 downto 24));
			end if;
			-- SS restore tail: MUL/MAC (0x4A..0x55)
			if SS_BUSY = '1' and SS_WR = '1' then
				case ADDR(7 downto 0) is
					when x"4A" => MACL(7 downto 0)   <= DI;
					when x"4B" => MACL(15 downto 8)  <= DI;
					when x"4C" => MACL(23 downto 16) <= DI;
					when x"4D" => MACH(7 downto 0)   <= DI;
					when x"4E" => MACH(15 downto 8)  <= DI;
					when x"4F" => MACH(23 downto 16) <= DI;
					when x"50" => MULA(7 downto 0)   <= signed(DI);
					when x"51" => MULA(15 downto 8)  <= signed(DI);
					when x"52" => MULA(23 downto 16) <= signed(DI);
					when x"53" => MULB(7 downto 0)   <= signed(DI);
					when x"54" => MULB(15 downto 8)  <= signed(DI);
					when x"55" => MULB(23 downto 16) <= signed(DI);
					when others => null;
				end case;
			end if;
		end if;
	end process;


	--Registers
	process(CLK, RST_N)
	begin
		if RST_N = '0' then
			A <= (others => '0');
		elsif rising_edge(CLK) then
			if CPU_EN = '1' then
				if INST = I_MOV then
					if IR(10 downto 8) = "000" then
						A <= RDB;
					elsif IR(10 downto 8) = "100" then
						A <= x"0000" & IR(7 downto 0);
					end if;
				elsif INST = I_ADDSUB or INST = I_LOG or INST = I_SHIFT or INST = I_EXTS then
					A <= ALUR;
				elsif INST = I_SWAP then
					A <= GPR(to_integer(unsigned(IR(3 downto 0))));
				elsif INST = I_CLR then
					A <= (others => '0');
				end if;
			end if;
			-- SS restore tail: A (0x00..0x02)
			if SS_BUSY = '1' and SS_WR = '1' then
				case ADDR(7 downto 0) is
					when x"00" => A(7 downto 0)   <= DI;
					when x"01" => A(15 downto 8)  <= DI;
					when x"02" => A(23 downto 16) <= DI;
					when others => null;
				end case;
			end if;
		end if;
	end process;
	
	process(CLK, RST_N)
	begin
		if RST_N = '0' then
			MBR <= (others => '0');
			MAR <= (others => '0');
			EXT_BUS_ADDR <= (others => '0');
			BUS_ACCESS_CNT <= (others => '0');
			ROM_ACCESS <= '0';
			SRAM_ACCESS <= '0';
			SRAM_WR <= '0';
		elsif rising_edge(CLK) then
			if CPU_EN = '1' then
				if ROM_ACCESS = '1' or SRAM_ACCESS = '1' then 
					if BUS_ACCESS_CNT = 0 then
						ROM_ACCESS <= '0';
						SRAM_ACCESS <= '0';
						SRAM_WR <= '0';
					else
						BUS_ACCESS_CNT <= BUS_ACCESS_CNT - 1;
					end if;
				end if;

				if INST = I_MOV then
					case IR(10 downto 8) is
						when "001" =>
							MBR <= RDB(7 downto 0);
							if IR(7 downto 1) = "0010111" then
								EXT_BUS_ADDR <= MAR;
								if IR(0) = '0' then
									ROM_ACCESS <= '1';
									BUS_ACCESS_CNT <= unsigned(WS1) - 1;
								else
									SRAM_ACCESS <= '1';
									BUS_ACCESS_CNT <= unsigned(WS2) - 1;
									SRAM_WR <= '0';
								end if;
							end if;
						when "010" =>
							MAR <= GPR(to_integer(unsigned(IR(3 downto 0))));
						when "101" =>
							MBR <= IR(7 downto 0);
						when "110" =>
							MAR <= x"0000" & IR(7 downto 0);						
						when others => null;
					end case;
				elsif INST = I_INCEXT then
					MAR <= std_logic_vector(unsigned(MAR) + 1);
				elsif INST = I_FINEXT then
					if BUS_ACCESS_CNT = 0 then
						MBR <= BUS_DI;
					end if;
				elsif INST = I_ST then
					if IR(8) = '0' and IR(6 downto 0) = "0010011" then
						MAR <= A;
					elsif IR(8) = '0' and IR(6 downto 0) = "0000011" then
						MBR <= A(7 downto 0);
					elsif IR(8) = '1' and IR(7 downto 0) = "00101111" then
						SRAM_ACCESS <= '1';
						BUS_ACCESS_CNT <= unsigned(WS2) - 1;
						SRAM_WR <= '1';
					end if;
				end if;
			end if;
			-- SS restore tail: MBR/MAR/bus FSM (0x56..0x60)
			if SS_BUSY = '1' and SS_WR = '1' then
				case ADDR(7 downto 0) is
					when x"56" => MAR(7 downto 0)         <= DI;
					when x"57" => MAR(15 downto 8)        <= DI;
					when x"58" => MAR(23 downto 16)       <= DI;
					when x"59" => MBR                     <= DI;
					when x"5A" => ROM_ACCESS               <= DI(0);
					when x"5B" => SRAM_ACCESS              <= DI(0);
					when x"5C" => SRAM_WR                  <= DI(0);
					when x"5D" => BUS_ACCESS_CNT           <= unsigned(DI(2 downto 0));
					when x"5E" => EXT_BUS_ADDR(7 downto 0)  <= DI;
					when x"5F" => EXT_BUS_ADDR(15 downto 8) <= DI;
					when x"60" => EXT_BUS_ADDR(23 downto 16)<= DI;
					when others => null;
				end case;
			end if;
		end if;
	end process;

	process(CLK, RST_N)
	begin
		if RST_N = '0' then
			P <= (others => '1');
		elsif rising_edge(CLK) then
			if CPU_EN = '1' then
				if INST = I_MOV then
					case IR(10 downto 8) is
						when "011" =>
							P <= GPR(to_integer(unsigned(IR(3 downto 0))))(14 downto 0);
						when "111" =>
							P <= "0000000" & IR(7 downto 0);
						when others => null;
					end case;
				elsif INST = I_LDP then
					if IR(8) = '0' then
						P(7 downto 0) <= IR(7 downto 0);
					else
						P(14 downto 8) <= IR(6 downto 0);
					end if;
				elsif INST = I_CLR then
					P <= (others => '0');
				end if;
			end if;
			-- SS restore tail: P (0x69..0x6A)
			if SS_BUSY = '1' and SS_WR = '1' then
				case ADDR(7 downto 0) is
					when x"69" => P(7 downto 0)  <= DI;
					when x"6A" => P(14 downto 8) <= DI(6 downto 0);
					when others => null;
				end case;
			end if;
		end if;
	end process;

	process(CLK, RST_N, INST, FLAGS, IR)
		variable NEXT_PC : std_logic_vector(7 downto 0);
	begin
		if INST = I_BR or INST = I_BSUB then
			case IR(12 downto 10) is
				when "010" => COND <= '1';
				when "011" => COND <= FLAGS(FLAG_Z);
				when "100" => COND <= FLAGS(FLAG_T);
				when "101" => COND <= FLAGS(FLAG_N);
				when "110" => COND <= FLAGS(FLAG_V);
				when others => COND <= '0';
			end case;
		elsif INST = I_SKIP then
			case IR(9 downto 8) is
				when "00" => COND <= FLAGS(FLAG_V) xor (not IR(0));
				when "01" => COND <= FLAGS(FLAG_T) xor (not IR(0));
				when "10" => COND <= FLAGS(FLAG_Z) xor (not IR(0));
				when "11" => COND <= FLAGS(FLAG_N) xor (not IR(0));
				when others => COND <= '0';
			end case;
		else
			COND <= '0';
		end if;
		
		if RST_N = '0' then
			PC <= (others => '0');
			BANK <= '0';
			STACK_RAM <= (others => (others => '0'));
			SP <= (others => '0');
			CPU_RUN <= '0';
			IRQ <= '0';
			IRQ_FLAG <= '0';
		elsif rising_edge(CLK) then
			if ENABLE = '1' and CPU_RUN = '0' then
				if MMIO_WR = '1' and ADDR(11 downto 0) = x"F48" then	--7F48
					BANK <= DI(0);
				elsif MMIO_WR = '1' and ADDR(11 downto 0) = x"F4F" then	--7F4F
					CPU_RUN <= '1';
					PC <= DI;
					if CACHE_PAGE(0)(15) = '1' and CACHE_PAGE(0)(14 downto 0) = ROM_PAGE then
						BANK <= '0';
					elsif CACHE_PAGE(1)(15) = '1' and CACHE_PAGE(1)(14 downto 0) = ROM_PAGE then
						BANK <= '1';
					end if;
					SP <= (others => '0');
				elsif MMIO_WR = '1' and ADDR(11 downto 0) = x"F53" then	--7F53
					CPU_RUN <= '0';
					IRQ <= IRQ_EN;
					IRQ_FLAG <= IRQ_EN;
				elsif MMIO_WR = '1' and ADDR(11 downto 0) = x"F51" then	--7F51
					if DI(0) = '1' then
						IRQ <= '0';
						IRQ_FLAG <= '0';
					end if;
				elsif MMIO_WR = '1' and ADDR(11 downto 0) = x"F5E" then	--7F5E
					IRQ_FLAG <= '0';
				end if;
			elsif CPU_EN = '1' then
				NEXT_PC := std_logic_vector(unsigned(PC) + 1);
				if INST = I_BR or INST = I_BSUB then
					if COND = '0' then
						PC <= NEXT_PC;
						EXTRA_CYCLES <= 0;
					else
						EXTRA_CYCLES <= 2;
					end if;

					if EXTRA_CYCLES = 2 then
						EXTRA_CYCLES <= 1;
						if INST = I_BSUB then
							STACK_RAM(to_integer(SP)) <= BANK & NEXT_PC;
							SP <= SP + 1;
						end if;
					elsif EXTRA_CYCLES = 1 then
						EXTRA_CYCLES <= 0;
						PC <= IR(7 downto 0);
						BANK <= BANK xor IR(9);
					end if;

				elsif INST = I_SKIP then
					if COND = '0' then
						PC <= NEXT_PC;
						EXTRA_CYCLES <= 0;
					else
						EXTRA_CYCLES <= 1;
					end if;

					if EXTRA_CYCLES = 1 then
						EXTRA_CYCLES <= 0;
						PC <= std_logic_vector(unsigned(NEXT_PC) + 1);
					end if;

				elsif INST = I_RTS then
					EXTRA_CYCLES <= 2;

					if EXTRA_CYCLES = 2 then
						EXTRA_CYCLES <= 1;
						SP <= SP - 1;
					elsif EXTRA_CYCLES = 1 then
						EXTRA_CYCLES <= 0;
						PC <= STACK_RAM(to_integer(SP))(7 downto 0);
						BANK <= STACK_RAM(to_integer(SP))(8);
					end if;

				elsif INST = I_FINEXT then
					if BUS_ACCESS_CNT = 0 then
						PC <= NEXT_PC;
					end if;
				else
					PC <= NEXT_PC;
				end if;
				
				if INST = I_HLT then
					CPU_RUN <= '0';
					IRQ <= IRQ_EN;
					IRQ_FLAG <= IRQ_EN;
				end if;
			end if;
			-- SS restore tail: PC/BANK/STACK/SP/CPU_RUN/IRQ/IRQ_FLAG/EXTRA_CYCLES (0x04..0x19, 0xB8)
			if SS_BUSY = '1' and SS_WR = '1' then
				case ADDR(7 downto 0) is
					when x"04" => PC                       <= DI;
					when x"05" => BANK                     <= DI(0);
					when x"06" => STACK_RAM(0)(7 downto 0) <= DI;
					when x"07" => STACK_RAM(0)(8)          <= DI(0);
					when x"08" => STACK_RAM(1)(7 downto 0) <= DI;
					when x"09" => STACK_RAM(1)(8)          <= DI(0);
					when x"0A" => STACK_RAM(2)(7 downto 0) <= DI;
					when x"0B" => STACK_RAM(2)(8)          <= DI(0);
					when x"0C" => STACK_RAM(3)(7 downto 0) <= DI;
					when x"0D" => STACK_RAM(3)(8)          <= DI(0);
					when x"0E" => STACK_RAM(4)(7 downto 0) <= DI;
					when x"0F" => STACK_RAM(4)(8)          <= DI(0);
					when x"10" => STACK_RAM(5)(7 downto 0) <= DI;
					when x"11" => STACK_RAM(5)(8)          <= DI(0);
					when x"12" => STACK_RAM(6)(7 downto 0) <= DI;
					when x"13" => STACK_RAM(6)(8)          <= DI(0);
					when x"14" => STACK_RAM(7)(7 downto 0) <= DI;
					when x"15" => STACK_RAM(7)(8)          <= DI(0);
					when x"16" => SP                       <= unsigned(DI(2 downto 0));
					when x"17" => CPU_RUN                  <= DI(0);
					when x"18" => IRQ                      <= DI(0);
					when x"19" => IRQ_FLAG                 <= DI(0);
					when x"B8" =>
						-- EXTRA_CYCLES range is 0 to 2; saturate the out-of-range
						-- "11" encoding so a corrupt SS blob cannot trip a range-check.
						if DI(1 downto 0) = "11" then
							EXTRA_CYCLES <= 2;
						else
							EXTRA_CYCLES <= to_integer(unsigned(DI(1 downto 0)));
						end if;
					when others => null;
				end case;
			end if;
		end if;
	end process;

	IRQ_N <= not IRQ;
	
	process(CLK, RST_N)
	begin
		if RST_N = '0' then
			DPR <= (others => '0');
		elsif rising_edge(CLK) then
			if CPU_EN = '1' then
				if INST = I_ST and IR(8) = '0' and IR(6 downto 0) = "0011100" then
					DPR <= A(11 downto 0);
				end if;
			end if;
			-- SS restore tail: DPR (0x67..0x68)
			if SS_BUSY = '1' and SS_WR = '1' then
				case ADDR(7 downto 0) is
					when x"67" => DPR(7 downto 0)  <= DI;
					when x"68" => DPR(11 downto 8) <= DI(3 downto 0);
					when others => null;
				end case;
			end if;
		end if;
	end process;

	process(CLK, RST_N)
	begin
		if RST_N = '0' then
			GPR <= (others => (others => '0'));
		elsif rising_edge(CLK) then
			if ENABLE = '1' and CPU_RUN = '0' then
				if MMIO_WR = '1' and ADDR(11 downto 8) = x"F" then	--7F80-7FAF
					case ADDR(7 downto 0) is
						when x"80" => GPR(0)(7 downto 0) <= DI;
						when x"81" => GPR(0)(15 downto 8) <= DI;
						when x"82" => GPR(0)(23 downto 16) <= DI;
						when x"83" => GPR(1)(7 downto 0) <= DI;
						when x"84" => GPR(1)(15 downto 8) <= DI;
						when x"85" => GPR(1)(23 downto 16) <= DI;
						when x"86" => GPR(2)(7 downto 0) <= DI;
						when x"87" => GPR(2)(15 downto 8) <= DI;
						when x"88" => GPR(2)(23 downto 16) <= DI;
						when x"89" => GPR(3)(7 downto 0) <= DI;
						when x"8A" => GPR(3)(15 downto 8) <= DI;
						when x"8B" => GPR(3)(23 downto 16) <= DI;
						when x"8C" => GPR(4)(7 downto 0) <= DI;
						when x"8D" => GPR(4)(15 downto 8) <= DI;
						when x"8E" => GPR(4)(23 downto 16) <= DI;
						when x"8F" => GPR(5)(7 downto 0) <= DI;
						when x"90" => GPR(5)(15 downto 8) <= DI;
						when x"91" => GPR(5)(23 downto 16) <= DI;
						when x"92" => GPR(6)(7 downto 0) <= DI;
						when x"93" => GPR(6)(15 downto 8) <= DI;
						when x"94" => GPR(6)(23 downto 16) <= DI;
						when x"95" => GPR(7)(7 downto 0) <= DI;
						when x"96" => GPR(7)(15 downto 8) <= DI;
						when x"97" => GPR(7)(23 downto 16) <= DI;
						when x"98" => GPR(8)(7 downto 0) <= DI;
						when x"99" => GPR(8)(15 downto 8) <= DI;
						when x"9A" => GPR(8)(23 downto 16) <= DI;
						when x"9B" => GPR(9)(7 downto 0) <= DI;
						when x"9C" => GPR(9)(15 downto 8) <= DI;
						when x"9D" => GPR(9)(23 downto 16) <= DI;
						when x"9E" => GPR(10)(7 downto 0) <= DI;
						when x"9F" => GPR(10)(15 downto 8) <= DI;
						when x"A0" => GPR(10)(23 downto 16) <= DI;
						when x"A1" => GPR(11)(7 downto 0) <= DI;
						when x"A2" => GPR(11)(15 downto 8) <= DI;
						when x"A3" => GPR(11)(23 downto 16) <= DI;
						when x"A4" => GPR(12)(7 downto 0) <= DI;
						when x"A5" => GPR(12)(15 downto 8) <= DI;
						when x"A6" => GPR(12)(23 downto 16) <= DI;
						when x"A7" => GPR(13)(7 downto 0) <= DI;
						when x"A8" => GPR(13)(15 downto 8) <= DI;
						when x"A9" => GPR(13)(23 downto 16) <= DI;
						when x"AA" => GPR(14)(7 downto 0) <= DI;
						when x"AB" => GPR(14)(15 downto 8) <= DI;
						when x"AC" => GPR(14)(23 downto 16) <= DI;
						when x"AD" => GPR(15)(7 downto 0) <= DI;
						when x"AE" => GPR(15)(15 downto 8) <= DI;
						when x"AF" => GPR(15)(23 downto 16) <= DI;
						when others => null;
					end case;
				end if;
			elsif CPU_EN = '1' then
				if (INST = I_ST and IR(8) = '0' and IR(6 downto 4) = "110") or INST = I_SWAP then
					GPR(to_integer(unsigned(IR(3 downto 0)))) <= A;
				end if;
			end if;
			-- SS restore tail: GPR(0..15) (0x1A..0x49)
			if SS_BUSY = '1' and SS_WR = '1' then
				case ADDR(7 downto 0) is
					when x"1A" => GPR(0)(7 downto 0)   <= DI;
					when x"1B" => GPR(0)(15 downto 8)  <= DI;
					when x"1C" => GPR(0)(23 downto 16) <= DI;
					when x"1D" => GPR(1)(7 downto 0)   <= DI;
					when x"1E" => GPR(1)(15 downto 8)  <= DI;
					when x"1F" => GPR(1)(23 downto 16) <= DI;
					when x"20" => GPR(2)(7 downto 0)   <= DI;
					when x"21" => GPR(2)(15 downto 8)  <= DI;
					when x"22" => GPR(2)(23 downto 16) <= DI;
					when x"23" => GPR(3)(7 downto 0)   <= DI;
					when x"24" => GPR(3)(15 downto 8)  <= DI;
					when x"25" => GPR(3)(23 downto 16) <= DI;
					when x"26" => GPR(4)(7 downto 0)   <= DI;
					when x"27" => GPR(4)(15 downto 8)  <= DI;
					when x"28" => GPR(4)(23 downto 16) <= DI;
					when x"29" => GPR(5)(7 downto 0)   <= DI;
					when x"2A" => GPR(5)(15 downto 8)  <= DI;
					when x"2B" => GPR(5)(23 downto 16) <= DI;
					when x"2C" => GPR(6)(7 downto 0)   <= DI;
					when x"2D" => GPR(6)(15 downto 8)  <= DI;
					when x"2E" => GPR(6)(23 downto 16) <= DI;
					when x"2F" => GPR(7)(7 downto 0)   <= DI;
					when x"30" => GPR(7)(15 downto 8)  <= DI;
					when x"31" => GPR(7)(23 downto 16) <= DI;
					when x"32" => GPR(8)(7 downto 0)   <= DI;
					when x"33" => GPR(8)(15 downto 8)  <= DI;
					when x"34" => GPR(8)(23 downto 16) <= DI;
					when x"35" => GPR(9)(7 downto 0)   <= DI;
					when x"36" => GPR(9)(15 downto 8)  <= DI;
					when x"37" => GPR(9)(23 downto 16) <= DI;
					when x"38" => GPR(10)(7 downto 0)  <= DI;
					when x"39" => GPR(10)(15 downto 8) <= DI;
					when x"3A" => GPR(10)(23 downto 16)<= DI;
					when x"3B" => GPR(11)(7 downto 0)  <= DI;
					when x"3C" => GPR(11)(15 downto 8) <= DI;
					when x"3D" => GPR(11)(23 downto 16)<= DI;
					when x"3E" => GPR(12)(7 downto 0)  <= DI;
					when x"3F" => GPR(12)(15 downto 8) <= DI;
					when x"40" => GPR(12)(23 downto 16)<= DI;
					when x"41" => GPR(13)(7 downto 0)  <= DI;
					when x"42" => GPR(13)(15 downto 8) <= DI;
					when x"43" => GPR(13)(23 downto 16)<= DI;
					when x"44" => GPR(14)(7 downto 0)  <= DI;
					when x"45" => GPR(14)(15 downto 8) <= DI;
					when x"46" => GPR(14)(23 downto 16)<= DI;
					when x"47" => GPR(15)(7 downto 0)  <= DI;
					when x"48" => GPR(15)(15 downto 8) <= DI;
					when x"49" => GPR(15)(23 downto 16)<= DI;
					when others => null;
				end case;
			end if;
		end if;
	end process;

	process( IR, A, DPR, RAMB, DMA_RUN, DMA_DST_ADDR, RAM_SEL, DMA_DAT)
	begin
		if DMA_RUN = '1' and RAM_SEL = '1' then
			DATA_RAM_ADDR_A <= DMA_DST_ADDR(11 downto 0);
		elsif IR(10) = '0' then
			DATA_RAM_ADDR_A <= A(11 downto 0);
		else
			DATA_RAM_ADDR_A <= std_logic_vector(unsigned(DPR) + unsigned(IR(7 downto 0)));
		end if;
		
		if DMA_RUN = '1' and RAM_SEL = '1' then
			DATA_RAM_DI_A <= DMA_DAT;
		else
			case IR(9 downto 8) is
				when "00" =>   DATA_RAM_DI_A <= RAMB(7 downto 0);
				when "01" =>   DATA_RAM_DI_A <= RAMB(15 downto 8);
				when others => DATA_RAM_DI_A <= RAMB(23 downto 16);
			end case;
		end if;
	end process; 
		
	process(CLK, RST_N)
	begin
		if RST_N = '0' then
			RAMB <= (others => '0');
		elsif rising_edge(CLK) then
			if CPU_EN = '1' then
				if INST = I_RDRAM then
					case IR(9 downto 8) is
						when "00" => RAMB(7 downto 0) <= DATA_RAM_Q_A;
						when "01" => RAMB(15 downto 8) <= DATA_RAM_Q_A;
						when "10" => RAMB(23 downto 16) <= DATA_RAM_Q_A;
						when others => null;
					end case;
				elsif INST = I_ST and IR(8) = '0' and IR(6 downto 0) = "0001100" then
					RAMB <= A;
				elsif INST = I_CLR then
					RAMB <= (others => '0');
				end if;
			end if;
			-- SS restore tail: RAMB (0x64..0x66)
			if SS_BUSY = '1' and SS_WR = '1' then
				case ADDR(7 downto 0) is
					when x"64" => RAMB(7 downto 0)   <= DI;
					when x"65" => RAMB(15 downto 8)  <= DI;
					when x"66" => RAMB(23 downto 16) <= DI;
					when others => null;
				end case;
			end if;
		end if;
	end process;

	process(CLK, RST_N, IR, A)
	begin
		if IR(10) = '0' then
			DATA_ROM_ADDR <= A(9 downto 0);
		else
			DATA_ROM_ADDR <= IR(9 downto 0);
		end if;

		if RST_N = '0' then
			ROMB <= (others => '0');
		elsif rising_edge(CLK) then
			if CPU_EN = '1' then
				if INST = I_RDROM then
					ROMB <= DATA_ROM_Q;
				end if;
			end if;
			-- SS restore tail: ROMB (0x61..0x63)
			if SS_BUSY = '1' and SS_WR = '1' then
				case ADDR(7 downto 0) is
					when x"61" => ROMB(7 downto 0)   <= DI;
					when x"62" => ROMB(15 downto 8)  <= DI;
					when x"63" => ROMB(23 downto 16) <= DI;
					when others => null;
				end case;
			end if;
		end if;
	end process;

	DATA_ROM : entity work.spram generic map(10, 24, "rtl/chip/CX4/drom.mif")
	port map(
		clock		=> not CLK,
		address	=> DATA_ROM_ADDR,
		q			=> DATA_ROM_Q
	);
	
	DATA_RAM_WE_A <= '1' when (CPU_EN = '1' and INST = I_WRRAM) or (EN = '1' and DMA_RUN = '1' and RAM_SEL = '1' and DMA_STATE = '1') else '0';
	DATA_RAM_ADDR_B <= SS_RAM_A             when SS_BUSY = '1' else ADDR(11 downto 0);
	DATA_RAM_DI_B   <= SS_RAM_DI            when SS_BUSY = '1' else DI;
	DATA_RAM_WE_B   <= SS_RAM_WR            when SS_BUSY = '1'
	               else '1' when ENABLE = '1' and RAMIO_WR = '1' and CPU_RUN = '0' else '0';
	SS_RAM_DO       <= DATA_RAM_Q_B;
	DATA_RAM : entity work.dpram_difclk generic map(12, 8, 12, 8)
	port map(
		clock0		=> not CLK,
		address_a	=> DATA_RAM_ADDR_A,
		data_a		=> DATA_RAM_DI_A,
		wren_a		=> DATA_RAM_WE_A,
		q_a			=> DATA_RAM_Q_A,
		
		clock1		=> CLK,
		address_b	=> DATA_RAM_ADDR_B,
		data_b		=> DATA_RAM_DI_B,
		wren_b		=> DATA_RAM_WE_B,
		q_b			=> DATA_RAM_Q_B
	);

	-- SS byte map for the save mux below and the restore tails: see the
	-- "CX4 CA[7:0] savestate byte map" table near the top of this architecture.

	-- Registered save mux -- must be clocked, never combinational (no latch)
	process(CLK)
	begin
		if rising_edge(CLK) then
			if SS_RAM_SEL = '1' then
				SS_DO <= DATA_RAM_Q_B;               -- 8-bit port B; no byte-lane mux needed
			else
				case ADDR(7 downto 0) is
					-- PROCESS: A
					when x"00" => SS_DO <= A(7 downto 0);
					when x"01" => SS_DO <= A(15 downto 8);
					when x"02" => SS_DO <= A(23 downto 16);
					-- PROCESS: FLAGS
					when x"03" => SS_DO <= "0000" & FLAGS;
					-- PROCESS: PC/BANK/STACK/SP/CPU_RUN/IRQ
					when x"04" => SS_DO <= PC;
					when x"05" => SS_DO <= "0000000" & BANK;
					when x"06" => SS_DO <= STACK_RAM(0)(7 downto 0);
					when x"07" => SS_DO <= "0000000" & STACK_RAM(0)(8);
					when x"08" => SS_DO <= STACK_RAM(1)(7 downto 0);
					when x"09" => SS_DO <= "0000000" & STACK_RAM(1)(8);
					when x"0A" => SS_DO <= STACK_RAM(2)(7 downto 0);
					when x"0B" => SS_DO <= "0000000" & STACK_RAM(2)(8);
					when x"0C" => SS_DO <= STACK_RAM(3)(7 downto 0);
					when x"0D" => SS_DO <= "0000000" & STACK_RAM(3)(8);
					when x"0E" => SS_DO <= STACK_RAM(4)(7 downto 0);
					when x"0F" => SS_DO <= "0000000" & STACK_RAM(4)(8);
					when x"10" => SS_DO <= STACK_RAM(5)(7 downto 0);
					when x"11" => SS_DO <= "0000000" & STACK_RAM(5)(8);
					when x"12" => SS_DO <= STACK_RAM(6)(7 downto 0);
					when x"13" => SS_DO <= "0000000" & STACK_RAM(6)(8);
					when x"14" => SS_DO <= STACK_RAM(7)(7 downto 0);
					when x"15" => SS_DO <= "0000000" & STACK_RAM(7)(8);
					when x"16" => SS_DO <= "00000" & std_logic_vector(SP);
					when x"17" => SS_DO <= "0000000" & CPU_RUN;
					when x"18" => SS_DO <= "0000000" & IRQ;
					when x"19" => SS_DO <= "0000000" & IRQ_FLAG;
					-- PROCESS: GPR
					when x"1A" => SS_DO <= GPR(0)(7 downto 0);
					when x"1B" => SS_DO <= GPR(0)(15 downto 8);
					when x"1C" => SS_DO <= GPR(0)(23 downto 16);
					when x"1D" => SS_DO <= GPR(1)(7 downto 0);
					when x"1E" => SS_DO <= GPR(1)(15 downto 8);
					when x"1F" => SS_DO <= GPR(1)(23 downto 16);
					when x"20" => SS_DO <= GPR(2)(7 downto 0);
					when x"21" => SS_DO <= GPR(2)(15 downto 8);
					when x"22" => SS_DO <= GPR(2)(23 downto 16);
					when x"23" => SS_DO <= GPR(3)(7 downto 0);
					when x"24" => SS_DO <= GPR(3)(15 downto 8);
					when x"25" => SS_DO <= GPR(3)(23 downto 16);
					when x"26" => SS_DO <= GPR(4)(7 downto 0);
					when x"27" => SS_DO <= GPR(4)(15 downto 8);
					when x"28" => SS_DO <= GPR(4)(23 downto 16);
					when x"29" => SS_DO <= GPR(5)(7 downto 0);
					when x"2A" => SS_DO <= GPR(5)(15 downto 8);
					when x"2B" => SS_DO <= GPR(5)(23 downto 16);
					when x"2C" => SS_DO <= GPR(6)(7 downto 0);
					when x"2D" => SS_DO <= GPR(6)(15 downto 8);
					when x"2E" => SS_DO <= GPR(6)(23 downto 16);
					when x"2F" => SS_DO <= GPR(7)(7 downto 0);
					when x"30" => SS_DO <= GPR(7)(15 downto 8);
					when x"31" => SS_DO <= GPR(7)(23 downto 16);
					when x"32" => SS_DO <= GPR(8)(7 downto 0);
					when x"33" => SS_DO <= GPR(8)(15 downto 8);
					when x"34" => SS_DO <= GPR(8)(23 downto 16);
					when x"35" => SS_DO <= GPR(9)(7 downto 0);
					when x"36" => SS_DO <= GPR(9)(15 downto 8);
					when x"37" => SS_DO <= GPR(9)(23 downto 16);
					when x"38" => SS_DO <= GPR(10)(7 downto 0);
					when x"39" => SS_DO <= GPR(10)(15 downto 8);
					when x"3A" => SS_DO <= GPR(10)(23 downto 16);
					when x"3B" => SS_DO <= GPR(11)(7 downto 0);
					when x"3C" => SS_DO <= GPR(11)(15 downto 8);
					when x"3D" => SS_DO <= GPR(11)(23 downto 16);
					when x"3E" => SS_DO <= GPR(12)(7 downto 0);
					when x"3F" => SS_DO <= GPR(12)(15 downto 8);
					when x"40" => SS_DO <= GPR(12)(23 downto 16);
					when x"41" => SS_DO <= GPR(13)(7 downto 0);
					when x"42" => SS_DO <= GPR(13)(15 downto 8);
					when x"43" => SS_DO <= GPR(13)(23 downto 16);
					when x"44" => SS_DO <= GPR(14)(7 downto 0);
					when x"45" => SS_DO <= GPR(14)(15 downto 8);
					when x"46" => SS_DO <= GPR(14)(23 downto 16);
					when x"47" => SS_DO <= GPR(15)(7 downto 0);
					when x"48" => SS_DO <= GPR(15)(15 downto 8);
					when x"49" => SS_DO <= GPR(15)(23 downto 16);
					-- PROCESS: MUL/MAC
					when x"4A" => SS_DO <= MACL(7 downto 0);
					when x"4B" => SS_DO <= MACL(15 downto 8);
					when x"4C" => SS_DO <= MACL(23 downto 16);
					when x"4D" => SS_DO <= MACH(7 downto 0);
					when x"4E" => SS_DO <= MACH(15 downto 8);
					when x"4F" => SS_DO <= MACH(23 downto 16);
					when x"50" => SS_DO <= std_logic_vector(MULA(7 downto 0));
					when x"51" => SS_DO <= std_logic_vector(MULA(15 downto 8));
					when x"52" => SS_DO <= std_logic_vector(MULA(23 downto 16));
					when x"53" => SS_DO <= std_logic_vector(MULB(7 downto 0));
					when x"54" => SS_DO <= std_logic_vector(MULB(15 downto 8));
					when x"55" => SS_DO <= std_logic_vector(MULB(23 downto 16));
					-- PROCESS: MBR/MAR/bus
					when x"56" => SS_DO <= MAR(7 downto 0);
					when x"57" => SS_DO <= MAR(15 downto 8);
					when x"58" => SS_DO <= MAR(23 downto 16);
					when x"59" => SS_DO <= MBR;
					when x"5A" => SS_DO <= "0000000" & ROM_ACCESS;
					when x"5B" => SS_DO <= "0000000" & SRAM_ACCESS;
					when x"5C" => SS_DO <= "0000000" & SRAM_WR;
					when x"5D" => SS_DO <= "00000" & std_logic_vector(BUS_ACCESS_CNT);
					when x"5E" => SS_DO <= EXT_BUS_ADDR(7 downto 0);
					when x"5F" => SS_DO <= EXT_BUS_ADDR(15 downto 8);
					when x"60" => SS_DO <= EXT_BUS_ADDR(23 downto 16);
					-- PROCESS: ROMB
					when x"61" => SS_DO <= ROMB(7 downto 0);
					when x"62" => SS_DO <= ROMB(15 downto 8);
					when x"63" => SS_DO <= ROMB(23 downto 16);
					-- PROCESS: RAMB
					when x"64" => SS_DO <= RAMB(7 downto 0);
					when x"65" => SS_DO <= RAMB(15 downto 8);
					when x"66" => SS_DO <= RAMB(23 downto 16);
					-- PROCESS: DPR
					when x"67" => SS_DO <= DPR(7 downto 0);
					when x"68" => SS_DO <= "0000" & DPR(11 downto 8);
					-- PROCESS: P
					when x"69" => SS_DO <= P(7 downto 0);
					when x"6A" => SS_DO <= "0" & P(14 downto 8);
					-- PROCESS: MMIO regs
					when x"6B" => SS_DO <= DMA_SRC(7 downto 0);
					when x"6C" => SS_DO <= DMA_SRC(15 downto 8);
					when x"6D" => SS_DO <= DMA_SRC(23 downto 16);
					when x"6E" => SS_DO <= DMA_DST(7 downto 0);
					when x"6F" => SS_DO <= DMA_DST(15 downto 8);
					when x"70" => SS_DO <= DMA_DST(23 downto 16);
					when x"71" => SS_DO <= DMA_LEN(7 downto 0);
					when x"72" => SS_DO <= DMA_LEN(15 downto 8);
					when x"73" => SS_DO <= ROM_BASE(7 downto 0);
					when x"74" => SS_DO <= ROM_BASE(15 downto 8);
					when x"75" => SS_DO <= ROM_BASE(23 downto 16);
					when x"76" => SS_DO <= ROM_PAGE(7 downto 0);
					when x"77" => SS_DO <= "0" & ROM_PAGE(14 downto 8);
					when x"78" => SS_DO <= "0000000" & PAGE_SEL;
					when x"79" => SS_DO <= "000000" & PAGE_LOCK;
					when x"7A" => SS_DO <= "00000" & WS1;
					when x"7B" => SS_DO <= "00000" & WS2;
					when x"7C" => SS_DO <= "0000000" & ROM_MODE;
					when x"7D" => SS_DO <= "0000000" & SUSPEND;
					when x"7E" => SS_DO <= "0000000" & IRQ_EN;
					when x"7F" => SS_DO <= VEC_MEM(0);
					when x"80" => SS_DO <= VEC_MEM(1);
					when x"81" => SS_DO <= VEC_MEM(2);
					when x"82" => SS_DO <= VEC_MEM(3);
					when x"83" => SS_DO <= VEC_MEM(4);
					when x"84" => SS_DO <= VEC_MEM(5);
					when x"85" => SS_DO <= VEC_MEM(6);
					when x"86" => SS_DO <= VEC_MEM(7);
					when x"87" => SS_DO <= VEC_MEM(8);
					when x"88" => SS_DO <= VEC_MEM(9);
					when x"89" => SS_DO <= VEC_MEM(10);
					when x"8A" => SS_DO <= VEC_MEM(11);
					when x"8B" => SS_DO <= VEC_MEM(12);
					when x"8C" => SS_DO <= VEC_MEM(13);
					when x"8D" => SS_DO <= VEC_MEM(14);
					when x"8E" => SS_DO <= VEC_MEM(15);
					when x"8F" => SS_DO <= VEC_MEM(16);
					when x"90" => SS_DO <= VEC_MEM(17);
					when x"91" => SS_DO <= VEC_MEM(18);
					when x"92" => SS_DO <= VEC_MEM(19);
					when x"93" => SS_DO <= VEC_MEM(20);
					when x"94" => SS_DO <= VEC_MEM(21);
					when x"95" => SS_DO <= VEC_MEM(22);
					when x"96" => SS_DO <= VEC_MEM(23);
					when x"97" => SS_DO <= VEC_MEM(24);
					when x"98" => SS_DO <= VEC_MEM(25);
					when x"99" => SS_DO <= VEC_MEM(26);
					when x"9A" => SS_DO <= VEC_MEM(27);
					when x"9B" => SS_DO <= VEC_MEM(28);
					when x"9C" => SS_DO <= VEC_MEM(29);
					when x"9D" => SS_DO <= VEC_MEM(30);
					when x"9E" => SS_DO <= VEC_MEM(31);
					-- PROCESS: DMA FSM
					when x"9F" => SS_DO <= "0000000" & DMA_RUN;
					when x"A0" => SS_DO <= DMA_SRC_ADDR(7 downto 0);
					when x"A1" => SS_DO <= DMA_SRC_ADDR(15 downto 8);
					when x"A2" => SS_DO <= DMA_SRC_ADDR(23 downto 16);
					when x"A3" => SS_DO <= DMA_DST_ADDR(7 downto 0);
					when x"A4" => SS_DO <= DMA_DST_ADDR(15 downto 8);
					when x"A5" => SS_DO <= DMA_DST_ADDR(23 downto 16);
					when x"A6" => SS_DO <= std_logic_vector(DMA_CNT(7 downto 0));
					when x"A7" => SS_DO <= std_logic_vector(DMA_CNT(15 downto 8));
					when x"A8" => SS_DO <= "00000" & std_logic_vector(DMA_WAIT_CNT);
					when x"A9" => SS_DO <= DMA_DAT;
					when x"AA" => SS_DO <= "0000000" & DMA_STATE;
					-- PROCESS: Cache FSM
					when x"AB" => SS_DO <= "0000000" & CACHE_RUN;
					when x"AC" => SS_DO <= "0000000" & CACHE_BANK;
					when x"AD" => SS_DO <= CACHE_PAGE(0)(7 downto 0);
					when x"AE" => SS_DO <= CACHE_PAGE(0)(15 downto 8);
					when x"AF" => SS_DO <= CACHE_PAGE(1)(7 downto 0);
					when x"B0" => SS_DO <= CACHE_PAGE(1)(15 downto 8);
					when x"B1" => SS_DO <= CACHE_ADDR(7 downto 0);
					when x"B2" => SS_DO <= "0000000" & CACHE_ADDR(8);
					when x"B3" => SS_DO <= "00000" & std_logic_vector(CACHE_WAIT_CNT);
					when x"B4" => SS_DO <= CACHE_BUS_ADDR(7 downto 0);
					when x"B5" => SS_DO <= CACHE_BUS_ADDR(15 downto 8);
					when x"B6" => SS_DO <= CACHE_BUS_ADDR(23 downto 16);
					-- PROCESS: BUS_RD_CNT
					when x"B7" => SS_DO <= "000000" & std_logic_vector(BUS_RD_CNT);
					-- PROCESS: PC FSM -- EXTRA_CYCLES
					when x"B8" => SS_DO <= std_logic_vector(to_unsigned(EXTRA_CYCLES, 8));
					-- PROCESS: SNES_ADDR
					when x"B9" => SS_DO <= SNES_ADDR(7 downto 0);
					when x"BA" => SS_DO <= SNES_ADDR(15 downto 8);
					when x"BB" => SS_DO <= SNES_ADDR(23 downto 16);
					when others => SS_DO <= x"00";
				end case;
			end if;
		end if;
	end process;

	CACHE_ADDR_RD <= BANK & PC;
	CACHE_ADDR_WR <= CACHE_BANK & CACHE_ADDR;
	CACHE_WE <= '1' when CACHE_RUN = '1' and EN = '1' and CACHE_WAIT_CNT = unsigned(WS1) else '0';
	CACHE_DI <= BUS_DI;

	-- Cache port mux: during SS the program cache is serialized byte-for-byte over
	-- SS_CACHE_*; otherwise the normal CPU read / fill-FSM write paths drive it.
	-- SS_CACHE_A(0) = L('0')/H('1) lane select, SS_CACHE_A(9:1) = 9-bit cache index.
	CACHE_RDADDR <= SS_CACHE_A(9 downto 1) when SS_BUSY = '1' else CACHE_ADDR_RD;
	CACHE_WRADDR <= SS_CACHE_A(9 downto 1) when SS_BUSY = '1' else CACHE_ADDR_WR(9 downto 1);
	CACHE_WDATA  <= SS_CACHE_DI            when SS_BUSY = '1' else CACHE_DI;
	CACHEL_WE    <= (SS_CACHE_WR and not SS_CACHE_A(0)) when SS_BUSY = '1'
	              else (CACHE_WE and not CACHE_ADDR_WR(0));
	CACHEH_WE    <= (SS_CACHE_WR and SS_CACHE_A(0))     when SS_BUSY = '1'
	              else (CACHE_WE and CACHE_ADDR_WR(0));
	SS_CACHE_DO  <= CACHE_Q_H when SS_CACHE_A(0) = '1' else CACHE_Q_L;

	CACHEL : entity work.cx4cache
	port map(
		clock			=> CLK,
		wraddress	=> CACHE_WRADDR,
		data			=> CACHE_WDATA,
		wren			=> CACHEL_WE,
		rdaddress	=> CACHE_RDADDR,
		q				=> CACHE_Q_L
	);

	CACHEH : entity work.cx4cache
	port map(
		clock			=> CLK,
		wraddress	=> CACHE_WRADDR,
		data			=> CACHE_WDATA,
		wren			=> CACHEH_WE,
		rdaddress	=> CACHE_RDADDR,
		q				=> CACHE_Q_H
	);
	
end rtl;

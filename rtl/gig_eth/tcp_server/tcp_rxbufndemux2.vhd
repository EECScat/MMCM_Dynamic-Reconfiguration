-------------------------------------------------------------
-- MSS copyright 2014
--	Filename:  TCP_RXBUFNDEMUX2.VHD
-- Author: Alain Zarembowitch / MSS
--	Version: 1
--	Date last modified: 2/18/14 AZ
-- Inheritance: 	TCP_RXBUFNDEMUX.vhd rev4 1/31/14
--
-- description:  This component has two objectives:
-- (1) tentatively hold a received TCP frame on the fly until its validity is confirmed at the end of frame.
-- Discard if invalid or further process if valid.
-- (2) demultiplex multiple TCP streams, based on the destination port number
--
-- Because of the TCP protocol, data can only be validated at the end of a packet.
-- So the buffer management has to be able to backtrack, discard previous data and 
-- reposition pointer. 
--
-- The overall buffer size (which affects overall throughput) is user selected in the generic section.
-- This component is written of a single TCP stream.
--
-- This component is written for NTCPSTREAMS TCP tx streams. Adjust as needed in the com5402pkg package.
-- 
-- Note: This component should work in all application case, at the expense of many block RAM. 
-- Use the more efficient TCP_RXBUFNDEMUX only when the application is reading data faster than the data source
-- and when RAMBs are at a premium.
---------------------------------------------------------------
library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;
use IEEE.STD_LOGIC_UNSIGNED.ALL;
use work.com5402pkg.all;	-- defines global types, number of TCP streams, etc

entity TCP_RXBUFNDEMUX2 is
	generic (
		NBUFS: integer := 4
			-- number of 16Kb dual-port RAM buffers instantiated within for each stream.
			-- Trade-off buffer depth and overall TCP throughput.
			-- Valid values: 1,2,4,8
			-- Total number of RAMB16 used within is thus NBUFS*NTCPSTREAMS
			-- Recommended value for GbE: at least 4
	);
    Port ( 
		--// CLK, RESET
		SYNC_RESET: in std_logic;
		CLK: in std_logic;		-- synchronous clock	
			-- Must be global clocks. No BUFG instantiation within this component.

		--// TCP RX protocol -> RX BUFFER 
		RX_DATA: in std_logic_vector(7 downto 0);
			-- TCP payload data field when RX_DATA_VALID = '1'
		RX_DATA_VALID: in std_logic;
			-- delineates the TCP payload data field
		RX_SOF: in std_logic;
			-- 1st byte of RX_DATA
			-- Read ancillary information at this time:
			-- (a) destination RX_STREAM_NO (based on the destination TCP port)
		RX_STREAM_NO: in integer range 0 to (NTCPSTREAMS-1);
			-- output port based on the destination TCP port
			-- maximum range 0 - 255
		RX_EOF: in std_logic;
			-- 1 CLK pulse indicating that RX_DATA is the last byte in the TCP data field.
			-- ALWAYS CHECK RX_DATA_VALID at the end of packet (RX_EOF = '1') to confirm
			-- that the TCP packet is valid. 
			-- Note: All packet information stored is tentative until
			-- the entire frame is confirmed (RX_EOF = '1') and (RX_DATA_VALID = '1').
			-- MSbs are dropped.
			-- If the frame is invalid, the data and ancillary information just received is discarded.
			-- Reason: we only knows about bad TCP packets at the end.
		RX_FREE_SPACE: out SLV16xNTCPSTREAMStype;
			-- buffer available space, expressed in bytes. 
			-- Beware of delay (as data may be in transit and information is slightly old).
		
		--// RX BUFFER -> APPLICATION INTERFACE
		-- NTCPSTREAMS can operate independently and concurrently. No scheduling arbitration needed here.
		RX_APP_DATA: out SLV8xNTCPSTREAMStype;
		RX_APP_DATA_VALID: out std_logic_vector((NTCPSTREAMS-1) downto 0);
		RX_APP_SOF: out std_logic_vector((NTCPSTREAMS-1) downto 0);
		RX_APP_EOF: out std_logic_vector((NTCPSTREAMS-1) downto 0);
		RX_APP_RTS: out std_logic_vector((NTCPSTREAMS-1) downto 0);
		RX_APP_CTS: in std_logic_vector((NTCPSTREAMS-1) downto 0);

		TP: out std_logic_vector(10 downto 1)

			);
end entity;

architecture Behavioral of TCP_RXBUFNDEMUX2 is
--------------------------------------------------------
--      COMPONENTS
--------------------------------------------------------
	COMPONENT BRAM_DP
	GENERIC(
		DATA_WIDTHA: integer;
		ADDR_WIDTHA: integer;
		DATA_WIDTHB: integer;
		ADDR_WIDTHB: integer
	);
	PORT(
	    CLKA   : in  std_logic;
	    WEA    : in  std_logic;
	    ADDRA  : in  std_logic_vector(ADDR_WIDTHA-1 downto 0);
	    DIA   : in  std_logic_vector(DATA_WIDTHA-1 downto 0);
	    DOA  : out std_logic_vector(DATA_WIDTHA-1 downto 0);
	    CLKB   : in  std_logic;
	    WEB    : in  std_logic;
	    ADDRB  : in  std_logic_vector(ADDR_WIDTHB-1 downto 0);
	    DIB   : in  std_logic_vector(DATA_WIDTHB-1 downto 0);
	    DOB  : out std_logic_vector(DATA_WIDTHB-1 downto 0)
		);
	END COMPONENT;
--------------------------------------------------------
--     SIGNALS
--------------------------------------------------------
-- freeze ancilliary input data at the SOF
signal RX_STREAM_NO_D: integer range 0 to (NTCPSTREAMS-1);

--//-- ELASTIC BUFFER ---------------------------
signal RX_DATA_D: std_logic_vector(7 downto 0) := (others => '0');
signal RX_DATA_VALID_D: std_logic := '0';
signal RX_SOF_D: std_logic := '0';
signal RX_EOF_D: std_logic := '0';
signal WPTR: std_logic_vector(13 downto 0) := (others => '0');
signal WPTR_MEMINDEX: std_logic_vector(2 downto 0) := "000";
signal PTR_MASK: std_logic_vector(13 downto 0) := (others => '1');
type WEtype is array (integer range 0 to (NTCPSTREAMS-1)) of std_logic_vector((NBUFS-1) downto 0);
signal WEA: WEtype;
signal DIA: std_logic_vector(8 downto 0) := (others => '0');
type PTRtype is array (integer range 0 to (NTCPSTREAMS-1)) of std_logic_vector(13 downto 0);
signal WPTR0: PTRtype := (others => (others => '0'));
signal WPTR_CONFIRMED: PTRtype := (others => (others => '0'));
signal RPTR: PTRtype := (others => (others => '0'));
signal BUF_SIZE: PTRtype := (others => (others => '0'));
type MEMINDEXtype is array (integer range 0 to (NTCPSTREAMS-1)) of std_logic_vector(2 downto 0);
signal RPTR_MEMINDEX: MEMINDEXtype := (others => (others => '0'));
signal RPTR_MEMINDEX_D: MEMINDEXtype := (others => (others => '0'));
type DOBtype is array(integer range 0 to (NTCPSTREAMS-1),integer range 0 to (NBUFS-1)) of std_logic_vector(8 downto 0);
signal DOB: DOBtype;
signal DOB_VALID_E: std_logic_vector((NTCPSTREAMS-1) downto 0) := (others => '0');
signal DOB_VALID: std_logic_vector((NTCPSTREAMS-1) downto 0) := (others => '0');

--------------------------------------------------------
--      IMPLEMENTATION
--------------------------------------------------------
begin

-- freeze ancilliary data at the SOF
FREEZE_INPUT: process(CLK) 
begin
	if rising_edge(CLK) then
		if(RX_SOF = '1') then
			RX_STREAM_NO_D <= RX_STREAM_NO;
		end if;
	end if;
end process;

--//-- ELASTIC BUFFER ---------------------------
-- write pointer management. 
-- Definition: next memory location to be written to.
WPTR_GEN_001: process(CLK)
begin
	if rising_edge(CLK) then
		RX_DATA_D <= RX_DATA;
		RX_DATA_VALID_D <= RX_DATA_VALID;
		RX_SOF_D <= RX_SOF;
		RX_EOF_D <= RX_EOF;

		if(SYNC_RESET = '1') then
			WPTR <= (others => '0');
			WPTR_CONFIRMED <= (others => (others => '0'));
		elsif(RX_SOF = '1') then
			-- for each received frame, position the write pointer as per the last confirmed pointer position
			WPTR <= WPTR_CONFIRMED(RX_STREAM_NO);
		elsif(RX_DATA_VALID = '1') then
			WPTR <= (WPTR + 1) and PTR_MASK;
		end if;
		 
		if(RX_EOF_D = '1') and (RX_DATA_VALID_D = '1') then
			-- last frame confirmed valid. Remember the writer position (next location to write to)
			WPTR_CONFIRMED(RX_STREAM_NO_D) <= (WPTR + 1) and PTR_MASK;
		end if;
	end if;
end process;

-- remember the wptr for each stream (we need it to compute free space)
WPTR_GEN_002x: FOR I in 0 to (NTCPSTREAMS-1) generate
	WPTR_GEN_002: process(CLK)
	begin
		if rising_edge(CLK) then
			if(SYNC_RESET = '1') then
				WPTR0(I) <= (others => '0');
			elsif(I = RX_STREAM_NO_D) and (RX_DATA_VALID_D = '1') then
				WPTR0(I) <= (WPTR + 1) and PTR_MASK;
			end if;
		end if;
	end process;
end generate;


-- Mask upper address bits, depending on the memory depth (1,2,4, or 8 RAMblocks)
WPTR_MEMINDEX <= WPTR(13 downto 11) when (NBUFS = 8) else
				"0" & WPTR(12 downto 11) when (NBUFS = 4) else
				"00" & WPTR(11 downto 11) when (NBUFS = 2) else
				"000"; -- when  (NBUFS = 1) 

PTR_MASK <= "11111111111111" when (NBUFS = 8) else
				"01111111111111" when (NBUFS = 4) else
				"00111111111111" when (NBUFS = 2) else
				"00011111111111"; -- when  (NBUFS = 1) 

-- select which RAMBlock to write to.
WEA_GENx: FOR I in 0 to (NTCPSTREAMS-1) generate
	WEA_GEN_001: process(RX_STREAM_NO_D, WPTR_MEMINDEX, RX_DATA_VALID_D)
	begin
		for J in 0 to (NBUFS -1) loop
			if(RX_STREAM_NO_D = I) and (WPTR_MEMINDEX = J) then	-- range 0 through 7
				WEA(I)(J) <= RX_DATA_VALID_D;
			else
				WEA(I)(J) <= '0';
			end if;
		end loop;
	end process;
end generate;

-- 1,2,4, or 8 RAM blocks.
DIA <= RX_EOF_D & RX_DATA_D;
RAMB_16_S9_S9_X: for I in 0 to (NTCPSTREAMS-1) generate
	RAMB_16_S9_S9_Y: for J in 0 to (NBUFS-1) generate
		-- 18Kbit buffer(s) 
		RAMB16_S9_S9_001: BRAM_DP 
		GENERIC MAP(
			DATA_WIDTHA => 9,		
			ADDR_WIDTHA => 11,
			DATA_WIDTHB => 9,		 
			ADDR_WIDTHB => 11

		)
		PORT MAP(
			CLKA => CLK,
			WEA => WEA(I)(J),      -- Port A Write Enable Input
			ADDRA => WPTR(10 downto 0),  -- Port A 11-bit Address Input
			DIA => DIA,      -- Port A 9-bit Data Input
			DOA => open,
			CLKB => CLK,
			WEB => '0',
			ADDRB => RPTR(I)(10 downto 0),  -- Port B 11-bit Address Input
			DIB => "000000000",      -- Port B 9-bit Data Input
			DOB => DOB(I,J)      -- Port B 9-bit Data Output
		);
	end generate;
end generate;

-- Mask upper address bits, depending on the memory depth (1,2,4, or 8 RAMblocks)
RPTR_MEMINDEXx: FOR I in 0 to (NTCPSTREAMS-1) generate
	RPTR_MEMINDEX(I) <= RPTR(I)(13 downto 11) when (NBUFS = 8) else
					"0" & RPTR(I)(12 downto 11) when (NBUFS = 4) else
					"00" & RPTR(I)(11 downto 11) when (NBUFS = 2) else
					"000"; -- when  (NBUFS = 1) 
end generate;

-- How many bytes are waiting to be read? 
RX_BUFFER_SIZE_GENx: for I in 0 to (NTCPSTREAMS - 1) generate
	BUF_SIZE(I) <= (WPTR_CONFIRMED(I) + (not RPTR(I))) and PTR_MASK;
	-- tell the application when data is available to read
	RX_APP_RTS(I) <= '0' when (BUF_SIZE(I) = 0) else '1';
end generate;

-- read pointer management
-- Rule #1: RPTR points to the next memory location to be read
RPTR_GENx: FOR I in 0 to (NTCPSTREAMS-1) generate
	RPTR_GEN_001: process(CLK)
	begin
		if rising_edge(CLK) then
			RPTR_MEMINDEX_D(I) <= RPTR_MEMINDEX(I);	-- one CLK delay to read data from block RAM
			DOB_VALID(I) <= DOB_VALID_E(I);
			
			if(SYNC_RESET = '1') then
				RPTR(I) <= (others => '1');
			elsif(BUF_SIZE(I) /= 0) and (RX_APP_CTS(I) = '1') then
				RPTR(I) <= (RPTR(I) + 1) and PTR_MASK;
				DOB_VALID_E(I) <= '1';
			else
				DOB_VALID_E(I) <= '0';
			end if;
		end if;
	end process;
end generate;

-- mux
RECLOCK_OUTPUT_00X: FOR I in 0 to (NTCPSTREAMS-1) generate
	RECLOCK_OUTPUT_001: process(CLK)
		begin
			if rising_edge(CLK) then
				RX_APP_DATA(I) <= DOB(I,to_integer(unsigned(RPTR_MEMINDEX_D(I))))(7 downto 0);
				RX_APP_EOF(I) <= DOB(I,to_integer(unsigned(RPTR_MEMINDEX_D(I))))(8);
				RX_APP_DATA_VALID(I) <= DOB_VALID(I);
				
				-- report the worst case available space to the TCP engine (including space currently occupied by invalid frames)
				RX_FREE_SPACE(I) <= "00" & ((RPTR(I) - WPTR0(I)) and PTR_MASK);
			end if;
	end process;
end generate;

end Behavioral;

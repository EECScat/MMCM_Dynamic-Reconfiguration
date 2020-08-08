-------------------------------------------------------------
-- MSS copyright 2011-2014
--	Filename:  TCP_TXBUF.VHD
-- Author: Alain Zarembowitch / MSS
--	Version: 6
--	Date last modified: 2/14/14
-- Inheritance: 	n/a
--
-- description:  Buffer management for the transmit TCP payload data.
-- Payload data and partial checksum computation has to be ready immediately when requested by the TCP 
-- protocol engine (TCP_SERVER.vhd).
-- This component segments the data stream into packets, raises the Ready-To-Send flag (RTS) and waits
-- for trigger from the TCP protocol engine.
-- The input stream is segmented into data packets. The packet transmission
-- is triggered when one of two events occur:
-- (a) full packet: the number of bytes waiting for transmission is greater than or equal to MSS = MTU-40 = 1460 for ethernet
-- or, if less, the effective rx window as defined in the TCP protocol. 
-- (b) no-new-input timeout: there are a few bytes waiting for transmission but no new input 
-- bytes were received in the last 200us (or adjust constant TX_IDLE_TIMEOUT within).
-- The overall buffer size (which affects overall throughput) is user selected in the generic section.
-- This component is written for NTCPSTREAMS TCP tx streams. Adjust as needed in the com5401pkg package.
--
-- A frame is ready for transmission when 
-- (a) the effective client rx window size is non-zero
-- (b) the tx buffer contains either the effective client rx window size or MSS bytes or no new data received in the last 200us
--
-- Rev 2 11/2/11 AZ
-- Corrected bug (undefined RPTR_MEMINDEX) when multiple elastic buffers are instantiated (NBUFS > 1).
--
-- Rev 3 11/4/11 AZ
-- Corrected bug (missing 1st tx byte)
--
-- Rev 4 10/11/13 AZ
-- Encapsulated block RAM for easier porting to other FPGA types
-- Transition from ASYNC_RESET to SYNC_RESET
--
-- Rev 5 1/25/14 AZ
-- correction: account for EFF_RX_WINDOW_SIZE going temporarily negative
-- Increased EFF_RX_WINDOW_SIZE_PARTIAL precision to 17 bits to detect abnormal negative window size reports
-- 
-- Rev 6 1/31/14 AZ
-- Updated sensitivity lists.
-- moved TX_IDLE_TIMEOUT up to a generic parameter.
---------------------------------------------------------------
library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.STD_LOGIC_ARITH.ALL;
use IEEE.STD_LOGIC_UNSIGNED.ALL;
use work.com5402pkg.all;	-- defines global types, number of TCP streams, etc

entity TCP_TXBUF is
	generic (
		NBUFS: integer := 4;
			-- number of 16Kb dual-port RAM buffers instantiated within for each stream.
			-- Trade-off buffer depth and overall TCP throughput.
			-- Valid values: 1,2,4,8
			-- Total number of RAMB16 used within is thus NBUFS*NTCPSTREAMS
			-- Recommended value for GbE: at least 4
		TX_IDLE_TIMEOUT: integer range 0 to 50:= 50;	
			-- inactive input timeout, expressed in 4us units. -- 50*4us = 200us 
			-- Controls the transmit stream segmentation: data in the elastic buffer will be transmitted if
			-- no input is received within TX_IDLE_TIMEOUT, without waiting for the transmit frame to be filled with MSS data bytes.
		MSS: std_logic_vector(15 downto 0) := x"05B4"
			-- The Maximum Segment Size (MSS) is the largest segment of TCP data that can be transmitted.
			-- Fixed as the Ethernet MTU (Maximum Transmission Unit) of 1500 bytes - 40 overhead bytes = 1460 bytes.
	);
    Port ( 
		--// CLK, RESET
		SYNC_RESET: in std_logic;
		CLK: in std_logic;		-- synchronous clock
			-- Must be a global clocks. No BUFG instantiation within this component.
		TICK_4US: in std_logic;
			-- 1 CLK-wide pulse every 4us

		--// APPLICATION INTERFACE -> TX BUFFER
		-- NTCPSTREAMS can operate independently and concurrently. No scheduling arbitration needed here.
		APP_DATA: in SLV8xNTCPSTREAMStype;
		APP_DATA_VALID: in std_logic_vector((NTCPSTREAMS-1) downto 0);
		APP_CTS: out std_logic_vector((NTCPSTREAMS-1) downto 0);	
			-- Clear To Send = transmit flow control. 
			-- App is responsible for checking the CTS signal before sending APP_DATA

		--// TX BUFFER <-> TX TCP protocol layer
		-- Part I: control path to/from TCP_SERVER engine
		-- (a) TCP_SERVER sends rx window information upon receiving an ACK from the TCP client
		-- Partial computation (rx window size + RX_TCP_ACK_NO)
		EFF_RX_WINDOW_SIZE_PARTIAL_IN: in std_logic_vector(16 downto 0);
		EFF_RX_WINDOW_SIZE_PARTIAL_STREAM: in integer range 0 to (NTCPSTREAMS-1) := 0;
		EFF_RX_WINDOW_SIZE_PARTIAL_VALID: in std_logic; -- 1 CLK-wide pulse to indicate that the above information is valid
		-- (b)  TCP_SERVER sends location of next frame start. Warning: could rewind to an earlier location.
		TX_SEQ_NO_IN: in SLV17xNTCPSTREAMStype;
		-- (c) for tx flow-control purposes, last acknowledged tx byte location
		RX_TCP_ACK_NO_D: in SLV17xNTCPSTREAMStype;

		-- (d) TCP_SERVER reports about TCP connection state. 
		-- '1' when TCP-IP connection is in the 'connected' state, 0 otherwise
		-- Do not store tx data until a connection is established
		CONNECTED_FLAG: in std_logic_vector((NTCPSTREAMS-1) downto 0);
		-- (e) upon reaching TCP_TX_STATE = 2, tell the TCP protocol engine (TCP_SERVER) 
		-- which stream is ready to send data next, i.e. meets the following criteria:
		-- (1) MSS bytes, or a lower size that meets the client effective rx window size, ready to send, OR
		-- (2) some data to be sent but no additional data received in the last 200us
		TX_STREAM_SEL: out integer range 0 to (NTCPSTREAMS-1) := 0;	
			-- valid only when TX_PAYLOAD_RTS = '1', ignore otherwise
		TX_PAYLOAD_RTS: out std_logic;
			-- '1' when at least one stream has payload data available for transmission.
		TX_PAYLOAD_CHECKSUM: out std_logic_vector(16 downto 0);
			-- partial TCP checksum computation. payload only, no header. bit 16 is the carry, add later.
			-- valid only when TX_PAYLOAD_RTS = '1', ignore otherwise
		TX_PAYLOAD_SIZE: out std_logic_vector(10 downto 0);
			-- payload size in bytes for the next tx frame
			-- valid only when TX_PAYLOAD_RTS = '1', ignore otherwise
			-- range is 0 - MSS 

		-- Part II: data path to TCP_TX for frame formatting
		TX_PAYLOAD_CTS: in std_logic;
			-- clear to send payload data: go ahead signal for forwarding data from the TX_STREAM_SEL stream
			-- to the TCP_TX component responsible for formatting the next transmit packet.
			-- 2 CLK latency until 1st data byte is available at TX_PAYLOAD_DATA
		TX_PAYLOAD_DATA: out std_logic_vector(7 downto 0);
			-- TCP payload data field when TX_PAYLOAD_DATA_VALID = '1'
		TX_PAYLOAD_DATA_VALID: out std_logic;
			-- delineates the TCP payload data field
		MAC_TX_EOF: in std_logic;	-- need to know when packet tx is complete

		TP: out std_logic_vector(10 downto 1)

			);
end entity;

architecture Behavioral of TCP_TXBUF is
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

--//-- INPUT IDLE DETECTION ---------------------------
type CNTRtype is array (integer range 0 to (NTCPSTREAMS-1)) of integer range 0 to 50;
signal TX_IDLE_TIMER: CNTRtype := (others => TX_IDLE_TIMEOUT);
signal TX_IDLE: std_logic_vector((NTCPSTREAMS-1) downto 0) := (others => '0');

--//-- ELASTIC BUFFER ---------------------------
signal DIA: SLV9xNTCPSTREAMStype := (others => (others => '0'));
signal PTR_MASK: std_logic_vector(13 downto 0) := (others => '1');
type PTRtype is array (integer range 0 to (NTCPSTREAMS-1)) of std_logic_vector(13 downto 0);
signal WPTR: PTRtype := (others => (others => '0'));
signal RPTR: PTRtype := (others => (others => '0'));
signal RPTR_D: PTRtype := (others => (others => '0'));
signal BUF_SIZE: PTRtype := (others => (others => '0'));
signal NEXT_TX_FRAME_SIZE: PTRtype := (others => (others => '0'));
signal AVAILABLE_BUF_SPACE: PTRtype := (others => (others => '0'));
type WEtype is array (integer range 0 to (NTCPSTREAMS-1)) of std_logic_vector((NBUFS-1) downto 0);
signal WEA: WEtype;
type MEMINDEXtype is array (integer range 0 to (NTCPSTREAMS-1)) of std_logic_vector(2 downto 0);
signal WPTR_MEMINDEX: MEMINDEXtype := (others => (others => '0'));
signal RPTR_MEMINDEX_E: MEMINDEXtype := (others => (others => '0'));
signal RPTR_MEMINDEX: MEMINDEXtype := (others => (others => '0'));
signal APP_CTS_local: std_logic_vector((NTCPSTREAMS-1) downto 0) := (others => '0');
signal CONNECTED_FLAG_D: std_logic_vector((NTCPSTREAMS-1) downto 0) := (others => '0');
signal CONNECTED_FLAG_D2: std_logic_vector((NTCPSTREAMS-1) downto 0) := (others => '0');

--// SEGMENT INPUT DATA INTO PACKETS 
signal SAMPLE2_CLK: std_logic_vector((NTCPSTREAMS-1) downto 0) := (others => '0');
signal SAMPLE3_CLK: std_logic_vector((NTCPSTREAMS-1) downto 0) := (others => '0');
signal TX_STREAM_SEL_local: integer range 0 to (NTCPSTREAMS-1) := 0;
type DOBtype is array(integer range 0 to (NTCPSTREAMS-1),integer range 0 to (NBUFS-1)) of std_logic_vector(8 downto 0);
signal DOB: DOBtype;
signal TX_PAYLOAD_DATA_local: std_logic_vector(7 downto 0) := x"00";

--// TCP_SERVER INTERFACE ------------------------
signal EFF_RX_WINDOW_SIZE: SLV17xNTCPSTREAMStype := (others => (others => '0'));
signal EFF_RX_WINDOW_SIZE_MSB: std_logic_vector((NTCPSTREAMS-1) downto 0) := (others => '0'); 
signal EFF_RX_WINDOW_SIZE_PARTIAL: SLV17xNTCPSTREAMStype := (others => (others => '0'));
signal TX_SEQ_NO: SLV17xNTCPSTREAMStype := (others => (others => '0'));

--// TCP TX CHECKSUM  ---------------------------
signal TX_DATA: SLV8xNTCPSTREAMStype := (others => (others => '0'));
signal TX_DATA_D: SLV8xNTCPSTREAMStype := (others => (others => '0'));
signal TX_TCP_CHECKSUM: SLV17xNTCPSTREAMStype := (others => (others => '0'));
signal ODD_EVENn: std_logic_vector((NTCPSTREAMS-1) downto 0) := (others => '0');
 


--// TCP TX STATE MACHINE ---------------------------
type STATEtype is array (integer range 0 to (NTCPSTREAMS-1)) of integer range 0 to 6;
signal TCP_TX_STATE: STATEtype;
type TIMERtype is array (integer range 0 to (NTCPSTREAMS-1)) of integer range 0 to 6;
signal TIMER: TIMERtype;


--------------------------------------------------------
--      IMPLEMENTATION
--------------------------------------------------------
begin

--// SEGMENT INPUT DATA INTO PACKETS -----------------

-- Raise a flag when no new Tx data is received in the last 200 us. 
-- Keep track for each stream.
TX_IDLE_GENx: FOR I in 0 to (NTCPSTREAMS-1) generate
	TX_IDLE_GEN_001: process(CLK)
	begin
		if rising_edge(CLK) then
			if(SYNC_RESET = '1') then
				TX_IDLE_TIMER(I) <= TX_IDLE_TIMEOUT;
			elsif(APP_DATA_VALID(I) = '1') then
				-- new transmit data, reset counter
				--TX_IDLE_TIMER(I) <= 1;	-- TEST TEST TEST FOR SIMULATION PURPOSES ONLY
				TX_IDLE_TIMER(I) <= TX_IDLE_TIMEOUT;
			elsif(TICK_4US = '1') and (TX_IDLE_TIMER(I) /= 0) then
				-- otherwise, decrement until counter reaches 0 (TX_IDLE condition)
				TX_IDLE_TIMER(I) <= TX_IDLE_TIMER(I) -1;
			end if;
		end if;
	end process;

	TX_IDLE(I) <= '1' when (TX_IDLE_TIMER(I) = 0) and (APP_DATA_VALID(I) = '0') else '0';
end generate;

--//-- INPUT ELASTIC BUFFER ---------------------------
-- write pointer management. One for each stream.
-- Definition: next memory location to be written to.
WPTR_GENx: FOR I in 0 to (NTCPSTREAMS-1) generate
	WPTR_GEN_001: process(CLK)
	begin
		if rising_edge(CLK) then
			if(SYNC_RESET = '1') then
				WPTR(I) <= (others => '0');
			elsif(CONNECTED_FLAG(I) = '0') then
				-- no TCP-IP connection yet. Do not write into tx elastic buffer.
			elsif(CONNECTED_FLAG_D(I) = '0') then
				-- start of connection. TX_SEQ_NO_IN is ready to be read.
				-- Pre-position the write and read memory pointers so that the addresses are consistent with the 
				-- TCP sequence numbers (which start with a random initial sequence number upon establishing a TCP connection).
				WPTR(I) <= TX_SEQ_NO_IN(I)(13 downto 0) and PTR_MASK;
			elsif(APP_DATA_VALID(I) = '1') then
				WPTR(I) <= (WPTR(I) + 1) and PTR_MASK;
			end if;
		end if;
	end process;
end generate;

-- Mask upper address bits, depending on the memory depth (1,2,4, or 8 RAMblocks)
WPTR_MEMINDEXx: FOR I in 0 to (NTCPSTREAMS-1) generate
	WPTR_MEMINDEX(I) <= WPTR(I)(13 downto 11) when (NBUFS = 8) else
					"0" & WPTR(I)(12 downto 11) when (NBUFS = 4) else
					"00" & WPTR(I)(11 downto 11) when (NBUFS = 2) else
					"000"; -- when  (NBUFS = 1) 
end generate;

PTR_MASK <= "11111111111111" when (NBUFS = 8) else
				"01111111111111" when (NBUFS = 4) else
				"00111111111111" when (NBUFS = 2) else
				"00011111111111"; -- when  (NBUFS = 1) 

-- select which RAMBlock to write to.
WEA_GENx: FOR I in 0 to (NTCPSTREAMS-1) generate
	WEA_GEN_001: process(WPTR_MEMINDEX, APP_DATA_VALID)
	begin
		for J in 0 to (NBUFS -1) loop
			if(WPTR_MEMINDEX(I) = J) then	-- range 0 through 7
				WEA(I)(J) <= APP_DATA_VALID(I);
			else
				WEA(I)(J) <= '0';
			end if;
		end loop;
	end process;
end generate;

-- 1,2,4, or 8 RAM blocks.
RAMB_16_S9_S9_X: for I in 0 to (NTCPSTREAMS-1) generate
	DIA(I) <= APP_DATA(I) & "0";
	RAMB_16_S9_S9_Y: for J in 0 to (NBUFS-1) generate
		-- 16Kbit buffer(s) 
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
			ADDRA => WPTR(I)(10 downto 0),  -- Port A 11-bit Address Input
			DIA => DIA(I),      -- Port A 9-bit Data Input
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
	RPTR_MEMINDEX_E(I) <= RPTR(I)(13 downto 11) when (NBUFS = 8) else
					"0" & RPTR(I)(12 downto 11) when (NBUFS = 4) else
					"00" & RPTR(I)(11 downto 11) when (NBUFS = 2) else
					"000"; -- when  (NBUFS = 1) 
end generate;

-- read pointer management
-- Rule #1: RPTR = TX_SEQ_NO(I)(13:0)
-- Rule #2: RPTR points to the next memory location to be read
-- Rule #3: Clear all data within the elastic buffer after closing TCP connection
RPTR_GENx: FOR I in 0 to (NTCPSTREAMS-1) generate
	RPTR_GEN_001: process(CLK)
	begin
		if rising_edge(CLK) then
			if(SYNC_RESET = '1') then
				RPTR(I) <= (others => '0');
				SAMPLE2_CLK(I) <= '0';	-- SAMPLE2_CLK is reserved for TCP checksum bytes. 
				SAMPLE3_CLK(I) <= '0';	-- SAMPLE3_CLK is reserved for sending TCP payload data to TCP_TX formatting component.
			else
				RPTR_MEMINDEX(I) <= RPTR_MEMINDEX_E(I); 	-- one CLK delay to read data from the block RAM
				RPTR_D(I) <= RPTR(I);
				
				if(TCP_TX_STATE(I) = 0) then
					-- idle state. pre-position the read pointer at the start of the next frame
					RPTR(I) <= (TX_SEQ_NO_IN(I)(13 downto 0)) and PTR_MASK;
				elsif(TCP_TX_STATE(I) = 1) then
					-- 1st pass: scan next frame to compute payload checksum
					if(((RPTR(I) - TX_SEQ_NO(I)(13 downto 0)) and PTR_MASK) < NEXT_TX_FRAME_SIZE(I)) then
						-- continue scanning through next frame
						RPTR(I) <= (RPTR(I) + 1) and PTR_MASK;
						SAMPLE2_CLK(I) <= '1';
					else
						-- completed checksum scan. 
						SAMPLE2_CLK(I) <= '0';
					end if;
				elsif(TCP_TX_STATE(I) = 2) then
					-- data waiting to be read. awaiting TCP SERVER "clear to send"
					-- Pre-position the read pointer at the start of the next frame
					RPTR(I) <= (TX_SEQ_NO(I)(13 downto 0)) and PTR_MASK;

				elsif(TCP_TX_STATE(I) = 3) then
					-- 2nd pass: scan next frame while sending data to TCP_TX for frame formatting
					if(((RPTR(I) - TX_SEQ_NO(I)(13 downto 0)) and PTR_MASK) < NEXT_TX_FRAME_SIZE(I)) then
						-- continue scanning through next frame
						RPTR(I) <= (RPTR(I) + 1) and PTR_MASK;
						SAMPLE3_CLK(I) <= '1';
					else
						-- completed 2nd read scan. 
						SAMPLE3_CLK(I) <= '0';
					end if;

				else
					-- nothing to read
					SAMPLE2_CLK(I) <= '0';
					SAMPLE3_CLK(I) <= '0';
				end if;
			end if;
		end if;
	end process;
end generate;


--// TCP TX CHECKSUM  ---------------------------
-- Compute the TCP payload checksum (excluding headers which are included in the TCP_TX formatting component).
-- This partial checksum is ready 1(even number of bytes in payload) or 2 (odd number) into TCP_TX_STATE = 2.
-- This delay is ok since it takes us at least 1 CLK to select which stream to send next, then the TCP_SERVER has
-- to think for a few CLKs. So the checksum will always be ready when needed.
TCP_TX_CHECKSUM_GENx: FOR I in 0 to (NTCPSTREAMS-1) generate

	TX_DATA(I) <= DOB(I,conv_integer(RPTR_MEMINDEX(I)))(8 downto 1) when (SAMPLE2_CLK(I) = '1') else x"00";	-- pad last odd byte with a zero byte

	TCP_TX_CHECKSUM_GEN_001: process(CLK)
	begin
		if rising_edge(CLK) then
			if(SYNC_RESET = '1') then
				TX_TCP_CHECKSUM(I) <= (others => '0');
				ODD_EVENn(I) <= '0';
			elsif(TCP_TX_STATE(I) = 0) then
				-- idle state. clear checksum
				TX_TCP_CHECKSUM(I) <= (others => '0');
				ODD_EVENn(I) <= '0';
			elsif(SAMPLE2_CLK(I) = '1') then
				ODD_EVENn(I) <= not ODD_EVENn(I);	-- toggle odd/even
				if(ODD_EVENn(I) = '0') then
					TX_DATA_D(I) <= TX_DATA(I);
				else
					TX_TCP_CHECKSUM(I) <= ("0" & TX_TCP_CHECKSUM(I)(15 downto 0)) + 
											 (x"0000" & TX_TCP_CHECKSUM(I)(16)) +
											 ("0" & TX_DATA_D(I) & TX_DATA(I)); 
				end if;
			elsif(ODD_EVENn(I) = '1') then
				-- odd number of bytes in the TCP payload. Pad on the right with zeros and sum one last time.
				ODD_EVENn(I) <= not ODD_EVENn(I);	-- toggle odd/even
				TX_TCP_CHECKSUM(I) <= ("0" & TX_TCP_CHECKSUM(I)(15 downto 0)) + 
										 (x"0000" & TX_TCP_CHECKSUM(I)(16)) +
										 ("0" & TX_DATA_D(I) & TX_DATA(I)); 
			end if;
		end if;
	end process;
end generate;


--// TCP_SERVER INTERFACE ------------------------
-- Freeze TX_SEQ_NO when TCP_TX_STATE is idle (0)
FREEZE_TX_SEQ_NO_x: for I in 0 to (NTCPSTREAMS - 1) generate
	FREEZE_TX_SEQ_NO_001: process(CLK)
	begin
		if rising_edge(CLK) then
			if(TCP_TX_STATE(I) = 0) or (TCP_TX_STATE(I) = 4)  then
				-- update TCP_TX_NO up to the tx decision time
				-- Once the decision to transmit is taken, freeze TCP_TX_NO until the frame transmission is complete.
				TX_SEQ_NO(I) <= TX_SEQ_NO_IN(I);
			end if;
		end if;
	end process;
end generate;


-- compute the Effective TCP rx window size = advertised TCP rx window size - unacknowledged but sent data size
-- changes at end of tx frame, and upon receiving a valid ack
EFF_RX_WINDOW_SIZE_GENx: for I in 0 to (NTCPSTREAMS - 1) generate
	EFF_RX_WINDOW_SIZE_GEN_001: process(CLK)
	begin
		if rising_edge(CLK) then
			if(EFF_RX_WINDOW_SIZE_PARTIAL_VALID = '1') and (EFF_RX_WINDOW_SIZE_PARTIAL_STREAM = I) then
				EFF_RX_WINDOW_SIZE_PARTIAL(I) <= EFF_RX_WINDOW_SIZE_PARTIAL_IN;
			end if;
		end if;
	end process;
end generate;
			
	
-- effective TCP rx window size is EFF_RX_WINDOW_SIZE_PARTIAL - TX_SEQ_NO 
-- This is the maximum number of bytes that the TCP client can accept.
-- EFF_RX_WINDOW_SIZE is valid only up to the tx decision time (while TCP_TX_STATE = 4 or 0)
EFF_RX_WINDOW_SIZE_GENy: for I in 0 to (NTCPSTREAMS - 1) generate
	EFF_RX_WINDOW_SIZE(I) <= EFF_RX_WINDOW_SIZE_PARTIAL(I) - TX_SEQ_NO_IN(I);
	EFF_RX_WINDOW_SIZE_MSB(I) <= EFF_RX_WINDOW_SIZE(I)(16);
			-- detect if window size goes negative temporarily (can happen if the other side adjusts the rx window)
end generate;
			
--// TX EVENTS -------------------------------------
-- has the input been idle for over 200us? see TX_IDLE

-- How many bytes are waiting in the tx buffer? 
-- BUF_SIZE is valid only up to the tx decision time (while TCP_TX_STATE = 4 or 0)
TX_BUFFER_SIZE_GENx: for I in 0 to (NTCPSTREAMS - 1) generate
	BUF_SIZE(I) <= (WPTR(I) - TX_SEQ_NO_IN(I)(13 downto 0)) and PTR_MASK;
end generate;

-- Compute the next tx frame size
-- two upper bounds for the tx frame size: MSS bytes and EFF_RX_WINDOW_SIZE
NEXT_TX_FRAME_SIZE_GENx: for I in 0 to (NTCPSTREAMS - 1) generate
	NEXT_TX_FRAME_SIZE_GEN_001:  process(CLK)
	begin
		if rising_edge(CLK) then
			if(SYNC_RESET = '1') then
				NEXT_TX_FRAME_SIZE(I) <= (others => '0');
			elsif(CONNECTED_FLAG_D2(I) = '0') then
				-- no TCP-IP connection yet, or pointer information not fully available yet. Nothing to send.
				NEXT_TX_FRAME_SIZE(I) <= (others => '0');
			elsif(TCP_TX_STATE(I) = 0) or (TCP_TX_STATE(I) = 4)  then
				-- update frame size up to the tx decision time
				-- Once the decision to transmit is taken, freeze NEXT_TX_FRAME_SIZE until the frame transmission is complete.
				
				if(EFF_RX_WINDOW_SIZE_MSB(I) = '1') then	-- new 1/25/14
					-- negative number. Really means zero
					NEXT_TX_FRAME_SIZE(I) <= (others => '0');
				elsif(EFF_RX_WINDOW_SIZE(I) > MSS) then
					-- effective rx window size not the most stringent constraint.
					-- maximum payload size is constrained by MSS byte ceiling
					if(MSS(15 downto 14) = "00") and (BUF_SIZE(I) >= MSS(13 downto 0)) then
						-- more than enough bytes awaiting transmission in tx buffer
						-- clamp to MSS
						if((MSS(13 downto 0) and PTR_MASK) = MSS(13 downto 0)) then
							-- MSS is smaller than the instantiated buffer(s) address range.
							NEXT_TX_FRAME_SIZE(I) <= MSS(13 downto 0);
						else
							-- MSS is greater than the instantiated buffer(s) address range
							NEXT_TX_FRAME_SIZE(I) <= PTR_MASK;
						end if;
					else
						NEXT_TX_FRAME_SIZE(I) <= BUF_SIZE(I);
					end if;
				else
					-- maximum payload size is constrained by the client effective rx window size
					if(EFF_RX_WINDOW_SIZE(I)(15 downto 14) = "00") and (BUF_SIZE(I) >= EFF_RX_WINDOW_SIZE(I)(13 downto 0)) then
						-- more data than the client can receive. Clamp to EFF_RX_WINDOW_SIZE.
						if((EFF_RX_WINDOW_SIZE(I)(13 downto 0) and PTR_MASK) = EFF_RX_WINDOW_SIZE(I)(13 downto 0)) then
							-- EFF_RX_WINDOW_SIZE is smaller than the instantiated buffer(s) address range.
							NEXT_TX_FRAME_SIZE(I) <= EFF_RX_WINDOW_SIZE(I)(13 downto 0);
						else
							-- EFF_RX_WINDOW_SIZE is greater than the instantiated buffer(s) address range
							NEXT_TX_FRAME_SIZE(I) <= PTR_MASK;
						end if;
					else
						NEXT_TX_FRAME_SIZE(I) <= BUF_SIZE(I);
					end if;
				end if;
			end if;
		end if;
	end process;
end generate;

--// TX STATE MACHINE -------------------------------------
-- Decision to send a packet is made here based on
-- (a) input has been idle for more than 200 us, or
-- (b) the packet size collected so far has reached its threshold of MSS bytes, or less if the effective 
-- rx window is smaller. 

TCP_TX_STATE_GENx: for I in 0 to (NTCPSTREAMS - 1) generate
	TCP_TX_STATE_GEN_001: process(CLK)
	begin
		if rising_edge(CLK) then
			if(SYNC_RESET = '1') then
				TCP_TX_STATE(I) <= 0;
				TIMER(I) <= 0;
			elsif(CONNECTED_FLAG(I) = '0') then
				-- lost or no connection. Reset tx state machine, irrespective of the current state
				TCP_TX_STATE(I) <= 0;	-- back to idle
				
			-- transmit decision time
			elsif(TCP_TX_STATE(I) = 0) and (NEXT_TX_FRAME_SIZE(I) > 0) and (TX_IDLE(I) = '1') then
				-- no new data in 200us while data is waiting to be transmitted. Initiate transmission
				TCP_TX_STATE(I) <= 1;	-- start computing payload checksum
			elsif(TCP_TX_STATE(I) = 0) and (NEXT_TX_FRAME_SIZE(I) = MSS(13 downto 0)) then
				-- enough data for a full tx frame. don't wait. Initiate transmission.
				TCP_TX_STATE(I) <= 1;	-- start computing payload checksum
			elsif(TCP_TX_STATE(I) = 0) and (NEXT_TX_FRAME_SIZE(I) > 0) and (APP_CTS_local(I) = '0') then
				-- Elastic buffer is full. don't wait. Initiate transmission.
				TCP_TX_STATE(I) <= 1;	-- start computing payload checksum
				
			elsif (TCP_TX_STATE(I) = 1) and (((RPTR(I) - TX_SEQ_NO(I)(13 downto 0)) and PTR_MASK) = NEXT_TX_FRAME_SIZE(I)) then
				-- completed 1st pass scan to compute payload checksum
				TCP_TX_STATE(I) <= 2;	-- await go ahead from TCP_SERVER
			
			elsif (TCP_TX_STATE(I) = 2) and (TX_STREAM_SEL_local = I) and (TX_PAYLOAD_CTS = '1') then
				-- received a CTS for the selected stream. Sending data
				TCP_TX_STATE(I) <= 3;	-- sendind data to TCP_TX frame formatting component

			elsif (TCP_TX_STATE(I) = 3) and (TX_STREAM_SEL_local = I) and (MAC_TX_EOF = '1') then
				-- completed 2nd pass scan to send data to TCP_TX for frame formatting.
				-- Packet is sent to MAC.
				TCP_TX_STATE(I) <= 4;	-- wait until NEXT_TX_FRAME_SIZE is updated 
				TIMER(I) <= 1;				-- MAC_TX_EOF to NEXT_TX_FRAME_SIZE latency is 3 CLKs
			elsif(TIMER(I) /= 0) then
				TIMER(I) <= TIMER(I) - 1;
			elsif (TCP_TX_STATE(I) = 4) then
				TCP_TX_STATE(I) <= 0;	-- timer expired. back to idle
			end if;
			
		end if;
	end process;
end generate;

-- select the stream for the next tx frame.
-- scan all possible streams until we reach TCP_TX_STATE(I) = 2 (ready to send) or 3 (sending)
NEXT_STREAM_SELECT_GEN: process(CLK)
begin
	if rising_edge(CLK) then
		if(SYNC_RESET = '1') then
			TX_STREAM_SEL_local <= 0;
		elsif(TCP_TX_STATE(TX_STREAM_SEL_local) < 2) or
		((TCP_TX_STATE(TX_STREAM_SEL_local) = 3) and (MAC_TX_EOF = '1'))then
			-- this stream is not ready for next tx frame. move on.
			-- or this stream just completed a frame transmission, back to the end of the line
			if(TX_STREAM_SEL_local = (NTCPSTREAMS - 1)) then
				TX_STREAM_SEL_local <= 0;
			else
				TX_STREAM_SEL_local <= TX_STREAM_SEL_local + 1;
			end if;
		end if;
	end if;
end process;
	
-- tell the TCP_SERVER about the stream selected for the next tx frame, the partial checksum, the number of payload bytes.
-- The information is valid when TX_PAYLOAD_RTS = '1'.
TX_STREAM_SEL <= TX_STREAM_SEL_local;
-- bit 16 is the carry
TX_PAYLOAD_CHECKSUM <= TX_TCP_CHECKSUM(TX_STREAM_SEL_local);
-- payload size in bytes
TX_PAYLOAD_SIZE <= ext(NEXT_TX_FRAME_SIZE(TX_STREAM_SEL_local),TX_PAYLOAD_SIZE'length);
-- payload data
TX_PAYLOAD_DATA_local <= DOB(TX_STREAM_SEL_local,conv_integer(RPTR_MEMINDEX(TX_STREAM_SEL_local)))(8 downto 1);
TX_PAYLOAD_DATA <= TX_PAYLOAD_DATA_local;
TX_PAYLOAD_DATA_VALID <= SAMPLE3_CLK(TX_STREAM_SEL_local);
-- delay TX_PAYLOAD_RTS so that we have time to finish the checksum computation
RECLOCK_001: process(CLK)
begin
	if rising_edge(CLK) then
		if(TCP_TX_STATE(TX_STREAM_SEL_local) = 2) then
			TX_PAYLOAD_RTS <= '1';
		else
			TX_PAYLOAD_RTS <= '0';
		end if;
	end if;
end process;


--// TCP TX FLOW CONTROL  ---------------------------
-- The basic tx flow control rule is that the buffer WPTR must never pass the last acknowledged tx byte location.
AVAILABLE_BUF_SPACE_GENx: for I in 0 to (NTCPSTREAMS - 1) generate

	AVAILABLE_BUF_SPACE_001: process(CLK)
	begin
		if rising_edge(CLK) then
			if(SYNC_RESET = '1') then
				AVAILABLE_BUF_SPACE(I) <=(others => '0');
				CONNECTED_FLAG_D(I) <= '0';
				CONNECTED_FLAG_D2(I) <= '0';
			else
				CONNECTED_FLAG_D(I) <= CONNECTED_FLAG(I); 
				CONNECTED_FLAG_D2(I) <= CONNECTED_FLAG_D(I); -- align with AVAILABLE_BUF_SPACE
				AVAILABLE_BUF_SPACE(I) <= (RX_TCP_ACK_NO_D(I)(13 downto 0) + not(WPTR(I))) and PTR_MASK;
			end if;
		end if;
	end process;
	
	-- input flow control
	-- no point in asking for data when there is no TCP connection and data is being discarded.	
	-- allow more tx data in if there is room for at least 128 bytes
	APP_CTS_local(I) <= 	'0' when (CONNECTED_FLAG_D2(I) = '0') else 
						'1' when (AVAILABLE_BUF_SPACE(I)(13 downto 7) /=  0) and (NBUFS = 8) else
						'1' when (AVAILABLE_BUF_SPACE(I)(12 downto 7) /=  0) and (NBUFS = 4) else
						'1' when (AVAILABLE_BUF_SPACE(I)(11 downto 7) /=  0) and (NBUFS = 2) else
						'1' when (AVAILABLE_BUF_SPACE(I)(10 downto 7) /=  0) and (NBUFS = 1) else
						'0';
end generate;
APP_CTS <= APP_CTS_local;
-- allow more tx data in if there is room for at least 128 bytes

--// TEST POINTS --------------------------------
TP(1) <= WPTR(0)(0);
TP(2) <= RPTR(0)(0);
TP(3) <= CONNECTED_FLAG(0);
TP(4) <= '1' when (TCP_TX_STATE(0) = 0) else '0';
TP(5) <= '1' when (RX_TCP_ACK_NO_D(0)(13 downto 0) = TX_SEQ_NO(0)(13 downto 0)) else '0';
TP(6) <= '1' when (RX_TCP_ACK_NO_D(0)(13 downto 0) = TX_SEQ_NO_IN(0)(13 downto 0)) else '0';
TP(7) <= TX_SEQ_NO(0)(0);
TP(8) <= RX_TCP_ACK_NO_D(0)(0);
TP(9) <= SAMPLE3_CLK(0);
TP(10) <= TX_SEQ_NO_IN(0)(0);



end Behavioral;

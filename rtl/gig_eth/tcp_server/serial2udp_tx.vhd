-------------------------------------------------------------
-- MSS copyright 2011
--	Filename:  SERIAL2UDP_TX.VHD
-- Author: Alain Zarembowitch / MSS
--	Version: 1
--	Date last modified: 2-14-11
-- Inheritance: 	none
--
-- description:  UDP transmit protocol. 
-- Encapsulates a data packet in a (UDP) datagram.
-- The packet boundaries are marked by a Start Of Frame (SOF) and End Of Frame (EOF) marker.
-- The destination port and IP address 
-- Converts a data stream into a UDP packet.
-- The UDP packet destination is the source address of the last successfully received UDP packet.
-- Packet is transmitted within 100ms of the last received byte. 		
-- There is NO flow control. The key assumption is that the LAN sink always has a higher
-- average throughput than the serial link.
-- However, decoding of serial input stream continues while UDP packets are being assembled
-- and transmitted.
---------------------------------------------------------------
library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.STD_LOGIC_ARITH.ALL;
use IEEE.STD_LOGIC_UNSIGNED.ALL;

entity UDP_TX is
    Port ( 
		--// CLK, RESET
		ASYNC_RESET: in std_logic;
		CLK: in std_logic;
		TICK_1MS: in std_logic;
			-- 1 CLK-wide pulse every one ms (0.998ms to be precise)

		--// Configuration data: IP address, MAC address
		REG0: in std_logic_vector(7 downto 0);	-- IP MSB
		REG1: in std_logic_vector(7 downto 0);	
		REG2: in std_logic_vector(7 downto 0);
		REG3: in std_logic_vector(7 downto 0);	-- IP LSB
			-- IP address
		MAC_ADDR: in std_logic_vector(47 downto 0);
			-- MAC address. Unique for each network interface card.

		-- destination IP address
		DEST_MAC_ADDRESS: in std_logic_vector(47 downto 0);
		DEST_IP_ADDRESS: in std_logic_vector(31 downto 0);
		DEST_PORT_NO: in std_logic_vector(15 downto 0);

		--// Asynchronous serial interface
		-- 115.2 Kbaud/s, 8-bit no parity 1 stop bit.
		-- There is NO flow control. The key assumption is that the LAN sink always has a higher
		-- average throughput than the serial link.
		SERIAL_IN: in std_logic;


		--// Transmit frame/packet
		TX_DATA: out std_logic_vector(15 downto 0);
		TX_SAMPLE_CLK: out std_logic;
			-- one CLK-wide pulse indicating a new word is sent on TX_DATA
		TX_SOF: out std_logic;
			-- Start of Frame: one CLK-wide pulse indicating the first word in the transmit frame
			-- aligned with TX_SAMPLE_CLK.
		TX_EOF: out std_logic;
			-- End of Frame: one CLK-wide pulse indicating the last word in the transmit frame.
 		   -- aligned with TX_SAMPLE_CLK.
		TX_SAMPLE_CLK_REQ: in std_logic;
			-- 1 CLK-wide pulse requesting output samples. Check RTS first.
		RTS: out std_logic;
			-- '1' when a full or partial packet is ready to be read.
			-- '0' when output buffer is empty.
			-- When the user starts reading the output buffer, it is expected that it will be
			-- read until empty.
		TX_BYTE_COUNT: out std_logic_vector(10 downto 0);
			-- transmit packet size, in bytes. Valid only when RTS = '1'. 
			-- excludes overhead of LAN91C111 IC (status word, size, control byte).

		-- Test Points
		TP_UDP_TX: out std_logic_vector(10 downto 1)

			);
end entity;

architecture Behavioral of UDP_TX is
--------------------------------------------------------
--      COMPONENTS
--------------------------------------------------------
component RAMB4_S8_S16
  port (DIA    : in STD_LOGIC_VECTOR (7 downto 0);
        DIB    : in STD_LOGIC_VECTOR (15 downto 0);
        ENA    : in STD_logic;
        ENB    : in STD_logic;
        WEA    : in STD_logic;
        WEB    : in STD_logic;
        RSTA   : in STD_logic;
        RSTB   : in STD_logic;
        CLKA   : in STD_logic;
        CLKB   : in STD_logic;
        ADDRA  : in STD_LOGIC_VECTOR (8 downto 0);
        ADDRB  : in STD_LOGIC_VECTOR (7 downto 0);
        DOA    : out STD_LOGIC_VECTOR (15 downto 0);
        DOB    : out STD_LOGIC_VECTOR (15 downto 0)); 
end component;

--------------------------------------------------------
--     SIGNALS
--------------------------------------------------------
--// constants
signal ZERO: std_logic;
signal ONE: std_logic;
signal ZERO16: std_logic_vector(15 downto 0);

--// Async serial
signal NCO_ACC: std_logic_vector(15 downto 0);
signal NCO_ACC_MSB: std_logic;
signal BAUD_CLK: std_logic;
signal SERIAL_STATE: integer range 0 to 10;
signal SERIAL_STATE_INC: integer range 0 to 10;

--// DPRAM
signal DIA: std_logic_vector(7 downto 0);
signal WEA: std_logic;
signal WPTR: std_logic_vector(8 downto 0);
signal WPTR_INC: std_logic_vector(8 downto 0);
signal ELASTIC_BUFFER_SIZE: std_logic_vector(8 downto 0); 
signal MESSAGE_LENGTH: std_logic_vector(8 downto 0);  
signal MESSAGE_WPTR_START: std_logic_vector(8 downto 0); 
signal RPTR: std_logic_vector(7 downto 0);
signal RPTR_INC: std_logic_vector(7 downto 0);
signal DOB: std_logic_vector(15 downto 0);
signal WORD_COUNT: std_logic_vector(8 downto 0);
signal RX_DATA_D: std_logic_vector(15 downto 0);
signal RX_SAMPLE_CLK_D: std_logic;
signal RX_EOF_D: std_logic;

--// Message assembly
signal UDP_TX_INPROGRESS: std_logic;
signal MESSAGE_COMPLETE: std_logic;
signal IP_IDENT: std_logic_vector(15 downto 0);	-- IP identification field
signal IP_CKSUM: std_logic_vector(15 downto 0);
signal UDP_CKSUM: std_logic_vector(15 downto 0);

constant PORT_NO: std_logic_vector(15 downto 0) := x"0405"; --1029;
constant BAUD_RATE: std_logic_vector(15 downto 0) := x"005E"; -- 94;

--// Timers
signal TIMER1: integer range 0 to 255;
constant TM001: integer range 0 to 255 := 100;
	-- timeout timer 1, 100ms

--------------------------------------------------------
--      IMPLEMENTATION
--------------------------------------------------------
begin

--// constant
ZERO <= '0';
ONE <= '1';
ZERO16 <= (others => '0');

--// serial to parallel conversion
SERIAL_STATE_INC <= SERIAL_STATE + 1;

S2P_001:  process(ASYNC_RESET, CLK)
begin
	if(ASYNC_RESET = '1') then
		SERIAL_STATE <= 0;
	elsif rising_edge(CLK) then
		if(SERIAL_STATE = 0) and (SERIAL_IN = '0') then
			-- start of start bit
			SERIAL_STATE <= SERIAL_STATE_INC;
		elsif (BAUD_CLK = '1') then
			if(SERIAL_STATE < 10) then
				SERIAL_STATE <= SERIAL_STATE_INC;
			else
				SERIAL_STATE <= 0;
			end if;
		end if;
	end if;
end process;

--// push serial data bits into a byte
-- LSB is received first
S2P_002:  process(ASYNC_RESET, CLK)
begin
	if(ASYNC_RESET = '1') then
		DIA <= (others => '0');
	elsif rising_edge(CLK) then
		if(BAUD_CLK = '1') and (SERIAL_STATE > 1) and (SERIAL_STATE < 10) then
			-- new bit. shift right
			DIA(7) <= SERIAL_IN;
			DIA(6 downto 0) <= DIA(7 downto 1);
		end if;
	end if;
end process;

S2P_003:  process(ASYNC_RESET, CLK)
begin
	if(ASYNC_RESET = '1') then
		WEA <= '0';
	elsif rising_edge(CLK) then
		if(BAUD_CLK = '1') and (SERIAL_STATE = 9) then
			WEA <= '1';
		else
			WEA <= '0';
		end if;
	end if;
end process;


-- NCO for 115.2 Kbaud clock based on 40 MHz clock
-- 16-bit NCO sufficient for 1% baud rate precision
-- BAUD_RATE = 115200/40MHz * 2^15
NCO_GEN_001: process(ASYNC_RESET, CLK)
begin
	if(ASYNC_RESET = '1') then
		NCO_ACC <= (others => '0');
		NCO_ACC_MSB <= '0';
		BAUD_CLK <= '0';
	elsif rising_edge(CLK) then
		if(SERIAL_STATE = 0) and (SERIAL_IN = '0') then
			-- detected start of start bit. 
			-- create 115.2 Kbaud pulses, starting 1/2 bit later
			NCO_ACC <= x"4000";
			NCO_ACC_MSB <= '0';
			BAUD_CLK <= '0';
		elsif(SERIAL_STATE > 0) then
			-- generate baud clock only when needed
			NCO_ACC <= NCO_ACC + BAUD_RATE;
			NCO_ACC_MSB <= NCO_ACC(15);
			if(NCO_ACC(15) /= NCO_ACC_MSB) then
				BAUD_CLK <= '1';
			else
				BAUD_CLK <= '0';
			end if;
	 	end if;
	end if;
end process;

--// write pointer management
-- Circular elastic buffer. Allows one to keep on writing while transmitting UDP packets.
-- Move pointer after each write.
--NOTE: always align start of new message with even byte.
WPTR_GEN_001: process(ASYNC_RESET, CLK)
begin
	if(ASYNC_RESET = '1') then
		WPTR <= (others => '0');
	elsif rising_edge(CLK) then
		if(WEA = '0') and (MESSAGE_COMPLETE = '1') then
			-- align write pointer with even byte for start of next message
			WPTR <= MESSAGE_WPTR_START;	
		elsif(WEA = '1') and (MESSAGE_COMPLETE = '1') then
			-- concurrent start of new message and new byte. 
			-- (almost) never happen. just to be rigorous.
			WPTR <= MESSAGE_WPTR_START + 1;
		elsif(WEA = '1') then
			WPTR <= WPTR + 1;
		end if;
	end if;
end process;

--// DPRAM
RAMB4_001: RAMB4_S8_S16 port map(
	DIA => DIA,	
	DIB => ZERO16,
	ENA => ONE,
	ENB => ONE,
	WEA => WEA,
	WEB => ZERO,
	RSTA => ASYNC_RESET,
	RSTB => ASYNC_RESET,
	CLKA => CLK,
	CLKB => CLK,
	ADDRA => WPTR,
	ADDRB => RPTR,
--	DOA => 
	DOB => DOB
);

--// timer to send packets.
-- Wait 100ms after last received serial byte or 478 bytes, whichever comes first.
-- Then raise RTS flag.
TIME_SINCE_LAST_RX_BYTE: process(ASYNC_RESET, CLK)
begin
	if(ASYNC_RESET = '1') then
		TIMER1 <= 0;	-- expired by default.
	elsif rising_edge(CLK) then
		if(WEA = '1') then
			-- new incoming byte. Thus reset timer to 100ms
			TIMER1 <= TM001;
		elsif(TIMER1 = 0) then
			-- timer1 expired
		elsif(TICK_1MS = '1') then
			-- no activity, decrement timers
			TIMER1 <= TIMER1 - 1;
		end if;
	end if;
end process;

WPTR_INC <= WPTR + 1;

-- compute remaining bytes to transmit
ELASTIC_BUFFER_SIZE <= WPTR_INC + not(MESSAGE_WPTR_START);


-- start / stop UDP_TX_INPROGRESS
-- raise a flag (MESSAGE_COMPLETE) when message transmission starts
UDP_TX_INPROGRESS_GEN_001: process(ASYNC_RESET, CLK)
begin
	if(ASYNC_RESET = '1') then
		UDP_TX_INPROGRESS <= '0';	
		MESSAGE_WPTR_START <= (others => '0');
		MESSAGE_COMPLETE <= '0';
		MESSAGE_LENGTH <= (others => '0');
	elsif rising_edge(CLK) then
		-- start UDP packet transmission
		if(UDP_TX_INPROGRESS = '0') and 
		( ((TIMER1 = 0) and (MESSAGE_WPTR_START /= WPTR)) or
			 ((ELASTIC_BUFFER_SIZE > 478)) ) then
			-- timer1 has expired and elastic buffer is not empty 
			-- OR elastic buffer has reach its maximum size. Start transmission 
			UDP_TX_INPROGRESS <= '1';	
			-- freeze (record) new message start while transmitting current message
			-- will be useful to detect the end of transmission. see below.
			-- Align with (next) even address
			MESSAGE_WPTR_START <= WPTR_INC(8 downto 1) & '0';
			MESSAGE_COMPLETE <= '1';
			MESSAGE_LENGTH <= ELASTIC_BUFFER_SIZE;

 		-- stop UDP packet transmission
		elsif(UDP_TX_INPROGRESS = '1') then
			MESSAGE_COMPLETE <= '0';
			if(RPTR = MESSAGE_WPTR_START(8 downto 1)) then
				-- end of transmission
				UDP_TX_INPROGRESS <= '0';	
		  	end if;

 	  	else
			MESSAGE_COMPLETE <= '0';
	  	end if;
	end if;
end process; 

RTS <= UDP_TX_INPROGRESS;


--// Flow control 
RPTR_INC <= RPTR + 1;

RTS_GEN_001: process(ASYNC_RESET, CLK)
begin
	if(ASYNC_RESET = '1') then
		WORD_COUNT <= (others => '0');
		RPTR <= (others => '0');
		TX_SAMPLE_CLK <= '0';
		TX_SOF <= '0';
		TX_EOF <= '0';
		IP_IDENT <= (others => '0');
	elsif rising_edge(CLK) then
		if(MESSAGE_COMPLETE = '1') then
			-- start of message transmission. reset word counter
			WORD_COUNT <= (others => '0');

		elsif(TX_SAMPLE_CLK_REQ = '1') then
			if(WORD_COUNT < 24) then
				-- transmit LAN(14B)/IP(20B)/UDP(8B) headers = 24 16-bit words 
				TX_SAMPLE_CLK <= '1';
				WORD_COUNT <= WORD_COUNT + 1;
				if(WORD_COUNT = 0) then
					-- just read the first word
					TX_SOF <= '1';
				else
					TX_SOF <= '0';
				end if;
			elsif(RPTR < MESSAGE_WPTR_START(8 downto 1)) then
				WORD_COUNT <= WORD_COUNT + 1;
				RPTR <= RPTR + 1;	-- preposition read pointer before next word request
				TX_SAMPLE_CLK <= '1';
				if(RPTR_INC = MESSAGE_WPTR_START(8 downto 1)) then
					-- just read the last word
					TX_EOF <= '1';
					IP_IDENT <= IP_IDENT + 1;	-- increment IP identification field.
				end if;
			else
				TX_SAMPLE_CLK <= '0';
				TX_SOF <= '0';
				TX_EOF <= '0';
			end if;
		else
			TX_SAMPLE_CLK <= '0';
			TX_SOF <= '0';
			TX_EOF <= '0';
		end if;
	end if;
end process;

-- UDP datagram data field
TX_DATA_GEN_001: process(WORD_COUNT, DEST_MAC_ADDRESS, MAC_ADDR, RX_DATA_D,
	REG0, REG1, REG2, REG3)
begin
	--========= Ethernet header ====================
	if(WORD_COUNT = 0) then
	  	-- tx packet dest Ethernet address
		TX_DATA <= DEST_MAC_ADDRESS(47 downto 32);	 
	elsif(WORD_COUNT = 1) then
	  	-- tx packet dest Ethernet address
		TX_DATA <= DEST_MAC_ADDRESS(31 downto 16);	 
	elsif(WORD_COUNT = 2) then
	  	-- tx packet dest Ethernet address
		TX_DATA <= DEST_MAC_ADDRESS(15 downto 0);	 
	elsif(WORD_COUNT = 3) then
	  	-- tx packet source Ethernet address
		TX_DATA <= MAC_ADDR(7 downto 0) & MAC_ADDR(15 downto 8);	 
	elsif(WORD_COUNT = 4) then
	  	-- tx packet source Ethernet address
		TX_DATA <= MAC_ADDR(23 downto 16) & MAC_ADDR(31 downto 24);	
	elsif(WORD_COUNT = 5) then
	  	-- tx packet source Ethernet address
		TX_DATA <= MAC_ADDR(39 downto 32) & MAC_ADDR(47 downto 40);	
	elsif(WORD_COUNT = 6) then
		-- tx packet type 
		TX_DATA <= x"0800";	-- IP datagram
	--========= IP header ====================
	elsif(WORD_COUNT = 7) then
		-- IP header. version/header length/TOS (minimize delay)
		TX_DATA <= x"4510";	
	elsif(WORD_COUNT = 8) then
		-- IP header. total length 
		TX_DATA(8 downto 0) <= MESSAGE_LENGTH + 28;	-- 20(IP header) + 8(UDP header) + payload data in bytes
		TX_DATA(15 downto 9) <= (others => '0');
	elsif(WORD_COUNT = 9) then
		-- IP header. identification field 
		TX_DATA <= IP_IDENT;	--
	elsif(WORD_COUNT = 10) then
		-- IP header. fragment offset, flags 
		TX_DATA <= x"0000";	-- (TBC see RFC-760???)
	elsif(WORD_COUNT = 11) then
		-- IP header. TTL(64), Protocol(17)
		TX_DATA <= x"4011";	
	elsif(WORD_COUNT = 12) then
		-- IP header. IP checksum
		TX_DATA <= IP_CKSUM;	
 	elsif(WORD_COUNT = 13) then
		-- source IP address
		TX_DATA <= REG0 & REG1;
	elsif(WORD_COUNT = 14) then
		-- source IP address
		TX_DATA <= REG2 & REG3;
 	elsif(WORD_COUNT = 15) then
		-- destination IP address
		TX_DATA <= DEST_IP_ADDRESS(31 downto 16);
	elsif(WORD_COUNT = 16) then
		-- destination IP address
		TX_DATA <= DEST_IP_ADDRESS(15 downto 0);
	--========= UDP header ====================
 	elsif(WORD_COUNT = 17) then
		-- UDP source port number
		TX_DATA <= PORT_NO;
 	elsif(WORD_COUNT = 18) then
		-- UDP destination port number
		TX_DATA <= DEST_PORT_NO;
	elsif(WORD_COUNT = 19) then
		-- UDP header. total length 
		TX_DATA(8 downto 0) <= MESSAGE_LENGTH + 8;	-- 8(UDP header) + payload data in bytes
		TX_DATA(15 downto 9) <= (others => '0');
	elsif(WORD_COUNT = 20) then
		-- UDP checksum
		TX_DATA <= UDP_CKSUM; --(TBD)
 	else 
		-- rest of incoming packet is copied.
		TX_DATA <= DOB;
	end if;
end process;


TX_BYTE_COUNT <= MESSAGE_LENGTH + 42;	

--// Test Point
TP_UDP_TX(1) <= WEA;


end Behavioral;

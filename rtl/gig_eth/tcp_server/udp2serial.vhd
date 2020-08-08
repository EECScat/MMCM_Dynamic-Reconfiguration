-------------------------------------------------------------
-- MSS copyright 2003-2011
--	Filename:  UDP2SERIAL.VHD
-- Author: Alain Zarembowitch / MSS
--	Version: 1
--	Date last modified: 2-12-11
-- Inheritance: 	COM-5003 UDP_RX2.VHD 2-9-06
--
-- description:  UDP protocol (receive-only). 
-- Receives packets on port PORT_NO, save contents in small buffer, then
-- converts it to 115 Kbaud/s asynchronous serial.
-- Difference with UDP.VHD: use short elastic output buffer to alleviate the need for 
-- a RAMB. The maximum message length is 16 which is sufficient for the "@000RST\r\n"
-- reset message. If not, adjust constants within.
-- Discard filler bytes used to pad the datagram for minimum size.
-- Because of the shallow buffer and the slow output serial speed, this component processes one message at a time. 
-- It discards any premature incoming message while serialization is being performed for the previous message.
--
-- As there is no difference between IPv4 and IPv6 for UDP, this component is compatible with both IPv4 and IPv6.
---------------------------------------------------------------
library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.STD_LOGIC_ARITH.ALL;
use IEEE.STD_LOGIC_UNSIGNED.ALL;

entity UDP2SERIAL is
	generic (
		PORT_NO: std_logic_vector(15 downto 0) := x"0405";  --1029;
			-- this UDP component's port number.
		CLK_FREQUENCY: integer := 120
			-- CLK frequency in MHz. Needed to compute actual delays.
	);
    Port ( 
		--// CLK, RESET
		ASYNC_RESET: in std_logic;
		CLK: in std_logic;


		--// Received IP frame
		-- Excludes MAC layer header. Includes IP header.
		IP_RX_DATA: in std_logic_vector(7 downto 0);
		IP_RX_DATA_VALID: in std_logic;	
		IP_RX_SOF: in std_logic;
		IP_RX_EOF: in std_logic;
		IP_HEADER_FLAG: in std_logic;
			-- latency: 2 CLKs after MAC_RX_DATA
			-- As the IP frame validity is checked on-the-fly, the user should always check if 
			-- the IP_RX_DATA_VALID is high AT THE END of the IP frame (IP_RX_EOF) to confirm that the 
			-- ENTIRE IP frame is valid. Validity checks performed within are 
			-- (a) destination IP address matches
			-- (b) protocol is IP
			-- (c) correct IP header checksum

		--// IP type: 
		RX_IP_PROTOCOL: in std_logic_vector(7 downto 0);
			-- The protocol information is valid as soon as the 8-bit IP protocol field in the IP header is read.
			-- Information stays until start of following packet.
			-- most common protocols: 
			-- 0 = unknown, 1 = ICMP, 2 = IGMP, 6 = TCP, 17 = UDP, 41 = IPv6 encapsulation, 89 = OSPF, 132 = SCTP
			-- latency: 3 CLK after IP protocol field at byte 9 of the IP header
	  	RX_IP_PROTOCOL_RDY: in std_logic;
			-- 1 CLK wide pulse. 

		--// Serial port RX interface
		-- 115.2 Kbaud/s asynchronous serial
		SERIAL_OUT: out std_logic;

		-- Test Points
		TP: out std_logic_vector(10 downto 1)

			);
end entity;

architecture Behavioral of UDP2SERIAL is
--------------------------------------------------------
--      COMPONENTS
--------------------------------------------------------
--------------------------------------------------------
--     SIGNALS
--------------------------------------------------------
--// STATE MACHINE -----------------------------
signal STATE: integer range 0 to 2;
signal BLOCK_INPUT: std_logic := '0';

--// UDP BYTE COUNT -----------------------------
signal UDP_BYTE_COUNT: std_logic_vector(10 downto 0);
signal IP_RX_DATA_PREVIOUS: std_logic_vector(7 downto 0);

--// CHECK UDP VALIDITY -----------------------------
signal VALID_RX_UDP: std_logic := '0';
signal IP_RX_EOF_D: std_logic := '0';

--// COPY UDP DATA TO BUFFER ------------------------
signal IP_RX_DATA16: std_logic_vector(15 downto 0);
signal RX_UDP_SIZE: std_logic_vector(15 downto 0);

--// elastic buffer
signal WEA: std_logic := '0';
signal DIA: std_logic_vector(7 downto 0);
constant DEPTH: integer  := 128;		-- maximum of 16 characters in incoming message.
	-- buffer depth
constant DEPTH_LOG2: integer := 7;	
	-- number of bits to represent the read/write pointers (log2(DEPTH))
signal EBUFFER: std_logic_vector((DEPTH-1) downto 0) := (others => '0');
signal RPTR: std_logic_vector((DEPTH_LOG2-4) downto 0) := (others => '0');

--// Async serial
signal NCO_ACC: std_logic_vector(15 downto 0) := (others => '0');
signal NCO_ACC_MSB: std_logic := '0';
signal BAUD_CLK: std_logic := '0';
signal P2S_STATE: integer range 0 to 11;
signal P2S_STATE_INC: integer range 0 to 12;
signal DOB: std_logic_vector(7 downto 0);
signal SERIAL_OUT_LOCAL: std_logic := '1';	-- '1' is idle
-- BAUD_RATE = 0.115200/CLK_FREQUENCY * 2^15
constant BAUD_RATE: std_logic_vector(15 downto 0) := conv_std_logic_vector(3775/CLK_FREQUENCY, 16);


--------------------------------------------------------
--      IMPLEMENTATION
--------------------------------------------------------
begin
--// STATE MACHINE -----------------------------
-- Task #1: Because of the very shallow buffer, no new message is accepted until serialization buffer is empty.
-- Task #2: we only know about bad UDP packets at the end. Clear the buffer if the incoming message turns out
-- to be invalid.
UDP_STATE_001: process(ASYNC_RESET, CLK)
begin
	if(ASYNC_RESET = '1') then
		STATE <= 0;
	elsif rising_edge(CLK) then
		if(STATE = 0) and (IP_RX_SOF = '1') then
			-- incoming message being processed
			STATE <= 1;
		elsif(STATE = 1) and (IP_RX_EOF_D = '1') then
			-- end of message
			if(VALID_RX_UDP = '1') then
				-- message is all good. OK to send to serial output.
				STATE <= 2;
			else
				-- invalid message. Clear buffer. Go back to idle
				STATE <= 0;
			end if;
		elsif(STATE = 2) and (RPTR = 0) then
			-- buffer is empty. All data sent to serial output. Go back to idle
			STATE <= 0;
		end if;
	end if;
end process;

BLOCK_INPUT <= '1' when (STATE = 2) else '0';

--// UDP BYTE COUNT -----------------------------
-- counts bytes within the UDP frame (i.e. excluding MAC and IP headers) but including UDP header and data fields.
UDP_BYTE_COUNT_001: process(ASYNC_RESET, CLK)
begin
	if(ASYNC_RESET = '1') then
		UDP_BYTE_COUNT <= (others => '0');
	elsif rising_edge(CLK) then
		if(IP_RX_SOF = '1') and (BLOCK_INPUT = '0') then
			-- new IP packet. Reset UDP byte counter
			UDP_BYTE_COUNT <= (others => '0');
		elsif(IP_RX_DATA_VALID = '1') and (BLOCK_INPUT = '0') and (IP_HEADER_FLAG = '0') then
			-- UDP frame
			UDP_BYTE_COUNT <= UDP_BYTE_COUNT + 1;
			IP_RX_DATA_PREVIOUS <= IP_RX_DATA;	-- remember previous byte (useful when reading 16-bit fields)
		end if;
	end if;
end process;

--// CHECK UDP VALIDITY -----------------------------
-- The UDP packet reception is immediately cancelled if 
-- (a) the received packet type is not an IP datagram  (done in common code PACKET_PARSING)
-- (b) invalid destination IP  (done in common code PACKET_PARSING)
-- (c) incorrect IP header checksum (done in common code PACKET_PARSING)
-- (d) the received IP type is not UDP 
-- (e) port number is not the specified PORT_NO (constant)
-- (f) destination port number is not the specified PORT_NO (constant)
VALIDITY_CHECK_001: process(ASYNC_RESET, CLK)
begin
	if(ASYNC_RESET = '1') then
		VALID_RX_UDP <= '1';
		IP_RX_EOF_D <= '0';
	elsif rising_edge(CLK) then
		IP_RX_EOF_D <= IP_RX_EOF;	-- read VALID_RX_UDP at the end of the packet.
		
		if(IP_RX_SOF = '1') and (BLOCK_INPUT = '0') then
			-- just received first word. Valid UDP datagram until proven otherwise
			VALID_RX_UDP <= '1';
		elsif(IP_RX_EOF = '1') and (IP_RX_DATA_VALID = '0') and (BLOCK_INPUT = '0') then
			-- invalid IP frame reported at the end of the IP frame.
			VALID_RX_UDP <= '0';
		elsif(RX_IP_PROTOCOL /= 17) and (RX_IP_PROTOCOL_RDY = '1') then
			-- (d) the received IP type is not UDP 
			VALID_RX_UDP <= '0';
		elsif(IP_RX_DATA_VALID = '1') and (BLOCK_INPUT = '0') and (UDP_BYTE_COUNT = 2) and (IP_RX_DATA /= PORT_NO(15 downto 8)) then
			-- (f) destination port number is not the specified PORT_NO (constant)
			VALID_RX_UDP <= '0';
		elsif(IP_RX_DATA_VALID = '1') and (BLOCK_INPUT = '0') and (UDP_BYTE_COUNT = 3) and (IP_RX_DATA /= PORT_NO(7 downto 0)) then
			-- (f) destination port number is not the specified PORT_NO (constant)
			VALID_RX_UDP <= '0';
	 	end if;
	end if;
end process;

--// COPY UDP DATA TO BUFFER ------------------------
IP_RX_DATA16 <= IP_RX_DATA_PREVIOUS & IP_RX_DATA;	-- reconstruct 16-bit field. 

-- Manage write pointer to buffer
-- Keep track of the actual number of UDP bytes (otherwise we may forward dummy data
-- when the datagram is small and padded for minimum length).
WPTR_GEN_001: process(ASYNC_RESET, CLK)
begin
	if(ASYNC_RESET = '1') then
		WEA <= '0';
		DIA <= (others => '0');
	elsif rising_edge(CLK) then
		if(IP_RX_DATA_VALID = '1') and (BLOCK_INPUT = '0') and (UDP_BYTE_COUNT = 5) then 
			-- UDP datagram size.
			RX_UDP_SIZE <= (IP_RX_DATA16 - 8);	-- subtract the UDP header (8 bytes).
			WEA <= '0';
	  	elsif(IP_RX_DATA_VALID = '1') and (BLOCK_INPUT = '0') and (IP_HEADER_FLAG = '0') and (VALID_RX_UDP = '1') and (UDP_BYTE_COUNT >= 8) and (RX_UDP_SIZE /= 0) then 
			-- UDP header is always 8 bytes. Data field starts at byte 8.
			-- write byte to buffer as long as there is meaningful and valid UDP data, not filler.
			WEA <= '1';
			DIA <= IP_RX_DATA;
			RX_UDP_SIZE <= RX_UDP_SIZE - 1;
	  	else
			WEA <= '0';
		end if;
	end if;
end process;


-- write into elastic buffer
PUSH_001: process(CLK)
begin
	if rising_edge(CLK) then
		if (WEA = '1') then
			EBUFFER(7 downto 0) <= DIA;
			EBUFFER((DEPTH -1) downto 8) <= EBUFFER((DEPTH - 9) downto 0);
		end if;	 
	end if;
end process;

-- Manage read pointer
RPTR_001: process(CLK)
begin
	if rising_edge(CLK) then
		if (STATE = 0) then
			-- idle state. Clear buffer (maybe last message was invalid)
			RPTR <= (others => '0');
		elsif (STATE = 2)and (RPTR /= 0) and (P2S_STATE = 0) then 
			-- wait until the entire message is in the buffer (i.e. STATE = 2) to read
			-- (because we only know about validity upon receiving the last byte).
			if(WEA = '0')  then
				-- start reading a byte, while no write
				RPTR <= RPTR -1 ;
			else
				-- both read and write are simultaneous. RPTR does not move.
			end if;	
		elsif (WEA = '1') then
			-- wrote a byte while no read.
			RPTR <= RPTR + 1;
		end if;
	end if;
end process;

-- output elastic buffer. 8 bit words.
DOB_GEN: process(RPTR, EBUFFER)
begin
	case RPTR is
		when "0000" => DOB <= EBUFFER(7 downto 0);
		when "0001" => DOB <= EBUFFER(15 downto 8);
		when "0010" => DOB <= EBUFFER(23 downto 16);
		when "0011" => DOB <= EBUFFER(31 downto 24);
		when "0100" => DOB <= EBUFFER(39 downto 32);
		when "0101" => DOB <= EBUFFER(47 downto 40);
		when "0110" => DOB <= EBUFFER(55 downto 48);
		when "0111" => DOB <= EBUFFER(63 downto 56);
		when "1000" => DOB <= EBUFFER(71 downto 64);
		when "1001" => DOB <= EBUFFER(79 downto 72);
		when "1010" => DOB <= EBUFFER(87 downto 80);
		when "1011" => DOB <= EBUFFER(95 downto 88);
		when "1100" => DOB <= EBUFFER(103 downto 96);
		when "1101" => DOB <= EBUFFER(111 downto 104);
		when others => DOB <= EBUFFER(119 downto 112);
	end case;
end process;

-- NCO for 115.2 Kbaud clock based on the clock frequency CLK_FREQUENCY (expressed in MHz)
-- 16-bit NCO sufficient for 1% baud rate precision
-- BAUD_RATE = 0.115200/CLK_FREQUENCY * 2^15
NCO_GEN_001: process(CLK)
begin
	if rising_edge(CLK) then
		NCO_ACC <= NCO_ACC + BAUD_RATE;
		NCO_ACC_MSB <= NCO_ACC(15);
		if(NCO_ACC(15) /= NCO_ACC_MSB) then
			BAUD_CLK <= '1';
		else
			BAUD_CLK <= '0';
		end if;
	end if;
end process;

P2S_STATE_INC <= P2S_STATE + 1;

-- Parallel to serial conversion
-- LSB is always transmitted first in async serial links
P2S_001_GEN: process(ASYNC_RESET, CLK)
begin
	if(ASYNC_RESET = '1') then
		SERIAL_OUT_LOCAL <= '1'; -- '1' is idle
	elsif rising_edge(CLK) then
		if(STATE = 2) and (RPTR /= 0) and (P2S_STATE = 0) then	
			-- wait until the entire message is in the buffer (i.e. STATE = 2) to read
			-- (because we only know about validity upon receiving the last byte).
			-- elastic buffer not empty
			-- start serial conversion. Await for next BAUD_CLK.
			P2S_STATE <= P2S_STATE_INC;
		elsif(BAUD_CLK = '1') then
			if(P2S_STATE = 1) then	
				-- start bit
				P2S_STATE <= P2S_STATE_INC;
				SERIAL_OUT_LOCAL <= '0';	
			elsif(P2S_STATE = 2) then
				-- first data bit
				SERIAL_OUT_LOCAL <= DOB(0); 
				P2S_STATE <= P2S_STATE_INC;
			elsif(P2S_STATE = 3) then
				SERIAL_OUT_LOCAL <= DOB(1); 
				P2S_STATE <= P2S_STATE_INC;
			elsif(P2S_STATE = 4) then
				SERIAL_OUT_LOCAL <= DOB(2); 
				P2S_STATE <= P2S_STATE_INC;
			elsif(P2S_STATE = 5) then
				SERIAL_OUT_LOCAL <= DOB(3); 
				P2S_STATE <= P2S_STATE_INC;
			elsif(P2S_STATE = 6) then
				SERIAL_OUT_LOCAL <= DOB(4); 
				P2S_STATE <= P2S_STATE_INC;
			elsif(P2S_STATE = 7) then
				SERIAL_OUT_LOCAL <= DOB(5); 
				P2S_STATE <= P2S_STATE_INC;
			elsif(P2S_STATE = 8) then
				SERIAL_OUT_LOCAL <= DOB(6); 
				P2S_STATE <= P2S_STATE_INC;
			elsif(P2S_STATE = 9) then
				-- last data bit
				SERIAL_OUT_LOCAL <= DOB(7); 
				P2S_STATE <= P2S_STATE_INC;
			elsif(P2S_STATE = 10) then
				-- stop bit
				SERIAL_OUT_LOCAL <= '1'; 
				P2S_STATE <= P2S_STATE_INC;
			elsif(P2S_STATE = 11) then
				-- ready to read another byte
				P2S_STATE <= 0;
			end if;
		end if;
	end if;
end process;

SERIAL_OUT <= SERIAL_OUT_LOCAL;

--// Test Point
TP(1) <= VALID_RX_UDP;
TP(2) <= BAUD_CLK;
TP(3) <= SERIAL_OUT_LOCAL;
TP(4) <= WEA;
TP(5) <= '1' when (P2S_STATE = 0) else '0';
TP(6) <= '1' when (RPTR /= 0) else '0';
TP(7) <= RPTR(0);
TP(8) <= '1' when (IP_RX_DATA = x"40") else '0';
TP(9) <= '1' when (DIA = x"40") else '0';
TP(10) <= '1' when (DOB = x"40") else '0';

-- TODO:
-- UDP CHECKSUM


end Behavioral;

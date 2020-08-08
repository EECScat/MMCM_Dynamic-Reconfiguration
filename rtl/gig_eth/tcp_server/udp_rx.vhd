-------------------------------------------------------------
-- MSS copyright 2003-2012
--	Filename:  UDP_RX.VHD
-- Author: Alain Zarembowitch / MSS
--	Version: 2
--	Date last modified: 3/6/12
-- Inheritance: 	COM-5402 UDP_RX2.VHD 2-12-11
--
-- description:  UDP protocol (receive-only). 
-- Receives and validates UDP frames. The data segment of the UDP frame is immediately 
-- forwarded to the application without any intermediate storage in an elastic buffer.
-- Thus the application must be capable of receiving data at full speed (125MHz/8-bit wide).
-- 
-- Various validation checks are performed in real-time while receiving a new frame.
-- If any of the check fails, the APP_DATA_VALID is cleared. It is therefore IMPORTANT
-- that the application rejects frame if APP_DATA_VALID = '0' at the end of the frame  
-- (APP_EOF = '1'). 
-- 
-- Validation checks:
-- MAC address, IP type, IP destination address, UDP protocol, 
-- UDP destination port, IP header checksum, UDP checksum
-- 
-- As there is no difference between IPv4 and IPv6 for UDP, this component is compatible with 
-- both IPv4 and IPv6.
--
-- Rev 2 3/6/12 AZ
-- Now parsing the UDP port number of the source.
---------------------------------------------------------------
library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.STD_LOGIC_ARITH.ALL;
use IEEE.STD_LOGIC_UNSIGNED.ALL;
--use work.com5402pkg.all;	-- defines global types, number of UDP rx streams, etc

entity UDP_RX is
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
		IP_BYTE_COUNT: in std_logic_vector(15 downto 0);	
		IP_HEADER_FLAG: in std_logic;
			-- latency: 2 CLKs after MAC_RX_DATA
			-- As the IP frame validity is checked on-the-fly, the user should always check if 
			-- the IP_RX_DATA_VALID is high AT THE END of the IP frame (IP_RX_EOF) to confirm that the 
			-- ENTIRE IP frame is valid. Validity checks already performed (in PACKET_PARSING) are 
			-- (a) destination IP address matches
			-- (b) protocol is IP
			-- (c) correct IP header checksum
			-- IP_BYTE_COUNT is reset at the start of the data field (i.e. immediately after the header)
			-- Always use IP_BYTE_COUNT using the IP_HEADER_FLAG context (inside or outside the IP header?)

		--// IP type, already parsed in PACKET_PARSING (shared code)
		RX_IP_PROTOCOL: in std_logic_vector(7 downto 0);
			-- The protocol information is valid as soon as the 8-bit IP protocol field in the IP header is read.
			-- Information stays until start of following packet.
			-- This component responds to protocol 17 = UDP 
			-- latency: 3 CLK after IP protocol field at byte 9 of the IP header
	  	RX_IP_PROTOCOL_RDY: in std_logic;
			-- 1 CLK wide pulse. 

		--// UDP attributes, already parsed in PACKET_PARSING (shared code)
		RX_UDP_CKSUM: in std_logic_vector(16 downto 0);
			-- UDP checksum (including pseudo-header).
			-- Correct checksum is either x10000 or x00001
		RX_UDP_CKSUM_RDY: in std_logic;
			-- 1 CLK pulse. Latency: 3 CLK after receiving the last UDP byte.
		
		--// configuration
		PORT_NO: in std_logic_vector(15 downto 0);
			-- accepts UDP packets with a destination port PORT_NO
		
		--// Application interface 
		-- Latency: 2 CLKs after the received IP frame.
		APP_DATA: out std_logic_vector(7 downto 0);
			-- UDP data field when APP_DATA_VALID = '1'
		APP_DATA_VALID: out std_logic;
			-- delineates the UDP data field
		APP_SOF: out std_logic;
			-- 1 CLK pulse indicating that APP_DATA is the first byte in the UDP data field.
		APP_EOF: out std_logic;
			-- 1 CLK pulse indicating that APP_DATA is the last byte in the UDP data field.
			-- ALWAYS CHECK APP_DATA_VALID at the end of packet (APP_EOF = '1') to confirm
			-- that the UDP packet is valid. External buffer may have to backtrack to the the last
			-- valid pointer to discard an invalid UDP packet.
			-- Reason: we only knows about bad UDP packets at the end.
		APP_SRC_UDP_PORT: out std_logic_vector(15 downto 0);
			-- Identify the source UDP port. Read when APP_EOF = '1' 
			

		-- Test Points
		TP: out std_logic_vector(10 downto 1)

			);
end entity;

architecture Behavioral of UDP_RX is
--------------------------------------------------------
--      COMPONENTS
--------------------------------------------------------
--------------------------------------------------------
--     SIGNALS
--------------------------------------------------------

--// UDP 16-BIT WORD -----------------------------
signal IP_RX_DATA_PREVIOUS: std_logic_vector(7 downto 0) := (others => '0');
signal UDP_BYTE_COUNT: std_logic_vector(15 downto 0) := (others => '0');

--// CHECK UDP VALIDITY -----------------------------
signal VALID_RX_UDP: std_logic := '0';
signal VALID_RX_UDP_CKSUM: std_logic := '0';
signal IP_RX_EOF_D: std_logic := '0';

--// COPY UDP DATA TO BUFFER ------------------------
signal IP_RX_DATA16: std_logic_vector(15 downto 0) := (others => '0');
signal RX_UDP_SIZE: std_logic_vector(15 downto 0) := (others => '0');
signal APP_DATA_E: std_logic_vector(7 downto 0) := (others => '0');
signal APP_DATA_VALID_E: std_logic := '0';
signal APP_SOF_E: std_logic  := '0';
signal APP_EOF_E: std_logic  := '0';

--------------------------------------------------------
--      IMPLEMENTATION
--------------------------------------------------------
begin

UDP_BYTE_COUNT <= IP_BYTE_COUNT;	-- valid outside the IP header, inside the UDP frame.

--// UDP 16-BIT WORD -----------------------------
-- reconstruct 16-bit words
UDP_PREVIOUS_BYTE_001: process(CLK)
begin
	if rising_edge(CLK) then
		if(IP_RX_DATA_VALID = '1') and (IP_HEADER_FLAG = '0') then
			-- UDP frame
			IP_RX_DATA_PREVIOUS <= IP_RX_DATA;	-- remember previous byte (useful when reading 16-bit fields)
		end if;
	end if;
end process;
IP_RX_DATA16 <= IP_RX_DATA_PREVIOUS & IP_RX_DATA;	-- reconstruct 16-bit field. 

--// CHECK UDP VALIDITY -----------------------------
-- The UDP packet reception is immediately cancelled if 
-- (a) the received packet type is not an IP datagram  (done in common code PACKET_PARSING)
-- (b) invalid destination IP  (done in common code PACKET_PARSING)
-- (c) incorrect IP header checksum (done in common code PACKET_PARSING)
-- (d) the received IP type is not UDP 
-- (e) destination port number is not the specified PORT_NO (constant)
-- (f) UDP checksum is incorrect
-- Aligned with IP_RX_DATA_VALID_D
VALIDITY_CHECK_001: process(ASYNC_RESET, CLK)
begin
	if(ASYNC_RESET = '1') then
		VALID_RX_UDP <= '1';
		IP_RX_EOF_D <= '0';
	elsif rising_edge(CLK) then
		IP_RX_EOF_D <= IP_RX_EOF;	-- read VALID_RX_UDP at the end of the packet.
		
		if(IP_RX_SOF = '1') then
			-- just received first word. Valid UDP datagram until proven otherwise
			VALID_RX_UDP <= '1';
		elsif(IP_RX_EOF = '1') and (IP_RX_DATA_VALID = '0') then
			-- invalid IP frame reported at the end of the IP frame.
			VALID_RX_UDP <= '0';
		elsif(RX_IP_PROTOCOL /= 17) and (RX_IP_PROTOCOL_RDY = '1') then
			-- (d) the received IP type is not UDP 
			VALID_RX_UDP <= '0';
		elsif(IP_RX_DATA_VALID = '1') and (UDP_BYTE_COUNT = 3) and (IP_HEADER_FLAG = '0') and (IP_RX_DATA16 /= PORT_NO) then
			-- (e) destination port number is not the specified PORT_NO (constant)
			VALID_RX_UDP <= '0';
	 	end if;
	end if;
end process;

-- new 3/6/12 AZ
-- parse UDP port of the source
APP_SRC_UDP_PORT_GEN: process(ASYNC_RESET, CLK)
begin
	if(ASYNC_RESET = '1') then
		APP_SRC_UDP_PORT <= (others => '0');
	elsif rising_edge(CLK) then
		if(IP_RX_DATA_VALID = '1') and (UDP_BYTE_COUNT = 1) and (IP_HEADER_FLAG = '0') then
			-- source port number 
			APP_SRC_UDP_PORT <= IP_RX_DATA16;
	 	end if;
	end if;
end process;

-- late arrival (one CLK after IP_RX_EOF)
VALID_RX_UDP_CKSUM <= '0' when (RX_UDP_CKSUM_RDY = '1') and not((RX_UDP_CKSUM = "1" & x"0000") or (RX_UDP_CKSUM = "0" & x"0001") ) 
								else '1';
		--(f) UDP checksum is incorrect
		-- NOTE: this check is performed while reading the last UDP byte. The outcome is available
		-- one clock AFTER the UDP_EOF
								



--// COPY UDP DATA TO OUTPUT BUFFER ------------------------
IP_RX_DATA16 <= IP_RX_DATA_PREVIOUS & IP_RX_DATA;	-- reconstruct 16-bit field. 

-- Prepare output
-- Keep track of the actual number of UDP bytes (otherwise we may forward dummy data
-- when the datagram is small and padded for minimum length).
-- Aligned with IP_RX_DATA_VALID_D
OUTPUT_GEN_001: process(ASYNC_RESET, CLK)
begin
	if(ASYNC_RESET = '1') then
		APP_DATA_E <= (others => '0');
		APP_DATA_VALID_E <= '0';
		APP_SOF_E <= '0';
		APP_EOF_E <= '0';
	elsif rising_edge(CLK) then
		if(IP_RX_DATA_VALID = '1') and (UDP_BYTE_COUNT = 5) and (IP_HEADER_FLAG = '0') then 
			-- UDP datagram size.
			RX_UDP_SIZE <= (IP_RX_DATA16 - 8);	-- subtract the UDP header (8 bytes).
			APP_DATA_VALID_E <= '0';
			APP_SOF_E <= '0';
			APP_EOF_E <= '0';
	  	elsif(IP_RX_DATA_VALID = '1') and (IP_HEADER_FLAG = '0') and (UDP_BYTE_COUNT >= 8) and (RX_UDP_SIZE /= 0) then 
			-- UDP header is always 8 bytes. Data field starts at byte 8.
			-- write byte to buffer as long as there is meaningful and valid UDP data, not filler.
			APP_DATA_E <= IP_RX_DATA;
			APP_DATA_VALID_E <= '1';
			RX_UDP_SIZE <= RX_UDP_SIZE - 1;
			if(UDP_BYTE_COUNT = 8) then
				APP_SOF_E <= '1';
			else
				APP_SOF_E <= '0';
			end if;
			if(RX_UDP_SIZE = 1) then
				APP_EOF_E <= '1';
			else
				APP_EOF_E <= '0';
			end if;
	  	else
			APP_DATA_VALID_E <= '0';
			APP_SOF_E <= '0';
			APP_EOF_E <= '0';
		end if;
	end if;
end process;

-- Delay UDP output because we have to wait one more CLK for the UDP checksum outcome.
-- Aligned with IP_RX_DATA_VALID_D2
OUTPUT_GEN_002: process(ASYNC_RESET, CLK)
begin
	if(ASYNC_RESET = '1') then
		APP_DATA <= (others => '0');
		APP_DATA_VALID <= '0';
		APP_SOF <= '0';
		APP_EOF <= '0';
	elsif rising_edge(CLK) then
		APP_DATA <= APP_DATA_E;
		APP_DATA_VALID <= APP_DATA_VALID_E and VALID_RX_UDP and VALID_RX_UDP_CKSUM;
		APP_SOF <= APP_SOF_E and VALID_RX_UDP;	-- no need for SOF if UDP frame is invalid
		APP_EOF <= APP_EOF_E;
	end if;
end process;





--// Test Point
TP(1) <= '1' when (RX_IP_PROTOCOL = 17) and (RX_IP_PROTOCOL_RDY = '1')  else '0';	-- UDP
TP(2) <= APP_SOF_E;
TP(3) <= APP_DATA_VALID_E;
TP(4) <= APP_EOF_E;
TP(5) <= VALID_RX_UDP;	-- valie at EOF
TP(6) <= VALID_RX_UDP_CKSUM;	-- valid at EOF


end Behavioral;

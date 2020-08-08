-------------------------------------------------------------
-- MSS copyright 2003-2014
--	Filename:  PACKET_PARSING.VHD
-- Author: Alain Zarembowitch / MSS
--	Version: 4
--	Date last modified: 2/1/14
-- Inheritance: 	COM-5003 PACKET_PARSING.VHD  9/4/2008
--
-- description: Common code. This component parses the received packets from the MAC
-- and extracts key information shared by all protocols.  
-- Reads receive packet structure on the fly and detect the following
-- (a) encapsulation: ethernet (RFC 894) or 802.2/802.3 (RFC 1042)
-- (b) type: 0800 IP datagram, 0806 ARP request/reply, 8035 RARP request/reply
-- (c) IP address match
-- (d) IP port match
-- (e) IP protocol detected: ICMP, UDP, TCP-IP
-- (f) IP checksum verification
-- It also saves the source IP/source LAN address on the fly to avoid doing ARPs
-- This module includes all checks which could be performed in multiple protocol modules.
-- The goal is to share these checks to save implementation gates.
-- Each protocol layer is associated with one CLK latency. 
--
-- Limitations: 802.3/802.2 encapsulation is only detected, not supported for any protocol.
--
-- KEY ASSUMPTION: there is never a gap in a rx packet (i.e. MAC_RX_DATA_VALID is high
-- from start of frame to end of frame inclusive). This is a correct assumption when 
-- interfacing with a MAC, but is incompatible with a local tx->rx loopback test because
-- a transmit packet can include gaps).
--
-- Rev 2 7/27/13 AZ
-- when SIMULATION = '1' UDP checksum is forced to a valid 0x0001 irrespective of the 16-bit checksum
-- captured by Wireshark (Wireshark many not be able to collect offloaded checksum computations)
--
-- Rev 3 11/14/13 AZ
-- changed IP_HEADER_CHECKSUM_VALID when SIMULATION = '1'.
-- additional outputs for use by external components.
--
-- Rev 4 2/1/14 AZ
-- Updated sensitivity lists.
---------------------------------------------------------------
library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.STD_LOGIC_ARITH.ALL;
use IEEE.STD_LOGIC_UNSIGNED.ALL;

entity PACKET_PARSING is
	generic (
		IPv6_ENABLED: std_logic := '0';
			-- 0 to minimize size, 1 to allow IPv6 in addition to IPv4 (larger size)
		SIMULATION: std_logic := '0'
			-- 1 during simulation with Wireshark .cap file, '0' otherwise
			-- Wireshark many not be able to collect offloaded checksum computations.
			-- when SIMULATION =  '1': (a) IP header checksum is valid if 0000,
			-- (b) TCP checksum computation is forced to a valid 00001 irrespective of the 16-bit checksum
			-- captured by Wireshark.
			-- (c) UDP checksum is forced to a valid 0x0001 irrespective of the 16-bit checksum
			-- captured by Wireshark
	);
    Port ( 
		--// CLK, RESET
		ASYNC_RESET: in std_logic;
		CLK: in std_logic;
		TICK_4US: in std_logic;

		--// Packet/Frame received
		MAC_RX_DATA: in std_logic_vector(7 downto 0);
		MAC_RX_DATA_VALID: in std_logic;
			-- one CLK-wide pulse indicating a new byte is read from the received frame
			-- and can be read at MAC_RX_DATA
			-- ALWAYS ON FROM SOF TO EOF (i.e. no gaps)
		MAC_RX_SOF: in std_logic;
			-- Start of Frame: one CLK-wide pulse indicating the first word in the received frame
			-- aligned with MAC_RX_DATA_VALID.
		MAC_RX_EOF: in std_logic;
			-- End of Frame: one CLK-wide pulse indicating the last word in the received frame
			-- aligned with MAC_RX_DATA_VALID.

		--// local IP address
		IPv4_ADDR: in std_logic_vector(31 downto 0);
		IPv6_ADDR: in std_logic_vector(127 downto 0);
			-- local IP address. 4 bytes for IPv4, 16 bytes for IPv6
			-- Natural order (MSB) 172.16.1.128 (LSB) as transmitted in the IP frame.
			
		--// Received IP frame
		-- Excludes MAC layer header. Includes IP header.
		IP_RX_DATA: out std_logic_vector(7 downto 0);
		IP_RX_DATA_VALID: out std_logic;	
		IP_RX_SOF: out std_logic;
		IP_RX_EOF: out std_logic;
		IP_BYTE_COUNT: out std_logic_vector(15 downto 0);	
		IP_HEADER_FLAG: out std_logic;
			-- latency: 2 CLKs after MAC_RX_DATA
			-- As the IP frame validity is checked on-the-fly, the user should always check if 
			-- the IP_RX_DATA_VALID is high AT THE END of the IP frame (IP_RX_EOF) to confirm that the 
			-- ENTIRE IP frame is valid. Validity checks performed within are 
			-- (a) destination IP address matches
			-- (b) protocol is IP
			-- (c) correct IP header checksum
			-- IP_BYTE_COUNT is reset at the start of the data field (i.e. immediately after the header)
			-- Always use IP_BYTE_COUNT using the IP_HEADER_FLAG context (inside or outside the IP header?)


		--// Received type
		RX_TYPE: out std_logic_vector(3 downto 0);
			-- Information stays until start of following packet.
			-- 0 = unknown type
			-- 1 = Ethernet encapsulation, IP datagram
			-- 2 = Ethernet encapsulation, ARP request/reply
			-- 3 = Ethernet encapsulation, RARP request/reply
			-- 9 = IEEE 802.3/802.2  encapsulation, IP datagram (almost never used)
			-- 10 = IEEE 802.3/802.2  encapsulation, ARP request/reply (almost never used)
			-- 11 = IEEE 802.3/802.2  encapsulation, RARP request/reply (almost never used)
	  	RX_TYPE_RDY: out std_logic;
			-- 1 CLK-wide pulse indicating that a detection was made on the received packet
			-- type, and that RX_TYPE can be read.
			-- Detection occurs as soon as possible, two clocks after receiving byte 13 or 21.

		--// IP type: 
		RX_IPv4_6n: out std_logic;
			-- IP version. 4 or 6
		RX_IP_PROTOCOL: out std_logic_vector(7 downto 0);
			-- The protocol information is valid as soon as the 8-bit IP protocol field in the IP header is read.
			-- Information stays until start of following packet.
			-- most common protocols: 
			-- 0 = unknown, 1 = ICMP, 2 = IGMP, 6 = TCP, 17 = UDP, 41 = IPv6 encapsulation, 89 = OSPF, 132 = SCTP
			-- latency: 3 CLK after IP protocol field at byte 9 of the IP header
	  	RX_IP_PROTOCOL_RDY: out std_logic;
			-- 1 CLK wide pulse. 

		--// Destination IP check for IP datagram
		-- IP is checked only for IP datagrams (RX_TYPE 1)
		-- Check is agains full IP address, full broadcast and subnet-directed broadcast.
		VALID_DEST_IP: out std_logic;
			-- 1 = valid , 0 = invalid. Read when VALID_DEST_IP_RDY = '1'
		VALID_DEST_IP_RDY : out std_logic;
			-- 1 CLK wide pulse. 

		--// IP header checksum verification
		IP_HEADER_CHECKSUM_VALID: out std_logic;
		IP_HEADER_CHECKSUM_VALID_RDY: out std_logic;
		
		--// Packet origin, already parsed in PACKET_PARSING (shared code)
		RX_SOURCE_MAC_ADDR: out std_logic_vector(47 downto 0);	-- all received packets
		RX_SOURCE_IP_ADDR: out std_logic_vector(127 downto 0);  	-- IPv4,IPv6,ARP
		RX_SOURCE_TCP_PORT_NO: out std_logic_vector(15 downto 0);
		RX_DEST_IP_ADDR: out std_logic_vector(127 downto 0);  	
			
		--// UDP attributes
		RX_UDP_CKSUM: out std_logic_vector(16 downto 0);
			-- UDP checksum (including pseudo-header).
			-- Correct checksum is either x10000 or x00001
		RX_UDP_CKSUM_RDY: out std_logic;
			-- 1 CLK pulse. Latency: 3 CLK after receiving the last UDP byte.

		--// TCP attributes
		RX_TCP_BYTE_COUNT: out std_logic_vector(15 downto 0);
		RX_TCP_HEADER_FLAG: out std_logic;
			-- counts bytes within the TCP frame (i.e. excluding MAC and IP headers) 
			-- but including TCP header and data fields.	Also outlines the TCP header.
			-- Aligned with IP_RX_....
		RX_TCP_FLAGS: out std_logic_vector(7 downto 0);
			-- TCP flags (MSb) CWR/ECE/URG/ACK/PSH/RST/SYN/FIN (LSb)
		RX_TCP_CKSUM: out std_logic_vector(16 downto 0);
			-- TCP checksum (including pseudo-header).
			-- Correct checksum is either x10000 or x00001. Read 1 clk after IP_RX_EOF
		RX_TCP_SEQ_NO: out std_logic_vector(31 downto 0);
			-- sequence number decoded from the incoming TCP segment 
		RX_TCP_ACK_NO: out std_logic_vector(31 downto 0);
			-- acknowledgement number decoded from the incoming TCP segment
		RX_TCP_WINDOW_SIZE: out std_logic_vector(15 downto 0);
			-- window size decoded from the incoming TCP segment 
		RX_DEST_TCP_PORT_NO: out std_logic_vector(15 downto 0);
			-- destination TCP port
		
		--// TEST POINTS, COMSCOPE TRACES
		CS1: out std_logic_vector(7 downto 0);
		CS1_CLK: out std_logic;
		CS2: out std_logic_vector(7 downto 0);
		CS2_CLK: out std_logic;
		TP: out std_logic_vector(10 downto 1)

			);
end entity;

architecture Behavioral of PACKET_PARSING is
--------------------------------------------------------
--      COMPONENTS
--------------------------------------------------------
--------------------------------------------------------
--     SIGNALS
--------------------------------------------------------
-- NOTATIONS: 
-- _E as one-CLK early sample
-- _D as one-CLK delayed sample
-- _D2 as two-CLKs delayed sample

--// BYTE COUNT ----------------------
signal MAC_RX_DATA_VALID_D: std_logic := '0';
signal MAC_RX_SOF_D: std_logic := '0';
signal MAC_RX_EOF_D: std_logic := '0';
signal MAC_RX_DATA_D: std_logic_vector(7 downto 0) := x"00";
signal MAC_RX_DATA_PREVIOUS_D: std_logic_vector(7 downto 0) := x"00";
signal BYTE_COUNT: integer range 0 to 2047;			-- read/use at MAC_RX_DATA_VALID_D

--// TYPE ---------------------------------
signal RX_TYPE_local: std_logic_vector(3 downto 0) := x"0";
signal RX_TYPE_RDY_local: std_logic := '0';
signal TYPE_FIELD_D: std_logic_vector(15 downto 0) := (others => '0');

--// SOURCE MAC ADDRESS ------------------------------------
signal RX_SOURCE_MAC_ADDR_local: std_logic_vector(47 downto 0) := (others => '0');

--// IP BYTE COUNT ----------------------
signal MAC_RX_DATA_VALID_D2: std_logic := '0';
signal MAC_RX_SOF_D2: std_logic := '0';
signal MAC_RX_EOF_D2: std_logic := '0';
signal MAC_RX_DATA_D2: std_logic_vector(7 downto 0) := x"00";
signal IP_BYTE_COUNT_local: std_logic_vector(15 downto 0) := (others => '0');			-- read/use at MAC_RX_DATA_VALID_D2
signal IP_BYTE_COUNT_INC: std_logic_vector(15 downto 0) := (others => '0');		-- read/use at MAC_RX_DATA_VALID_D2
signal IP_HEADER_FLAG_local: std_logic := '0';							-- read/use at MAC_RX_DATA_VALID_D2
signal IP_FRAME_FLAG: std_logic := '0';							-- read/use at MAC_RX_DATA_VALID_D2
signal IP_RX_SOF_local: std_logic := '0';							-- read/use at MAC_RX_DATA_VALID_D2
signal IP_RX_EOF_local: std_logic := '0';							-- read/use at MAC_RX_DATA_VALID_D2
signal IP_HEADER_LENGTH_WORDS: std_logic_vector(3 downto 0) := (others => '0');	-- expressed in 32-bit words. read/use at MAC_RX_DATA_VALID_D2
signal RX_IPv4_6n_local: std_logic := '1';
signal IP_RX_DATA_VALID_local: std_logic := '0';
signal IP_BYTE_COUNT_E: std_logic_vector(15 downto 0) := x"0000";			-- earlier
signal IP_HEADER_FLAG_E: std_logic := '0';							
signal IP_FRAME_FLAG_E: std_logic := '0';						
signal IP_HEADER_LENGTH_WORDS_DEC: std_logic_vector(3 downto 0) := "0000";	
signal IP_RX_EOF_E: std_logic := '0';


--// IP PROTOCOL ----------------------
signal RX_IP_PROTOCOL_local: std_logic_vector(7 downto 0) := x"00";

--// VALIDATE IP ADDRESS ----------------------
signal VALID_DEST_IP_local: std_logic := '0';
signal VALID_DEST_IP_RDY_local: std_logic := '0';
signal IP_ADDR_local: std_logic_vector(127 downto 0) := x"00000000000000000000000000000000";

--// VALIDATE IP HEADER CHECKSUM ----------------------
signal TYPE_FIELD_D2: std_logic_vector(15 downto 0) := (others => '0');
signal IP_HEADER_CHECKSUM: std_logic_vector(16 downto 0) := (others => '0');	-- 16-bit sum + carry
signal IP_HEADER_CHECKSUM_VALID_local: std_logic := '0';							-- read/use at MAC_RX_DATA_VALID_D3
signal IP_HEADER_CHECKSUM_VALID_RDY_local: std_logic := '0';							-- read/use at MAC_RX_DATA_VALID_D3
signal IP_HEADER_FLAG_D: std_logic := '0';	

--// IP LENGTH ----------------------
signal IP_PAYLOAD_LENGTH: std_logic_vector(15 downto 0) := x"0000";	-- read/use at RX_SAMPLE_CLK_D3_LOCAL. IP payload length in bytes
signal IP_PAYLOAD_LENGTH_RDY: std_logic := '0';

--// SOURCE & DESTINATION IP ADDRESS -------------------------
signal RX_SOURCE_IP_ADDR_local: std_logic_vector(127 downto 0) := (others => '0');
signal RX_DEST_IP_ADDR_local: std_logic_vector(127 downto 0) := (others => '0');

--// CHECK IP VALIDITY ----------------------
signal VALID_IP_FRAME: std_logic := '0';

--//--- UDP LAYER ---------------------------------
signal RX_UDP_CKSUM_local: std_logic_vector(16 downto 0) := (others => '0');
signal RX_UDP_CKSUM_A: std_logic_vector(16 downto 0) := (others => '0');

--//-- TCP LAYER ---------------------------------
signal RX_TCP_BYTE_COUNT_local: std_logic_vector(15 downto 0) := (others => '0');
signal RX_TCP_BYTE_COUNT_INC: std_logic_vector(15 downto 0) := (others => '0');
signal RX_TCP_DATA_OFFSET: std_logic_vector(3 downto 0) := (others => '0');
signal RX_TCP_CKSUM_local: std_logic_vector(16 downto 0) := (others => '0');
signal RX_TCP_CKSUM_A: std_logic_vector(16 downto 0) := (others => '0');
signal RX_TCP_HEADER_FLAG_local: std_logic := '0';

------------------------------------------------------
--      IMPLEMENTATION
--------------------------------------------------------
begin

---------------------------------------------------
---- PACKET LAYER ---------------------------------
---------------------------------------------------

--// PACKET BYTE COUNT ----------------------
-- Most packet processing is performed with a 1CLK latency (processes MAC_RX_DATA_D and MAC_RX_DATA_VALID_D)
-- count received bytes for each incoming packet. 0 is the first byte.
BYTE_COUNT_001: process(ASYNC_RESET, CLK)
begin
	if(ASYNC_RESET = '1') then
		BYTE_COUNT <= 0;
		MAC_RX_DATA_D <= (others => '0');
		MAC_RX_DATA_VALID_D <= '0';
		MAC_RX_SOF_D <= '0';
		MAC_RX_EOF_D <= '0';
	elsif rising_edge(CLK) then
		-- reclock data and sample clock so that they are aligned with the byte count.
		MAC_RX_DATA_VALID_D <= MAC_RX_DATA_VALID;
		MAC_RX_SOF_D <= MAC_RX_SOF;
		MAC_RX_EOF_D <= MAC_RX_EOF;

		if(MAC_RX_DATA_VALID = '1') then
			MAC_RX_DATA_D <= MAC_RX_DATA;
			-- also remember previous byte (useful when comparing 16-bit fields)
			MAC_RX_DATA_PREVIOUS_D <= MAC_RX_DATA_D;
		end if;

		if(MAC_RX_SOF = '1') then
			-- just received first byte. 
			BYTE_COUNT <= 0;
	  	elsif(MAC_RX_DATA_VALID = '1') then
			BYTE_COUNT <= BYTE_COUNT + 1;
		end if;
	end if;
end process;

--// PACKET TYPE ---------------------------------
-- type detection at word 6 (Ethernet encapsulation, RFC 894)
-- OR at word 10 (802.3)
TYPE_FIELD_D <= MAC_RX_DATA_PREVIOUS_D & MAC_RX_DATA_D;	-- reconstruct 16-bit type field. Aligned with MAC_RX_DATA_VALID_D

DETECT_TYPE_001: process(ASYNC_RESET, CLK)
begin
	if(ASYNC_RESET = '1') then
		RX_TYPE_local <= x"0";	-- unknown type
		RX_TYPE_RDY_local <= '0';
	elsif rising_edge(CLK) then
		if(MAC_RX_SOF_D = '1') then
			-- clear type to unknown
			RX_TYPE_local <= x"0";	-- unknown type
		elsif(MAC_RX_DATA_VALID_D = '1') and (BYTE_COUNT = 13) and (RX_TYPE_local = 0) then
			-- Ethernet encapsulation, RFC 894
			if(TYPE_FIELD_D = x"0800") then
				-- IP datagram
				RX_TYPE_local <= x"1";
				RX_TYPE_RDY_local <= '1';
			elsif(TYPE_FIELD_D = x"0806") then
				-- ARP request/reply
				RX_TYPE_local <= x"2";
				RX_TYPE_RDY_local <= '1';
			elsif(TYPE_FIELD_D = x"8035") then
				-- RARP request/reply
				RX_TYPE_local <= x"3";
				RX_TYPE_RDY_local <= '1';
			else
				RX_TYPE_RDY_local <= '0';
		  	end if;
		elsif(MAC_RX_DATA_VALID_D = '1') and (BYTE_COUNT = 21) and (RX_TYPE_local = 0) then
			-- IEEE 802.3/802.2 encapsulation, RFC 1042
			if(TYPE_FIELD_D = x"0800") then
				-- IP datagram
				RX_TYPE_local <= x"9";
				RX_TYPE_RDY_local <= '1';
			elsif(TYPE_FIELD_D = x"0806") then
				-- ARP request/reply
				RX_TYPE_local <= x"A";
				RX_TYPE_RDY_local <= '1';
			elsif(TYPE_FIELD_D = x"8035") then
				-- RARP request/reply
				RX_TYPE_local <= x"B";
				RX_TYPE_RDY_local <= '1';
			else
				RX_TYPE_RDY_local <= '0';
		  	end if;
		elsif(MAC_RX_DATA_VALID_D = '1') and (BYTE_COUNT = 22) and (RX_TYPE_local = 0) then
			-- still unrecognized type at byte count 22, declare unknown type
			RX_TYPE_RDY_local <= '1';
		else
			RX_TYPE_RDY_local <= '0';
		end if;
	end if;
end process;
RX_TYPE <= RX_TYPE_local;
RX_TYPE_RDY <= RX_TYPE_RDY_local;

--// SOURCE MAC ADDRESS ------------------------------------
CAPTURE_001: process(ASYNC_RESET, CLK)
begin
	if(ASYNC_RESET = '1') then
		RX_SOURCE_MAC_ADDR_local <= (others => '0');
	elsif rising_edge(CLK) then
		if(MAC_RX_SOF_D = '1') then
			-- new packet. Reset MAC address
			RX_SOURCE_MAC_ADDR_local <= (others => '0');
		elsif(MAC_RX_DATA_VALID_D = '1') and (BYTE_COUNT >= 6) and (BYTE_COUNT <= 11) then
			RX_SOURCE_MAC_ADDR_local(47 downto 8) <= RX_SOURCE_MAC_ADDR_local(39 downto 0);
			RX_SOURCE_MAC_ADDR_local(7 downto 0) <= MAC_RX_DATA_D;
		end if;
	end if;
end process;
RX_SOURCE_MAC_ADDR <= RX_SOURCE_MAC_ADDR_local;

---------------------------------------------------
---- IP LAYER ---------------------------------
---------------------------------------------------

-- Most packet processing is performed with a 2CLK latency w.r.t. the input
-- (processes MAC_RX_DATA_D2 and MAC_RX_DATA_VALID_D2)
RECLOCK_001: process(ASYNC_RESET, CLK)
begin
	if(ASYNC_RESET = '1') then
		MAC_RX_DATA_D2 <= (others => '0');
		MAC_RX_DATA_VALID_D2 <= '0';
		MAC_RX_SOF_D2 <= '0';
		MAC_RX_EOF_D2 <= '0';
		TYPE_FIELD_D2 <= (others => '0');
	elsif rising_edge(CLK) then
		-- reclock data and sample clock so that they are aligned with the IP word count.
		MAC_RX_DATA_VALID_D2 <= MAC_RX_DATA_VALID_D;
		MAC_RX_SOF_D2 <= MAC_RX_SOF_D;
		MAC_RX_EOF_D2 <= MAC_RX_EOF_D;
		MAC_RX_DATA_D2 <= MAC_RX_DATA_D;
		TYPE_FIELD_D2 <= TYPE_FIELD_D;	-- reconstruct 16-bit type field. Aligned with MAC_RX_DATA_VALID_D2
	end if;
end process;

--// IP BYTE COUNT ----------------------
-- Start counting at the first IP header byte. 0 is the first byte.
-- Also delineate the IP header boundaries
-- The IP_BYTE_COUNT, IP_HEADER_FLAG, IP_HEADER_LENGTH_WORDS are to be used at MAC_RX_DATA_VALID_D2. 
-- Valid only if type is IP. 
IP_BYTE_COUNT_001: process(ASYNC_RESET, CLK)
begin
	if(ASYNC_RESET = '1') then
		IP_RX_SOF_local <= '0';
		IP_HEADER_LENGTH_WORDS <= (others => '0');
		RX_IPv4_6n_local <= '1';
 	elsif rising_edge(CLK) then
	
	
		if(MAC_RX_SOF_D = '1') then
			-- clear last IP word count, header flag, IP header length
			IP_RX_SOF_local <= '0';
			IP_HEADER_LENGTH_WORDS <= (others => '0');
			RX_IPv4_6n_local <= '1';
		elsif(MAC_RX_DATA_VALID_D = '1') and (BYTE_COUNT = 14) and (RX_TYPE_local = 1) then
			-- IP datagram, Ethernet encapsulation. 1st byte.
			IP_RX_SOF_local <= '1';
			if(MAC_RX_DATA_D(7 downto 4) = 6) then -- IPv4 or IPv6
				RX_IPv4_6n_local <= '0';	-- IPv6
			else
				RX_IPv4_6n_local <= '1';	-- IPv4
			end if;
			-- capture IP header length in 32-bit words.
			if(MAC_RX_DATA_D(7 downto 4) = 4) then
				-- IPv4 header
				IP_HEADER_LENGTH_WORDS <= MAC_RX_DATA_D(3 downto 0);	
			elsif(MAC_RX_DATA_D(7 downto 4) = 6) then
				-- IPv6 header. Fixed length 10*32-bit words
				IP_HEADER_LENGTH_WORDS <= x"A";	
			end if;
		elsif (MAC_RX_DATA_VALID_D = '1') and (RX_TYPE_local = 1) then
			IP_RX_SOF_local <= '0';
		else
			IP_RX_SOF_local <= '0';
	 	end if;
	end if;
end process;
RX_IPv4_6n <= RX_IPv4_6n_local;

-- Alternate (earlier) computation of the IP_BYTE_COUNT_E, can be helpful for better timing
IP_HEADER_LENGTH_WORDS_DEC <= IP_HEADER_LENGTH_WORDS - 1;
IP_BYTE_COUNT_E_001: process(ASYNC_RESET, CLK)
begin
	if(ASYNC_RESET = '1') then
		IP_BYTE_COUNT_E <= (others => '0');
		IP_FRAME_FLAG_E <= '0';
		IP_HEADER_FLAG_E <= '0';
		IP_BYTE_COUNT_local <= (others => '0');
		IP_BYTE_COUNT_INC <= conv_std_logic_vector(1, IP_BYTE_COUNT_INC'length) ;
		IP_FRAME_FLAG <= '0';
		IP_HEADER_FLAG_local <= '0';
		IP_RX_EOF_local <= '0';
 	elsif rising_edge(CLK) then
		-- delay one input byte
		if (MAC_RX_DATA_VALID_D2 = '1') then
			IP_BYTE_COUNT_local <= IP_BYTE_COUNT_E;
			IP_BYTE_COUNT_INC <= IP_BYTE_COUNT_E + 1;
			IP_FRAME_FLAG <= IP_FRAME_FLAG_E;
			IP_HEADER_FLAG_local <= IP_HEADER_FLAG_E;
			IP_RX_EOF_local <= IP_RX_EOF_E;
		else
			IP_RX_EOF_local <= '0';
		end if;

		if(MAC_RX_SOF_D = '1') then
			-- clear last IP word count
			IP_BYTE_COUNT_E <= (others => '0');
			IP_FRAME_FLAG_E <= '0';
			IP_HEADER_FLAG_E <= '0';
		elsif(MAC_RX_DATA_VALID_D = '1') and (BYTE_COUNT = 13) and (RX_TYPE_local = 0) and (TYPE_FIELD_D = x"0800") then
			-- last byte Ethernet header
			IP_FRAME_FLAG_E <= '1';
			IP_HEADER_FLAG_E <= '1';
		elsif (IP_RX_EOF_E = '1') then
			-- end of IP frame? (could happen before end of MAC data because of MAC frame padding)
			IP_BYTE_COUNT_E <= IP_BYTE_COUNT_E + 1;
			IP_FRAME_FLAG_E <= '0';
		elsif (MAC_RX_DATA_VALID_D = '1') and (RX_TYPE_local = 1) then 
			if (IP_HEADER_FLAG_E = '1') and (IP_BYTE_COUNT_E = ("0000000000" & IP_HEADER_LENGTH_WORDS_DEC & "11")) then
				-- last byte in the IP header
				IP_HEADER_FLAG_E <= '0';
				-- reset IP_BYTE_COUNT_E
				IP_BYTE_COUNT_E <= (others => '0');
			else
				IP_BYTE_COUNT_E <= IP_BYTE_COUNT_E + 1;
			end if;
		elsif(MAC_RX_EOF = '1') then
			-- catch all (in case length field is erroneous)
			IP_HEADER_FLAG_E <= '0';
		else
			IP_FRAME_FLAG_E <= '0';
	 	end if;
	end if;
end process;

IP_RX_EOF_E <= '1' when (MAC_RX_DATA_VALID_D2 = '1') and (IP_HEADER_FLAG_E = '0') and ((IP_BYTE_COUNT_E + 1) = IP_PAYLOAD_LENGTH) else '0';

--// IP PROTOCOL ----------------------
-- IP protocol (ICMP, UDP, TCP) detection 
-- latency: 3 CLK after IP protocol field at word 4 of the IP header
DETECT_IP_PROTOCOL_001: process(ASYNC_RESET, CLK)
begin
	if(ASYNC_RESET = '1') then
		RX_IP_PROTOCOL_local <= x"00";
		RX_IP_PROTOCOL_RDY <= '0';
	elsif rising_edge(CLK) then
		if(MAC_RX_SOF_D2 = '1') then
			-- clear type to unknown
	 		RX_IP_PROTOCOL_local <= x"00";
			RX_IP_PROTOCOL_RDY <= '0';
		elsif (RX_IPv4_6n_local = '1') and (MAC_RX_DATA_VALID_D2 = '1') and 
				(IP_BYTE_COUNT_local = 9) and (IP_HEADER_FLAG_local = '1') then
			-- IPv4. 
			-- Ethernet encapsulation, RFC 894 or IEEE 802.3 encapsulation, RFC 1042
			RX_IP_PROTOCOL_local <= MAC_RX_DATA_D2;
			RX_IP_PROTOCOL_RDY <= '1';
		elsif (IPv6_ENABLED = '1') and (RX_IPv4_6n_local = '0') and (MAC_RX_DATA_VALID_D2 = '1') and 
				(IP_BYTE_COUNT_local = 6) and (IP_HEADER_FLAG_local = '1') then
			-- IPv6 (only if enabled prior to synthesis)
			RX_IP_PROTOCOL_local <= MAC_RX_DATA_D2;	-- Next Header field. 
			RX_IP_PROTOCOL_RDY <= '1';
		else
			RX_IP_PROTOCOL_RDY <= '0';
		end if;
	end if;
end process;
RX_IP_PROTOCOL <= RX_IP_PROTOCOL_local;

--// VALIDATE IP ADDRESS ----------------------
-- Check only in the case of IP datagram, as identified by the RX_TYPE = 1 
-- latency: 3 CLK after receiving the last byte of the destination address field.
DEST_IP_CHECK_001: process(ASYNC_RESET, CLK)
begin
	if(ASYNC_RESET = '1') then
		VALID_DEST_IP_local <= '1';
		VALID_DEST_IP_RDY_local <= '0';
	elsif rising_edge(CLK) then
		if(MAC_RX_SOF_D2 = '1') then
			-- valid until proven otherwise
			VALID_DEST_IP_local <= '1';
			VALID_DEST_IP_RDY_local <= '0';
		elsif(RX_IPv4_6n_local = '1') and (MAC_RX_DATA_VALID_D2 = '1') and (IP_HEADER_FLAG_local = '1') then
			-- IPv4
			if (IP_BYTE_COUNT_local = 0) then
				-- at this point in the IP header, we know about IP version (4 or 6)
				IP_ADDR_local(31 downto 0) <= IPv4_ADDR;	-- move IPv4 address to a circular shifter
			elsif (IP_BYTE_COUNT_local >= 16) and (IP_BYTE_COUNT_local <= 19) then
				-- circular shift left
				IP_ADDR_local(7 downto 0) <= IP_ADDR_local(31 downto 24);
				IP_ADDR_local(31 downto 8) <= IP_ADDR_local(23 downto 0);
				-- does address byte match?
				if((MAC_RX_DATA_D2 /= IP_ADDR_local(31 downto 24)) and (MAC_RX_DATA_D2 /= x"FF")) then
					-- IP destination does not match this byte
					VALID_DEST_IP_local <= '0';
				end if;
				if(IP_BYTE_COUNT_local = 19) then
					VALID_DEST_IP_RDY_local <= '1';
				end if;
			else
				VALID_DEST_IP_RDY_local <= '0';
			end if;
		elsif(IPv6_ENABLED = '1') and (RX_IPv4_6n_local = '0') 
					and (MAC_RX_DATA_VALID_D2 = '1') and (IP_HEADER_FLAG_local = '1') then
			-- IPv6 (only if enabled prior to synthesis)
			if (IP_BYTE_COUNT_local = 0) then
				-- at this point in the IP header, we know about IP version (4 or 6)
				IP_ADDR_local <= IPv6_ADDR;	-- move IPv6 address to a circular shifter
			elsif (IP_BYTE_COUNT_local >= 24) and (IP_BYTE_COUNT_local <= 39) then
				-- circular shift left
				IP_ADDR_local(7 downto 0) <= IP_ADDR_local(127 downto 120);
				IP_ADDR_local(127 downto 8) <= IP_ADDR_local(119 downto 0);
				-- does address byte match?
				if((MAC_RX_DATA_D2 /= IP_ADDR_local(127 downto 120)) and (MAC_RX_DATA_D2 /= x"FF")) then
					-- IP destination does not match this byte
					VALID_DEST_IP_local <= '0';
				end if;
				if(IP_BYTE_COUNT_local = 39) then
					VALID_DEST_IP_RDY_local <= '1';
				end if;
			else
				VALID_DEST_IP_RDY_local <= '0';
			end if;
		else
			VALID_DEST_IP_RDY_local <= '0';
		end if;		
	end if;
end process;
VALID_DEST_IP <= VALID_DEST_IP_local;
VALID_DEST_IP_RDY <= VALID_DEST_IP_RDY_local;

--// VALIDATE IP HEADER CHECKSUM ----------------------
-- perform 1's complement sum of all 16-bit words within the header.
-- IP valid flag ready one CLK after the last header word (RX_SAMPLE_CLK_D2_LOCAL)
-- This applies only to IPv4 (no such field in IPv6)

IP_HEADER_CHECKSUM_001: process(ASYNC_RESET, CLK)
begin
	if(ASYNC_RESET = '1') then
		IP_HEADER_CHECKSUM <= (others => '0');
		IP_HEADER_CHECKSUM_VALID_local <= '0';
		IP_HEADER_CHECKSUM_VALID_RDY_local <= '0';
		IP_HEADER_FLAG_D <= '0';
	elsif rising_edge(CLK) then
		IP_HEADER_FLAG_D <= IP_HEADER_FLAG_local;

		if(MAC_RX_SOF_D2 = '1') then
			-- clear last checksum
			IP_HEADER_CHECKSUM <= (others => '0');
			IP_HEADER_CHECKSUM_VALID_local <= '0';
			IP_HEADER_CHECKSUM_VALID_RDY_local <= '0';
--		elsif (SIMULATION = '1') and (IP_BYTE_COUNT_local = 11) and (TYPE_FIELD_D2 = 0) then
--			-- special case: input is a wireshark .cap capture file.
--			-- wireshark cannot know about the IP header checksum because it was offloaded to hardware
--			IP_HEADER_CHECKSUM_VALID_RDY_local <= '1';
--			IP_HEADER_CHECKSUM_VALID_local <= '1';
		elsif (RX_IPv4_6n_local = '1') and (MAC_RX_DATA_VALID_D2 = '1') and (IP_HEADER_FLAG_local = '1') and (IP_BYTE_COUNT_local(0) = '1') then 
			-- once every word (2 bytes) do 16-bit sum, 1's complement. If previous carry in IP_HEADER_CHECKSUM(16), add 1.
			IP_HEADER_CHECKSUM <=  ("0" & IP_HEADER_CHECKSUM(15 downto 0)) 
										+ ("0" & TYPE_FIELD_D2) + (x"0000" & IP_HEADER_CHECKSUM(16)); 
--		elsif (SIMULATION = '0') and (RX_IPv4_6n_local = '1') and (IP_HEADER_FLAG_local = '0') and (IP_HEADER_FLAG_D = '1') then
		elsif (RX_IPv4_6n_local = '1') and (IP_HEADER_FLAG_local = '0') and (IP_HEADER_FLAG_D = '1') then
			-- end of IP header. Correct for last carry and verify checksum.
			IP_HEADER_CHECKSUM_VALID_RDY_local <= '1';
			
			if(IP_HEADER_CHECKSUM(16 downto 0) = "0" & x"FFFF") then
				-- case1: no previous carry. Checksum OK
				IP_HEADER_CHECKSUM_VALID_local <= '1';
			elsif(IP_HEADER_CHECKSUM(16 downto 0) = "1" & x"FFFE") then
				-- case2: previous carry. Checksum OK
				IP_HEADER_CHECKSUM_VALID_local <= '1';
			elsif(SIMULATION = '1') then
				-- special case: input is a wireshark .cap capture file.
				-- wireshark may know about the IP header checksum because it may have been offloaded to hardware
				IP_HEADER_CHECKSUM_VALID_local <= '1';
			end if;
		else
			IP_HEADER_CHECKSUM_VALID_RDY_local <= '0';
	   end if;
 	end if;
end process;

-- make information available to other components
IP_HEADER_CHECKSUM_VALID <= IP_HEADER_CHECKSUM_VALID_local;
IP_HEADER_CHECKSUM_VALID_RDY <= IP_HEADER_CHECKSUM_VALID_RDY_local;


--// IP LENGTH ----------------------
-- parse IP payload length (excluding header), expressed in bytes. 

IP_PAYLOAD_LENGTH_001: process(ASYNC_RESET, CLK)
begin
	if(ASYNC_RESET = '1') then
		IP_PAYLOAD_LENGTH <= (others => '0');
		IP_PAYLOAD_LENGTH_RDY <= '0';
	elsif rising_edge(CLK) then
		if(MAC_RX_SOF_D2 = '1') then
			-- clear length
			IP_PAYLOAD_LENGTH <= (others => '0');
		elsif(RX_IPv4_6n_local = '1') and (MAC_RX_DATA_VALID_D2 = '1') and 
				(IP_HEADER_FLAG_local = '1') and (IP_BYTE_COUNT_local = 3) then
			-- IPv4. Get total length first then subtract header size (expressed in 32-bit words)
			-- (needed?) IP_TOTAL_LENGTH <= TYPE_FIELD_D2;
			IP_PAYLOAD_LENGTH <= TYPE_FIELD_D2 - ("0000000000" & IP_HEADER_LENGTH_WORDS & "00");
			IP_PAYLOAD_LENGTH_RDY <= '1';
		elsif(IPv6_ENABLED = '1') and (RX_IPv4_6n_local = '0') and (MAC_RX_DATA_VALID_D2 = '1') and 
				(IP_HEADER_FLAG_local = '1') and (IP_BYTE_COUNT_local = 5) then
			-- IPv6 (only if enabled prior to synthesis)
			IP_PAYLOAD_LENGTH <= TYPE_FIELD_D2;	-- Payload length, including any extension header. Expressed in bytes.
			IP_PAYLOAD_LENGTH_RDY <= '1';
		else
			IP_PAYLOAD_LENGTH_RDY <= '0';
		end if;
	end if;
end process;


--// SOURCE & DESTINATION IP ADDRESS -------------------------
-- includes IP (v4, v6) and ARP
CAPTURE_SOURCE_IP_001: process(ASYNC_RESET, CLK)
begin
	if(ASYNC_RESET = '1') then
		RX_SOURCE_IP_ADDR_local <= (others => '0');
	elsif rising_edge(CLK) then
		if(MAC_RX_SOF_D2 = '1') then
			-- new packet. clear field.
			RX_SOURCE_IP_ADDR_local <= (others => '0');

		elsif(RX_IPv4_6n_local = '1') then
			-- IPv4
			if(MAC_RX_DATA_VALID_D2 = '1') and (IP_HEADER_FLAG_local = '1') and 
				(IP_BYTE_COUNT_local >= 12) and (IP_BYTE_COUNT_local <= 15)  then
				-- IP datagram
				RX_SOURCE_IP_ADDR_local(31 downto 8) <= RX_SOURCE_IP_ADDR_local(23 downto 0);
				RX_SOURCE_IP_ADDR_local(7 downto 0) <= MAC_RX_DATA_D2;
				
			elsif(MAC_RX_DATA_VALID_D = '1') and (RX_TYPE_local = 2) and (BYTE_COUNT >= 28) and (BYTE_COUNT <= 31) then
				-- ARP request/reply, Ethernet encapsulation, RFC 894
				RX_SOURCE_IP_ADDR_local(31 downto 8) <= RX_SOURCE_IP_ADDR_local(23 downto 0);
				RX_SOURCE_IP_ADDR_local(7 downto 0) <= MAC_RX_DATA_D;
			end if;

		elsif (IPv6_ENABLED = '1') and (RX_IPv4_6n_local = '0')	then		
			-- IPv6 (when enabled)
			if(MAC_RX_DATA_VALID_D2 = '1') and (IP_HEADER_FLAG_local = '1') and 
				(IP_BYTE_COUNT_local >= 8) and (IP_BYTE_COUNT_local <= 23)  then
				-- IP datagram
				RX_SOURCE_IP_ADDR_local(127 downto 8) <= RX_SOURCE_IP_ADDR_local(119 downto 0);
				RX_SOURCE_IP_ADDR_local(7 downto 0) <= MAC_RX_DATA_D2;
			end if;
		end if;
	end if;
end process;
RX_SOURCE_IP_ADDR <= RX_SOURCE_IP_ADDR_local;

CAPTURE_DEST_IP_001: process(ASYNC_RESET, CLK)
begin
	if(ASYNC_RESET = '1') then
		RX_DEST_IP_ADDR_local <= (others => '0');
	elsif rising_edge(CLK) then
		if(MAC_RX_SOF_D2 = '1') then
			-- new packet. clear field.
			RX_DEST_IP_ADDR_local <= (others => '0');

		elsif(RX_IPv4_6n_local = '1') then
			-- IPv4
			if(MAC_RX_DATA_VALID_D2 = '1') and (IP_HEADER_FLAG_local = '1') and 
				(IP_BYTE_COUNT_local >= 16) and (IP_BYTE_COUNT_local <= 19)  then
				-- IP datagram
				RX_DEST_IP_ADDR_local(31 downto 8) <= RX_DEST_IP_ADDR_local(23 downto 0);
				RX_DEST_IP_ADDR_local(7 downto 0) <= MAC_RX_DATA_D2;
				
			elsif(MAC_RX_DATA_VALID_D = '1') and (RX_TYPE_local = 2) and (BYTE_COUNT >= 38) and (BYTE_COUNT <= 41) then
				-- ARP request/reply, Ethernet encapsulation, RFC 894
				RX_DEST_IP_ADDR_local(31 downto 8) <= RX_DEST_IP_ADDR_local(23 downto 0);
				RX_DEST_IP_ADDR_local(7 downto 0) <= MAC_RX_DATA_D;
			end if;

		elsif (IPv6_ENABLED = '1') and (RX_IPv4_6n_local = '0')	then		
			-- IPv6 (when enabled)
			if(MAC_RX_DATA_VALID_D2 = '1') and (IP_HEADER_FLAG_local = '1') and 
				(IP_BYTE_COUNT_local >= 24) and (IP_BYTE_COUNT_local <= 39)  then
				-- IP datagram
				RX_DEST_IP_ADDR_local(127 downto 8) <= RX_DEST_IP_ADDR_local(119 downto 0);
				RX_DEST_IP_ADDR_local(7 downto 0) <= MAC_RX_DATA_D2;
			end if;
		end if;
	end if;
end process;
RX_DEST_IP_ADDR <= RX_DEST_IP_ADDR_local;


--// CHECK IP VALIDITY ----------------------
IP_BYTE_COUNT <= IP_BYTE_COUNT_local;
IP_RX_DATA <= MAC_RX_DATA_D2;
IP_RX_SOF <= IP_RX_SOF_local;
IP_RX_EOF <= IP_RX_EOF_local;
IP_RX_DATA_VALID_local <= MAC_RX_DATA_VALID_D2 and VALID_IP_FRAME and IP_FRAME_FLAG;
IP_RX_DATA_VALID <= IP_RX_DATA_VALID_local;
IP_HEADER_FLAG <= IP_HEADER_FLAG_local;

-- The received IP frame is presumed valid until proven otherwise. 
-- IP frame validity checks include: 
-- (a) destination IP address matches
-- (b) protocol is IP
-- (c) correct IP header checksum
VALID_IP_FRAME_CHECK_001: process(ASYNC_RESET, CLK)
begin
	if(ASYNC_RESET = '1') then
		VALID_IP_FRAME <= '1';
	elsif rising_edge(CLK) then
		if(MAC_RX_SOF = '1') then
			-- just received first byte. valid until proven otherwise
			VALID_IP_FRAME <= '1';
		elsif(RX_TYPE_RDY_local = '1') and (RX_TYPE_local /= 1) then
			-- (a) the received packet type is not an IP datagram 
			VALID_IP_FRAME <= '0';
		elsif(VALID_DEST_IP_RDY_local = '1') and (VALID_DEST_IP_local = '0') then
			-- (b) invalid destination IP (VALID_DEST_IP = '0') 
			VALID_IP_FRAME <= '0';
		elsif(IP_HEADER_CHECKSUM_VALID_RDY_local = '1') and (IP_HEADER_CHECKSUM_VALID_local = '0') then
			-- (c) invalid IP header checksum
			VALID_IP_FRAME <= '0';
	 	end if;
	end if;
end process;

---------------------------------------------------
--//--- UDP LAYER ---------------------------------
---------------------------------------------------

-- Compute UDP checksum, using the pseudo-header. 
-- Different pseudo-headers are used for IPv4 and IPv6
UDP_CHECKSUM_001: process(CLK)
begin
	if rising_edge(CLK) then
		RX_UDP_CKSUM_RDY <= IP_RX_EOF_local;
		
		if(RX_IPv4_6n_local = '1') and (MAC_RX_DATA_VALID_D2 = '1')  and (IP_FRAME_FLAG = '1') then
			-- IPv4
			if(IP_HEADER_FLAG_local = '1') then
				-- pseudo header
				if(IP_BYTE_COUNT_local = 3)  then 
					RX_UDP_CKSUM_local <= RX_UDP_CKSUM_A;	
				elsif(IP_BYTE_COUNT_local(0) = '1') and (IP_BYTE_COUNT_local >= 9) and (IP_BYTE_COUNT_local <= 19) 
					and (IP_BYTE_COUNT_local /= 11) then 	
					RX_UDP_CKSUM_local <= ("0" & RX_UDP_CKSUM_local(15 downto 0)) + RX_UDP_CKSUM_A + RX_UDP_CKSUM_local(16);
				end if;	
			else
				-- entire UDP packet (IP frame - header), 16-bit at a time
				if(IP_RX_EOF_local = '1')  and (SIMULATION = '1') then	-- new 7/27/13
					-- special case during simulation with Wireshark capture
					RX_UDP_CKSUM_local <= "0" & x"FFFF";
				elsif(IP_RX_EOF_local = '1')  and (IP_BYTE_COUNT_local(0) = '0') then
					-- special case: last UDP data byte is at an even address (odd number of bytes)
					RX_UDP_CKSUM_local <= ("0" & RX_UDP_CKSUM_local(15 downto 0)) + RX_UDP_CKSUM_A + RX_UDP_CKSUM_local(16);
				elsif(IP_BYTE_COUNT_local(0) = '1') then
					RX_UDP_CKSUM_local <= ("0" & RX_UDP_CKSUM_local(15 downto 0)) + RX_UDP_CKSUM_A + RX_UDP_CKSUM_local(16);
				end if;
			end if;	

		elsif (IPv6_ENABLED = '1') and (RX_IPv4_6n_local = '0') and (MAC_RX_DATA_VALID_D2 = '1')  and (IP_FRAME_FLAG = '1') then			
			-- IPv6 (when enabled)
			if(IP_HEADER_FLAG_local = '1') then
				-- pseudo header
				if(IP_BYTE_COUNT_local = 5)  then 
					RX_UDP_CKSUM_local <= RX_UDP_CKSUM_A;	
				elsif(IP_BYTE_COUNT_local(0) = '1') and (IP_BYTE_COUNT_local >= 7) and (IP_BYTE_COUNT_local <= 39) then 	
					RX_UDP_CKSUM_local <= ("0" & RX_UDP_CKSUM_local(15 downto 0)) + RX_UDP_CKSUM_A + RX_UDP_CKSUM_local(16);
				end if;	
			else
				-- entire UDP packet (IP frame - header), 16-bit at a time
				if(IP_RX_EOF_local = '1')  and (IP_BYTE_COUNT_local(0) = '0') then
					-- special case: last UDP data byte is at an even address (odd number of bytes)
					RX_UDP_CKSUM_local <= ("0" & RX_UDP_CKSUM_local(15 downto 0)) + RX_UDP_CKSUM_A + RX_UDP_CKSUM_local(16);
				elsif(IP_BYTE_COUNT_local(0) = '1') then
					RX_UDP_CKSUM_local <= ("0" & RX_UDP_CKSUM_local(15 downto 0)) + RX_UDP_CKSUM_A + RX_UDP_CKSUM_local(16);
				end if;
			end if;	
			
		end if;
	end if;
end process;

UDP_CHECKSUM_002: process(RX_IPv4_6n_local, IP_HEADER_FLAG_local, IP_BYTE_COUNT_local, TYPE_FIELD_D2, 
								  MAC_RX_DATA_D2, IP_RX_EOF_local)
begin
	if(RX_IPv4_6n_local = '1') then
			-- IPv4	
		if (IP_HEADER_FLAG_local = '1') then
			-- pseudo-header
			if(IP_BYTE_COUNT_local = 3) then
				RX_UDP_CKSUM_A <= "0" & TYPE_FIELD_D2 - 20;	-- UDP length
			elsif(IP_BYTE_COUNT_local = 9) then
				RX_UDP_CKSUM_A <= "0" & x"00" & MAC_RX_DATA_D2;	-- zeros + protocol (0x11)
			else
				RX_UDP_CKSUM_A <= "0" & TYPE_FIELD_D2; -- IP source and destination addresses
			end if;
		elsif(IP_RX_EOF_local = '1')  and (IP_BYTE_COUNT_local(0) = '0') then
			-- special case: last UDP data byte is at an even address (odd number of bytes)
			RX_UDP_CKSUM_A <= "0" & MAC_RX_DATA_D2 & x"00"; -- last byte
--		elsif(IP_BYTE_COUNT_local(0) = '1') then
		else
			-- entire UDP packet (IP frame - header), 16-bit at a time
			RX_UDP_CKSUM_A <= "0" & TYPE_FIELD_D2; -- add 16-bit at a time
		end if;		
		
	elsif (IPv6_ENABLED = '1') and (RX_IPv4_6n_local = '0')  then		
		-- IPv6 (when enabled)
		if (IP_HEADER_FLAG_local = '1') then
			if(IP_BYTE_COUNT_local = 5) then
				RX_UDP_CKSUM_A <= "0" & TYPE_FIELD_D2 - 40;	-- payload (UDP) length
			elsif(IP_BYTE_COUNT_local = 7) then
				RX_UDP_CKSUM_A <= "0" & x"00" & TYPE_FIELD_D2(15 downto 8);	-- zeros + protocol (0x11). trick for simpler code: protocol is at byte 6. 
			else
				RX_UDP_CKSUM_A <= "0" & TYPE_FIELD_D2; -- IP source and destination addresses
			end if;
		elsif(IP_RX_EOF_local = '1')  and (IP_BYTE_COUNT_local(0) = '0') then
			-- special case: last UDP data byte is at an even address (odd number of bytes)
			RX_UDP_CKSUM_A <= "0" & MAC_RX_DATA_D2 & x"00"; -- last byte
--		elsif(IP_BYTE_COUNT_local(0) = '1') then
		else
			-- entire UDP packet (IP frame - header), 16-bit at a time
			RX_UDP_CKSUM_A <= "0" & TYPE_FIELD_D2; -- add 16-bit at a time
		end if;	
	else
		RX_UDP_CKSUM_A <= (others => '0');
	end if;
end process;

RX_UDP_CKSUM <= not RX_UDP_CKSUM_local(16 downto 0);

---------------------------------------------------
---- TCP LAYER ---------------------------------
---------------------------------------------------

--// TCP RX BYTE COUNT -----------------------------
-- counts bytes within the TCP frame (i.e. excluding MAC and IP headers) but including TCP header and data fields.
-- Aligned with IP_RX_DATA_VALID
RX_TCP_BYTE_COUNT_INC <= RX_TCP_BYTE_COUNT_local + 1;
RX_TCP_BYTE_COUNT_001: process(ASYNC_RESET, CLK)
begin
	if(ASYNC_RESET = '1') then
		RX_TCP_BYTE_COUNT_local <= (others => '0');
		RX_TCP_HEADER_FLAG_local <= '0';
	elsif rising_edge(CLK) then
		if(IP_RX_SOF_local = '1') then
			-- new IP packet. Reset TCP byte counter.
			RX_TCP_BYTE_COUNT_local <= (others => '0');
			RX_TCP_HEADER_FLAG_local <= '0';
			
		-- last byte in the IP header	and next protocol is TCP
		elsif (MAC_RX_DATA_VALID_D = '1') and (RX_TYPE_local = 1) and (IP_HEADER_FLAG_local = '1') 
			and (IP_BYTE_COUNT_INC = ("0000000000" & IP_HEADER_LENGTH_WORDS & "00")) 
			and (RX_IP_PROTOCOL_local = 6) then

			RX_TCP_HEADER_FLAG_local <= '1';
			
		elsif (IP_HEADER_FLAG_local = '0') then
			-- TCP frame
			-- Note: count bytes even if we are not sure about the IP packet validity
			-- because we need to clear the TCP header flag in ALL cases
			RX_TCP_BYTE_COUNT_local <= RX_TCP_BYTE_COUNT_INC;

			-- end of TCP header
			if(RX_TCP_BYTE_COUNT_INC = ("0000000000" & RX_TCP_DATA_OFFSET & "00")) then
				RX_TCP_HEADER_FLAG_local <= '0';
			end if;
			
		end if;
	end if;
end process;
RX_TCP_BYTE_COUNT <= RX_TCP_BYTE_COUNT_local;
RX_TCP_HEADER_FLAG <= RX_TCP_HEADER_FLAG_local;

-- Decode key TCP fields
TCP_DECODE_001: process(ASYNC_RESET, CLK)
begin
	if(ASYNC_RESET = '1') then
		RX_SOURCE_TCP_PORT_NO <= (others => '0');
		RX_DEST_TCP_PORT_NO <= (others => '0');
		RX_TCP_SEQ_NO <= (others => '0');
		RX_TCP_ACK_NO <= (others => '0');
		RX_TCP_DATA_OFFSET <= (others => '0');
		RX_TCP_FLAGS <= (others => '0');
		RX_TCP_WINDOW_SIZE <= (others => '0');
	elsif rising_edge(CLK) then
		if(IP_RX_SOF_local = '1') then
			-- new IP packet. Reset TCP fields collected from previous frames.
			RX_SOURCE_TCP_PORT_NO <= (others => '0');
			RX_DEST_TCP_PORT_NO <= (others => '0');
			RX_TCP_SEQ_NO <= (others => '0');
			RX_TCP_ACK_NO <= (others => '0');
			RX_TCP_DATA_OFFSET <= x"5";	-- minimum data offset is 5. use until we reach the data offset field.
			RX_TCP_FLAGS <= (others => '0');
			RX_TCP_WINDOW_SIZE <= (others => '0');
			
		elsif(IP_RX_DATA_VALID_local = '1') and (RX_TCP_HEADER_FLAG_local = '1') then
			-- TCP header

			-- source port
			if(RX_TCP_BYTE_COUNT_local = 1) then
				RX_SOURCE_TCP_PORT_NO <= TYPE_FIELD_D2;
			end if;

			-- destination port
			if(RX_TCP_BYTE_COUNT_local = 3) then
				RX_DEST_TCP_PORT_NO <= TYPE_FIELD_D2;	
			end if;

			-- sequence number
			if(RX_TCP_BYTE_COUNT_local = 5) then
				RX_TCP_SEQ_NO(31 downto 16) <= TYPE_FIELD_D2;	
			end if;
			if(RX_TCP_BYTE_COUNT_local = 7) then
				RX_TCP_SEQ_NO(15 downto 0) <= TYPE_FIELD_D2;	
			end if;
			
			-- acknowledgment number
			if(RX_TCP_BYTE_COUNT_local = 9) then
				RX_TCP_ACK_NO(31 downto 16) <= TYPE_FIELD_D2;	
			end if;
			if(RX_TCP_BYTE_COUNT_local = 11) then
				RX_TCP_ACK_NO(15 downto 0) <= TYPE_FIELD_D2;	
			end if;

			-- capture TCP flags, data offset
			if(RX_TCP_BYTE_COUNT_local = 13) then
				RX_TCP_DATA_OFFSET <= TYPE_FIELD_D2(15 downto 12);	-- size of the TCP header in 32-bit words.
				RX_TCP_FLAGS <= MAC_RX_DATA_D2(7 downto 0);	-- TCP flags (aka control bits)
			end if;
			
			-- window size
			if(RX_TCP_BYTE_COUNT_local = 15) then
				RX_TCP_WINDOW_SIZE(15 downto 0) <= TYPE_FIELD_D2;	
			end if;
			
		end if;
	end if;
end process;





-- Compute TCP checksum, using the pseudo-header. 
-- Different pseudo-headers are used for IPv4 and IPv6
TCP_CHECKSUM_001: process(CLK)
begin
	if rising_edge(CLK) then
		
		if(RX_IPv4_6n_local = '1') and (MAC_RX_DATA_VALID_D2 = '1')  and (IP_FRAME_FLAG = '1') then
			-- IPv4
			if(IP_HEADER_FLAG_local = '1') then
				-- pseudo header
				if(IP_BYTE_COUNT_local = 3)  then 
					RX_TCP_CKSUM_local <= RX_TCP_CKSUM_A;	
				elsif(IP_BYTE_COUNT_local(0) = '1') and (IP_BYTE_COUNT_local >= 9) and (IP_BYTE_COUNT_local <= 19) 
					and (IP_BYTE_COUNT_local /= 11) then 	
					RX_TCP_CKSUM_local <= ("0" & RX_TCP_CKSUM_local(15 downto 0)) + RX_TCP_CKSUM_A + RX_TCP_CKSUM_local(16);
				end if;	
			else
				-- entire TCP packet (IP frame - header), 16-bit at a time
				if(IP_RX_EOF_local = '1')  and (IP_BYTE_COUNT_local(0) = '0') then
					-- special case: last TCP data byte is at an even address (odd number of bytes)
					RX_TCP_CKSUM_local <= ("0" & RX_TCP_CKSUM_local(15 downto 0)) + RX_TCP_CKSUM_A + RX_TCP_CKSUM_local(16);
				elsif(IP_BYTE_COUNT_local(0) = '1') then
					RX_TCP_CKSUM_local <= ("0" & RX_TCP_CKSUM_local(15 downto 0)) + RX_TCP_CKSUM_A + RX_TCP_CKSUM_local(16);
				end if;
			end if;	

		elsif (IPv6_ENABLED = '1') and (RX_IPv4_6n_local = '0') and (MAC_RX_DATA_VALID_D2 = '1')  and (IP_FRAME_FLAG = '1') then			
			-- IPv6 (when enabled)
			if(IP_HEADER_FLAG_local = '1') then
				-- pseudo header
				if(IP_BYTE_COUNT_local = 5)  then 
					RX_TCP_CKSUM_local <= RX_TCP_CKSUM_A;	
				elsif(IP_BYTE_COUNT_local(0) = '1') and (IP_BYTE_COUNT_local >= 7) and (IP_BYTE_COUNT_local <= 39) then 	
					RX_TCP_CKSUM_local <= ("0" & RX_TCP_CKSUM_local(15 downto 0)) + RX_TCP_CKSUM_A + RX_TCP_CKSUM_local(16);
				end if;	
			else
				-- entire TCP packet (IP frame - IP header), 16-bit at a time
				if(IP_RX_EOF_local = '1')  and (IP_BYTE_COUNT_local(0) = '0') then
					-- special case: last TCP data byte is at an even address (odd number of bytes)
					RX_TCP_CKSUM_local <= ("0" & RX_TCP_CKSUM_local(15 downto 0)) + RX_TCP_CKSUM_A + RX_TCP_CKSUM_local(16);
				elsif(IP_BYTE_COUNT_local(0) = '1') then
					RX_TCP_CKSUM_local <= ("0" & RX_TCP_CKSUM_local(15 downto 0)) + RX_TCP_CKSUM_A + RX_TCP_CKSUM_local(16);
				end if;
			end if;	
			
		end if;
	end if;
end process;

TCP_CHECKSUM_002: process(RX_IPv4_6n_local, IP_HEADER_FLAG_local, IP_BYTE_COUNT_local, TYPE_FIELD_D2,
								  MAC_RX_DATA_D2, IP_RX_EOF_local)
begin
	if(RX_IPv4_6n_local = '1') then
			-- IPv4	
		if(IP_HEADER_FLAG_local = '1') then
			if(IP_BYTE_COUNT_local = 3) then
				RX_TCP_CKSUM_A <= "0" & TYPE_FIELD_D2 - 20;	-- TCP length
			elsif(IP_BYTE_COUNT_local = 9) then
				RX_TCP_CKSUM_A <= "0" & x"00" & MAC_RX_DATA_D2;	-- zeros + protocol (0x11)
			else
				RX_TCP_CKSUM_A <= "0" & TYPE_FIELD_D2; -- IP source and destination addresses
			end if;
		elsif(IP_RX_EOF_local = '1')  and (IP_BYTE_COUNT_local(0) = '0') then
			-- special case, odd number of bytes
			RX_TCP_CKSUM_A <= "0" & MAC_RX_DATA_D2 & x"00"; -- last byte
--		elsif(IP_BYTE_COUNT_local(0) = '1') then
		else
			-- entire TCP packet (IP frame - header), 16-bit at a time
			RX_TCP_CKSUM_A <= "0" & TYPE_FIELD_D2; -- add 16-bit at a time
		end if;		
		
	elsif (IPv6_ENABLED = '1') and (RX_IPv4_6n_local = '0')  then		
		-- IPv6 (when enabled)
		if(IP_HEADER_FLAG_local = '1') then
			if(IP_BYTE_COUNT_local = 5) then
				RX_TCP_CKSUM_A <= "0" & TYPE_FIELD_D2 - 40;	-- payload (TCP) length
			elsif(IP_BYTE_COUNT_local = 7) then
				RX_TCP_CKSUM_A <= "0" & x"00" & TYPE_FIELD_D2(15 downto 8);	-- zeros + protocol (0x11). trick for simpler code: protocol is at byte 6. 
			else
				RX_TCP_CKSUM_A <= "0" & TYPE_FIELD_D2; -- IP source address
			end if;
		elsif(IP_RX_EOF_local = '1')  and (IP_BYTE_COUNT_local(0) = '0') then
			-- special case, odd number of bytes
			RX_TCP_CKSUM_A <= "0" & MAC_RX_DATA_D2 & x"00"; -- last byte
--		elsif(IP_BYTE_COUNT_local(0) = '1') then
		else
			-- entire TCP packet (IP frame - header), 16-bit at a time
			RX_TCP_CKSUM_A <= "0" & TYPE_FIELD_D2; -- add 16-bit at a time
		end if;	
	else
		RX_TCP_CKSUM_A <= (others => '0');
	end if;
end process;

-- mask the checksum when simulating using a Wireshark .cap capture file as input
-- Reason: the checksum field may be wrong due to TCP checksum offload to hardware.
RX_TCP_CKSUM <= (not RX_TCP_CKSUM_local(16 downto 0)) when (SIMULATION = '0') else ("0" & x"0001");


---------------------------------------------------
---- MISC ---------------------------------
---------------------------------------------------

TP(1) <= '1' when (IP_HEADER_CHECKSUM_VALID_RDY_local = '1') and (IP_HEADER_CHECKSUM_VALID_local = '0') else '0'; 
-- invalid IP header checksum
end Behavioral;


-------------------------------------------------------------
-- MSS copyright 2011
--	Filename:  TCP_TX.VHD
-- Author: Alain Zarembowitch / MSS
--	Version: 1
--	Date last modified: 8/29/11
-- Inheritance: 	N/A
--
-- description:  Sends a TCP packet, including the IP and MAC headers.
-- All input information is available at the time of the transmit trigger.
---------------------------------------------------------------
library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.STD_LOGIC_ARITH.ALL;
use IEEE.STD_LOGIC_UNSIGNED.ALL;

entity TCP_TX is
	generic (
		MSS: std_logic_vector(15 downto 0) := x"05B4";
			-- The Maximum Segment Size (MSS) is the largest segment of TCP data that can be transmitted.
			-- Fixed as the Ethernet MTU (Maximum Transmission Unit) of 1500 bytes - 40 overhead bytes = 1460 bytes.
		IPv6_ENABLED: std_logic := '0'
			-- 0 to minimize size, 1 to allow IPv6 in addition to IPv4 (larger size)
	);
    Port ( 
		--// CLK, RESET
		ASYNC_RESET: in std_logic;
		CLK: in std_logic;	
			-- Must be a global clock. No BUFG instantiation within this component.

		--// CONFIGURATION PARAMETERS
		MAC_ADDR: in std_logic_vector(47 downto 0);
			-- MAC address. Unique for each network interface card.
			-- Natural byte order: (MSB) 0x000102030405 (LSB) 
			-- as transmitted in the Ethernet packet.
		IPv4_ADDR: in std_logic_vector(31 downto 0);
		IPv6_ADDR: in std_logic_vector(127 downto 0);


		--// INPUT: HEADERS
		TX_PACKET_SEQUENCE_START: in std_logic;	
			-- 1 CLK pulse to trigger packet transmission. The decision to transmit is taken by TCP_SERVER.
			-- From this trigger pulse to the end of frame, this component assembles and send data bytes
			-- like clockwork. 
			-- Note that the payload data has to be ready at exactly the right time to be appended.
			
		-- These variables must be fixed at the start of packet and not change until the transmit EOF.
		-- They can change from packet to packet (internal code is entirely memoryless).
		TX_DEST_MAC_ADDR_IN: in std_logic_vector(47 downto 0);
		TX_DEST_IP_ADDR_IN: in std_logic_vector(127 downto 0);
		TX_DEST_PORT_NO_IN: in std_logic_vector(15 downto 0);
		TX_SOURCE_PORT_NO_IN: in std_logic_vector(15 downto 0);
		TX_IPv4_6n_IN: in std_logic;
		TX_SEQ_NO_IN: in std_logic_vector(31 downto 0);
		TX_ACK_NO_IN: in std_logic_vector(31 downto 0);
		TX_ACK_WINDOW_LENGTH_IN: in std_logic_vector(15 downto 0);
		IP_ID_IN: in std_logic_vector(15 downto 0);
			-- 16-bit IP ID, unique for each datagram. Incremented every time
			-- an IP datagram is sent (not just for this socket).
		TX_FLAGS_IN: in std_logic_vector(7 downto 0);
		TX_PACKET_TYPE_IN : in std_logic_vector(1 downto 0);


		--// INPUT: EXTERNAL TX BUFFER -> TX TCP PAYLOAD
		TX_PAYLOAD_DATA: in std_logic_vector(7 downto 0);
			-- TCP payload data field when TX_PAYLOAD_DATA_VALID = '1'
		TX_PAYLOAD_DATA_VALID: in std_logic;
			-- delineates the TCP payload data field
		TX_PAYLOAD_RTS: in std_logic;  
			-- '1' to tell TX TCP layer that the application has a packet ready to send
			-- Must stay high at least until TX_CTS goes high, but not beyond TX_EOF.
		TX_PAYLOAD_CTS: out std_logic;
			-- clear to send. 2 CLK latency until 1st data byte is available at TX_PAYLOAD_DATA
		TX_PAYLOAD_SIZE: in std_logic_vector(10 downto 0);
			-- packet size (TCP payload data only). valid (and fixed) while TX_RTS = '1'.
			-- Limited range: 0 - 2047 (11-bits)
		TX_PAYLOAD_CHECKSUM: in std_logic_vector(16 downto 0);
			-- partial TCP checksum computation. payload only, no header. bit 16 is the carry, add later.
			-- valid only when TX_PAYLOAD_RTS = '1', ignore otherwise


		--// OUTPUT: TX TCP layer -> Transmit MAC Interface
		-- 32-bit CRC is automatically appended by MAC. Not supplied here.
		-- Synchonous with the user-side CLK
		MAC_TX_DATA: out std_logic_vector(7 downto 0) := x"00";
			-- MAC reads the data at the rising edge of CLK when MAC_TX_DATA_VALID = '1'
		MAC_TX_DATA_VALID: out std_logic := '0';
			-- data valid
		MAC_TX_EOF: out std_logic := '0';
			-- '1' when sending the last byte in a packet to be transmitted. 
			-- Aligned with MAC_TX_DATA_VALID
		MAC_TX_CTS: in std_logic;
			-- MAC-generated Clear To Send flow control signal, indicating room in the 
			-- MAC tx elastic buffer for a complete maximum size frame 1518B. 
			-- The user should check that this signal is high before deciding to send
			-- sending the next frame. 
			-- Note: MAC_TX_CTS may go low while the frame is transfered in. Ignore it as space is guaranteed
			-- at the start of frame.



--		-- Test Points
	TP: out std_logic_vector(10 downto 1)

			);
end entity;

architecture Behavioral of TCP_TX is
--------------------------------------------------------
--      COMPONENTS
--------------------------------------------------------
--------------------------------------------------------
--     SIGNALS
--------------------------------------------------------

--//---- FREEZE INPUTS -----------------------
signal TX_DEST_MAC_ADDR: std_logic_vector(47 downto 0);
signal TX_DEST_IP_ADDR: std_logic_vector(127 downto 0);
signal TX_DEST_PORT_NO: std_logic_vector(15 downto 0);
signal TX_SOURCE_MAC_ADDR: std_logic_vector(47 downto 0);
signal TX_SOURCE_IP_ADDR: std_logic_vector(127 downto 0);
signal TX_SOURCE_PORT_NO: std_logic_vector(15 downto 0);
signal TX_IPv4_6n: std_logic;
signal TX_TCP_HEADER_LENGTH: std_logic_vector(3 downto 0);	-- in 32-bit words
signal TX_TCP_HEADER_LENGTH_DEC: std_logic_vector(3 downto 0);	-- in 32-bit words
signal TX_TCP_PAYLOAD_SIZE: std_logic_vector(10 downto 0);	-- TCP payload size in bytes.
signal TX_SEQ_NO: std_logic_vector(31 downto 0);
signal TX_ACK_NO: std_logic_vector(31 downto 0);
signal TX_ACK_WINDOW_LENGTH: std_logic_vector(15 downto 0);
signal IP_ID: std_logic_vector(15 downto 0);
signal TX_FLAGS: std_logic_vector(7 downto 0);
signal TX_PACKET_TYPE:  std_logic_vector(1 downto 0);

--//---- TX PACKET ASSEMBLY   ----------------------
signal TX_ACTIVE: std_logic;
signal TX_ETHERNET_HEADER: std_logic := '0';
signal TX_ETHERNET_HEADER_LAST_BYTE: std_logic := '0';
signal TX_IP_HEADER: std_logic := '0';
signal TX_TCP_HEADER: std_logic := '0';
signal TX_TCP_PAYLOAD: std_logic := '0';
signal TX_BYTE_COUNTER: std_logic_vector(10 downto 0) := (others => '0'); 
signal TX_BYTE_COUNTER_D: std_logic_vector(10 downto 0) := (others => '0'); 
signal TX_BYTE_COUNTER_INC: std_logic_vector(10 downto 0) := (others => '0'); 
signal MAC_TX_DATA_local:  std_logic_vector(7 downto 0) := x"00";
signal MAC_TX_EOF_local: std_logic := '0';
signal TX_TCP_LAST_HEADER_BYTE: std_logic := '0';

--// TX IP HEADER CHECKSUM ---------------------------------------------
signal TX_IP_HEADER_D: std_logic := '0';
signal MAC_TX_DATA_D:  std_logic_vector(7 downto 0) := x"00";
signal TX_IP_HEADER_CKSUM_DATA : std_logic_vector(15 downto 0);
signal TX_IP_HEADER_CKSUM_FLAG: std_logic;
signal TX_IP_HEADER_CHECKSUM: std_logic_vector(16 downto 0) := "0" & x"0000";
signal TX_IP_HEADER_CHECKSUM_FINAL: std_logic_vector(15 downto 0) := x"0000";
signal TX_IP_LENGTH: std_logic_vector(15 downto 0);

--// TX TCP CHECKSUM ---------------------------------------------
signal TX_TCP_HEADER_D: std_logic := '0';
signal TX_TCP_CKSUM_DATA: std_logic_vector(15 downto 0);
signal TX_TCP_CKSUM_FLAG: std_logic := '0';
signal TX_TCP_CHECKSUM: std_logic_vector(16 downto 0);
signal TX_TCP_CHECKSUM_FINAL: std_logic_vector(15 downto 0);
signal TX_TCP_LENGTH: std_logic_vector(15 downto 0);




--------------------------------------------------------
--      IMPLEMENTATION
--------------------------------------------------------
begin

--//---- FREEZE INPUTS -----------------------
-- Latch in all key fields at the start trigger, or at the latest during the Ethernet header.

INFO_001: process(CLK)
begin
	if rising_edge(CLK) then
		if(TX_PACKET_SEQUENCE_START = '1') then
			-- latch in all key fields at the start trigger
			TX_DEST_MAC_ADDR <= TX_DEST_MAC_ADDR_IN;	
		--// shifting large fields
		elsif(MAC_TX_CTS = '1') and (TX_ETHERNET_HEADER = '1') then
			-- sending IP packet: assembling ethernet header
			if (TX_BYTE_COUNTER >= 0) and (TX_BYTE_COUNTER <= 4) then
				-- shift while assembling the tx packet (to minimize size)
				TX_DEST_MAC_ADDR(47 downto 8) <= TX_DEST_MAC_ADDR(39 downto 0);
			end if;
		end if;
	end if;
end process;

INFO_002: process(CLK)
begin
	if rising_edge(CLK) then
		if(TX_PACKET_SEQUENCE_START = '1') then
			-- latch in all key fields at the start trigger
			TX_SOURCE_MAC_ADDR <= MAC_ADDR;
		--// shifting large fields
		elsif(MAC_TX_CTS = '1') and (TX_ETHERNET_HEADER = '1') then
			-- sending IP packet: assembling ethernet header
			if (TX_BYTE_COUNTER >= 6) and (TX_BYTE_COUNTER <= 10) then
				-- shift while assembling the tx packet (to minimize size)
				TX_SOURCE_MAC_ADDR(47 downto 8) <= TX_SOURCE_MAC_ADDR(39 downto 0);
			end if;
		end if;
	end if;
end process;

INFO_003: process(CLK)
begin
	if rising_edge(CLK) then
		if(TX_PACKET_SEQUENCE_START = '1') then
			-- latch in all key fields at the start trigger
			TX_DEST_IP_ADDR <= TX_DEST_IP_ADDR_IN;	
		--// shifting large fields
		elsif(MAC_TX_CTS = '1') and (TX_IP_HEADER = '1') and (TX_IPv4_6n = '1') then
			-- sending IPv4 packet: assembling IP header
			if(TX_BYTE_COUNTER >= 16) and (TX_BYTE_COUNTER <= 18) then
				-- shift while assembling the tx packet (to minimize size)
				TX_DEST_IP_ADDR(31 downto 8) <= TX_DEST_IP_ADDR(23 downto 0);
			end if;
		elsif(MAC_TX_CTS = '1') and (TX_IP_HEADER = '1') and (IPv6_ENABLED = '1') and (TX_IPv4_6n = '0') then
			-- sending IPv6 packet: assembling IP header
			if(TX_BYTE_COUNTER >= 24) and (TX_BYTE_COUNTER <= 38) then
				-- shift while assembling the tx packet (to minimize size)
				TX_DEST_IP_ADDR(127 downto 8) <= TX_DEST_IP_ADDR(119 downto 0);
			end if;
		end if;
	end if;
end process;

INFO_004: process(CLK)
begin
	if rising_edge(CLK) then
		if(TX_PACKET_SEQUENCE_START = '1') then
			-- latch in all key fields at the start trigger
			if(IPv6_ENABLED = '1') and (TX_IPv4_6n_IN = '0') then
				TX_SOURCE_IP_ADDR <= IPv6_ADDR;	
			else
				TX_SOURCE_IP_ADDR(31 downto 0) <= IPv4_ADDR;	
			end if;
		--// shifting large fields
		elsif(MAC_TX_CTS = '1') and (TX_IP_HEADER = '1') and (TX_IPv4_6n = '1') then
			-- sending IPv4 packet: assembling IP header
			if(TX_BYTE_COUNTER >= 12) and (TX_BYTE_COUNTER <= 14) then
				-- shift while assembling the tx packet (to minimize size)
				TX_SOURCE_IP_ADDR(31 downto 8) <= TX_SOURCE_IP_ADDR(23 downto 0);
			end if;
		elsif(MAC_TX_CTS = '1') and (TX_IP_HEADER = '1') and (IPv6_ENABLED = '1') and (TX_IPv4_6n = '0') then
			-- sending IPv6 packet: assembling IP header
			if(TX_BYTE_COUNTER >= 8) and (TX_BYTE_COUNTER <= 22) then
				-- shift while assembling the tx packet (to minimize size)
				TX_SOURCE_IP_ADDR(127 downto 8) <= TX_SOURCE_IP_ADDR(119 downto 0);
			end if;
		end if;
	end if;
end process;

-- Save gates by shifting long (32+ bits) fields (instead of a large mux)
INFO_005: process(CLK)
begin
	if rising_edge(CLK) then
		if(TX_PACKET_SEQUENCE_START = '1') then
			-- latch in key fields at start of packet assembly (they can change during packet assembly, 
			-- for example if an ACK is received).
			TX_DEST_PORT_NO <= TX_DEST_PORT_NO_IN;	
			TX_SOURCE_PORT_NO <= TX_SOURCE_PORT_NO_IN;
			TX_IPv4_6n <= TX_IPv4_6n_IN;	
			IP_ID <= IP_ID_IN;
			TX_SEQ_NO <= TX_SEQ_NO_IN;
			TX_ACK_NO <= TX_ACK_NO_IN;
			TX_ACK_WINDOW_LENGTH <= TX_ACK_WINDOW_LENGTH_IN;
			TX_FLAGS <= TX_FLAGS_IN;
			TX_PACKET_TYPE <= TX_PACKET_TYPE_IN;
			if(TX_PACKET_TYPE_IN = 3) then
				-- payload size from TCP_TXBUF
				TX_TCP_PAYLOAD_SIZE <= TX_PAYLOAD_SIZE;
			else
				-- no payload
				TX_TCP_PAYLOAD_SIZE <= (others => '0');
			end if;

		--// shifting large fields
		elsif(MAC_TX_CTS = '1') and (TX_TCP_HEADER = '1') then
			if(TX_BYTE_COUNTER(10 downto 2) = 1) and (TX_BYTE_COUNTER(1 downto 0) /= 3) then
			--if(TX_BYTE_COUNTER >= 4) and (TX_BYTE_COUNTER <= 6) then	-- alternate phrasing above for better timing
				-- shift while assembling the tx packet (to minimize size)
				TX_SEQ_NO(31 downto 8) <= TX_SEQ_NO(23 downto 0);
			end if;
			if(TX_BYTE_COUNTER(10 downto 2) = 2) and (TX_BYTE_COUNTER(1 downto 0) /= 3) then
			--if(TX_BYTE_COUNTER >= 8) and (TX_BYTE_COUNTER <= 10) then  -- alternate phrasing above for better timing
				-- shift while assembling the tx packet (to minimize size)
				TX_ACK_NO(31 downto 8) <= TX_ACK_NO(23 downto 0);
			end if;
		end if;
	end if;
end process;



--//---- TX PACKET SIZE ---------------------------
TX_PACKET_TYPE_GEN_001: process(CLK)
begin
	if rising_edge(CLK) then
		if(TX_PACKET_TYPE = 1) then
			TX_TCP_HEADER_LENGTH <= x"6";	-- 24 bytes, includes MSS option.
		else
			-- default length
			TX_TCP_HEADER_LENGTH <= x"5";	-- 20 bytes, default
		end if;
		
		TX_TCP_LENGTH <= ("0000000000" & TX_TCP_HEADER_LENGTH & "00") + TX_TCP_PAYLOAD_SIZE ;	
			-- total TCP frame size, in bytes. Part of TCP pseudo-header needed for TCP checksum computation

		-- total IP frame size, in bytes. IP header is always the standard size of 20 bytes (IPv4) or 40 bytes (IPv6)
		if(TX_IPv4_6n = '1') then
			TX_IP_LENGTH <= TX_TCP_LENGTH + 20;	
		else
			TX_IP_LENGTH <= TX_TCP_LENGTH + 40;	
		end if;
	end if;
end process;


--//---- TX PACKET ASSEMBLY   ---------------------
-- Transmit packet is assembled on the fly, consistent with our design goal
-- of minimizing storage in each TCP_SERVER component.
-- The packet includes the lower layers, i.e. IP layer and Ethernet layer.
-- 
-- First, we tell the outsider arbitration that we are ready to send by raising RTS high.
-- When the transmit path becomes available, the arbiter tells us to go ahead with the transmission MAC_TX_CTS = '1'

STATE_MACHINE_001: process(CLK)
begin
	if rising_edge(CLK) then
		if (TX_PACKET_SEQUENCE_START = '1') then
			TX_ACTIVE <= '1';
		elsif(MAC_TX_EOF_local = '1') then
			TX_ACTIVE <= '0';
		end if;
	end if;
end process;

TX_ETHERNET_HEADER_LAST_BYTE <= '1' when (TX_ACTIVE = '1') and (TX_ETHERNET_HEADER = '1') and (TX_BYTE_COUNTER = 13) else '0';

TX_SCHEDULER_001: process(ASYNC_RESET, CLK)
begin
	if(ASYNC_RESET = '1') then
		TX_BYTE_COUNTER <= (others => '0');
		TX_BYTE_COUNTER_INC <= (0 => '1', others => '0');
		MAC_TX_DATA_VALID <= '0';
		TX_ETHERNET_HEADER <= '0';	
		TX_IP_HEADER <= '0';	
		TX_TCP_HEADER <= '0';	
		TX_TCP_PAYLOAD <= '0';	
	elsif rising_edge(CLK) then
	
		if(MAC_TX_EOF_local = '1') then
			-- For clarity, wait 1 CLK after the end of the previous packet to do anything.
			 MAC_TX_DATA_VALID <= '0';
		elsif (TX_PACKET_SEQUENCE_START = '1') then
			-- We have a packet ready to send. Waiting for MAC layer to agree to send it.
			-- initiating tx request. Reset counters. 
			 TX_BYTE_COUNTER <= (others => '0');
			 TX_BYTE_COUNTER_INC <= (0 => '1', others => '0');
			 MAC_TX_DATA_VALID <= '0';
			 TX_ETHERNET_HEADER <= '1';	
		elsif(TX_ACTIVE = '1') and (MAC_TX_CTS = '1') then
			-- one packet is ready to send and MAC requests another byte
			MAC_TX_DATA_VALID <= '1';  -- enable path to MAC

			if(TX_ETHERNET_HEADER = '1') and (TX_BYTE_COUNTER = 13) then	
				-- end of 22-byte Ethernet header (including preamble, SOF, MAC addresses and Ethertype)
				TX_BYTE_COUNTER <= (others => '0');	-- reset byte counter as we enter a new header
				TX_BYTE_COUNTER_INC <= (0 => '1', others => '0');
				TX_ETHERNET_HEADER <= '0';	-- done with Ethernet header.
				TX_IP_HEADER <= '1';	-- entering IP header
			elsif(TX_IP_HEADER = '1') and (TX_BYTE_COUNTER = 19) then	
				-- end of IP header
				TX_BYTE_COUNTER <= (others => '0'); 	-- reset byte counter as we enter a new header
				TX_BYTE_COUNTER_INC <= (0 => '1', others => '0');
				TX_IP_HEADER <= '0';	-- done with IP header.
				TX_TCP_HEADER <= '1';	-- entering TCP header
			elsif(TX_TCP_LAST_HEADER_BYTE = '1') then	
---???????????????????????????????????????????????????????????????????????????????
--IMPORTANT: DOUBLE CHECK THE STATEMENT ABOVE ... COMPARE WITH UDP_TX.VHD -----AZ 8/15/11
---???????????????????????????????????????????????????????????????????????????????
				-- end of TCP header
				-- TCP header can be greater than 20 bytes depending on the option
				TX_BYTE_COUNTER <= (others => '0'); 	-- reset byte counter as we enter the payload
				TX_BYTE_COUNTER_INC <= (0 => '1', others => '0');
				TX_TCP_HEADER <= '0';	-- done with TCP header.
				if(TX_TCP_PAYLOAD_SIZE /= 0) then
					TX_TCP_PAYLOAD <= '1';	-- entering TCP payload
				end if;
			elsif(TX_TCP_PAYLOAD = '1') and (TX_BYTE_COUNTER_INC = TX_TCP_PAYLOAD_SIZE) then	
				-- end of TCP payload
				TX_BYTE_COUNTER <= (others => '0'); 	-- reset byte counter as we enter the payload
				TX_BYTE_COUNTER_INC <= (0 => '1', others => '0');
				TX_TCP_PAYLOAD <= '0';	-- done with TCP payload
			elsif (TX_ETHERNET_HEADER = '1') or (TX_IP_HEADER = '1') or (TX_TCP_HEADER = '1') or (TX_TCP_PAYLOAD = '1') then
				-- regular pointer increment
				TX_BYTE_COUNTER <= TX_BYTE_COUNTER_INC;
				TX_BYTE_COUNTER_INC <= TX_BYTE_COUNTER_INC + 1;
			end if;
		else
			MAC_TX_DATA_VALID <= '0';
		end if;
	end if;
end process;

-- for better timing, generate a pulse at the last TCP header byte
TX_TCP_LAST_HEADER_BYTE_GEN: process(ASYNC_RESET, CLK)
begin
	if(ASYNC_RESET = '1') then
		TX_TCP_LAST_HEADER_BYTE <= '0';
	elsif rising_edge(CLK) then
		if (TX_TCP_HEADER = '1') and (TX_BYTE_COUNTER_INC = ("00000" & TX_TCP_HEADER_LENGTH_DEC & "11")) then
			-- one before the last header byte
			TX_TCP_LAST_HEADER_BYTE <= '1';
		else
			TX_TCP_LAST_HEADER_BYTE <= '0';
		end if;
	end if;
end process;

MAC_TX_EOF_GEN_001: process(ASYNC_RESET, CLK)
begin
	if(ASYNC_RESET = '1') then
		MAC_TX_EOF_local <= '0';
	elsif rising_edge(CLK) then
		if(MAC_TX_EOF_local = '1') then
			-- For clarity, wait 1 CLK after the end of the previous packet to do anything.
			 MAC_TX_EOF_local <= '0';
		elsif (TX_PACKET_SEQUENCE_START = '1') then
			-- We have a packet ready to send. Waiting for MAC layer to agree to send it.
			-- initiating tx request. Reset counters. 
			 MAC_TX_EOF_local <= '0';
		elsif(TX_ACTIVE = '1') and (MAC_TX_CTS = '1') then
			-- one packet is ready to send and MAC requests another byte
			if(TX_TCP_LAST_HEADER_BYTE = '1') and  (TX_TCP_PAYLOAD_SIZE = 0) then
				-- last TCP header byte, empty TCP payload
				MAC_TX_EOF_local <= '1';
			elsif(TX_TCP_PAYLOAD = '1') and (TX_BYTE_COUNTER_INC = TX_TCP_PAYLOAD_SIZE) then
				MAC_TX_EOF_local <= '1';
			else
				MAC_TX_EOF_local <= '0';
			end if;
		else
			MAC_TX_EOF_local <= '0';
		end if;
	end if;
end process;

MAC_TX_EOF <= MAC_TX_EOF_local;

-- ask TCP_TXBUF to send payload data
-- clear to send. 2 CLK latency until 1st data byte is available at TX_PAYLOAD_DATA
-- Be sure to mask the CTS signal if the payload size is zero.
TX_TCP_HEADER_LENGTH_DEC <= TX_TCP_HEADER_LENGTH - 1;
TX_PAYLOAD_CTS_GEN: process(CLK)
begin
	if rising_edge(CLK) then
		if(TX_PACKET_TYPE /= 3) then
			-- no-payload frame. Don't ask for payload data.
			TX_PAYLOAD_CTS <= '0';
		elsif(TX_TCP_HEADER = '1') and (TX_BYTE_COUNTER_INC = ("00000" & TX_TCP_HEADER_LENGTH_DEC & "10")) then
			-- advanced notice that we are nearing the end of the TCP header. Time to ask for payload data
			TX_PAYLOAD_CTS <= '1';
		elsif(MAC_TX_EOF_local = '0') then
			-- payload data fully transferred from TCP_TXBUF to here. Stop requesting payload data.
			TX_PAYLOAD_CTS <= '0';
		end if;
	end if;
end process;


TX_SCHEDULER_002: process(ASYNC_RESET, CLK)
begin
	if(ASYNC_RESET = '1') then
		MAC_TX_DATA_local <= (others => '0');
	elsif rising_edge(CLK) then
		if(MAC_TX_CTS = '1') then
			if(TX_ETHERNET_HEADER = '1') then		
				-- Ethernet frame header
				if(TX_BYTE_COUNTER >= 0) and (TX_BYTE_COUNTER <= 5) then
					MAC_TX_DATA_local <= TX_DEST_MAC_ADDR(47 downto 40);	-- MAC destination (during shift)
				elsif(TX_BYTE_COUNTER >= 6) and (TX_BYTE_COUNTER <= 11) then
					MAC_TX_DATA_local <= TX_SOURCE_MAC_ADDR(47 downto 40);	-- MAC source (during shift)
				elsif(TX_BYTE_COUNTER = 12) then
					MAC_TX_DATA_local <= x"08";		-- Ethertype IP datagram
				elsif(TX_BYTE_COUNTER = 13) then
					MAC_TX_DATA_local <= x"00";		-- Ethertype IP datagram
				end if;
			elsif(TX_IP_HEADER = '1') and (TX_IPv4_6n = '1') then	
				-- IPv4 header
				if(TX_BYTE_COUNTER = 0) then
					MAC_TX_DATA_local <= x"45";		-- IPv4, 5 word header
				elsif(TX_BYTE_COUNTER = 1) then
					MAC_TX_DATA_local <= x"00";		-- TOS x00 unused.
				elsif(TX_BYTE_COUNTER = 2) then
					MAC_TX_DATA_local <=  TX_IP_LENGTH(15 downto 8); 	-- IP packet length in bytes. Fixed upon decision to send datagram.
				elsif(TX_BYTE_COUNTER = 3) then
					MAC_TX_DATA_local <=  TX_IP_LENGTH(7 downto 0); 	-- IP packet length in bytes. Fixed upon decision to send datagram.
				elsif(TX_BYTE_COUNTER = 4) then
					MAC_TX_DATA_local <=  IP_ID(15 downto 8); 	-- 16-bit identification, incremented for each IP datagram.
				elsif(TX_BYTE_COUNTER = 5) then
					MAC_TX_DATA_local <=  IP_ID(7 downto 0); 	 	-- 16-bit identification, incremented for each IP datagram.
				elsif(TX_BYTE_COUNTER = 6) then
					MAC_TX_DATA_local <= x"40";		-- 13-bit fragment offset. Flags: don't fragment, last fragment
				elsif(TX_BYTE_COUNTER = 7) then
					MAC_TX_DATA_local <= x"00";		-- 13-bit fragment offset. Flags: don't fragment, last fragment
				elsif(TX_BYTE_COUNTER = 8) then
					MAC_TX_DATA_local <= x"80";		-- TTL = 128
				elsif(TX_BYTE_COUNTER = 9) then
					MAC_TX_DATA_local <= x"06";		-- protocol: TCP
				elsif(TX_BYTE_COUNTER = 10) then
					MAC_TX_DATA_local <= TX_IP_HEADER_CHECKSUM_FINAL(15 downto 8);		-- IP header checksum
				elsif(TX_BYTE_COUNTER = 11) then
					MAC_TX_DATA_local <= TX_IP_HEADER_CHECKSUM_FINAL(7 downto 0);		-- IP header checksum
				elsif(TX_BYTE_COUNTER >= 12) and (TX_BYTE_COUNTER <= 15) then
					MAC_TX_DATA_local <= TX_SOURCE_IP_ADDR(31 downto 24);	-- IP source (during shift)
				elsif(TX_BYTE_COUNTER >= 16) and (TX_BYTE_COUNTER <= 19) then
					MAC_TX_DATA_local <= TX_DEST_IP_ADDR(31 downto 24);	-- IP destination (during shift)
				end if;
			elsif(TX_IP_HEADER = '1') and (IPv6_ENABLED = '1') and (TX_IPv4_6n = '0') then	
				-- IPv6 header
				if(TX_BYTE_COUNTER >= 8) and (TX_BYTE_COUNTER <= 23) then
					MAC_TX_DATA_local <= TX_SOURCE_IP_ADDR(127 downto 120);	-- IP source (during shift)
				elsif(TX_BYTE_COUNTER >= 24) and (TX_BYTE_COUNTER <= 39) then
					MAC_TX_DATA_local <= TX_DEST_IP_ADDR(127 downto 120);	-- IP source (during shift)
				end if;
			elsif(TX_TCP_HEADER = '1') then		
				-- TCP header
				if(TX_BYTE_COUNTER = 0) then
					MAC_TX_DATA_local <= TX_SOURCE_PORT_NO(15 downto 8);
				elsif(TX_BYTE_COUNTER = 1) then
					MAC_TX_DATA_local <= TX_SOURCE_PORT_NO(7 downto 0);
				elsif(TX_BYTE_COUNTER = 2) then
					MAC_TX_DATA_local <= TX_DEST_PORT_NO(15 downto 8);
				elsif(TX_BYTE_COUNTER = 3) then
					MAC_TX_DATA_local <= TX_DEST_PORT_NO(7 downto 0);
				elsif(TX_BYTE_COUNTER >= 4) and (TX_BYTE_COUNTER <= 7) then
					MAC_TX_DATA_local <= TX_SEQ_NO(31 downto 24);
				elsif(TX_BYTE_COUNTER >= 8) and (TX_BYTE_COUNTER <= 11) then
					MAC_TX_DATA_local <= TX_ACK_NO(31 downto 24);
				elsif(TX_BYTE_COUNTER = 12) then
					MAC_TX_DATA_local <= TX_TCP_HEADER_LENGTH & "0000";	-- Data offset = TCP header size in 32-bit words.
				elsif(TX_BYTE_COUNTER = 13) then
					MAC_TX_DATA_local <= TX_FLAGS;	-- flags
				elsif(TX_BYTE_COUNTER = 14) then
					MAC_TX_DATA_local <= TX_ACK_WINDOW_LENGTH(15 downto 8); -- ack window. used to convey rx flow control information to the client
				elsif(TX_BYTE_COUNTER = 15) then
					MAC_TX_DATA_local <= TX_ACK_WINDOW_LENGTH(7 downto 0);
				elsif(TX_BYTE_COUNTER = 16) then
					MAC_TX_DATA_local <= TX_TCP_CHECKSUM_FINAL(15 downto 8);
				elsif(TX_BYTE_COUNTER = 17) then
					MAC_TX_DATA_local <= TX_TCP_CHECKSUM_FINAL(7 downto 0);
				elsif(TX_BYTE_COUNTER = 18) then
					MAC_TX_DATA_local <= x"00";	-- urgent pointer
				elsif(TX_BYTE_COUNTER = 19) then
					MAC_TX_DATA_local <= x"00";	-- urgent pointer
				elsif(TX_BYTE_COUNTER = 20) then
					MAC_TX_DATA_local <= x"02";	-- option: kind = 2
				elsif(TX_BYTE_COUNTER = 21) then
					MAC_TX_DATA_local <= x"04";	-- option: length = 4
				elsif(TX_BYTE_COUNTER = 22) then
					MAC_TX_DATA_local <= MSS(15 downto 8);	-- option: Maximum Size Segment
				elsif(TX_BYTE_COUNTER = 23) then
					MAC_TX_DATA_local <= MSS(7 downto 0);	-- option: Maximum Size Segment
				end if;
			elsif(TX_TCP_PAYLOAD = '1') then	
				-- TCP payload (if applicable)
				MAC_TX_DATA_local <= TX_PAYLOAD_DATA;
			end if;
		end if;
	end if;
end process;
MAC_TX_DATA <= MAC_TX_DATA_local;


--// TX IP HEADER CHECKSUM ---------------------------------------------
-- Transmit IP packet header checksum. Only applies to IPv4 (no header checksum in IPv6)
-- We must start the checksum early as the checksum field is not the last word in the header.

-- Note: same code used in udp_tx.vhd
TX_IP_HEADER_CHECKSUM_001: process(ASYNC_RESET, CLK)
begin
	if(ASYNC_RESET = '1') then
		TX_IP_HEADER_CKSUM_FLAG <= '0';
	elsif rising_edge(CLK) then
		TX_IP_HEADER_D <= TX_IP_HEADER;
		MAC_TX_DATA_D <= MAC_TX_DATA_local;
		TX_BYTE_COUNTER_D <= TX_BYTE_COUNTER;
	
		if(MAC_TX_CTS = '1') then
			-- sums the fields located after the checksum field at an earlier time (i.e. while assembling
			-- the ethernet header)
			-- 1's complement sum (add carry)
			if(TX_ETHERNET_HEADER = '1') then		
				if(TX_BYTE_COUNTER = 0) then
					TX_IP_HEADER_CKSUM_DATA <= TX_SOURCE_IP_ADDR(31 downto 16);
					TX_IP_HEADER_CKSUM_FLAG <= '1';
				elsif(TX_BYTE_COUNTER = 1) then
					TX_IP_HEADER_CKSUM_DATA <= TX_SOURCE_IP_ADDR(15 downto 0);
				elsif(TX_BYTE_COUNTER = 2) then
					TX_IP_HEADER_CKSUM_DATA <= TX_DEST_IP_ADDR(31 downto 16);
				elsif(TX_BYTE_COUNTER = 3) then
					TX_IP_HEADER_CKSUM_DATA <= TX_DEST_IP_ADDR(15 downto 0);
				elsif(TX_BYTE_COUNTER = 4) then
					TX_IP_HEADER_CKSUM_DATA <= x"8006";	-- must match TTL/protocol bytes as inserted above in TX_SCHEDULER_002
				else
					TX_IP_HEADER_CKSUM_FLAG <= '0';
				end if;
			elsif(TX_IP_HEADER_D = '1') and (TX_IPv4_6n = '1') and (TX_BYTE_COUNTER_D(0) = '1') and (TX_BYTE_COUNTER_D < 8) then	
				-- IPv4 header before the checksum field(we have already summed the fields after the checksum field)
				TX_IP_HEADER_CKSUM_DATA <= MAC_TX_DATA_D & MAC_TX_DATA_local;
				TX_IP_HEADER_CKSUM_FLAG <= '1';
			else
				TX_IP_HEADER_CKSUM_FLAG <= '0';
			end if;
		else
			TX_IP_HEADER_CKSUM_FLAG <= '0';
		end if;
	end if;
end process;

TX_IP_HEADER_CHECKSUM_002: process(ASYNC_RESET, CLK)
begin
	if(ASYNC_RESET = '1') then
		TX_IP_HEADER_CHECKSUM <= (others => '0');	
	elsif rising_edge(CLK) then
		if(TX_PACKET_SEQUENCE_START = '1') then
			-- initiating tx request.
			-- new tx packet. clear IP header checksum
			TX_IP_HEADER_CHECKSUM <= (others => '0');	
		elsif(TX_IP_HEADER_CKSUM_FLAG = '1') then
			-- 1's complement sum (add carry)
			TX_IP_HEADER_CHECKSUM <= ("0" & TX_IP_HEADER_CHECKSUM(15 downto 0)) + (x"0000" & TX_IP_HEADER_CHECKSUM(16)) + ("0" & TX_IP_HEADER_CKSUM_DATA);
		end if;
	end if;
end process;
--// final checksum
-- don't forget to add the last carry immediately at the end of the IP header
TX_IP_HEADER_CHECKSUM_FINAL <= not(TX_IP_HEADER_CHECKSUM(15 downto 0) + ("000" & x"000" & TX_IP_HEADER_CHECKSUM(16))) ;
					

--// TX TCP CHECKSUM ---------------------------------------------
-- Transmit TCP packet checksum. Applies equally to IPv4/IPv6
-- We must start the checksum early as the checksum field is not the last word in the header.
TX_TCP_CHECKSUM_001: process(ASYNC_RESET, CLK)
begin
	if(ASYNC_RESET = '1') then
		TX_TCP_CKSUM_DATA <= (others => '0');
		TX_TCP_CKSUM_FLAG <= '1';
	elsif rising_edge(CLK) then
		TX_TCP_HEADER_D <= TX_TCP_HEADER;
		
		if(MAC_TX_CTS = '1') and (TX_IP_HEADER = '1') then
			-- include pseudo-header
			if(TX_BYTE_COUNTER = 0) then
				TX_TCP_CKSUM_DATA <= TX_SOURCE_IP_ADDR(31 downto 16);
				TX_TCP_CKSUM_FLAG <= '1';
			elsif(TX_BYTE_COUNTER = 1) then
				TX_TCP_CKSUM_DATA <= TX_SOURCE_IP_ADDR(15 downto 0);
			elsif(TX_BYTE_COUNTER = 2) then
				TX_TCP_CKSUM_DATA <= TX_DEST_IP_ADDR(31 downto 16);
			elsif(TX_BYTE_COUNTER = 3) then
				TX_TCP_CKSUM_DATA <= TX_DEST_IP_ADDR(15 downto 0);
			elsif(TX_BYTE_COUNTER = 4) then
				TX_TCP_CKSUM_DATA <= x"0006";	-- protocol (from IP header) = TCP
			elsif(TX_BYTE_COUNTER = 5) then
				TX_TCP_CKSUM_DATA <= TX_TCP_LENGTH;	-- TCP length (header + payload), computed

			-- include TCP header fields located after the checksum field or just before (no time to compute): window size,
			-- urgent pointer (x0000) and option(x0204 when present)
			elsif(TX_BYTE_COUNTER = 6) then
				TX_TCP_CKSUM_DATA <= TX_ACK_WINDOW_LENGTH; -- window size
				TX_TCP_CKSUM_FLAG <= '1';
			elsif(TX_BYTE_COUNTER = 7) and (TX_PACKET_TYPE = 1)  then
				-- optional TCP header
				TX_TCP_CKSUM_DATA <= x"0204"; -- urgent pointer (x0000) and option(x0204 when present)
			elsif(TX_BYTE_COUNTER = 8) and (TX_PACKET_TYPE = 1)  then
				-- optional TCP header
				TX_TCP_CKSUM_DATA <= MSS; -- MSS
			else
				TX_TCP_CKSUM_FLAG <= '0';
			end if;
		elsif(MAC_TX_CTS = '1') and (TX_TCP_HEADER_D = '1') and (TX_BYTE_COUNTER_D(0) = '1')  then
			TX_TCP_CKSUM_DATA <= MAC_TX_DATA_D & MAC_TX_DATA_local; 
			TX_TCP_CKSUM_FLAG <= '1';
		else
			TX_TCP_CKSUM_FLAG <= '0';
		end if;
	end if;
end process;

TX_TCP_CHECKSUM_002: process(ASYNC_RESET, CLK)
begin
	if(ASYNC_RESET = '1') then
		TX_TCP_CHECKSUM <= (others => '0');
	elsif rising_edge(CLK) then
		if(TX_PACKET_SEQUENCE_START = '1') then
			-- initiating tx request. new tx packet. 
			-- assume that frame includes payload data. 
			-- initialize with ready-to-use payload checksum as provided by TCP_TXBUF.
			TX_TCP_CHECKSUM <= TX_PAYLOAD_CHECKSUM;
		elsif(TX_ETHERNET_HEADER = '1') and (TX_BYTE_COUNTER = 13) and (TX_PACKET_TYPE /= 3) then	
			-- end of Ethernet header 
			-- frame has no payload data.
			TX_TCP_CHECKSUM <= (others => '0');
		elsif(TX_TCP_CKSUM_FLAG = '1') then
			-- compute during IP header and TCP header
			-- 1's complement sum (add carry)
			TX_TCP_CHECKSUM <= ("0" & TX_TCP_CHECKSUM(15 downto 0)) + 
									 (x"0000" & TX_TCP_CHECKSUM(16)) +
									 ("0" & TX_TCP_CKSUM_DATA); 
		end if;
	end if;
end process;
--// final checksum
-- don't forget to add the last carry immediately at the end of the IP header
TX_TCP_CHECKSUM_FINAL <= not(TX_TCP_CHECKSUM(15 downto 0) + ("000" & x"000" & TX_TCP_CHECKSUM(16))) ;


end Behavioral;

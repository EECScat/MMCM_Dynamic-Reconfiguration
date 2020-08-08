-------------------------------------------------------------
-- MSS copyright 2003-2014
--	Filename:  PING.VHD
-- Author: Alain Zarembowitch / MSS
--	Version: 2
--	Date last modified: 1/11/14
-- Inheritance: 	COM-5003 PING.VHD 11-21-03
--
-- description:  PING protocol. 
-- Reads receive packet structure on the fly and generates a ping echo.
-- Any new received packet is presumed to be an ICMP echo (ping) request. Within a few bytes,
-- information is received as to the real protocol associated with the received packet.
-- The ping echo generation is immediately cancelled if 
-- (a) the received packet type is not an IP datagram 
-- (b) the received IP type is not ICMP (RX_IP_TYPE /= 1)
-- (c) invalid destination IP 
-- (d) ICMP incoming packet is not an echo request (ICMP type /= x"0800")
-- (e) packet size is greater than MAX_PING_SIZE bytes 
-- (f) incorrect IP header checksum

-- rev 2 1/11/14 AZ
-- Corrected error in checksum computation (missing carry). (from ?????? ???????)
-- Switched to numeric_std library.
-- Initialized signals for simulation.
---------------------------------------------------------------
library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;
use IEEE.STD_LOGIC_UNSIGNED.ALL;
library UNISIM;
use UNISIM.VComponents.all;

entity PING is
	generic (
		IPv6_ENABLED: std_logic := '0';
			-- 0 to minimize size, 1 to allow IPv6 in addition to IPv4 (larger size)
		MAX_PING_SIZE: std_logic_vector(15 downto 0) := x"0200" 	
			-- maximum PING size. Larger echo requests will be ignored.
		
	);
    Port ( 
		--// CLK, RESET
		ASYNC_RESET: in std_logic;
		CLK: in std_logic;
			-- Must be a global clock. No BUFG instantiation within this component.

		--// Packet/Frame received
		MAC_RX_DATA: in std_logic_vector(7 downto 0);
		MAC_RX_DATA_VALID: in std_logic;
			-- one CLK-wide pulse indicating a new byte is read from the received frame
			-- and can be read at MAC_RX_DATA
		MAC_RX_SOF: in std_logic;
			-- Start of Frame: one CLK-wide pulse indicating the first word in the received frame
			-- aligned with MAC_RX_DATA_VALID.
		MAC_RX_EOF: in std_logic;
			-- End of Frame: one CLK-wide pulse indicating the last word in the received frame
			-- aligned with MAC_RX_DATA_VALID.


		--// Configuration data: IP address, MAC address
		MAC_ADDR: in std_logic_vector(47 downto 0);
			-- MAC address. Unique for each network interface card.
			-- Natural byte order: (MSB) 0x000102030405 (LSB) 
			-- as transmitted in the Ethernet packet.
		IPv4_ADDR: in std_logic_vector(31 downto 0);
		IPv6_ADDR: in std_logic_vector(127 downto 0);
			-- local IP address. 4 bytes for IPv4, 16 bytes for IPv6
			-- Natural order (MSB) 172.16.1.128 (LSB) as transmitted in the IP frame.
		
		--// IP type: 
		RX_IPv4_6n: in std_logic;
			-- IP version. 4 or 6
		RX_IP_PROTOCOL: in std_logic_vector(7 downto 0);
			-- The protocol information is valid as soon as the 8-bit IP protocol field in the IP header is read.
			-- Information stays until start of following packet.
			-- most common protocols: 
			-- 0 = unknown, 1 = ICMP, 2 = IGMP, 6 = TCP, 17 = UDP, 41 = IPv6 encapsulation, 89 = OSPF, 132 = SCTP
			-- latency: 3 CLK after IP protocol field at byte 9 of the IP header
	  	RX_IP_PROTOCOL_RDY: in std_logic;
			-- 1 CLK wide pulse. 
		IP_RX_DATA_VALID: in std_logic;	
			-- two clocks after MAC_RX_DATA. Read when IP_RX_EOF = '1'
			-- Validity checks performed within are 
			-- (a) protocol is IP
			-- (c) destination IP address matches
			-- (f) correct IP header checksum
		IP_RX_EOF: in std_logic;
			-- latency: 2 CLKs after MAC_RX_DATA

		--// USER -> Transmit MAC Interface
		-- 32-bit CRC is automatically appended. User should not supply it.
		-- Synchonous with the user-side CLK
		MAC_TX_DATA: out std_logic_vector(7 downto 0);
			-- MAC reads the data at the rising edge of CLK when MAC_TX_DATA_VALID = '1'
		MAC_TX_DATA_VALID: out std_logic;
			-- data valid
		MAC_TX_EOF: out std_logic;
			-- '1' when sending the last byte in a packet to be transmitted. 
			-- Aligned with MAC_TX_DATA_VALID
		MAC_TX_CTS: in std_logic;
			-- MAC-generated Clear To Send flow control signal. The user should check that this 
			-- signal is high before sending the next MAC_TX_DATA byte. 
		RTS: out std_logic;
			-- '1' when a full or partial packet is ready to be read.
			-- '0' when output buffer is empty.
			-- When the user starts reading the output buffer, it is expected that it will be
			-- read until empty.

		-- Test Points
		TP: out std_logic_vector(10 downto 1)

			);
end entity;

architecture Behavioral of PING is
--------------------------------------------------------
--      COMPONENTS
--------------------------------------------------------
--------------------------------------------------------
--     SIGNALS
--------------------------------------------------------

--// BYTE COUNT ----------------------
signal MAC_RX_DATA_VALID_D: std_logic := '0';
signal MAC_RX_SOF_D: std_logic := '0';
signal MAC_RX_EOF_D: std_logic := '0';
signal MAC_RX_DATA_D: std_logic_vector(7 downto 0) := x"00";
signal MAC_RX_DATA_PREVIOUS_D: std_logic_vector(7 downto 0) := x"00";
signal BYTE_COUNT: integer range 0 to 2047 := 0;			-- read/use at MAC_RX_DATA_VALID_D
signal MAC_RX_DATA16_D: std_logic_vector(15 downto 0) := (others => '0');
signal VALID_PING_REQ_A: std_logic := '0';
signal VALID_PING_REQ: std_logic := '0';
signal CS_CARRY: std_logic := '0';

--// DPRAM signals
signal WPTR: std_logic_vector(10 downto 0) := (others => '0');
signal WPTR_CONFIRMED: std_logic_vector(10 downto 0) := (others => '0');
signal WEA: std_logic := '0';
signal DIA: std_logic_vector(7 downto 0);
signal DIPA: std_logic_vector(0 downto 0);
signal DOPB: std_logic_vector(0 downto 0);
signal RPTR: std_logic_vector(10 downto 0) := (others => '1');
signal BUF_SIZE: std_logic_vector(10 downto 0) := (others => '0');

--// OUTPUT SECTION
signal MAC_TX_DATA_VALID_E: std_logic := '0';
signal MAC_TX_DATA_VALID_local: std_logic := '0';
signal RTS_LOCAL: std_logic := '0';
--------------------------------------------------------
--      IMPLEMENTATION
--------------------------------------------------------
begin

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

MAC_RX_DATA16_D <= MAC_RX_DATA_PREVIOUS_D & MAC_RX_DATA_D;	-- reconstruct 16-bit field. Aligned with MAC_RX_DATA_VALID_D

-- manipulate the BLOCKRAM write pointer to move fields around
-- For example: copy source address into destination address
WPTR_GEN_001: process(ASYNC_RESET, CLK)
begin
	if(ASYNC_RESET = '1') then
		WPTR <= (others => '0');
		WEA <= '0';
	elsif rising_edge(CLK) then
		WEA <= MAC_RX_DATA_VALID_D;
		
		if(MAC_RX_DATA_VALID_D = '1') then
			-- new incoming byte. Always position the new echo reply starting at the last confirmed wptr location.
			if(MAC_RX_SOF_D = '1') then	-- start of destination address field
				WPTR <= WPTR_CONFIRMED + 6;		-- reposition write pointer to source address field
			elsif(BYTE_COUNT = 6) then 	-- start of source address field
				WPTR <= WPTR - 11;	-- reposition write pointer to destination address field
			elsif(BYTE_COUNT = 12) then	-- start of ethernet type
				WPTR <= WPTR + 7;	-- reposition write pointer to start of ethernet type/length field
				
			-- Ethernet encapsulation, RFC 894, IPv4
			elsif(RX_IPv4_6n = '1') then
				if(BYTE_COUNT = 26) then	
					WPTR <= WPTR + 5;	-- swap source / destination IP address
				elsif(BYTE_COUNT = 30) then
					WPTR <= WPTR - 7;	-- swap source / destination IP address
				elsif(BYTE_COUNT = 34) then
					WPTR <= WPTR + 5;	-- move pointer back to ICMP payload
				else
					WPTR <= WPTR + 1;	-- within a field. keep increasing pointer
				end if;
							
			-- Ethernet encapsulation, RFC 894, IPv6 (when enabled)
			elsif(IPv6_ENABLED = '1') and (RX_IPv4_6n = '0') then
			-- TODO

			else
				WPTR <= WPTR + 1;	-- within a field. keep increasing pointer
			end if;
		end if;
	end if;
end process;

-- confirm next write pointer location at the end of packet.
-- If valid echo request, new write pointer = current write pointer.
-- Otherwise, rewind to last good location.
WPTR_GEN_002: process(ASYNC_RESET, CLK)
begin
	if(ASYNC_RESET = '1') then
		WPTR_CONFIRMED <= (others => '0');
	elsif rising_edge(CLK) then
		if(IP_RX_EOF = '1') and (VALID_PING_REQ = '1') then
			WPTR_CONFIRMED <= WPTR + 1;	-- next write location
		end if;
	end if;
end process;

DIPA(0) <= IP_RX_EOF; 	-- keeps track of the end of echo response in the elastic buffer.

-- PING response data field
DIA_GEN_001: process(ASYNC_RESET, CLK)
begin
	if(ASYNC_RESET = '1') then
		DIA <= (others => '0');
	elsif rising_edge(CLK) then
		if(MAC_RX_DATA_VALID_D = '1') then
			-- new incoming byte
			
			-- Substitutions in echo
			if(BYTE_COUNT = 0) then 	-- always insert our own MAC address as source
				DIA <= MAC_ADDR(47 downto 40);
			elsif(BYTE_COUNT = 1) then
				DIA <= MAC_ADDR(39 downto 32);
			elsif(BYTE_COUNT = 2) then
				DIA <= MAC_ADDR(31 downto 24);
			elsif(BYTE_COUNT = 3) then
				DIA <= MAC_ADDR(23 downto 16);
			elsif(BYTE_COUNT = 4) then
				DIA <= MAC_ADDR(15 downto 8);
			elsif(BYTE_COUNT = 5) then
				DIA <= MAC_ADDR(7 downto 0);

			elsif(RX_IPv4_6n = '1') and (BYTE_COUNT = 34) then
				DIA <= x"00";	-- change from echo request to echo reply
				
			--TODO IPv6
				
			-- update ICMP payload checksum
			-- Only difference in checksum is the 0800 field turning into 0000. No need
			-- to recompute checksum, just subtract 0800
			elsif(RX_IPv4_6n = '1') and (BYTE_COUNT = 36) then
				DIA <= MAC_RX_DATA_D + x"08";
				if(MAC_RX_DATA_D >= x"F8") then
					CS_CARRY <= '1';
				else
					CS_CARRY <= '0';
				end if;
			elsif(RX_IPv4_6n = '1') and (BYTE_COUNT = 37) and (CS_CARRY = '1') then	-- new 1/11/14 AZ
				DIA <= MAC_RX_DATA_D + 1;
				
			--TODO IPv6
				
			-- copying from received message. 
			else
				DIA <= MAC_RX_DATA_D;
			end if;
			
		end if;
	end if;
end process;



-- Circular elastic buffer.
-- Capable of storing other ping requests while waiting for the transmit path to become available.
RAMB16_S9_S9_inst : RAMB16_S9_S9
port map (
	DOA => open,      -- Port A 8-bit Data Output
	DOB => MAC_TX_DATA,      -- Port B 8-bit Data Output
	DOPA => open,    -- Port A 1-bit Parity Output
	DOPB => DOPB,    -- Port B 1-bit Parity Output
	ADDRA => WPTR,  -- Port A 11-bit Address Input
	ADDRB => RPTR,  -- Port B 11-bit Address Input
	CLKA => CLK,    -- Port A Clock
	CLKB => CLK,    -- Port B Clock
	DIA => DIA,      -- Port A 8-bit Data Input
	DIB => x"00",      -- Port B 8-bit Data Input
	DIPA => DIPA,    -- Port A 1-bit parity Input
	DIPB => "0",    -- Port-B 1-bit parity Input
	ENA => '1',      -- Port A RAM Enable Input
	ENB => '1',      -- PortB RAM Enable Input
	SSRA => '0',    -- Port A Synchronous Set/Reset Input
	SSRB => '0',    -- Port B Synchronous Set/Reset Input
	WEA => WEA,      -- Port A Write Enable Input
	WEB => '0'       -- Port B Write Enable Input
);

MAC_TX_EOF <= DOPB(0) and MAC_TX_DATA_VALID_local;	-- '1' marks the end of the echo reply

--// Incoming packet check
-- The ping echo generation is immediately cancelled if 
-- (a) the received packet type is not an IP datagram 
-- (b) the received IP type is not ICMP (RX_IP_TYPE /= 1)
-- (c) invalid destination IP 
-- (d) ICMP incoming packet is not an echo request (ICMP type /= x"0800")
-- (e) packet size is greater than MAX_PING_SIZE bytes 
-- (f) incorrect IP header checksum 
VALIDITY_CHECK_001: process(ASYNC_RESET, CLK)
begin
	if(ASYNC_RESET = '1') then
		VALID_PING_REQ_A <= '1';
	elsif rising_edge(CLK) then
		if(MAC_RX_SOF = '1') then
			-- just received first byte. Consider ICMP echo request valid until proven otherwise
			VALID_PING_REQ_A <= '1';
		elsif(RX_IP_PROTOCOL_RDY = '1') and (RX_IP_PROTOCOL /= 1) then
			-- (b) the received IP type is not ICMP (RX_IP_TYPE /= 1)
			VALID_PING_REQ_A <= '0';
		elsif(BYTE_COUNT > MAX_PING_SIZE) then
			-- (d) packet size is greater than MAX_PING_SIZE bytes 
			VALID_PING_REQ_A <= '0';
		elsif(MAC_RX_DATA_VALID_D = '1') and (RX_IPv4_6n = '1') and (BYTE_COUNT = 35) 
			and (MAC_RX_DATA16_D /= x"0800") then
			-- (e) ICMP incoming packet is not an echo request (ICMP type /= x"0800")
			-- Ethernet encapsulation, RFC 894, IPv4
			VALID_PING_REQ_A <= '0';
--		elsif(MAC_RX_DATA_VALID_D = '1') and (IPv6_ENABLED = '1') and (RX_IPv4_6n = '0')  
--			and (BYTE_COUNT = 35) and (MAC_RX_DATA16_D /= x"0800") then
--				-- (e) ICMP incoming packet is not an echo request (ICMP type /= x"0800")
--				-- Ethernet encapsulation
--			-- TODO IPv6
	 	end if;
	end if;
end process;
			-- Invalid IP detected at the end of the IP frame
			-- (a) the received packet type is not an IP datagram 
			-- (c) invalid destination IP 
			-- (f) incorrect IP header checksum 
VALID_PING_REQ <= VALID_PING_REQ_A and IP_RX_DATA_VALID;	-- read at MAC_RX_DATA_VALID_D2

-- occupied buffer space, in bytes
BUF_SIZE <= WPTR_CONFIRMED + not(RPTR);

-- send request to send when (at least) one valid echo response is ready
RTS_LOCAL <= '1' when (BUF_SIZE /= 0) else '0';
RTS <= RTS_LOCAL;

--// OUTPUT SECTION
-- Transmit flow control 
-- Request to send when PING reply is ready.
RPTR_GEN_001: process(ASYNC_RESET, CLK)
begin
	if(ASYNC_RESET = '1') then
		RPTR <= (others => '1');
		MAC_TX_DATA_VALID_E <= '0';
		MAC_TX_DATA_VALID_local <= '0';
	elsif rising_edge(CLK) then
		MAC_TX_DATA_VALID_local <= MAC_TX_DATA_VALID_E;	-- it takes one clock to read data from RAMB.
		
		if(RTS_LOCAL = '1') and (MAC_TX_CTS = '1') then
			-- buffer is not empty and MAC requests another byte
			RPTR <= RPTR + 1;
			MAC_TX_DATA_VALID_E <= '1';
		else
			MAC_TX_DATA_VALID_E <= '0';
		end if;
	end if;
end process;
MAC_TX_DATA_VALID <= MAC_TX_DATA_VALID_local;


--// Test Point
TP(1) <= MAC_RX_DATA_VALID;
TP(2) <= IP_RX_DATA_VALID;
TP(3) <= RTS_LOCAL;
TP(4) <= IP_RX_EOF;
TP(5) <= '1' when ((IP_RX_EOF = '1') and (IP_RX_DATA_VALID = '1')) else '0';
TP(6) <= MAC_TX_CTS;
TP(7) <= VALID_PING_REQ;
TP(8) <= VALID_PING_REQ_A;
TP(9) <= MAC_TX_DATA_VALID_local;
TP(10) <= DOPB(0) and MAC_TX_DATA_VALID_local;	-- '1' marks the end of the echo reply;



end Behavioral;

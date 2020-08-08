-------------------------------------------------------------
-- MSS copyright 2003-2011
--	Filename:  ARP.VHD
-- Author: Alain Zarembowitch / MSS
--	Version: 1
--	Date last modified: 2/18/11
-- Inheritance: 	COM-5003 ARP.vhd 9/20/2005 Rev 2
--
-- description:  Address resolution protocol. 
-- Reads receive packet structure on the fly and generates an ARP reply.
-- Any new received packet is presumed to be an ARP request. Within a few bytes,
-- information is received as to the real protocol associated with the received packet.
-- The ARP reply generation is immediately cancelled if 
-- (a) the received packet type is not 0806
-- Supports only Ethernet (IEEE 802.3) encapsulation
-- ARP only applies to IPv6. For IPv6, use neighbour discovery protocol instead.
---------------------------------------------------------------
library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.STD_LOGIC_ARITH.ALL;
use IEEE.STD_LOGIC_UNSIGNED.ALL;

entity ARP is
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
			-- local IP address. 4 bytes for IPv4 only
			-- Natural order (MSB) 172.16.1.128 (LSB) as transmitted in the IP frame.

		--// Received type
		RX_TYPE: in std_logic_vector(3 downto 0);
			-- Information stays until start of following packet.
			-- Only one valid types: 
			-- 2 = Ethernet encapsulation, ARP request/reply
	  	RX_TYPE_RDY: in std_logic;
			-- 1 CLK-wide pulse indicating that a detection was made on the received packet
			-- type, and that RX_TYPE can be read.
			-- Detection occurs as soon as possible, two clocks after receiving byte 13 or 21.

		--// Packet origin, already parsed in PACKET_PARSING (shared code)
		RX_SOURCE_MAC_ADDR: in std_logic_vector(47 downto 0);
		RX_SOURCE_IP_ADDR: in std_logic_vector(31 downto 0);	-- IPv4 only

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

architecture Behavioral of ARP is
--------------------------------------------------------
--      COMPONENTS
--------------------------------------------------------
--------------------------------------------------------
--     SIGNALS
--------------------------------------------------------

--// STATE MACHINE ------------------
signal STATE: std_logic_vector(0 downto 0) := (others => '0');
signal INPUT_ENABLED: std_logic := '1';

--// BYTE COUNT ----------------------
signal MAC_RX_DATA_VALID_D: std_logic := '0';
signal MAC_RX_SOF_D: std_logic := '0';
signal MAC_RX_EOF_D: std_logic := '0';
signal MAC_RX_DATA_D: std_logic_vector(7 downto 0) := x"00";
signal MAC_RX_DATA_PREVIOUS_D: std_logic_vector(7 downto 0) := x"00";
signal BYTE_COUNT: integer range 0 to 2047;			-- read/use at MAC_RX_DATA_VALID_D
signal MAC_RX_DATA16_D: std_logic_vector(15 downto 0);
signal MAC_RX_EOF_D2: std_logic := '0';

--// VALIDATE ARP REQUEST -----------
signal VALID_ARP_REQ: std_logic;
signal RX_SOURCE_MAC_ADDR0: std_logic_vector(47 downto 0);
signal RX_SOURCE_IP_ADDR0: std_logic_vector(31 downto 0);

--// ARP REPLY -----------------
signal MAC_TX_EOF_local: std_logic;
signal RPTR: std_logic_vector(5 downto 0);	-- range 0 - 41
--------------------------------------------------------
--      IMPLEMENTATION
--------------------------------------------------------
begin

--// STATE MACHINE ------------------
-- A state machine is needed as this process is memoryless.
-- State 0 = idle or incoming packet being processed. No tx packet waiting.
-- State 1 = valid ARP request. tx packet waiting for tx capacity. Incoming packets are ignored.
STATE_GEN_001: process(ASYNC_RESET, CLK)
begin
	if(ASYNC_RESET = '1') then
		STATE <= (others => '0');
	elsif rising_edge(CLK) then
		if(STATE = 0) and (MAC_RX_EOF_D2 = '1') and (VALID_ARP_REQ = '1') then
			-- event = valid ARP request. Ready to send ARP reply when tx channel opens.
			-- In the mean time, incoming packets are ignored.
			STATE <= conv_std_logic_vector(1, STATE'length);
		elsif(STATE = 1) and (MAC_TX_EOF_local = '1') then
			-- event = successfully sent ARP reply. Reopen input
			STATE <= conv_std_logic_vector(0, STATE'length);
		end if;
	end if;
end process;

INPUT_ENABLED <= '1' when (STATE = 0) else '0';


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
		if(INPUT_ENABLED = '0') then
			-- we still waiting to send the last ARP reply. Ignore any incoming packets until transmission is complete.
			BYTE_COUNT <= 0;
			MAC_RX_DATA_D <= (others => '0');
			MAC_RX_DATA_VALID_D <= '0';
			MAC_RX_SOF_D <= '0';
			MAC_RX_EOF_D <= '0';
		else
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
	end if;
end process;

MAC_RX_DATA16_D <= MAC_RX_DATA_PREVIOUS_D & MAC_RX_DATA_D;	-- reconstruct 16-bit field. Aligned with MAC_RX_DATA_VALID_D

--// VALIDATE ARP REQUEST -----------
-- The ARP reply generation is immediately cancelled if 
-- (a) the received packet type is not an ARP request/reply
-- (b) the Opcode does not indicate an ARP request
-- (c) the IP address does not match

VALIDITY_CHECK_001: process(ASYNC_RESET, CLK)
begin
	if(ASYNC_RESET = '1') then
		VALID_ARP_REQ <= '1';
		MAC_RX_EOF_D2 <= '0';
	elsif rising_edge(CLK) then
		MAC_RX_EOF_D2 <= MAC_RX_EOF_D;
		
		if(MAC_RX_SOF_D = '1') then
			-- just received first byte. ARP request valid until proven otherwise
			VALID_ARP_REQ <= '1';
		elsif (RX_TYPE = 2) then
			-- Ethernet encapsulation
			if(MAC_RX_DATA_VALID_D = '1') and (BYTE_COUNT = 21) 
				and (MAC_RX_DATA16_D /= x"0001") then
				-- (b) op field does not indicate ARP request
				VALID_ARP_REQ <= '0';
			elsif(MAC_RX_DATA_VALID_D = '1') and (BYTE_COUNT = 39) 
				and (MAC_RX_DATA16_D /= IPv4_ADDR(31 downto 16)) then
				-- (c) Target IP address does not match
				VALID_ARP_REQ <= '0';
			elsif(MAC_RX_DATA_VALID_D = '1') and (BYTE_COUNT = 41) 
				and (MAC_RX_DATA16_D /= IPv4_ADDR(15 downto 0)) then
				-- (c) Target IP address does not match
				VALID_ARP_REQ <= '0';
			end if;
	  	elsif(MAC_RX_EOF_D = '1') and (RX_TYPE /= 2) then
			-- (a) the received packet type is not an ARP request/reply
			VALID_ARP_REQ <= '0';
	 	end if;
	end if;
end process;

--// freeze source MAC address and source IP address at the end of the packet 
-- Reason: we don't want subsequent packets to change this information while we are waiting
-- to send the ARP reply.
FREEZE_001: process(ASYNC_RESET, CLK)
begin
	if(ASYNC_RESET = '1') then
		RX_SOURCE_MAC_ADDR0 <= (others => '0');
		RX_SOURCE_IP_ADDR0 <= (others => '0');
	elsif rising_edge(CLK) then
	  	if(MAC_RX_EOF = '1') and (STATE = 0) then
			RX_SOURCE_MAC_ADDR0 <= RX_SOURCE_MAC_ADDR;
			RX_SOURCE_IP_ADDR0 <= RX_SOURCE_IP_ADDR;
	 	end if;
	end if;
end process;

	
--// ARP REPLY -----------------
--// Generate ARP reply packet on the fly
ARP_RESP_GEN_001: process(ASYNC_RESET, CLK)
begin
	if(ASYNC_RESET = '1') then
		MAC_TX_DATA <= (others => '0');
	elsif rising_edge(CLK) then
		if(MAC_TX_CTS = '1') and (RPTR <= 41) then
			case(RPTR) is
				-- destination Ethernet address
				when "000000" => MAC_TX_DATA <= RX_SOURCE_MAC_ADDR0(47 downto 40);	
				when "000001" => MAC_TX_DATA <= RX_SOURCE_MAC_ADDR0(39 downto 32);	 
				when "000010" => MAC_TX_DATA <= RX_SOURCE_MAC_ADDR0(31 downto 24);	
				when "000011" => MAC_TX_DATA <= RX_SOURCE_MAC_ADDR0(23 downto 16);
				when "000100" => MAC_TX_DATA <= RX_SOURCE_MAC_ADDR0(15 downto 8);	
				when "000101" => MAC_TX_DATA <= RX_SOURCE_MAC_ADDR0(7 downto 0);	 
				-- source Ethernet address
				when "000110" => MAC_TX_DATA <= MAC_ADDR(47 downto 40);	
				when "000111" => MAC_TX_DATA <= MAC_ADDR(39 downto 32);	
				when "001000" => MAC_TX_DATA <= MAC_ADDR(31 downto 24);		
				when "001001" => MAC_TX_DATA <= MAC_ADDR(23 downto 16);
				when "001010" => MAC_TX_DATA <= MAC_ADDR(15 downto 8);		
				when "001011" => MAC_TX_DATA <= MAC_ADDR(7 downto 0);
				-- Ethernet type
				when "001100" => MAC_TX_DATA <= x"08";	
				when "001101" => MAC_TX_DATA <= x"06";
				-- hardware type
				when "001110" => MAC_TX_DATA <= x"00";		
				when "001111" => MAC_TX_DATA <= x"01";	
				-- protocol type
				when "010000" => MAC_TX_DATA <= x"08";	
				when "010001" => MAC_TX_DATA <= x"00";
				-- hardware size, protocol size
				when "010010" => MAC_TX_DATA <= x"06";	
				when "010011" => MAC_TX_DATA <= x"04";
				-- op field. ARP reply
				when "010100" => MAC_TX_DATA <= x"00";	
				when "010101" => MAC_TX_DATA <= x"02";	
				-- source Ethernet address
				when "010110" => MAC_TX_DATA <= MAC_ADDR(47 downto 40);	
				when "010111" => MAC_TX_DATA <= MAC_ADDR(39 downto 32);	
				when "011000" => MAC_TX_DATA <= MAC_ADDR(31 downto 24);		
				when "011001" => MAC_TX_DATA <= MAC_ADDR(23 downto 16);
				when "011010" => MAC_TX_DATA <= MAC_ADDR(15 downto 8);		
				when "011011" => MAC_TX_DATA <= MAC_ADDR(7 downto 0);
				-- sender IP address
				when "011100" => MAC_TX_DATA <= IPv4_ADDR(31 downto 24);	
				when "011101" => MAC_TX_DATA <= IPv4_ADDR(23 downto 16);
				when "011110" => MAC_TX_DATA <= IPv4_ADDR(15 downto 8);	
				when "011111" => MAC_TX_DATA <= IPv4_ADDR(7 downto 0);
				-- destination Ethernet address
				when "100000" => MAC_TX_DATA <= RX_SOURCE_MAC_ADDR0(47 downto 40);	
				when "100001" => MAC_TX_DATA <= RX_SOURCE_MAC_ADDR0(39 downto 32);	 
				when "100010" => MAC_TX_DATA <= RX_SOURCE_MAC_ADDR0(31 downto 24);	
				when "100011" => MAC_TX_DATA <= RX_SOURCE_MAC_ADDR0(23 downto 16);
				when "100100" => MAC_TX_DATA <= RX_SOURCE_MAC_ADDR0(15 downto 8);	
				when "100101" => MAC_TX_DATA <= RX_SOURCE_MAC_ADDR0(7 downto 0);	 
				-- target IP address
				when "100110" => MAC_TX_DATA <= RX_SOURCE_IP_ADDR0(31 downto 24);		
				when "100111" => MAC_TX_DATA <= RX_SOURCE_IP_ADDR0(23 downto 16);	
				when "101000" => MAC_TX_DATA <= RX_SOURCE_IP_ADDR0(15 downto 8);		
				--when "101001" => MAC_TX_DATA <= RX_SOURCE_IP_ADDR0(7 downto 0);	
				when others => MAC_TX_DATA <= RX_SOURCE_IP_ADDR0(7 downto 0);	
			end case;
		end if;
	end if;
end process;


--// Sequence reply transmission and Flow control 
-- Request to send when ARP reply is ready.
RTS_GEN_001: process(ASYNC_RESET, CLK)
begin
	if(ASYNC_RESET = '1') then
		RTS <= '0';
		RPTR <= (others => '0');
		MAC_TX_DATA_VALID <= '0';
		MAC_TX_EOF_local <= '0';
	elsif rising_edge(CLK) then
		if(STATE = 0) and (MAC_RX_EOF_D2 = '1') and (VALID_ARP_REQ = '1') then
			-- Valid  & complete ARP request was received. Start reply transmission.
			RTS <= '1';	-- tell MAC we have a packet to send
			RPTR <= (others => '0');	
			MAC_TX_DATA_VALID <= '0';
		elsif(MAC_TX_CTS = '1') and (RPTR < 41) then
			-- Assemble reply on the fly. 
			-- Always Ethernet encapsulation
			RPTR <= RPTR + 1;	-- move read pointer in response to read request
			MAC_TX_DATA_VALID <= '1';

		elsif(MAC_TX_CTS = '1') and (RPTR = 41) then
			RPTR <= RPTR + 1;	-- move read pointer in response to read request
			MAC_TX_DATA_VALID <= '1';
			MAC_TX_EOF_local <= '1';
			RTS <= '0';
		else
			MAC_TX_DATA_VALID <= '0';
			MAC_TX_EOF_local <= '0';
		end if;
	end if;
end process;
MAC_TX_EOF <= MAC_TX_EOF_local;


--// Test Point
TP(1) <= MAC_RX_EOF;
TP(2) <= VALID_ARP_REQ;
TP(3) <= '1' when (RX_TYPE = 2) else '0';
TP(4) <= MAC_RX_SOF;
TP(5) <= '1' when (IPv4_ADDR = x"AC100181") else '0';



end Behavioral;

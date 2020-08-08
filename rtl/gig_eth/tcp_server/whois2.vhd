-------------------------------------------------------------
-- MSS copyright 2009-2012
--	Filename:  WHOIS2.VHD
-- Author: Alain Zarembowitch / MSS
--	Version: 1
--	Date last modified: 8/8/12
-- Inheritance: 	COM-5004 whois.vhd 2-27-09
--
-- description:  Asks around who is (given IP address) using the 
-- Address Resolution Protocol (ARP).
--
-- Rev1 8/8/12 AZ
-- Switched to SYNC_RESET 
---------------------------------------------------------------
library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.STD_LOGIC_ARITH.ALL;
use IEEE.STD_LOGIC_UNSIGNED.ALL;

entity WHOIS2 is
    Port ( 
		--// CLK, RESET
		SYNC_RESET: in std_logic;
		CLK: in std_logic;
		
		--// User interface
		WHOIS_IP_ADDR: in std_logic_vector(31 downto 0);
			-- user query: IP address to resolve. read at WHOIS_START
		WHOIS_START: in std_logic;
			-- 1 CLK pulse to start the ARP query
			-- new WHOIS requests will be ignored until the module is 
			-- finished with the previous request/reply transaction. 
		WHOIS_RDY: out std_logic;
			-- always check WHOIS_RDY before requesting a WHOIS transaction with WHOIS_START, otherwise
			-- there is risk that WHOIS is busy and that the request will be ignored.

		--// Configuration data: IP address, MAC address
		MAC_ADDR: in std_logic_vector(47 downto 0);
			-- MAC address. Unique for each network interface card.
			-- Natural byte order: (MSB = REG32) 0x000102030405 (LSB = REG37) 
			-- as transmitted in the Ethernet packet.
		IPv4_ADDR: in std_logic_vector(31 downto 0);
			-- local IP address
			-- Natural order (MSB - REG0) 172.16.1.128 (LSB-REG3)

		--// Transmit frame/packet
		MAC_TX_DATA: out std_logic_vector(7 downto 0);
		MAC_TX_DATA_VALID: out std_logic;
			-- one CLK-wide pulse indicating a new word is sent on MAC_TX_DATA
		MAX_TX_EOF: out std_logic;
			-- End of Frame: one CLK-wide pulse indicating the last word in the transmit frame.
 		   -- aligned with MAC_TX_DATA_VALID.
		MAC_TX_CTS: in std_logic;
			-- 1 CLK-wide pulse requesting output samples. Check RTS first.
		RTS: out std_logic;
			-- '1' when a full or partial packet is ready to be read.
			-- '0' when output buffer is empty.
			-- When the user starts reading the output buffer, it is expected that it will be
			-- read until empty.

		-- Test Points
		TP: out std_logic_vector(10 downto 1)

			);
end entity;

architecture Behavioral of WHOIS2 is
--------------------------------------------------------
--      COMPONENTS
--------------------------------------------------------
--------------------------------------------------------
--     SIGNALS
--------------------------------------------------------
signal WHOIS_STATE: integer range 0 to 1 := 0;
signal WHOIS_IP_ADDR_D: std_logic_vector(31 downto 0) := (others => '0');

--// ARP request
signal TX_PACKET_SEQUENCE: std_logic_vector(5 downto 0) := (others => '1');  -- 42 bytes max
signal MAC_TX_DATA_VALID_E: std_logic := '0';
signal MAX_TX_EOF_local: std_logic := '0';
signal RTS_local: std_logic := '0';
--------------------------------------------------------
--      IMPLEMENTATION
--------------------------------------------------------
begin

--// Generate ARP query
ARP_RESP_GEN_001: process(CLK)
begin
	if rising_edge(CLK) then
		if(SYNC_RESET = '1') then
			MAC_TX_DATA <= (others => '0');
		else
			case(TX_PACKET_SEQUENCE) is
				-- Ethernet header
				-- destination MAC address: broadcast. fixed at the time of connection establishment.
				when "000000" => MAC_TX_DATA <= x"FF";
				when "000001" => MAC_TX_DATA <= x"FF";
				when "000010" => MAC_TX_DATA <= x"FF";
				when "000011" => MAC_TX_DATA <= x"FF";
				when "000100" => MAC_TX_DATA <= x"FF";
				when "000101" => MAC_TX_DATA <= x"FF";
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
				-- op field. ARP request
				when "010100" => MAC_TX_DATA <= x"00";	
				when "010101" => MAC_TX_DATA <= x"01";	
				-- sender Ethernet address
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
				-- target Ethernet address
				when "100000" => MAC_TX_DATA <= x"00";	-- target Ethernet address. unfilled.
				when "100001" => MAC_TX_DATA <= x"00";	-- target Ethernet address. unfilled.
				when "100010" => MAC_TX_DATA <= x"00";	-- target Ethernet address. unfilled.
				when "100011" => MAC_TX_DATA <= x"00";	-- target Ethernet address. unfilled.
				when "100100" => MAC_TX_DATA <= x"00";	-- target Ethernet address. unfilled.
				when "100101" => MAC_TX_DATA <= x"00";	-- target Ethernet address. unfilled.	 
				-- target IP address
				when "100110" => MAC_TX_DATA <= WHOIS_IP_ADDR_D(31 downto 24);		
				when "100111" => MAC_TX_DATA <= WHOIS_IP_ADDR_D(23 downto 16);	
				when "101000" => MAC_TX_DATA <= WHOIS_IP_ADDR_D(15 downto 8);		
				when "101001" => MAC_TX_DATA <= WHOIS_IP_ADDR_D(7 downto 0);	
				when others => MAC_TX_DATA <= x"00"; -- default & trailer	
			end case;
		end if;
	end if;
end process;

TX_SEQUENCE_GEN: process(CLK)
begin
	if rising_edge(CLK) then
		if(SYNC_RESET = '1') then
			TX_PACKET_SEQUENCE <= (others => '1');
			WHOIS_IP_ADDR_D <= (others => '0');
			MAC_TX_DATA_VALID_E <= '0';
			MAC_TX_DATA_VALID <= '0';
		else

			MAC_TX_DATA_VALID <= MAC_TX_DATA_VALID_E;  -- 1 clk delay in reading MAC_TX_DATA

			if(WHOIS_START = '1') and (WHOIS_STATE = 0) then
				-- new transaction. Sending ARP request
				-- ready to send ARP request
				TX_PACKET_SEQUENCE <= (others => '1');
				-- save whois IP address
				WHOIS_IP_ADDR_D <= WHOIS_IP_ADDR;
			elsif(MAC_TX_CTS = '1') and ((TX_PACKET_SEQUENCE < 41) or (TX_PACKET_SEQUENCE(5 downto 4) = "11"))then
				-- read the next word
				TX_PACKET_SEQUENCE <= TX_PACKET_SEQUENCE + 1;
				MAC_TX_DATA_VALID_E <= '1';
			else 
				MAC_TX_DATA_VALID_E <= '0';
			end if;
		end if;
	end if;
end process;

-- aligned with MAC_TX_DATA_VALID
MAX_TX_EOF_GEN: process(CLK)
begin
	if rising_edge(CLK) then
		if(SYNC_RESET = '1') then
			MAX_TX_EOF_local <= '0';
		else
			if(MAC_TX_DATA_VALID_E = '1') and (TX_PACKET_SEQUENCE = 41) then
				-- done. transmitting the last word
				MAX_TX_EOF_local <= '1';
			else
				MAX_TX_EOF_local <= '0';
			end if;
		end if;
	end if;
end process;
MAX_TX_EOF <= MAX_TX_EOF_local;

-- WHOIS state machine
RTS_GEN: process(CLK)
begin
	if rising_edge(CLK) then
		if(SYNC_RESET = '1') then
			RTS_local <= '0';
			WHOIS_STATE <= 0;
		else
			if(WHOIS_START = '1') and (WHOIS_STATE = 0) then
				-- new transaction. Sending ARP request
				RTS_local <= '1';
				WHOIS_STATE <= 1;
			elsif(MAX_TX_EOF_local = '1') then
				-- done. transmitting the last word
				RTS_local <= '0';
				WHOIS_STATE <= 0;
			end if;
		end if;
	end if;
end process;
RTS <= RTS_local;
WHOIS_RDY <= RTS_local or WHOIS_START;


--// Test Point
TP(1) <= WHOIS_START;
TP(2) <= MAC_TX_CTS;
TP(3) <= MAC_TX_DATA_VALID_E;
TP(4) <= MAX_TX_EOF_local;
TP(5) <= RTS_local;

end Behavioral;

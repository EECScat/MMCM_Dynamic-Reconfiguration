-------------------------------------------------------------
-- MSS copyright 2009-2014
--	Filename:  ARP_CACHE2.VHD
-- Author: Alain Zarembowitch / MSS
--	Version: 4
--	Date last modified: 2/13/14
-- Inheritance: 	COM-5004 ARP_CACHE.VHD, rev2, 6/13/11
--
-- description:  table linking 32-bit IP address, 48-bit MAC address and the information
-- "freshness", i.e. time last seen, in effect a routing table. 
-- Uses one 16Kbit block RAM for a maximum of 128 entries.    
-- This component determines whether the destination IP address is local or not. In the
-- latter case, the MAC address of the gateway is returned. 
-- Only records regarding local addresses are stored (i.e. not WAN addresses since these often
-- point to the router MAC address anyway).
--
-- Assumming a 125 MHz clock...
-- Time to access an existing record: between 0.1 to 1.33 us max depending on the record location in the table.
-- Time to search entire table: 1.33us
-- Time to store a new record: 2.64us starting at the RX_SOURCE_ADDR_RDY pulse.
-- Time to refresh an existing record: between 0.1 and 2.64us depending on the record location in the table.


-- An important startup issue is that ARP requests sent shortly after power up are
-- lost either at our LAN IC or at the destination LAN network interface card (PC
-- operating system slow at detecting a new LAN connection). This is especially
-- true when the destination COM-5004 is connected directly (through a cross-over cable)
-- to the destination PC. 
--
-- Rev1 8/7/12 AZ
-- Do an ARP on the gateway IP address if gateway MAC address is undefined (0) and a packet is to be
-- forwarded to the gateway. It was unrealistic to only rely on gateway traffic to discover the gateway mac addr.
-- Switched from ASYNC_RESET to SYNC_RESET
--
-- Rev2 10/10/13 AZ
-- Added a timer to limit the rate at which ARP requests are sent out.
--
-- Rev 3 1/11/14 AZ
-- IP broadcast messages are treated as local broadcast (from ?????? ???????)
-- Switched to numeric_std library
--
-- Rev 4 2/13/14 AZ
-- Minor change to avoid modelsim warnings
---------------------------------------------------------------
library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;
use IEEE.STD_LOGIC_UNSIGNED.ALL;
Library UNISIM;
use UNISIM.vcomponents.all;

entity ARP_CACHE2 is
    Port ( 
		--// CLK, RESET
		SYNC_RESET: in std_logic;
			-- synchronous reset: MANDATORY to properly initialize this component
		CLK: in std_logic;	
			-- reference clock.
			-- Global clock. No BUFG instantiation within this component.
		TICK_100MS : in std_logic;
			-- 100 ms tick for timer
		
		--// User interface (query/reply)
		-- (a) query
		RT_IP_ADDR: in std_logic_vector(31 downto 0);
			-- user query: destination IP address to resolve (could be local or remote). read when RT_REQ_RTS = '1'
		RT_REQ_RTS: in std_logic;
			-- new requests will be ignored until the module is 
			-- finished with the previous request/reply transaction
		RT_CTS: out std_logic;	
			-- ready to accept a new routing query.
		-- (b) reply
		RT_MAC_REPLY: out std_logic_vector(47 downto 0);
			-- Destination MAC address associated with the destination IP address RT_IP_ADDR. 
			-- Could be the Gateway MAC address if the destination IP address is outside the local area network.
		RT_MAC_RDY: out std_logic;
			-- 1 CLK pulse to read the MAC reply
			-- The worst case latency from the RT_REQ_RTS request is 1.33us
			-- If there is no match in the table, no response will be provided. Calling routine should
			-- therefore have a timeout timer to detect lack of response.
		RT_NAK: out std_logic;
			-- 1 CLK pulse indicating that no record matching the RT_IP_ADDR was found in the table.

		--// Routing information
		MAC_ADDR : IN std_logic_vector(47 downto 0);
			-- local MAC address
		IPv4_ADDR: in std_logic_vector(31 downto 0);
			-- local IP address. 4 bytes for IPv4 only
			-- Natural order (MSB) 172.16.1.128 (LSB) as transmitted in an IP frame.
		SUBNET_MASK: in std_logic_vector(31 downto 0);
			-- local subnet mask. used to distinguish local vs wan packets
		GATEWAY_IP_ADDR: in std_logic_vector(31 downto 0);
			-- Gateway IP address. Direct WAN packets to that gateway if non-local;

		--// WHOIS interface (send ARP request)
		WHOIS_IP_ADDR: out std_logic_vector(31 downto 0) := x"00000000";
			-- user query: IP address to resolve. read at WHOIS_START
		WHOIS_START: out std_logic := '0';
			-- 1 CLK pulse to start the ARP query
			-- Note: since we do not check for the WHOIS_RDY signal, there is a small probability that WHOIS is busy 
			-- and that the request will be ignored. Higher-level Application should ask again in this case.

		--// Source MAC/IP addresses 
		-- Packet origin, parsed in PACKET_PARSING (shared code) from
		-- ARP responses and IP packets. Ignored when the component is busy.
		RX_SOURCE_ADDR_RDY: in std_logic;
		RX_SOURCE_MAC_ADDR: in std_logic_vector(47 downto 0);	-- all received packets
		RX_SOURCE_IP_ADDR: in std_logic_vector(31 downto 0);  	-- IPv4,ARP

		-- Test Points
		SREG1 : OUT std_logic_vector(7 downto 0);
		SREG2 : OUT std_logic_vector(7 downto 0);
		SREG3 : OUT std_logic_vector(7 downto 0);
		SREG4 : OUT std_logic_vector(7 downto 0);
		SREG5 : OUT std_logic_vector(7 downto 0);
		SREG6 : OUT std_logic_vector(7 downto 0);
		TP: out std_logic_vector(10 downto 1)

			);
end entity;

architecture Behavioral of ARP_CACHE2 is
--------------------------------------------------------
--      COMPONENTS
--------------------------------------------------------
--------------------------------------------------------
--     SIGNALS
--------------------------------------------------------
constant REFRESH_PERIOD: std_logic_vector(19 downto 0) := x"00BB8";  -- time between entries refreshed (5 minutes)

--// TIME ------------------------------------------------
signal TIMER1: integer range 0 to 50 := 0;
signal TIME_CNTR: std_logic_vector(19 downto 0) := (others => '0');

--//-- NEW QUERY IP CHECK ---------------------------------------------------
signal IPv4_MASKED: std_logic_vector(31 downto 0) := (others => '0');
signal RT_IP_ADDR_MASKED: std_logic_vector(31 downto 0) := (others => '0');
signal RT_IP_ADDR_D: std_logic_vector(31 downto 0) := (others => '0');
signal NEXT_IP: std_logic_vector(31 downto 0) := (others => '0');

--//-- B-SIDE STATE MACHINE ---------------------------------------
signal STATE_B: integer range 0 to 8;  
signal STATE_B_D: integer range 0 to 8;  
signal LAST_IP: std_logic_vector(31 downto 0) := (others => '0');
signal LAST_MAC: std_logic_vector(47 downto 0) := (others => '0');
signal LAST_TIME: std_logic_vector(19 downto 0) := (others => '0');
signal RT_MAC_RDY_local: std_logic;
signal RT_NAK_local: std_logic;
signal RT_MAC_REPLY_local: std_logic_vector(47 downto 0) := (others => '0');
signal ADDRB: std_logic_vector(9 downto 0) := (others => '0');  -- table is 512 x 36 + 1 bit for overflow detection
signal ADDRB_INC: std_logic_vector(9 downto 0) := (others => '0'); 
signal ADDRB_D: std_logic_vector(9 downto 0) := (others => '0'); 
signal WHOIS_START_local: std_logic := '0'; 
signal WHOIS_IP_ADDR_local: std_logic_vector(31 downto 0) := (others => '0'); 

--//-- LUT RECORD ---------------------------------------------------
signal LUT_IP: std_logic_vector(31 downto 0) := (others => '0');
signal LUT_MAC: std_logic_vector(47 downto 0) := (others => '0');
signal LUT_TIME: std_logic_vector(19 downto 0) := (others => '0');
signal LUT_RECORD_RDY: std_logic := '0';

--//-- ROUTING TABLE ---------------------------------------------------
signal WEA: std_logic := '0';
signal WEB: std_logic := '0';
signal ENA: std_logic := '0';
signal ENB: std_logic := '0';
signal DIA: std_logic_vector(31 downto 0) := (others => '0');
signal DIPA: std_logic_vector(3 downto 0) := (others => '0');
signal DOA: std_logic_vector(31 downto 0) := (others => '0');
signal DOPA: std_logic_vector(3 downto 0) := (others => '0');
signal DOB: std_logic_vector(31 downto 0) := (others => '0');
signal DOPB: std_logic_vector(3 downto 0) := (others => '0');

--//-- KEY MATCH ---------------------------------------------------
signal IP_KEY1_MATCH: std_logic := '0';
signal IP_KEY1: std_logic_vector (31 downto 0) := (others => '0');
signal IP_KEY1_ADDR: std_logic_vector (8 downto 0) := (others => '0');
signal IP_KEY2_MATCH: std_logic := '0';
signal IP_KEY2: std_logic_vector (31 downto 0) := (others => '0');
signal IP_KEY2_ADDR: std_logic_vector (8 downto 0) := (others => '0');

--//-- NEW MAC/IP ADDRESSES ENTRY ---------------------------------------------------
signal RX_SOURCE_MAC_ADDR_D: std_logic_vector(47 downto 0) := (others => '0');	
signal RX_SOURCE_IP_ADDR_D: std_logic_vector(31 downto 0) := (others => '0');	
signal LAST_RX_MAC: std_logic_vector(47 downto 0) := (others => '0');	
signal LAST_RX_IP: std_logic_vector(31 downto 0) := (others => '0');	
signal LAST_RX_TIME: std_logic_vector(19 downto 0) := (others => '0');
signal RX_SOURCE_IP_ADDR_MASKED:std_logic_vector(31 downto 0) := (others => '0');	

--//-- A-SIDE STATE MACHINE ---------------------------------------
signal STATE_A: integer range 0 to 8 := 0;  
signal STATE_A_D: integer range 0 to 8 := 0;  
signal ADDRA: std_logic_vector(9 downto 0) := (others => '0');  -- table is 512 x 36 + 1 bit for overflow detection
signal ADDRA_D: std_logic_vector(9 downto 0) := (others => '0'); 
signal GATEWAY_MAC_ADDR: std_logic_vector(47 downto 0) := (others => '0');

--//-- FIND OLDEST ENTRY -----------------------------
signal TIME_A: std_logic_vector(19 downto 0) := (others => '0'); 
signal TIME_B: std_logic_vector(19 downto 0) := (others => '0'); 
signal OLDEST_TIME: std_logic_vector(19 downto 0) := (others => '0'); 
signal OLDEST_ADDR: std_logic_vector(8 downto 0) := (others => '0');  
signal VIRGIN: std_logic := '0';

--------------------------------------------------------
--      IMPLEMENTATION
--------------------------------------------------------
begin

--// TIME ------------------------------------------------
-- keep track of time, by increments of 100ms
-- range: 29 hours
TIME_GEN_001: process(CLK)
begin
	if rising_edge(CLK) then
		if (SYNC_RESET = '1') then
			TIME_CNTR <= (others => '0');
		elsif(TICK_100MS = '1') then
			TIME_CNTR <= TIME_CNTR + 1;
		end if;
	end if;
end process;

-- prevent flood of ARP requests being sent out
TIMER1_GEN_001: process(CLK)
begin
	if rising_edge(CLK) then
		if (SYNC_RESET = '1') then
			TIMER1 <= 0;
		elsif (WHOIS_START_local = '1') then 
			-- re-arm timer
			TIMER1 <= 10;
		elsif(TICK_100MS = '1') and (TIMER1 > 0) then
			TIMER1 <= TIMER1 - 1;
		end if;
	end if;
end process;


--//-- NEW QUERY IP CHECK ---------------------------------------------------
-- Is target IP local or remote? If remote, the Gateway is the next hop 
-- -> search for Gateway MAC address instead.
NEXT_IP_GEN: process(CLK)
begin
	if rising_edge(CLK) then
		IPv4_MASKED <= IPv4_ADDR and SUBNET_MASK;

		-- new request
		if(STATE_B = 0) and (RT_REQ_RTS = '1') then
			-- idle + new query. freeze input information during the query 
			-- just in case two requests are very close to eachother)
			RT_IP_ADDR_MASKED <= RT_IP_ADDR and SUBNET_MASK;
			RT_IP_ADDR_D <= RT_IP_ADDR;
		end if;
		
		-- one CLK later...
		if(STATE_B = 1) then
			-- NEXT_IP ready at STATE_B 2
			if(RT_IP_ADDR_MASKED /= IPv4_MASKED) and (RT_IP_ADDR_D /= x"FF_FF_FF_FF") then 
				-- remote (WAN) address. substitute Gateway IP
				-- Do not forward IP broadcast messages to the WAN (new 1/11/14 AZ)
				NEXT_IP <= GATEWAY_IP_ADDR;
			else
				-- local area network address
				NEXT_IP <= RT_IP_ADDR_D;
			end if;
		end if;
	end if;
end process;

-- accept new routing queries when idle 
RT_CTS <= '1' when (STATE_B = 0) else '0';

--//-- B-SIDE STATE MACHINE ---------------------------------------
-- B-side of the block RAM used for (a) block RAM intialization and (b) look-up table

ADDRB_INC <= ADDRB + 1;

STATE_MACHINE_B_GEN: process(CLK)
begin
	if rising_edge(CLK) then
		if(SYNC_RESET = '1') then
			STATE_B <= 8;  -- start with clearing the RAMB (could remember old entries?)
			LAST_IP <= (others => '0');
			LAST_MAC <= (others => '0');
			LAST_TIME <= (others => '0');
			RT_MAC_REPLY_local <= (others => '0');
			RT_MAC_RDY_local <= '0';
			RT_NAK_local <= '0';
			ADDRB <= (others => '0');
			WEB <= '1';
			WHOIS_START_local <= '0';
			WHOIS_IP_ADDR_local <= (others => '0');
		elsif(STATE_B = 8) then
			-- one-time RAMB initialization. Scan through all the block RAM addresses 0 - 511
			if(ADDRB_INC(9) = '1') then
				-- done.
				STATE_B <= 0;
				WEB <= '0';
			else
				ADDRB <= ADDRB + 1;
			end if;
		elsif(STATE_B = 0) then
			-- idle
			WHOIS_START_local <= '0';			-- clear
			RT_MAC_RDY_local <= '0';			-- clear
			RT_NAK_local <= '0';					-- clear
			if (RT_REQ_RTS = '1') then
				-- new query. (1 CLK duration)
				STATE_B <= 1;
			end if;
		elsif(STATE_B = 1) then
			-- determine NEXT_IP  (1 CLK duration)
			STATE_B <= 2;
		elsif(STATE_B = 2) then
			-- new query. 
			
			-- NO LOOKUP QUICK ANSWERS without spending time looking-up in the routing table
			if (NEXT_IP = x"FF_FF_FF_FF") then	-- new 1/11/14 AZ
				-- Broadcast IP 255.255.255.255
				RT_MAC_REPLY_local <= x"FF_FF_FF_FF_FF_FF";
				RT_MAC_RDY_local <= '1';
				STATE_B <= 0;	-- back to idle
			elsif (NEXT_IP = LAST_IP) and ((TIME_CNTR - LAST_TIME) < REFRESH_PERIOD) then
				-- (a) same as last and last information is recent. No need to go further. Same reply. 
				RT_MAC_REPLY_local <= LAST_MAC;
				RT_MAC_RDY_local <= '1';
				STATE_B <= 0;	-- back to idle
			elsif (NEXT_IP = GATEWAY_IP_ADDR) and (GATEWAY_MAC_ADDR /= 0)  then
				-- (b) Gateway IP
				RT_MAC_REPLY_local <= GATEWAY_MAC_ADDR;
				RT_MAC_RDY_local <= '1';
				STATE_B <= 0;	-- back to idle
			elsif (NEXT_IP = x"7F000001") or (NEXT_IP = IPv4_ADDR) then
				-- (c) local host 127.0.0.1. Local loopback
				RT_MAC_REPLY_local <= MAC_ADDR;
				RT_MAC_RDY_local <= '1';
				STATE_B <= 0;	-- back to idle
				
			-- SEARCH TO LOOKUP TABLE
			else
				STATE_B <= 3;  -- scan routing table from the bottom
				ADDRB <= (others => '0');
				RT_MAC_RDY_local <= '0';
			end if;

		elsif (STATE_B = 3) then 
			-- scan records 0 - 127 or until we find the target IP address

			-- is there a match with the query?
			if (NEXT_IP = DOB)  then
				-- yes!
				STATE_B <= 4;	-- read the rest of the selected record (1 record = 4 RAMB addresses)
				ADDRB <= ADDRB_D(9 downto 2) & "00";	-- rewind to the selected record

			elsif (ADDRB_D(9) = '1') and (STATE_B_D = 3) then
				-- no. reached end of range and yet no match
				-- send out an ARP request IF some conditions are met
				if(NEXT_IP /= WHOIS_IP_ADDR_local) or (TIMER1 = 0) then
					-- different address from last ARP request
					-- OR elapsed enough time since last similar ARP request
					WHOIS_IP_ADDR_local <= NEXT_IP;
					WHOIS_START_local <= '1';
				end if;
				-- and a NAK to the caller
				RT_NAK_local <= '1';
				STATE_B <= 0; -- back to idle
			
			elsif(ADDRB(9) = '0') then
				-- scan until we find the Target IP address
				ADDRB <= ADDRB + 4;  -- just look up the IP key to scan fast
				
			end if;
		elsif (STATE_B = 4) then 	
			-- found a record with matching IP key. Read the entire record
			-- read all 4 RAMB addresses for a complete record
			ADDRB <= ADDRB + 1;  

			if(LUT_RECORD_RDY = '1') then 
				RT_MAC_REPLY_local <= LUT_MAC;
				RT_MAC_RDY_local <= '1';
				-- remember last valid response just in case someone asks again (saves time)
				LAST_IP <= LUT_IP;
				LAST_MAC <= LUT_MAC;
				LAST_TIME <= LUT_TIME;
				STATE_B <= 0; -- back to idle
				if((TIME_CNTR - LUT_TIME) > REFRESH_PERIOD) and (TIMER1 = 0) then
					-- If the record is too old, send another ARP request to refresh the table
					WHOIS_IP_ADDR_local <= NEXT_IP;
					WHOIS_START_local <= '1';
				end if;
			end if;
		end if;
	end if;
end process;

RT_MAC_RDY <= RT_MAC_RDY_local;
RT_NAK <= RT_NAK_local;
RT_MAC_REPLY <= RT_MAC_REPLY_local;
WHOIS_START <= WHOIS_START_local;
WHOIS_IP_ADDR <= WHOIS_IP_ADDR_local;

--//-- ROUTING TABLE ---------------------------------------------------
-- Each entry comprises 4 * 36-bit locations
-- location0: 32-bit IP address + 4 bit MAC address(47:44)
-- location1: 32-bit MAC address (43:12) + 4-bit MAC address(11:8) 
-- location2: 7-bit MAC address (7:0) + 20-bit TIME (19:0) + spare
-- location3: spare
ENA <= '0' when (SYNC_RESET = '1') else '1';		-- to prevent warnings in modelsim
ENB <= '0' when (SYNC_RESET = '1') else '1';

RAMB16_001: RAMB16_S36_S36 port map(
	DIA => DIA,	
	DIB => x"00000000",
	DIPA => DIPA, 
	DIPB => "0000",	-- to initialize entries
	ENA => ENA,
	ENB => ENB,
	WEA => WEA,
	WEB => WEB,
	SSRA => '0',
	SSRB => '0',
	CLKA => CLK,
	CLKB => CLK,
	ADDRA => ADDRA(8 downto 0),
	ADDRB => ADDRB(8 downto 0), 
	DOA => DOA,
	DOB => DOB,
	DOPA => DOPA,
	DOPB => DOPB	
);

-- read look-up table record from B-side of the block RAM(4 addresses per record)
LUT_RECORDB_GEN_001: process(CLK)
begin
	if rising_edge(CLK) then
		ADDRB_D <= ADDRB;	-- 1 CLK delay to read data from the block RAM.
		ADDRA_D <= ADDRA; -- "
		STATE_B_D <= STATE_B;
		
		if(STATE_B_D = 4) then
			-- while reading...
			case ADDRB_D(1 downto 0) is
				when "00" => -- IP address  + MAC address part 1 
					LUT_IP <= DOB;
					LUT_MAC(47 downto 44) <= DOPB;
					LUT_RECORD_RDY <= '0';	-- wait until we read all 4 addresses
				when "01" => -- MAC address part 2
					LUT_MAC(43 downto 12) <= DOB;
					LUT_MAC(11 downto 8) <= DOPB;
					LUT_RECORD_RDY <= '0';
				when "10" => -- MAC address part 3 + timer
					LUT_MAC(7 downto 0) <= DOB(31 downto 24);
					LUT_TIME(19 downto 0) <= DOB(23 downto 4);
					-- + 8-bit spare
					LUT_RECORD_RDY <= '0';
				when others => -- future 36-bit spare
					-- 32 bits available here for add'l information
					LUT_RECORD_RDY <= '1';	-- full 4-address record ready to be processed
			end case;
		else
			LUT_RECORD_RDY <= '0';	
		end if;
	end if;
end process;

--//-- KEY MATCH ---------------------------------------------------
IP_KEY1 <= NEXT_IP;
IP_KEY2 <= RX_SOURCE_IP_ADDR_D;

-- Since both A and B sides of the block RAM are independently searching for IP address keys,
-- it will save time if we check both A and B outputs for match.
IP_KEY1_MATCH_DETECT_001: process(CLK) 
begin
	if rising_edge(CLK) then
		if(SYNC_RESET = '1') then
			IP_KEY1_MATCH <= '0';
			IP_KEY1_ADDR <= (others => '0');
		elsif(STATE_B_D = 4) and (DOB = IP_KEY1) and (ADDRB_D(1 downto 0)= "00") then
			-- found a match for IP_KEY1 at ADDRB_D while scanning B-side
			IP_KEY1_MATCH <= '1';
			IP_KEY1_ADDR <= ADDRB_D(8 downto 0);
		elsif(STATE_A_D = 2) and (DOA = IP_KEY1) and (ADDRA_D(1 downto 0)= "00") then
			-- found a match for IP_KEY1 at ADDRA_D while scanning A-side
			IP_KEY1_MATCH <= '1';
			IP_KEY1_ADDR <= ADDRA_D(8 downto 0);
		else
			IP_KEY1_MATCH <= '0';
		end if;
	end if;
end process;
		
IP_KEY2_MATCH_DETECT_001: process(CLK) 
begin
	if rising_edge(CLK) then
		if(SYNC_RESET = '1') then
			IP_KEY2_MATCH <= '0';
			IP_KEY2_ADDR <= (others => '0');
		elsif(STATE_B_D = 4) and (DOB = IP_KEY2) and (ADDRB_D(1 downto 0)= "00") then
			-- found a match for IP_KEY2 at ADDRB_D while scanning B-side
			IP_KEY2_MATCH <= '1';
			IP_KEY2_ADDR <= ADDRB_D(8 downto 0);
		elsif(STATE_A_D = 2) and (DOA = IP_KEY2) and (ADDRA_D(1 downto 0)= "00") then
			-- found a match for IP_KEY2 at ADDRA_D while scanning A-side
			IP_KEY2_MATCH <= '1';
			IP_KEY2_ADDR <= ADDRA_D(8 downto 0);
		else
			IP_KEY2_MATCH <= '0';
		end if;
	end if;
end process;

		

--//-- NEW MAC/IP ADDRESSES ---------------------------------------------------
-- Received another entry (decoded from received an IP or ARP response packet)
NEW_ENTRY_001: process(CLK)
begin
	if rising_edge(CLK) then
		-- new entry
		if(STATE_A = 0) and (RX_SOURCE_ADDR_RDY = '1') then
			-- idle + new entry. freeze input information during the processing 
			-- just in case two requests are very close to eachother.
			RX_SOURCE_MAC_ADDR_D <= RX_SOURCE_MAC_ADDR;
			RX_SOURCE_IP_ADDR_D <= RX_SOURCE_IP_ADDR;
			RX_SOURCE_IP_ADDR_MASKED <= RX_SOURCE_IP_ADDR and SUBNET_MASK;
		end if;
		
		-- special case/shortcut: detect Gateway MAC address immediately (saves time instead of searching)
		if(SYNC_RESET = '1') then
			GATEWAY_MAC_ADDR <= (others => '0');
		elsif(RX_SOURCE_ADDR_RDY = '1')  and (RX_SOURCE_IP_ADDR = GATEWAY_IP_ADDR) then
			GATEWAY_MAC_ADDR <= RX_SOURCE_MAC_ADDR;
		end if;
	end if;
end process;


--//-- A-SIDE STATE MACHINE ---------------------------------------
-- A-side of the block RAM used for (a) finding out the oldest entry and (b) save MAC/IP/timestamp
-- based on received packets (ARP response or IP)
-- Therefore, the address is incremented 2 by 2 when scanning (addresses ending on "00" for IP,
-- addresses ending on "10" for timestamp). 

STATE_MACHINE_A_GEN: process(CLK)
begin
	if rising_edge(CLK) then
		STATE_A_D <= STATE_A;
		
		if(SYNC_RESET = '1') then
			STATE_A <= 0;  
			WEA <= '0';
			DIPA <= (others => '0');
			DIA <= (others => '0');
			ADDRA <= (others => '0');
			LAST_RX_MAC <= (others => '0');
			LAST_RX_IP <= (others => '0');
			LAST_RX_TIME <= (others => '0');
		elsif(STATE_A = 0) then
			WEA <= '0';
			if(RX_SOURCE_ADDR_RDY = '1') then
				-- idle + new entry. 
				STATE_A <= 1;
			end if;
		elsif(STATE_A = 1) then
			-- SKIP LOOKUP CASES, don't waste time re-entering the information.
			if(RX_SOURCE_IP_ADDR_D = 0) then
				-- (a) meaningless zero IP address -> skip
				STATE_A <= 0;	-- go back to idle.
			elsif(RX_SOURCE_IP_ADDR_D = x"7F000001") then
				-- (b) meaningless localhost address -> skip
				STATE_A <= 0;	-- go back to idle.
			elsif(RX_SOURCE_IP_ADDR_D = IPv4_ADDR) then
				-- (c) meaningless self address -> skip
				STATE_A <= 0;	-- go back to idle.
			elsif(RX_SOURCE_IP_ADDR_MASKED /= IPv4_MASKED) then
				-- (d) WAN address. No need to store the MAC address because it has already
				-- been replaced by that of the gateway.
				STATE_A <= 0;	-- go back to idle.
			elsif(RX_SOURCE_IP_ADDR_D = GATEWAY_IP_ADDR) then
				-- (e) special case: gateway address is handled by a shortcut to minimize search time.
				STATE_A <= 0;	-- go back to idle.

			-- SEARCH ROUTING TABLE
			else
				-- search routing table by IP address key.
				STATE_A <= 2;
				ADDRA <= (others => '0');
			end if;
		elsif(STATE_A = 2) then
			-- scan address range 0 - 512 or until we find the target IP address
			if(ADDRA(9) = '0') then
				-- scan until we find the IP address key
				ADDRA <= ADDRA + 2;
			end if;
			
			if(IP_KEY2_MATCH = '1') then
				-- found a match
				ADDRA <= "0" & IP_KEY2_ADDR;
				STATE_A <= 3;  -- go write the MAC/IP/Timestamp to the routing table
			elsif(ADDRA_D(9) = '1') then
				-- reached the end of the scan without any key match
				-- find the oldest table entry and overwrite it with the newer MAC/IP/Timestamp.
				ADDRA <= "0" & OLDEST_ADDR;
				STATE_A <= 3;
			end if;
		elsif(STATE_A = 3) then
			-- (1/4) write IP address  + MAC address part 1 
			WEA <= '1';
			DIA <= RX_SOURCE_IP_ADDR_D;
			DIPA <= RX_SOURCE_MAC_ADDR_D(47 downto 44);
			STATE_A <= 4;
			-- remember so that we don't waste time doing successive repetitive write with the same parameters
			LAST_RX_MAC <= RX_SOURCE_MAC_ADDR_D;
			LAST_RX_IP <= RX_SOURCE_IP_ADDR_D;
			LAST_RX_TIME <= TIME_CNTR;
		elsif(STATE_A = 4) then
			-- (2/4) write MAC address part 2
			WEA <= '1';
			DIA <= RX_SOURCE_MAC_ADDR_D(43 downto 12);
			DIPA <= RX_SOURCE_MAC_ADDR_D(11 downto 8);
			ADDRA(1 downto 0) <= "01";
			STATE_A <= 5;
		elsif(STATE_A = 5) then
			-- (3/4) write MAC address part 3 + timer
			--WEA <= '1';
			DIA(31 downto 24) <= RX_SOURCE_MAC_ADDR_D(7 downto 0);
			DIA(23 downto 4) <= TIME_CNTR(19 downto 0);
			DIA(3 downto 0) <= (others => '0'); -- 8-bit spare
			DIPA <= (others => '0'); -- 4-bit spare
			ADDRA(1 downto 0) <= "10";
			STATE_A <= 6;	
		elsif(STATE_A = 6) then
			-- (4/4) spare
			--WEA <= '1';
			DIA <= (others => '0'); -- 32-bit spare
			DIPA <= (others => '0'); -- 4-bit spare
			ADDRA(1 downto 0) <= "11";
			STATE_A <= 0;	-- done. back to idle.
		end if;
	end if;
end process;

--//-- FIND OLDEST ENTRY -----------------------------
TIME_A <= DOA(23 downto 4);
TIME_B <= DOB(23 downto 4);

-- detect virgin record while scanning A side. Never been written to before. Therefore can be
-- used as 'oldest' record. 
VIRGIN_001: process(CLK) 
begin
	if rising_edge(CLK) then
		if (SYNC_RESET = '1') then
			VIRGIN <= '0';
		elsif(STATE_A_D = 2) and (ADDRA_D(1 downto 0)= "00") then
			if(DOA = x"00000000") then
				-- found virgin record
				VIRGIN <= '1';
			else
				VIRGIN <= '0';
			end if;
		end if;
	end if;
end process;


OLDEST_DETECT_001: process(CLK)
begin
	if rising_edge(CLK) then
		if (SYNC_RESET = '1') then
			OLDEST_TIME <= (others => '0');
			OLDEST_ADDR <= (others => '0');
		
		elsif (STATE_A = 2) and (IP_KEY2_MATCH = '0') and (ADDRA_D(9) = '1') then
			-- oldest entry is overwritten.... thus is no longer the oldest. Reset
			OLDEST_TIME <= TIME_CNTR;
			OLDEST_ADDR <= (others => '0');
--		elsif (STATE_B_D = 4) and (ADDRB_D(1 downto 0)= "10") and (OLDEST_TIME(19 downto 18) = "00") 
--				and (TIME_B(19 downto 18) = "11") then
--			-- found older entry (accounting for modulo time) while reading B-side
--			OLDEST_TIME <= TIME_B;
--			OLDEST_ADDR <= ADDRB_D(8 downto 2) & "00";
--		elsif (STATE_B_D = 4) and (ADDRB_D(1 downto 0)= "10") and (OLDEST_TIME > TIME_B) then
--			-- found older entry while reading B-side
--			OLDEST_TIME <= TIME_B;
--			OLDEST_ADDR <= ADDRB_D(8 downto 2) & "00";
		elsif (STATE_A_D = 2) and (ADDRA_D(1 downto 0)= "10") and (VIRGIN = '1') and (TIME_A = 0) 
		and (OLDEST_TIME /= 0) then
			-- virgin record. perfect for use as 'oldest entry'
			OLDEST_TIME <= TIME_A;
			OLDEST_ADDR <= ADDRA_D(8 downto 2) & "00";
		elsif (STATE_A_D = 2) and (ADDRA_D(1 downto 0)= "10") and (OLDEST_TIME(19 downto 18) = "00") 
				and (TIME_A(19 downto 18) = "11") then
			-- found older entry (accounting for modulo time) while reading A-side
			OLDEST_TIME <= TIME_A;
			OLDEST_ADDR <= ADDRA_D(8 downto 2) & "00";
		elsif (STATE_A_D = 2) and (ADDRA_D(1 downto 0)= "10") and (OLDEST_TIME > TIME_A) then
			-- found older entry while reading A-side
			OLDEST_TIME <= TIME_A;
			OLDEST_ADDR <= ADDRA_D(8 downto 2) & "00";
		end if;
	end if;
end process;

----// Test Point
TP(1) <= RT_REQ_RTS;
TP(2) <= '1' when (STATE_B = 0) else '0';  --RT_CTS 
TP(3) <= RT_MAC_RDY_local;
TP(4) <= RT_NAK_local;

TP(5) <= WHOIS_START_local;

TP(6) <= RX_SOURCE_ADDR_RDY;
TP(7) <= '1' when (STATE_A = 0) else '0';
TP(8) <= '1' when (STATE_A = 2) and (IP_KEY2_MATCH = '1') else '0';
TP(9) <= '1' when (STATE_A = 2) and (ADDRA_D(9) = '1') else '0';
TP(10) <= '1' when (STATE_A = 3) else '0';

--SREG1 <= OLDEST_ADDR(7 downto 0);
--SREG2 <= LAST_IP(31 downto 24);
--SREG3 <= LAST_IP(23 downto 16);
--SREG4 <= LAST_IP(15 downto 8);
--SREG5 <= LAST_IP(7 downto 0);
--SREG6 <= OLDEST_ADDR(7 downto 0);

end Behavioral;

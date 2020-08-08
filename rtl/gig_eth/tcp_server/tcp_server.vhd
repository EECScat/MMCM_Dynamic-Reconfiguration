-------------------------------------------------------------
-- MSS copyright 2004-2014
--	Filename:  TCP_SERVER.VHD
-- Author: Alain Zarembowitch / MSS
--	Version: 8
--	Date last modified: 2/14/14
-- Inheritance: 	COM-5003 TCP_PROT5.VHD 9/17/09
--
-- description:  TCP protocol for a server. Tx and Rx. 
-- Server awaits connection from a client. Once the connection is established, bi-directional
-- data transmission can take place. 
-- One instantiation per port. 
-- This component is mainly a state machine. It avoids storing any packet data to keep size to its minimum.
-- Consequently, the rx data recipient should be able to backtrack and throw out the received packet if
-- proven invalid at the end. 
-- Likewise, the tx data source should be able to rewind and re-transmit previous data if the TCP client 
-- requests is.
-- Since this is a server, we do not know a priori whether the protocol is IPv4 or IPv6 (it depends on the client).
-- So each server is given two IP addresses, one for each IP version.
--
-- Rev2 11/2/11 AZ
-- Added TCP_ISN pipelining for better timing.
-- 
-- Rev 3 11/4/11 AZ
-- restricts the retransmission scheme to the connected state. 
--
-- Rev 4 8/7/12 AZ
-- Added simulation initializations
--
-- Rev 5 10/9/13 AZ
-- Transition to SYNC_RESET.
-- Improve concurrent events handling in TX_PACKET_TYPE_QUEUED
--
-- Rev 6 1/28/14 AZ
-- Send multiple rx window resize messages, one for each stream, when window size is no longer zero.
-- Increased EFF_RX_WINDOW_SIZE_PARTIAL precision to 17 bits to detect abnormal negative window size reports
--
-- Rev7 1/31/14 AZ
-- Updated sensitivity lists.
--
-- Rev 8 2/13/14 AZ
-- Corrected double SYN ACK during connection setup
-- Added individual RX_FREE_SPACE for each stream
---------------------------------------------------------------
library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.STD_LOGIC_ARITH.ALL;
use IEEE.STD_LOGIC_UNSIGNED.ALL;
use work.com5402pkg.all;	-- defines global types, number of TCP streams, etc

entity TCP_SERVER is
	generic (
		MSS: std_logic_vector(15 downto 0) := x"05B4";
			-- The Maximum Segment Size (MSS) is the largest segment of TCP data that can be transmitted.
			-- Fixed as the Ethernet MTU (Maximum Transmission Unit) of 1500 bytes - 40 overhead bytes = 1460 bytes.
		IPv6_ENABLED: std_logic := '0';
			-- 0 to minimize size, 1 to allow IPv6 in addition to IPv4 (larger size)
		SIMULATION: std_logic := '0'
			-- 1 during simulation. for example to fix the tx_seq_no so that it matches the Wireshark 
			-- captures. 
	);
    Port ( 
		--// CLK, RESET
		CLK: in std_logic;	
			-- Must be a global clock. No BUFG instantiation within this component.
		SYNC_RESET: in std_logic;

		TICK_4US: in std_logic;
		TICK_100MS: in std_logic;
			-- 1 CLK-wide pulse every 4us and 10ms

		--// Configuration Fields
		MAC_ADDR: in std_logic_vector(47 downto 0);
			-- MAC address. Unique for each network interface card.
			-- Natural byte order: (MSB) 0x000102030405 (LSB) 
			-- as transmitted in the Ethernet packet.
		TCP_LOCAL_PORTS: in SLV16xNTCPSTREAMStype;
			-- TCP_SERVER port configuration. Each one of the NTCPSTREAMS streams handled by this
			-- component must be configured with a distinct port number. 
			-- This value is used as destination port number to filter incoming packets, 
			-- and as source port number in outgoing packets.

		--// User-initiated connection reset for stream I
		CONNECTION_RESET: in std_logic_vector((NTCPSTREAMS-1) downto 0);

		--// Received IP frame from MAC layer
		-- Excludes MAC and Ethernet layer headers. Includes IP header.
		-- Pre-processed by PACKET_PARSING to extract key Ethernet, IP and TCP information (see below)
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
		RX_IPv4_6n: in std_logic;
			-- IP version. 4 or 6
		RX_IP_PROTOCOL: in std_logic_vector(7 downto 0);
			-- The protocol information is valid as soon as the 8-bit IP protocol field in the IP header is read.
			-- Information stays until start of following packet.
			-- This component responds to protocol 6 = TCP 
	  	RX_IP_PROTOCOL_RDY: in std_logic;
			-- 1 CLK wide pulse. 
			
		--// Packet origin, already parsed in PACKET_PARSING (shared code)
		RX_SOURCE_MAC_ADDR: in std_logic_vector(47 downto 0);
		RX_SOURCE_IP_ADDR: in std_logic_vector(127 downto 0);
		RX_SOURCE_TCP_PORT_NO: in std_logic_vector(15 downto 0);

		--// TCP attributes, already parsed in PACKET_PARSING (shared code)
		-- BEWARE!!!!!!!! WE ALSO RECEIVE PACKETS NOT DESTINED FOR THIS SESSION (NOT FOR  THIS PORT)
		-- IT IS THE IMPLEMENTATION'S RESPONSIBILITY TO DISCARD DATA NOT DESTINED FOR THIS TCP PORT.
		RX_TCP_HEADER_FLAG: in std_logic;
			-- outlines the TCP header. Aligned with IP_RX_....
		RX_TCP_FLAGS: in std_logic_vector(7 downto 0);
			-- TCP flags (MSb) CWR/ECE/URG/ACK/PSH/RST/SYN/FIN (LSb)
		RX_TCP_CKSUM: in std_logic_vector(16 downto 0);
			-- TCP checksum (including pseudo-header).
			-- Correct checksum is either x10000 or x00001. Read 1 clk after IP_RX_EOF
		RX_TCP_SEQ_NO: in std_logic_vector(31 downto 0);
			-- sequence number decoded from the incoming TCP segment 
		RX_TCP_ACK_NO: in std_logic_vector(31 downto 0);
			-- acknowledgement number decoded from the incoming TCP segment
		RX_TCP_WINDOW_SIZE: in std_logic_vector(15 downto 0);
			-- window size decoded from the incoming TCP segment 
		RX_DEST_TCP_PORT_NO: in std_logic_vector(15 downto 0);
			-- destination TCP port (IDENTIFIES THE STREAM #)
			
		--// RX TCP PAYLOAD -> EXTERNAL RX BUFFER 
		-- Latency: 2 CLKs after the received IP frame.
		RX_DATA: out std_logic_vector(7 downto 0);
			-- TCP payload data field when RX_DATA_VALID = '1'
		RX_DATA_VALID: out std_logic;
			-- delineates the TCP payload data field
		RX_SOF: out std_logic;
			-- 1 CLK pulse indicating that RX_DATA is the first byte in the TCP data field.
		RX_STREAM_NO: out integer range 0 to (NTCPSTREAMS-1);
			-- output port based on the destination TCP port
		RX_EOF: out std_logic;
			-- 1 CLK pulse indicating that RX_DATA is the last byte in the TCP data field.
			-- ALWAYS CHECK RX_DATA_VALID at the end of packet (RX_EOF = '1') to confirm
			-- that the TCP packet is valid. External buffer may have to backtrack to the the last
			-- valid pointer to discard an invalid TCP packet.
			-- Reason: we only knows about bad TCP packets at the end.
		RX_FREE_SPACE: in SLV16xNTCPSTREAMStype;
			-- External buffer available space, expressed in bytes. 
			-- Information is updated upon receiving the EOF of a valid rx frame.
			-- The real-time available space is always larger

		--// OUTPUTS to TX PACKET ASSEMBLY (via TCP_TX.vhd component)
		TX_PACKET_SEQUENCE_START_OUT: out std_logic;	
			-- 1 CLK pulse to trigger packet transmission. The decision to transmit is taken by TCP_SERVER.
			-- From this trigger pulse to the end of frame, this component assembles and send data bytes
			-- like clockwork. 
			-- Note that the payload data has to be ready at exactly the right time to be appended.
			
		-- These variables are read only at the start of packet, when TX_PACKET_SEQUENCE_START_OUT = '1'
		-- They can change from packet to packet (internal code is memoryless).
		TX_DEST_MAC_ADDR_OUT: out std_logic_vector(47 downto 0);
		TX_DEST_IP_ADDR_OUT: out std_logic_vector(127 downto 0);
		TX_DEST_PORT_NO_OUT: out std_logic_vector(15 downto 0);
		TX_SOURCE_PORT_NO_OUT: out std_logic_vector(15 downto 0);
		TX_IPv4_6n_OUT: out std_logic;
		TX_SEQ_NO_OUT: out std_logic_vector(31 downto 0);
		TX_ACK_NO_OUT: out std_logic_vector(31 downto 0);
		TX_ACK_WINDOW_LENGTH_OUT: out std_logic_vector(15 downto 0);
		TX_FLAGS_OUT: out std_logic_vector(7 downto 0);
		TX_PACKET_TYPE_OUT : out std_logic_vector(1 downto 0); 


			

--		--// TX TCP layer -> Transmit MAC Interface
		MAC_TX_EOF: in std_logic;	-- need to know when packet tx is complete
		RTS: out std_logic := '0';
			-- '1' when a frame is ready to be sent (tell the COM5402 arbiter)
			-- When the MAC starts reading the output buffer, it is expected that it will be
			-- read until empty.

		--// EXTERNAL TX BUFFER <-> TX TCP layer
		-- upon receiving an ACK from the client, send rx window information to TXBUF for computing 
		-- the next packet size, boundaries, etc.
		-- Partial computation (rx window size + RX_TCP_ACK_NO).
		EFF_RX_WINDOW_SIZE_PARTIAL: out std_logic_vector(16 downto 0) := (others => '0');
		EFF_RX_WINDOW_SIZE_PARTIAL_STREAM: out integer range 0 to (NTCPSTREAMS-1);
		EFF_RX_WINDOW_SIZE_PARTIAL_VALID: out std_logic; -- 1 CLK-wide pulse to indicate that the above information is valid
		-- Let the TXBUF know where the next byte to be transmitted is located
		-- computing the next frame size, boundaries, etc
		TX_SEQ_NO: out SLV17xNTCPSTREAMStype;
		RX_TCP_ACK_NO_D: out SLV17xNTCPSTREAMStype;
			-- last acknowledged tx byte location


		CONNECTED_FLAG: out std_logic_vector((NTCPSTREAMS-1) downto 0);
			-- '1' when TCP-IP connection is in the 'connected' state, 0 otherwise
			-- Main use: TXBUF should not store tx data until a connection is established

		TX_STREAM_SEL: in integer range 0 to (NTCPSTREAMS-1) := 0;	
			-- valid only when TX_PAYLOAD_RTS = '1', ignore otherwise
		TX_PAYLOAD_RTS: in std_logic;
			-- '1' when at least one stream has payload data available for transmission.
		TX_PAYLOAD_SIZE: in std_logic_vector(10 downto 0);
		
	
		
		
		-- Test Points
		TP: out std_logic_vector(10 downto 1)

			);
end entity;

architecture Behavioral of TCP_SERVER is
--------------------------------------------------------
--      COMPONENTS
--------------------------------------------------------
--------------------------------------------------------
--     SIGNALS
--------------------------------------------------------
-- Suffix _D indicates a one CLK delayed version of the net with the same name
-- Suffix _E indicates a one CLK early version of the net with the same name
-- Suffix _X indicates an extended precision version of the net with the same name
-- Suffix _N indicates an inverted version of the net with the same name

--//===== NON-VOLATILE PORT-SPECIFIC DATA ==================
-- (to be saved after a packet ends) 
-- state machine
type STATEtype is array (integer range 0 to (NTCPSTREAMS-1)) of integer range 0 to 15;
signal TCP_STATE: STATEtype := (others => 0);
signal TIMER1: SLV8xNTCPSTREAMStype := (others => (others => '0'));	-- timer range 0 - 25.5s
-- relevant transmit destination information
type MAC_ADDRtype is array (integer range 0 to (NTCPSTREAMS-1)) of std_logic_vector(47 downto 0);
type IP_ADDRtype is array (integer range 0 to (NTCPSTREAMS-1)) of std_logic_vector(127 downto 0);
signal TX_DEST_MAC_ADDR: MAC_ADDRtype := (others => (others => '0'));
signal TX_DEST_IP_ADDR: IP_ADDRtype := (others => (others => '0'));
signal TX_DEST_PORT_NO: SLV16xNTCPSTREAMStype := (others => (others => '0'));
-- tx sequence numbers
signal TX_ACK_NO: SLV32xNTCPSTREAMStype := (others => (others => '0'));
signal TX_SEQ_NO_local: SLV32xNTCPSTREAMStype := (others => (others => '0'));
-- received sequence number
signal RX_TCP_ACK_NO_D_local: SLV32xNTCPSTREAMStype := (others => (others => '0'));
signal RX_TCP_SEQ_NO_MAX: SLV32xNTCPSTREAMStype := (others => (others => '0'));
signal TX_IPv4_6n: std_logic_vector((NTCPSTREAMS-1) downto 0);
signal TX_PACKET_TYPE_QUEUED: SLV2xNTCPSTREAMStype := (others => (others => '0'));
signal TX_PACKET_TYPE: std_logic_vector(1 downto 0) := "00";
signal TX_FLAGS: SLV8xNTCPSTREAMStype := (others => (others => '0'));


--//==== VARIABLES WITH A 1 PACKET LIFESPAN ==================
--// RX TCP 16-BIT WORD 
signal IP_RX_DATA_PREVIOUS: std_logic_vector(7 downto 0) := (others => '0');
signal IP_RX_DATA16: std_logic_vector(15 downto 0) := (others => '0');

--// CHECK RX TCP VALIDITY 
signal RX_TCP_STREAM_NO: integer range 0 to (NTCPSTREAMS-1) := 0;
signal RX_TCP_STREAM_NO_D: integer range 0 to (NTCPSTREAMS-1) := 0;
signal RX_TCP_STREAM_NO_RDY: std_logic := '0';
signal RX_TCP_STREAM_NO_VALID: std_logic := '0';
signal RX_TCP_STREAM_NO_VALID_D: std_logic := '0';
signal VALID_RX_TCP: std_logic := '0';
signal VALID_RX_TCP_CKSUM: std_logic := '0';
signal VALID_RX_TCP_ALL: std_logic := '0';
signal VALID_RX_TCP2: std_logic := '0';	-- aligned with RX_EOF_E

--// COPY RX TCP DATA TO BUFFER 
signal RX_DATA_E: std_logic_vector(7 downto 0) := (others => '0');
signal RX_DATA_VALID_E: std_logic := '0';
signal RX_DATA_VALID_local: std_logic := '0';
signal RX_SOF_E: std_logic := '0';
signal RX_EOF_E: std_logic := '0';
signal RX_EOF_local: std_logic := '0';
signal RX_WPTR_E: std_logic_vector(31 downto 0) := (others => '0');
signal RX_WPTR_E_INC: std_logic_vector(31 downto 0) := (others => '0');
signal RX_TCP_HEADER_FLAG_D: std_logic := '0';
signal RX_TCP_NON_ZERO_DATA_LENGTH: std_logic := '0';

--// RX SEQUENCE NUMBER 
signal RX_TCP_SEQ_NO_INC: std_logic_vector(31 downto 0) := (others => '0');
signal RX_OUTOFBOUND: std_logic := '0';
signal RX_ZERO_WINDOW_PROBE: std_logic := '0';
signal GAP_IN_RX_SEQ: std_logic := '0';
signal RETRANSMIT_FLAG: SLxNTCPSTREAMStype;
signal RX_VALID_ACK_TIMOUT: SLV24xNTCPSTREAMStype;

--// state machine
signal TCP_STATE_localrx: integer range 0 to 15 := 0;
signal EVENTS2: std_logic_vector((NTCPSTREAMS-1) downto 0):= (others => '0');
signal EVENTS5: std_logic_vector((NTCPSTREAMS-1) downto 0):= (others => '0');
signal EVENTS6: std_logic_vector((NTCPSTREAMS-1) downto 0):= (others => '0');
signal EVENTS7: std_logic_vector((NTCPSTREAMS-1) downto 0):= (others => '0');
signal EVENTS8: std_logic_vector((NTCPSTREAMS-1) downto 0):= (others => '0');
signal EVENTS10: std_logic_vector((NTCPSTREAMS-1) downto 0):= (others => '0');
signal EVENT1: std_logic:= '0';
signal EVENT2: std_logic:= '0';
signal EVENT4: std_logic:= '0';
signal EVENT4A: std_logic:= '0';
signal EVENT4B: std_logic:= '0';
signal EVENT5: std_logic:= '0';
signal EVENT6: std_logic:= '0';
signal EVENT8: std_logic:= '0';

----// ACK generation
signal SEND_ACK_NOW: std_logic:= '0';
signal SEND_ACK_NOW_D: std_logic_vector(7 downto 0) := (others => '0');
signal DUPLICATE_RX_TCP_ACK_CNTR: SLV2xNTCPSTREAMStype := (others => (others => '0'));

--// relevant transmit destination information
signal ORIGINATOR_IDENTIFIED: std_logic := '0';
signal RX_BUF_FULL: std_logic_vector((NTCPSTREAMS-1) downto 0):= (others => '0');
signal TX_ACK_WINDOW_LENGTH: std_logic_vector(15 downto 0) := (others => '0');
signal RX_WINDOW_RESIZE_STATE: SLV2xNTCPSTREAMStype := (others => (others => '0'));
signal SEND_RX_WINDOW_RESIZE: std_logic_vector((NTCPSTREAMS-1) downto 0):= (others => '0');

--// Measure round-trip delay: client -> server -> client
signal TXRX_DELAY_CNTR: SLV24xNTCPSTREAMStype := (others => (others => '0'));
signal TXRX_DELAY: SLV24xNTCPSTREAMStype := (others => (others => '0'));
signal TXRX_DELAY_STATE: std_logic_vector((NTCPSTREAMS-1) downto 0);


--// transmit packet assembly
signal TCP_ISN: std_logic_vector(31 downto 0) := x"010ae614";
signal TCP_ISN_D: std_logic_vector(31 downto 0) := x"010ae614";
constant TX_TCP_RTS: std_logic := '0';  -- temp

--//---- TX PACKET ASSEMBLY   
signal TCP_CONGESTION_WINDOW: SLV16xNTCPSTREAMStype;
signal TCP_TX_SLOW_START: std_logic_vector((NTCPSTREAMS-1) downto 0) := (others => '0');
signal NEXT_TX_TCP_FRAME_QUEUED: std_logic := '0';
signal NEXT_TX_TCP_STREAM_NO: integer range 0 to (NTCPSTREAMS-1) := 0;
signal TX_TCP_STREAM_NO: integer range 0 to (NTCPSTREAMS-1) := 0;
signal RTS_local: std_logic := '0';
signal TX_PACKET_SEQUENCE_START: std_logic := '0';

--------------------------------------------------------
--      IMPLEMENTATION
--------------------------------------------------------
begin

-------------------------------------------------
---- TCP stream identification ------------------
-------------------------------------------------
-- Identify the stream based on the destination tcp port for each 
-- incoming frame.
STREAM_INDEX_001: process(RX_DEST_TCP_PORT_NO, TCP_LOCAL_PORTS)
variable STREAM_NO: integer range 0 to (NTCPSTREAMS-1) := 0;
variable STREAM_NO_VALID: std_logic := '0';
begin
	STREAM_NO := 0;
	STREAM_NO_VALID := '0';
	for I in 0 to (NTCPSTREAMS-1) loop
		if(RX_DEST_TCP_PORT_NO  = TCP_LOCAL_PORTS(I)) then
			STREAM_NO := I;
			STREAM_NO_VALID := '1'; 
		end if;
	end loop;
	RX_TCP_STREAM_NO <= STREAM_NO;
	RX_TCP_STREAM_NO_VALID <= STREAM_NO_VALID;
end process;
-- earliest time when we know for sure the stream #
-- As the number of concurrent streams increases, it takes more time to match stream# and RX_DEST_TCP_PORT_NO
-- Adjust delay from IP_BYTE_COUNT = 4 (earliest) to IP_BYTE_COUNT = 18 (one before the end of TCP header).
RX_TCP_STREAM_NO_RDY <= '1' when (RX_TCP_HEADER_FLAG = '1') and (IP_BYTE_COUNT(4 downto 0) = 7) else '0';

-- reclock for better timing
STREAM_INDEX_002: process(CLK)
begin
	if rising_edge(CLK) then
		if(RX_TCP_STREAM_NO_RDY = '1') then  -- latch 
			RX_TCP_STREAM_NO_D <= RX_TCP_STREAM_NO;
			RX_TCP_STREAM_NO_VALID_D <= RX_TCP_STREAM_NO_VALID;
		end if;
	end if;
end process;
--
-------------------------------------------------
---- Collect response information ---------------
-------------------------------------------------
-- save destination IP, destination port and other relevant information
-- upon receiving SYN. The information will be kept until the connection is closed.
INFO_X: for I in 0 to (NTCPSTREAMS-1) generate
	INFO_001: process(CLK)
	begin
		if rising_edge(CLK) then
			if(I = RX_TCP_STREAM_NO_D) and (RX_TCP_STREAM_NO_VALID_D = '1') and (TCP_STATE(I) = 0) and (EVENT1 = '1') then
				-- Received valid SYN while in LISTEN state
				-- Save the destination addresses during the connection
				TX_DEST_MAC_ADDR(I) <= RX_SOURCE_MAC_ADDR;	
				TX_DEST_IP_ADDR(I) <= RX_SOURCE_IP_ADDR;	
				TX_DEST_PORT_NO(I) <= RX_SOURCE_TCP_PORT_NO;	
				TX_IPv4_6n(I) <= RX_IPv4_6n;
			end if;
		end if;
	end process;
end generate;

-- After the initial SYN message where the originator identification characteristics
-- are collected (MAC/IP/PORT), the origination of subsequent messages addressed 
-- to this IP/Port is verified. (we don't want a third party to crash our connection
-- by sending RST or other disrupting messages.
-- Information is valid at the end of the TCP header until the next received packet.
ORIGIN_001: process(CLK) 
begin
	if rising_edge(CLK) then
		if(RX_TCP_HEADER_FLAG = '1') and (RX_TCP_STREAM_NO_VALID_D = '1') then
			if(TX_DEST_MAC_ADDR(RX_TCP_STREAM_NO_D) = RX_SOURCE_MAC_ADDR) and 
				(TX_DEST_IP_ADDR(RX_TCP_STREAM_NO_D) = RX_SOURCE_IP_ADDR) and 
				(TX_DEST_PORT_NO(RX_TCP_STREAM_NO_D) = RX_SOURCE_TCP_PORT_NO)  then
				ORIGINATOR_IDENTIFIED <= '1';
			else
				ORIGINATOR_IDENTIFIED <= '0';
			end if;
		end if;
	end if;
end process;
	

-------------------------------------------------
---- State Machine / Events ---------------------
-------------------------------------------------
-- received packet is for this port and from the correct originator.
VALID_RX_TCP2 <= '1' when (RX_EOF_E = '1') and (VALID_RX_TCP_ALL = '1') and (ORIGINATOR_IDENTIFIED = '1') else '0';

TCP_STATE_X: for I in 0 to (NTCPSTREAMS-1) generate

	-- EVENTS2(I)
	-- End of TCP segment transmission (EVENTS8 is commitment to transmit, EVENTS2 is end of transmission)
	EVENTS2(I) <= '1' when (I = TX_TCP_STREAM_NO) and (MAC_TX_EOF = '1') else '0';


	-- EVENTS5(I)
	-- Received valid FIN flag from expected server. Wait until the end of frame to confirm validity.
	EVENTS5(I) <= '1' when (I = RX_TCP_STREAM_NO_D) and (RX_TCP_STREAM_NO_VALID_D = '1') and 
							(VALID_RX_TCP2 = '1') and (RX_TCP_FLAGS(0) = '1') 
							else '0';

	-- EVENTS6(I)
	-- Received valid ACK flag from expected server. Wait until the end of frame to confirm validity.
	EVENTS6(I) <= '1' when (I = RX_TCP_STREAM_NO_D) and (RX_TCP_STREAM_NO_VALID_D = '1') and 
							(VALID_RX_TCP2 = '1') and (RX_TCP_FLAGS(4) = '1') 
							else '0';

	-- EVENTS7(I)
	-- Received valid RST flag from the connection server
	EVENTS7(I) <= '1' when (I = RX_TCP_STREAM_NO_D) and (RX_TCP_STREAM_NO_VALID_D = '1') and 
							(VALID_RX_TCP2 = '1') and (RX_TCP_FLAGS(2) = '1') 
							else '0';
							
	-- EVENTS8(I)
	-- Non-payload frame queued. Delay 1 CLK
	EVENTS8_RECLOCK: process(CLK)
	begin
		if rising_edge(CLK) then
			if(SYNC_RESET = '1') then
				EVENTS8(I) <= '0';
			elsif(I = NEXT_TX_TCP_STREAM_NO) and (RTS_local = '0') and (NEXT_TX_TCP_FRAME_QUEUED = '1') then
				EVENTS8(I) <= '1';
			else
				EVENTS8(I) <= '0';
			end if;
		end if;
	end process;

	-- EVENTS10(I)
	-- Window resizing (receive flow control), no segment to transmit. The receive buffer is no 
	-- longer empty. Send a single ACK with a non-zero window.
	EVENTS10(I) <= '1' when ((SEND_RX_WINDOW_RESIZE(I) = '1') and (TX_TCP_RTS = '0')) else '0';
	
	TCP_STATE_001: process(CLK)
	begin
		if rising_edge(CLK) then
			if(SYNC_RESET = '1') then
				-- reset all connections (abrupt, may cause server side to remain connected, thus preventing any further connection on that port)
				TCP_STATE(I) <= 0;
			elsif(TCP_STATE(I) = 3) and (CONNECTION_RESET(I) = '1') then
				-- user-initiated selective connection request while connected
				TCP_STATE(I) <= 6;	-- send FIN
			elsif (TCP_STATE(I) = 2) and (TIMER1(I) = 0) then
				-- abnormal timeout event. Did not receive ACK from client. Terminate connection
				TCP_STATE(I) <= 0; -- self-reset. go back to idle

			-- rx-related events
			elsif(EVENTS7(I) = '1') then
				-- Reset / Abort (true in any state, as long as we verify the originator)
				-- received RST
				TCP_STATE(I) <= 0;
			elsif(RX_TCP_STREAM_NO_D = I) and (RX_TCP_STREAM_NO_VALID_D = '1') and (TCP_STATE(I) = 0)  and (EVENT1 = '1') then
				-- LISTEN
				-- Received valid SYN
				TCP_STATE(I) <= 1;	-- SYN_RCVD. Transmitting SYN,ACK in progress
			elsif(RX_TCP_STREAM_NO_D = I) and (RX_TCP_STREAM_NO_VALID_D = '1') and (TCP_STATE(I) = 2) and (EVENT4 = '1') then
				-- CONNECTION ESTABLISHMENT: Await ACK from client
				-- received valid ACK and ACK number
				TCP_STATE(I) <= 3;	-- CONNECTED state
			elsif (TCP_STATE(I) = 3) and (EVENTS5(I) = '1') then
				-- client-initiated connection termination . Send ACK
				TCP_STATE(I) <= 4;	-- sending ACK
			elsif (TCP_STATE(I) = 7) and (EVENTS5(I) = '1') then
				-- received FIN after FIN. Send final ACK.
				TCP_STATE(I) <= 8;	
			elsif (TCP_STATE(I) = 5) and (EVENTS6(I) = '1') then
				-- received final ACK after FIN/ACK+FIN. Connection is properly closed.
				TCP_STATE(I) <= 0;	
			

			-- tx-related events (end of transmission)
			elsif (TCP_STATE(I) = 6) and (EVENTS8(I) = '1') then
				-- sent FIN. Awaiting ACK + FIN
				TCP_STATE(I) <= 7;	
			elsif (TCP_STATE(I) = 8) and (EVENTS2(I) = '1') then
				-- Sent final ACK. Connection is properly closed
				TCP_STATE(I) <= 0;
			elsif (TCP_STATE(I) = 4) and (EVENTS8(I) = '1') then
				-- sent ACK after receiving FIN. send final FIN. Await final ack.
				TCP_STATE(I) <= 5;	
			elsif(TX_TCP_STREAM_NO = I) and (TCP_STATE(I) = 1) and (EVENT2 = '1') then
				-- CONNECTION ESTABLISHMENT: Await SYN/ACK transmission completion
				-- completed SYN/ACK transmission
				TCP_STATE(I) <= 2;	-- await ack during connection establishment
--			elsif(TX_TCP_STREAM_NO = I) and (TCP_STATE(I) = 4) and (EVENT2 = '1') then
--				-- CONNECTION TERMINATION: await end of ACK transmission
--				-- completed ACK transmission
--				TCP_STATE(I) <= 5;	-- await end of FIN/ACK transmission
--			elsif(TX_TCP_STREAM_NO = I) and (TCP_STATE(I) = 5) and (EVENT2 = '1') then
--				-- CONNECTION TERMINATION: await end of FIN/ACK transmission
--				-- completed FIN/ACK transmission
--				-- don't wait for an ACK from client (race condition: next connection SYN could arrive first)
--				TCP_STATE(I) <= 0;	-- LISTEN STATE
				
				
			-- timeouts
			elsif ((TCP_STATE(I) = 6) or (TCP_STATE(I) = 7) or (TCP_STATE(I) = 8)) and (TIMER1(I)= 0) then
				-- timeout waiting for normal server-originated connection termination. Abnormal connection termination.
				TCP_STATE(I) <= 0;
			elsif ((TCP_STATE(I) = 4) or (TCP_STATE(I) = 5)) and (TIMER1(I)= 0) then
				-- timeout waiting for normal client-originated connection termination. Abnormal connection termination.
				TCP_STATE(I) <= 0;
				
			
			end if;
		end if;
	end process;
end generate;

TCP_STATE_localrx <= TCP_STATE(RX_TCP_STREAM_NO_D) when (RX_TCP_STREAM_NO_VALID_D = '1') else 0;	
	-- contextual TCP_STATE while receiving a frame
	
-- state machine timer (so that we do not get stuck into a state)
TIMER1_GEN_X: for I in 0 to (NTCPSTREAMS-1) generate
	TIMER1_GEN_001: process(CLK)
	begin
		if rising_edge(CLK) then
			if(SYNC_RESET = '1') then
				-- reset all connections (abrupt, may cause server side to remain connected, thus preventing any further connection on that port)
				-- idle state, clear timer to 'expired' (0)
				TIMER1(I) <= (others => '0');
			elsif(TCP_STATE(I) = 3) and (CONNECTION_RESET(I) = '1') then
				-- user-initiated selective connection request while connected
				TIMER1(I) <= conv_std_logic_vector(20, TIMER1(I)'length);
			elsif (TCP_STATE(I) = 3) and (EVENTS5(I) = '1') then
				-- client-initiated connection termination . 
				TIMER1(I) <= conv_std_logic_vector(20, TIMER1(I)'length);
			elsif(TCP_STATE(I) = 0) then
				-- idle state, clear timer to 'expired' (0)
				TIMER1(I) <= (others => '0');
			elsif (TX_TCP_STREAM_NO = I) and (TCP_STATE(I) = 1) and (EVENT2 = '1') then
				-- entering state 2
				TIMER1(I) <= conv_std_logic_vector(50, TIMER1(I)'length);
			elsif(TICK_100MS = '1') and (TIMER1(I) /= 0) then
				-- decrement until timer has expired (0)
				TIMER1(I) <= TIMER1(I) - 1;
			end if;
		end if;
	end process;
end generate;

---------------------------------------------------
------ State Machine EVENTS -----------------------
---------------------------------------------------
-- Event 1: receive valid SYN flag (from anyone). Wait until the end of frame to confirm validity.
EVENT1 <= '1' when (RX_EOF_E = '1') and (VALID_RX_TCP_ALL = '1') and (RX_TCP_FLAGS(1) = '1') else '0';

-- Event 2: completed transmission of TCP segment.
EVENT2 <= MAC_TX_EOF;  

-- Event 4: received valid ACK flag and ACK number from the connection client
EVENT4 <= '1' when ((VALID_RX_TCP2 = '1') and (RX_TCP_FLAGS(4) = '1')) else '0';
-- Event 4A: received valid non-duplicate ACK (a subset of EVENT4)
EVENT4A <= EVENT4 when (RX_TCP_ACK_NO_D_local(RX_TCP_STREAM_NO_D)(15 downto 0) /= RX_TCP_ACK_NO(15 downto 0)) else '0';
-- Event 4B: received valid duplicate ACK (a subset of EVENT4)
EVENT4B <= EVENT4 when (RX_TCP_ACK_NO_D_local(RX_TCP_STREAM_NO_D)(15 downto 0) = RX_TCP_ACK_NO(15 downto 0)) else '0';


-- Event 6
-- received valid segment, no segment to transmit. generate ACK only.
-- Note: slightly delayed to wait for the latest FREE_SPACE information from TCP_RXBUFNDEMUX  1/26/14
EVENT6 <= '1' when ((SEND_ACK_NOW_D(7) = '1') and (TX_TCP_RTS = '0')) else '0'; 

-- Event 8
-- data is ready to be transmitted over TCP. Send data.  A distinct tx state machine is located 
-- in TCP_TXBUF together with the transmit buffers. 
-- Block sending until we receive a valid ACK from the previous transmission
-- A frame is ready for transmission when 
-- (a) the effective client rx window size is non-zero
-- (b) the tx buffer contains either the effective client rx window size or 1023 bytes or no new data received in the last 200us
-- (c) TCP is not busy transmitting/assembling another packet
-- implied condition: TCP is in connected state (3) otherwise TX_PAYLOAD_RTS = '0'
EVENT8 <= '1' when ((TX_PAYLOAD_RTS = '1') and (RTS_local = '0')) else '0';

-------------------------------------------------
---- Receive data -------------------------------
-------------------------------------------------

--// RX TCP 16-BIT WORD -----------------------------
-- reconstruct 16-bit words
TCP_PREVIOUS_BYTE_001: process(CLK)
begin
	if rising_edge(CLK) then
		if(IP_RX_DATA_VALID = '1') and (IP_HEADER_FLAG = '0') then
			-- TCP frame
			IP_RX_DATA_PREVIOUS <= IP_RX_DATA;	-- remember previous byte (useful when reading 16-bit fields)
		end if;
	end if;
end process;
IP_RX_DATA16 <= IP_RX_DATA_PREVIOUS & IP_RX_DATA;	-- reconstruct 16-bit field. 

--// CHECK RX TCP VALIDITY -----------------------------
-- The TCP packet reception is immediately cancelled if 
-- (a) the received packet type is not an IP datagram  (done in common code PACKET_PARSING)
-- (b) invalid destination IP  (done in common code PACKET_PARSING)
-- (c) incorrect IP header checksum (done in common code PACKET_PARSING)
-- (d) the received IP type is not TCP 
-- (e) destination port number is not the specified TCP_LOCAL_PORTS
-- (f) TCP checksum is incorrect
-- (g) TCP connection is established and origin MAC/IP/Port is invalid
-- Aligned with IP_RX_DATA_VALID_D
VALIDITY_CHECK_001: process(CLK)
begin
	if rising_edge(CLK) then
		if(SYNC_RESET = '1') then
			VALID_RX_TCP <= '1';
		elsif(IP_RX_SOF = '1') then
			-- just received first word. Valid TCP datagram until proven otherwise
			VALID_RX_TCP <= '1';
		elsif(RX_IP_PROTOCOL_RDY = '1') and (RX_IP_PROTOCOL /= 6) then
			-- (d) the received IP type is not TCP 
			VALID_RX_TCP <= '0';
		elsif(IP_RX_EOF = '1') then
			-- most checks performed at the end of frame
			if(IP_RX_DATA_VALID = '0') then
				-- (a)(b)(c) invalid IP frame reported at the end of the IP frame.
				VALID_RX_TCP <= '0';
			elsif (RX_TCP_STREAM_NO_VALID = '0') then
				-- (e) destination port number does not match any of the specified TCP_LOCAL_PORTS
				VALID_RX_TCP <= '0';
			elsif (TCP_STATE_localrx = 3) and (ORIGINATOR_IDENTIFIED = '0')then
				-- (g) TCP connection is established and origin MAC/IP/Port is inconsistent (spoof detection)
				VALID_RX_TCP <= '0';
			end if;
	 	end if;
	end if;
end process;

-- late arrival (one CLK after IP_RX_EOF)
VALID_RX_TCP_CKSUM <= '1' when ((RX_TCP_CKSUM = "1" & x"0000") or (RX_TCP_CKSUM = "0" & x"0001") ) else '0';
		--(f) TCP checksum is incorrect
		-- NOTE: this check is performed while reading the last TCP byte. The outcome is available
		-- one clock AFTER the TCP_EOF

-- overall TCP validity (All above criteria. Can also be used in the case of zero-length TCP data fields)
-- read at RX_EOF_E
-- Note: additional checks must be performed to forward data to the output data sink (TCP state = connected, 
-- enough space in data sink to accept the data).
VALID_RX_TCP_ALL <= VALID_RX_TCP_CKSUM and VALID_RX_TCP;

			

--// COPY TCP DATA TO OUTPUT BUFFER ------------------------

-- Prepare output. Strip IP and TCP headers.
-- Aligned with IP_RX_DATA_VALID_D
-- Keep track of whether the received packet has zero data length or not. (Needed to 
-- determine whether an ACK should be sent)
OUTPUT_GEN_001: process(CLK)
begin
	if rising_edge(CLK) then
		if(SYNC_RESET = '1') then
			RX_DATA_E <= (others => '0');
			RX_DATA_VALID_E <= '0';
			RX_SOF_E <= '0';
			RX_EOF_E <= '0';
			RX_TCP_HEADER_FLAG_D <= '0';
			RX_TCP_NON_ZERO_DATA_LENGTH <= '0';
		else
			RX_TCP_HEADER_FLAG_D <= RX_TCP_HEADER_FLAG;
			RX_EOF_E <= IP_RX_DATA_VALID and IP_RX_EOF; -- generate EOF even if TCP data field is empty
			
			if(IP_RX_DATA_VALID = '1') and (IP_RX_SOF = '1') then 
				RX_DATA_VALID_E <= '0';
				RX_SOF_E <= '0';
				RX_TCP_NON_ZERO_DATA_LENGTH <= '0';
				
			elsif(IP_RX_DATA_VALID = '1') and (RX_IP_PROTOCOL = 6) and (IP_HEADER_FLAG = '0') and 
				(RX_TCP_HEADER_FLAG = '0') and (GAP_IN_RX_SEQ = '0') and (RX_OUTOFBOUND = '0') then 
				-- Strip IP and TCP headers. Data field starts after TCP header.
				-- write byte to buffer as long as there is meaningful and valid TCP data, not filler.
				-- No point in writing non-TCP data to the rx buffer in the first place (those pesky
				-- NetBUI packets fill-up pretty fast, even if we rewind the write pointer at the next valid
				-- TCP packet)
				-- Do not forward data to the rx buffer if there is a gap in rx sequence or if the client 
				-- is doing a zero window-length probe (i.e. writing past the declared max)
				RX_DATA_E <= IP_RX_DATA;
				RX_DATA_VALID_E <= '1';	-- Data field starts after TCP header.
				if(RX_TCP_HEADER_FLAG_D = '1') then
					-- 1st TCP data byte
					RX_SOF_E <= '1';
					RX_TCP_NON_ZERO_DATA_LENGTH <= '1';	-- TCP payload field is not empty.
				else
					RX_SOF_E <= '0';
				end if;
			else
				RX_DATA_VALID_E <= '0';
				RX_SOF_E <= '0';
			end if;
		end if;
	end if;
end process;

-- read the TCP client sequence number in the received TCP header. 
-- This is subsequently used as ack when replying or sending data to the TCP client.
RX_WPTR_E_INC <= RX_WPTR_E + 1;
RX_WPTR_GEN_001: process(CLK)
begin
	if rising_edge(CLK) then
		if(SYNC_RESET = '1') then
			RX_WPTR_E <= (others => '0');
	  	elsif(IP_RX_DATA_VALID = '1') and (RX_IP_PROTOCOL = 6) and (RX_TCP_HEADER_FLAG = '1') 
		and (IP_BYTE_COUNT = 19) then
			-- last byte of a valid rx TCP header
			RX_WPTR_E <= RX_TCP_SEQ_NO; -- initialize external buffer write pointer location
		elsif(IP_RX_DATA_VALID = '1') and (RX_IP_PROTOCOL = 6) and (IP_HEADER_FLAG = '0') and 
			(RX_TCP_HEADER_FLAG = '0') and (GAP_IN_RX_SEQ = '0') and (RX_OUTOFBOUND = '0') then 
			-- Update as we read each data byte in the TCP data field
			RX_WPTR_E <= RX_WPTR_E_INC;	-- increment external buffer write pointer
		end if;
	end if;
end process;

-- Delay TCP payload output because we have to wait one more CLK for the TCP checksum outcome.
-- Aligned with IP_RX_DATA_VALID_D2
-- Forward data to output if and only if the TCP state is "Connected"
OUTPUT_GEN_002: process(CLK)
begin
	if rising_edge(CLK) then
		if(SYNC_RESET = '1') then
			RX_DATA <= (others => '0');
			RX_DATA_VALID_local <= '0';
			RX_SOF <= '0';
			RX_EOF_local <= '0';
		elsif(TCP_STATE_localrx = 3) then
			-- TCP connection is established. 
			RX_DATA <= RX_DATA_E;
			RX_SOF <= RX_SOF_E;
			RX_EOF_local <= RX_EOF_E; -- Always generate EOF (user must know when to check the final RX_DATA_VALID status)
			if(RX_SOF_E = '1') then
				-- let the demux know which stream
				RX_STREAM_NO <= RX_TCP_STREAM_NO_D;
			end if;
			if(RX_EOF_E = '1') then
				-- final tcp DATA validity information (including the checksum). 
				-- Does not include IP/TCP headers nor zero data length TCP frames.
				RX_DATA_VALID_local <= RX_DATA_VALID_E and VALID_RX_TCP_ALL;
			else
				-- Does not include IP/TCP headers nor zero data length TCP frames.
				RX_DATA_VALID_local <= RX_DATA_VALID_E;	-- packet assumed good until RX_EOF_E
			end if;
		else
			-- block data if not connected.
			RX_DATA <= (others => '0');
			RX_DATA_VALID_local <= '0';
			RX_SOF <= '0';
			RX_EOF_local <= '0';
		end if;
	end if;
end process;

RX_DATA_VALID <= RX_DATA_VALID_local;
RX_EOF <= RX_EOF_local;

--// RX SEQUENCE NUMBER ------------------------
RX_TCP_SEQ_NO_INC <= RX_TCP_SEQ_NO + 1;

-- Manage tx ack number
TX_ACK_GENx: for I in 0 to (NTCPSTREAMS-1) generate
	TX_ACK_GEN_001: process(CLK)
	begin
		if rising_edge(CLK) then
			if(I = RX_TCP_STREAM_NO_D) and (RX_TCP_STREAM_NO_VALID_D = '1') then
				-- rx event
				if(TCP_STATE(I) = 0) and (EVENT1 = '1') then
					-- Received valid SYN while in LISTEN state
					-- ACK sequence number is the one received + 1
					TX_ACK_NO(I) <= RX_TCP_SEQ_NO_INC;
				elsif(TCP_STATE(I) = 3) and (EVENT5 = '1') then
					-- Received valid FIN while in CONNECTED state
					-- ACK sequence number is the one received + 1
					-- Assumes FIN packet does not contain any data (not always true?????????????????? TBC)
					TX_ACK_NO(I) <= RX_TCP_SEQ_NO_INC;
				elsif(RX_ZERO_WINDOW_PROBE = '1') then
					-- TCP zero-window-length exception. sender may be testing whether the TX_ACK_WINDOW_LENGTH is 
					-- still zero by sending a 1-byte data. Treat as a zero-length packet
				elsif(GAP_IN_RX_SEQ = '1') then
					-- Do not update TX_ACK_NO if we have received a valid packet with unexpected RX_TCP_SEQ_NO (gap in sequence)
					-- as data was not written to the rx buffer, but we still send an ACK.
				elsif(TCP_STATE(I) = 3) and (VALID_RX_TCP2 = '1') then
					-- in CONNECTED state, received and successfully forwarded a rx segment. 
					-- TX_ACK_NO is the next expected number
					TX_ACK_NO(I) <= RX_WPTR_E;
				end if;
			end if;
		end if;
	end process;
end generate;


------------------------------------------------
---- TCP receive flow control -------------------
-------------------------------------------------

-- Detect when RX_TCP_SEQ_NO is beyond the TCP receive window (it happens, for example during TCP zero-window probes)
RX_OUTOFBOUND_001: process(CLK)
begin
	if rising_edge(CLK) then
		if(SYNC_RESET = '1') then
			RX_OUTOFBOUND <= '0';
		-- rx window upper bound (RX_TCP_SEQ_NO_MAX) computed upon sending the last tx frame.
		elsif(RX_TCP_SEQ_NO >= RX_TCP_SEQ_NO_MAX(RX_TCP_STREAM_NO_D)) and 
		not((RX_TCP_SEQ_NO(31 downto 30) = "11") and (RX_TCP_SEQ_NO_MAX(RX_TCP_STREAM_NO_D)(31 downto 30) = "00")) then
			-- a bit complicated because of modulo 2^32 counters.
			RX_OUTOFBOUND <= '1';
		else
			RX_OUTOFBOUND <= '0';
		end if;
	end if;
end process;


-- Send ACK immediately upon receiving a valid data segment while TCP connected.
-- Watch out for infinite loops! cannot send an ACK on an ACK
-- Therefore, inhibit SEND_ACK_NOW if the last packet received has the ACK with zero-length.
SEND_ACK_NOW <= VALID_RX_TCP2 when  (TCP_STATE_localrx = 3) and (RX_TCP_NON_ZERO_DATA_LENGTH = '1') else '0';
-- delay ACK by 8 CLKs to wait for the latest RX_FREE_SPACE information and include it in the ACK message triggered by SEND_ACK_NOW_D(7)
DELAY_SEND_ACK_NOW: process(CLK)
begin
	if rising_edge(CLK) then
		if(SYNC_RESET = '1') then
			SEND_ACK_NOW_D <= (others => '0');
		else
			SEND_ACK_NOW_D(7 downto 1) <= SEND_ACK_NOW_D(6 downto 0);
			SEND_ACK_NOW_D(0) <= SEND_ACK_NOW;
		end if;
	end if;
end process;



-- Detect when there is a gap in the RX_TCP_SEQ_NO, indicating a previous frame is missing
-- In general, we expect RX_TCP_SEQ_NO to match TX_ACK_NO, the next expected rx sequence number.
GAP_IN_RX_SEQ_GEN: process(CLK)
begin	
	if rising_edge(CLK) then
		if(RX_TCP_SEQ_NO /= TX_ACK_NO(RX_TCP_STREAM_NO_D))  and (RX_TCP_STREAM_NO_VALID_D = '1') then
			GAP_IN_RX_SEQ <= '1';
		else
			GAP_IN_RX_SEQ <= '0';
		end if;
	end if;
end process;

-- Detect when client tries to send data past the end of the window (for example during 
-- TCP zero-window probing. Sender may be probing whether the TX_ACK_WINDOW_LENGTH is 
--	still zero by sending a 1-byte data past the end of the window. 
RX_ZERO_WINDOW_PROBE <= (VALID_RX_TCP2 and RX_OUTOFBOUND) when  (TCP_STATE_localrx = 3) else '0';

-- external receive buffer is full 
RX_BUF_FULL_GEN: for I in 0 to (NTCPSTREAMS-1) generate
	RX_BUF_FULL(I) <= '1' when (RX_FREE_SPACE(I) = 0) else '0';
end generate;

-- flow control information is sent to the client within the ack 
-- using the TX_ACK_WINDOW_LENGTH window size FROZEN during packet transmission
TX_ACK_WINDOW_LENGTH_GEN: process(CLK) 
begin
	if rising_edge(CLK) then
		if(SYNC_RESET = '1') then
			TX_ACK_WINDOW_LENGTH <= MSS;	-- initial available is at least 1 MSS
		elsif(RTS_local = '0') then
			-- update TX_ACK_WINDOW_LENGTH when triggering a frame transmission back to a client
			-- Two trigger events:
			if(NEXT_TX_TCP_FRAME_QUEUED = '1') then
				-- short (no payload data) tx packet for stream NEXT_TX_TCP_STREAM_NO
				TX_ACK_WINDOW_LENGTH <= RX_FREE_SPACE(NEXT_TX_TCP_STREAM_NO);
			elsif(EVENT8 = '1') then
				-- long (with payload data) tx packet for stream TX_STREAM_SEL
				TX_ACK_WINDOW_LENGTH <= RX_FREE_SPACE(TX_STREAM_SEL);
			end if;
		end if;
	end if;
end process;
TX_ACK_WINDOW_LENGTH_OUT <= TX_ACK_WINDOW_LENGTH;

-- window resizing
-- set when transmitting an ACK with TX_ACK_WINDOW_LENGTH = 0 indicating receiver buffer is full,
-- clear when the input receive buffer is no longer empty. 
RX_WINDOW_RESIZE_STATEx: for I in 0 to (NTCPSTREAMS-1) generate
	RX_WINDOW_RESIZE_STATE_001: process(CLK)
	begin
		if rising_edge(CLK) then
			if(SYNC_RESET = '1') then
				RX_WINDOW_RESIZE_STATE(I) <= "00";
				SEND_RX_WINDOW_RESIZE(I) <= '0';
			elsif(TX_PACKET_SEQUENCE_START = '1') and (TX_TCP_STREAM_NO = I) and (RX_BUF_FULL(I) = '1') then
				-- not enough room in rx buffer. Sending ACK with zero-width ACK window to client I.
				RX_WINDOW_RESIZE_STATE(I) <= "01";
			elsif(RX_WINDOW_RESIZE_STATE(I) = "01") and (MAC_TX_EOF = '1') and (TX_TCP_STREAM_NO = I) then
				-- completed transmission of the ACK with TX_ACK_WINDOW_LENGTH = 0 to client I
				RX_WINDOW_RESIZE_STATE(I) <= "10";
			elsif (RX_WINDOW_RESIZE_STATE(I) = "10") and (RX_BUF_FULL(I) = '0') then
				-- Receive buffer has room for another segment. 
				-- time to send unsollicited ACKs to indicate window resizing. The receive window is no
				-- longer empty, the clients are on-hold due to the previous ACK with zero-width ack window.
				RX_WINDOW_RESIZE_STATE(I) <= "00";
				SEND_RX_WINDOW_RESIZE(I) <= '1';
			else
				SEND_RX_WINDOW_RESIZE(I) <= '0';
			end if;
		end if;
	end process;
end generate;

-- remember the receive window upper bound RX_TCP_SEQ_NO_MAX (exclusive)
-- to compare with follow-on RX_TCP_SEQ_NO
RX_WINDOW_UPPER_BOUNDx: for I in 0 to (NTCPSTREAMS-1) generate
	RX_WINDOW_UPPER_BOUND_001: process(CLK)
	begin
		if rising_edge(CLK) then
			if(SYNC_RESET = '1') then
				RX_TCP_SEQ_NO_MAX(I) <= (others => '0');
			elsif(TX_PACKET_SEQUENCE_START = '1') and (I = TX_TCP_STREAM_NO) then
				-- compute the receive address ceiling when sending the sequence ack to the client.
				RX_TCP_SEQ_NO_MAX(I) <= TX_ACK_NO(I) + TX_ACK_WINDOW_LENGTH;
				-- design note: TX_ACK_WINDOW_LENGTH is an aggregate value showing only space in the 
				-- common rx buffer (common to all streams). TODO: change when TCP_RXBUFNDEMUX is upgrade
				-- with individual buffers for each channel.
			end if;
		end if;
	end process;
end generate;

-- RECEIVE CODE ABOVE ^^^^^^^^^^^^^^^^^^^
--=============================================================================================
--=============================================================================================
--=============================================================================================
--=============================================================================================
-- TRANSMIT CODE BELOW  VVVVVVVVVVVVVVVVVV

---------------------------------------------------
------ Transmit EVENTS ----------------------------
---------------------------------------------------

---------------------------------------------------
--//---- TX SEQUENCER  ----------------------------
---------------------------------------------------
-- First, schedule a TX frame based on RX events.
-- The decision to transmit is made here and stored in non-volatile TX_PACKET_TYPE_QUEUED() variable until
-- the actual frame transmission can take place. This is a kind of queue to avoid conflicts.
-- Identify the stream based on the destination tcp port for each 
-- incoming frame.
SCHEDULE_TX_FRAME_GENx: for I in 0 to (NTCPSTREAMS-1) generate
	SCHEDULE_TX_FRAME_GEN_001: process(CLK)
	begin
		if rising_edge(CLK) then
			if(SYNC_RESET = '1') then
				TX_PACKET_TYPE_QUEUED(I) <= "00";	-- undefined tx packet type
			elsif (I = NEXT_TX_TCP_STREAM_NO) and (RTS_local = '0') and (NEXT_TX_TCP_FRAME_QUEUED = '1') then
				-- scheduled for transmission, clear any tx frame queued
				TX_PACKET_TYPE_QUEUED(I) <= "00";	-- undefined tx packet type
			elsif(TCP_STATE(I) = 3) and (CONNECTION_RESET(I) = '1') then
				-- user-initiated selective connection request while connected. Send FIN.
				TX_PACKET_TYPE_QUEUED(I) <= "10";		-- 40-byte long ACK, 20 bytes TCP header
			elsif (TCP_STATE(I) = 7) and (EVENTS5(I) = '1') then
				-- received FIN after FIN. Send final ACK.
				TX_PACKET_TYPE_QUEUED(I) <= "10";		-- 40-byte long ACK, 20 bytes TCP header
			elsif (TCP_STATE(I) = 3) and (EVENTS5(I) = '1') then
				-- client-initiated connection termination . Send ACK
				TX_PACKET_TYPE_QUEUED(I) <= "10";		-- 40-byte long ACK, 20 bytes TCP header
			elsif (TCP_STATE(I) = 4) and (EVENTS8(I) = '1') then
				-- sent ACK after receiving FIN. send final FIN
				TX_PACKET_TYPE_QUEUED(I) <= "10";		-- 40-byte long ACK, 20 bytes TCP header

			elsif(I = RX_TCP_STREAM_NO_D) and (RX_TCP_STREAM_NO_VALID_D = '1') then 
				-- rx-related events
				if ((TCP_STATE(I) = 0) and (EVENT1 = '1')) then
					-- Connection establishment. send SYN/ACK
					TX_PACKET_TYPE_QUEUED(I) <= "01";		-- SYN/ACK, 24 bytes TCP header, no TCP payload
					-- send MSS option with the SYN message. TCP header is thus 24 byte long.
				elsif ((TCP_STATE(I) = 3) and (EVENT6 = '1')) then
					-- received valid segment, no segment to transmit. generate ACK only.
					TX_PACKET_TYPE_QUEUED(I) <= "10";		-- 40-byte long ACK, 20 bytes TCP header
					-- default length
				elsif ((TCP_STATE(I) = 3) and (EVENTS10(I) = '1')) then
					-- Window resizing (receive flow control), no segment to transmit. The receive buffer is no 
					-- longer empty. Send a single ACK with a non-zero window.
					TX_PACKET_TYPE_QUEUED(I) <= "10";		-- 40-byte long ACK, 20 bytes TCP header
					-- default length
--				elsif(TCP_STATE(I) = 5) then
--					-- Connection termination. Send FIN/ACK
--					TX_PACKET_TYPE_QUEUED(I) <= "10";		-- 40-byte long ACK, 20 bytes TCP header
				end if;
				
			else
				-- non-rx related events		-- new 1/26/14
				if ((TCP_STATE(I) = 3) and (EVENTS10(I) = '1')) then
					-- Window resizing (receive flow control), no segment to transmit. The receive buffer is no 
					-- longer empty. Send a single ACK with a non-zero window.
					TX_PACKET_TYPE_QUEUED(I) <= "10";		-- 40-byte long ACK, 20 bytes TCP header
					-- default length
				end if;
			end if;
		end if;
	end process;
end generate;	

-- Trigger response
-- Which stream is next? Check if any non-payload packet is queued (TX_PACKET_TYPE_QUEUED(I) /= 0)
NEXT_TCP_TX_STREAM_INDEX_001: process(TX_PACKET_TYPE_QUEUED)
variable TX_STREAM_NO: integer range 0 to (NTCPSTREAMS-1) := 0;
variable TX_FRAME_QUEUED: std_logic := '0';
begin
	TX_STREAM_NO := 0;
	TX_FRAME_QUEUED := '0';
	for I in 0 to (NTCPSTREAMS-1) loop
		if(TX_FRAME_QUEUED = '0') and (TX_PACKET_TYPE_QUEUED(I) /= 0) then
			TX_FRAME_QUEUED := '1';
			TX_STREAM_NO := I;
		end if;
	end loop;
	NEXT_TX_TCP_STREAM_NO <= TX_STREAM_NO;
	NEXT_TX_TCP_FRAME_QUEUED <= TX_FRAME_QUEUED;
end process;

-- decision to transmit a frame (with or without payload) is made here.
-- TX_PACKET_TYPE is valid during transmission from the TX_PACKET_SEQUENCE_START pulse (incl) 
-- to MAC_TX_EOF (incl), undefined otherwise.
TX_PACKET_SEQUENCE_START_GEN_001: process(CLK)
begin
	if rising_edge(CLK) then
		if(SYNC_RESET = '1') then
			RTS_local <= '0';
			TX_PACKET_TYPE <= (others => '0');	-- undefined
		elsif(RTS_local = '0') then
			-- Prevent a new packet assembly/transmission until current assembly/transmission is complete.
			if(NEXT_TX_TCP_FRAME_QUEUED = '1') then
				-- short (no payload data) tx packet for stream NEXT_TX_TCP_STREAM_NO
				RTS_local <= '1';	
				TX_PACKET_SEQUENCE_START <='1';	
				TX_TCP_STREAM_NO <= NEXT_TX_TCP_STREAM_NO;
				TX_PACKET_TYPE <= TX_PACKET_TYPE_QUEUED(NEXT_TX_TCP_STREAM_NO);
			elsif(EVENT8 = '1') then
				-- long (with payload data) tx packet for stream TX_STREAM_SEL
				RTS_local <= '1';	
				TX_PACKET_SEQUENCE_START <='1';	
				TX_TCP_STREAM_NO <= TX_STREAM_SEL;
				TX_PACKET_TYPE <= "11";		-- tx data packet, 20 bytes TCP header
			end if;
		elsif(MAC_TX_EOF = '1') then
			-- transmit is complete.
			RTS_local <= '0';
			TX_PACKET_TYPE <= (others => '0');
		else
			TX_PACKET_SEQUENCE_START <= '0';	-- make it a one-CLK pulse
		end if;
	end if;
end process;
RTS <= RTS_local;	-- tell TCP_TX
		
		
-- send all relevant information to TCP_TX so that it can format the transmit frame
TX_PACKET_SEQUENCE_START_OUT <= TX_PACKET_SEQUENCE_START;
TX_DEST_MAC_ADDR_OUT <= TX_DEST_MAC_ADDR(TX_TCP_STREAM_NO);
TX_DEST_IP_ADDR_OUT <= TX_DEST_IP_ADDR(TX_TCP_STREAM_NO);
TX_DEST_PORT_NO_OUT <= TX_DEST_PORT_NO(TX_TCP_STREAM_NO);
TX_SOURCE_PORT_NO_OUT <= TCP_LOCAL_PORTS(TX_TCP_STREAM_NO);
TX_IPv4_6n_OUT <= TX_IPv4_6n(TX_TCP_STREAM_NO);	
TX_PACKET_TYPE_OUT <= TX_PACKET_TYPE;
TX_SEQ_NO_OUT <= TX_SEQ_NO_local(TX_TCP_STREAM_NO);
TX_ACK_NO_OUT <= TX_ACK_NO(TX_TCP_STREAM_NO);



---------------------------------------------------
------ TCP transmit flow control -------------------
---------------------------------------------------
-- last byte sent : TX_SEQ_NO
-- last byte ack'd: RX_TCP_ACK_NO
-- advertised rx window: RX_TCP_WINDOW_SIZE
-- sent and unacknowledged: TX_SEQ_NO - RX_TCP_ACK_NO

-- The next TCP tx frame size is determined by 
-- (a) the maximum packet size in the MAC (assumed 1023 payload data in TCP_TXBUF) or
-- (b) the effective TCP rx window size as reported by the receive side, or

-- Effective TCP rx window size = advertised TCP rx window size - unacknowledged but sent data size
-- changes at end of tx packet (TX_EOF_D2), and upon receiving a valid ack
-- Partial computation upon receiving a valid ACK, complete computation upon frame transmission
-- when TX_SEQ_NO is updated.
-- The effective TCP rx window size can be temporarily reduced by the TCP congestion window.

-- The TCP congestion window starts at 2 segments (see MSS) and doubles at each valid ACK.
EFF_RX_WINDOW_SIZE_PARTIAL_GEN_001: process(CLK)
begin
	if rising_edge(CLK) then
		if(SYNC_RESET = '1') then
			EFF_RX_WINDOW_SIZE_PARTIAL <= (others => '0');
			EFF_RX_WINDOW_SIZE_PARTIAL_STREAM <= 0;
			EFF_RX_WINDOW_SIZE_PARTIAL_VALID <= '0';
		elsif(TCP_STATE_localrx = 2) and (EVENT4 = '1') then
			-- entering the 'connected' state
			-- enter slow start phase: TCP congestion window starts with 2 segment. increases after each ACK
			-- until we reach the effective window size advertized by the receive side.
			EFF_RX_WINDOW_SIZE_PARTIAL <= ("0" & MSS(14 downto 0) & "0") + RX_TCP_ACK_NO(16 downto 0);	   
			TCP_CONGESTION_WINDOW(RX_TCP_STREAM_NO_D) <=  (MSS(14 downto 0) & "0");	 -- remember it for each stream
			EFF_RX_WINDOW_SIZE_PARTIAL_STREAM <= RX_TCP_STREAM_NO_D;
			EFF_RX_WINDOW_SIZE_PARTIAL_VALID <= '1';
			TCP_TX_SLOW_START(RX_TCP_STREAM_NO_D) <= '1';
		elsif(EVENT4A = '1') then 
			-- Valid ACK received for stream RX_TCP_STREAM_NO (not a duplicate ACK)
			if(TCP_TX_SLOW_START(RX_TCP_STREAM_NO_D) = '1') and (TCP_CONGESTION_WINDOW(RX_TCP_STREAM_NO_D)(15) = '0') and 
			(TCP_CONGESTION_WINDOW(RX_TCP_STREAM_NO_D)(14 downto 0) < RX_TCP_WINDOW_SIZE(15 downto 0)(15 downto 1)) then
				-- double the next tx frame size until we reach the effective TCP rx window size
				EFF_RX_WINDOW_SIZE_PARTIAL <= ("0" & TCP_CONGESTION_WINDOW(RX_TCP_STREAM_NO_D)(14 downto 0) & "0") + RX_TCP_ACK_NO(16 downto 0);
				-- remember it here
				TCP_CONGESTION_WINDOW(RX_TCP_STREAM_NO_D) <= TCP_CONGESTION_WINDOW(RX_TCP_STREAM_NO_D)(14 downto 0) & "0";  
			else
				EFF_RX_WINDOW_SIZE_PARTIAL <= ("0" & RX_TCP_WINDOW_SIZE) + RX_TCP_ACK_NO(16 downto 0);  
				TCP_TX_SLOW_START(RX_TCP_STREAM_NO_D) <= '0';	-- end of slow-start phase
			end if;
			EFF_RX_WINDOW_SIZE_PARTIAL_STREAM <= RX_TCP_STREAM_NO_D;
			EFF_RX_WINDOW_SIZE_PARTIAL_VALID <= '1';
			-- partial computation of the effective tcp rx window size
		elsif(EVENT4B = '1') then 
			-- Duplicate ACK for stream RX_TCP_STREAM_NO. Even though the RX_TCP_ACK_NO is the same, the
			-- RX_TCP_WINDOW_SIZE may have changed (window resizing)
			EFF_RX_WINDOW_SIZE_PARTIAL <= ("0" & RX_TCP_WINDOW_SIZE) + RX_TCP_ACK_NO(16 downto 0);  
			TCP_TX_SLOW_START(RX_TCP_STREAM_NO_D) <= '0';	-- end of slow-start phase
			EFF_RX_WINDOW_SIZE_PARTIAL_STREAM <= RX_TCP_STREAM_NO_D;
			EFF_RX_WINDOW_SIZE_PARTIAL_VALID <= '1';
		else
			-- ignore duplicate ACKs.
			EFF_RX_WINDOW_SIZE_PARTIAL_VALID <= '0';
		end if;
	end if;
end process;

-- detect duplicate ACKs (an indication that at least one of our tx packet got lost/collided)
-- keep the flag up until (a) the condition disappears, or (b) we rewind and transmit a packet 
RX_VALID_ACK_GENx: for I in 0 to (NTCPSTREAMS-1) generate
	-- send duplicate if we have received three ACKs in a row with the same ack no.
	-- why 3? because it is normal to receive two acks without lost packet (regular ack + window adjustment for example).

	-- tell TCP_TXBUF about the last acknowledged location.
	RX_TCP_ACK_NO_D(I) <= RX_TCP_ACK_NO_D_local(I)(16 downto 0);	-- don't need the entire 32-bits

	RX_VALID_ACK_GEN_002: process(CLK)
	begin
		if rising_edge(CLK) then
			if(EVENTS6(I) = '1') then
				-- rx event:
				-- save rx ack number (RX_TCP_ACK_NO is transient)
				RX_TCP_ACK_NO_D_local(I) <= RX_TCP_ACK_NO;
				-- detect duplicates
				if(RX_TCP_ACK_NO_D_local(I)(15 downto 0) = RX_TCP_ACK_NO(15 downto 0)) then
					-- Note: no need to compare all 31 bits of ack and sequence numbers 
					if(DUPLICATE_RX_TCP_ACK_CNTR(I)(1) = '0') then
						DUPLICATE_RX_TCP_ACK_CNTR(I) <= DUPLICATE_RX_TCP_ACK_CNTR(I) + 1;   -- counts from 0 to 2
					end if;
				else
					-- received new ack. condition is gone.
					DUPLICATE_RX_TCP_ACK_CNTR(I) <= "00";
				end if;
			elsif (TX_TCP_STREAM_NO = I) and (TX_PACKET_SEQUENCE_START = '1') and (TX_PACKET_TYPE = 3)
				and (TX_SEQ_NO_local(I)(15 downto 0) =  RX_TCP_ACK_NO_D_local(I)(15 downto 0)) then 
				-- tx event:
				-- started retransmitting unacknowledged data. clear flag
				DUPLICATE_RX_TCP_ACK_CNTR(I) <= "00";
			end if;
		end if;
	end process;
end generate;

-- Retransmission timeout
-- Compute timout since we have transmitted a packet and not received any ACK with different RX_TCP_ACK_NO.
-- See RFC 2988 Section 5: Managing the RTO timer. 
-- At this time, we do not implement the RTO mins (1s) and max(60s) nor the backing-off algorithm for 
-- repeated timeouts.
RX_VALID_ACK_TIMEOUT_x: for I in 0 to (NTCPSTREAMS-1) generate
	RX_VALID_ACK_TIMEOUT_001: process(CLK)
	begin
		if rising_edge(CLK) then
			if(SYNC_RESET = '1') then
				RX_VALID_ACK_TIMOUT(I) <= (others => '0');
			elsif(TX_TCP_STREAM_NO = I) and (TX_PACKET_TYPE = 3) and (MAC_TX_EOF = '1') then
				-- tx event: just (re)transmitted 1 frame with payload data. must wait for ACK
				-- arm timer
				RX_VALID_ACK_TIMOUT(I) <= TXRX_DELAY(I)(19 downto 0) & "0000"; -- 16* the average round-trip delay
			elsif(RX_TCP_STREAM_NO_D = I) and (RX_TCP_STREAM_NO_VALID_D = '1') and (EVENT4 = '1') 
			 and (RX_TCP_ACK_NO_D_local(I)(15 downto 0)  = TX_SEQ_NO_local(I)(15 downto 0)) then
				-- rx event: received a valid ACK, all outstanding data has been acknowledged
				-- turn off the retransmission timer.
				RX_VALID_ACK_TIMOUT(I) <= (others => '0');
			elsif(RX_TCP_STREAM_NO_D = I) and (RX_TCP_STREAM_NO_VALID_D = '1') and (EVENT4 = '1') 
			 and (RX_TCP_ACK_NO_D_local(I)(15 downto 0)  /= TX_SEQ_NO_local(I)(15 downto 0)) then
				-- rx event: received a valid ACK, acknowledging new data
				-- re-arm timer
				RX_VALID_ACK_TIMOUT(I) <= TXRX_DELAY(I)(19 downto 0) & "0000"; -- 16* the average round-trip delay
			elsif(TICK_4US = '1') and (RX_VALID_ACK_TIMOUT(I) > 1) then
				-- otherwise, decrement until counter reaches 1 (Re-transmit condition)
				RX_VALID_ACK_TIMOUT(I) <= RX_VALID_ACK_TIMOUT(I) -1;
			end if;
		end if;
	end process;

	RETRANSMIT_FLAG(I) <= '1' when (RX_VALID_ACK_TIMOUT(I) = 1) else '0'; 
end generate;

-- Measure round-trip delay: server -> client -> server
-- Units: 4us
TXRX_DELAY_x: for I in 0 to (NTCPSTREAMS-1) generate
	TXRX_DELAY_001: process(CLK)
	begin
		if rising_edge(CLK) then
			if(SYNC_RESET = '1') then
				TXRX_DELAY_STATE(I) <= '0';
				TXRX_DELAY_CNTR(I) <= (others => '0');
				TXRX_DELAY(I) <= x"01E848";  -- 0.5s worst case default (leave 6 extra MSBs for xX multiplication in timeout)
			elsif(TCP_STATE(I) = 0) then
				-- clear the last RT delay value at the start of connection
				TXRX_DELAY_STATE(I) <= '0';
				TXRX_DELAY_CNTR(I) <= (others => '0');
				TXRX_DELAY(I) <= x"01E848";  -- 0.5s worst case default (leave 6 extra MSBs for xX multiplication in timeout)
			elsif(TXRX_DELAY_STATE(I) = '0') and (TX_PACKET_SEQUENCE_START = '1') and (I = TX_TCP_STREAM_NO) then
				-- regular tx event
				TXRX_DELAY_STATE(I) <= '1';
				-- start the stop watch
				TXRX_DELAY_CNTR(I) <= (others => '0');
			elsif(TXRX_DELAY_STATE(I) = '1') and (EVENTS6(I) = '1') then
				-- received ACK 
				TXRX_DELAY_STATE(I) <= '0';
				-- set a minimum RT delay value (here 32us)
				if(TXRX_DELAY_CNTR(I)(19 downto 3) = 0) then
					TXRX_DELAY(I) <= x"000008";
				else
					TXRX_DELAY(I) <= TXRX_DELAY_CNTR(I);
				end if;
			elsif(TXRX_DELAY_STATE(I) = '1') and (TICK_4US = '1') then
				-- increment stop watch up to 0.5s max
				if(TXRX_DELAY_CNTR(I) <  x"01E848") then
					TXRX_DELAY_CNTR(I) <= TXRX_DELAY_CNTR(I) + 1;
				else
					-- reached the max value of 0.5s
					TXRX_DELAY_STATE(I) <= '0';
					TXRX_DELAY(I) <= TXRX_DELAY_CNTR(I);
				end if;
			end if;
		end if;
	end process;
end generate;


--
-------------------------------------------------
---- Transmit data ------------------------------
-------------------------------------------------
-- 32-bit initial sequence number to be used at TCP connection time.
-- This is simply a counter incremented every 4 usec.
TCP_ISN_GEN: process(CLK)
begin
	if rising_edge(CLK) then
		TCP_ISN_D <= TCP_ISN;	-- pipelining for better timing
		
		if(TICK_4US = '1') then
			TCP_ISN <= TCP_ISN + 1;
		end if;
	end if;
end process;

-- Manage tx sequence number. Changes based on INDEPENDENT rx and tx events (we may be receiving data about stream#1 
-- while transmitting data about stream#2).
-- To prevent deadlocks, TX_SEQ_NO should only change upon completing a frame transmission or when 
-- no data is waiting for transmission in TCP_TXBUF.
TX_SEQ_NO_GENx: for I in 0 to (NTCPSTREAMS-1) generate
	-- forward information to TXBUF (to compute effective rx window size and reposition the buffer read
	-- pointer)
	TX_SEQ_NO(I) <= TX_SEQ_NO_local(I)(16 downto 0);	-- don't need the entire 32-bits

	TX_SEQ_NO_GENx_001: process(CLK)
	begin
		if rising_edge(CLK) then
			if(RX_TCP_STREAM_NO_D = I) and (RX_TCP_STREAM_NO_VALID_D = '1') 
				and (TCP_STATE_localrx = 0) and (EVENT1 = '1') then
				-- rx event: Received valid SYN while in LISTEN state
				-- Save the initial sequence number
				if(SIMULATION = '1') then
					-- During simulations, set the TX_SEQ_NO so that it matches Wireshark captures
					-- (sequence number in the SYN/ACK packet)
--					TX_SEQ_NO_local(I) <= x"00000001";
					TX_SEQ_NO_local(I) <= x"01a8d12c";
				else
					-- use a random number (time)
					TX_SEQ_NO_local(I) <= TCP_ISN_D;
				end if;
			elsif(TX_TCP_STREAM_NO = I) and (TX_PACKET_TYPE = 3) and (MAC_TX_EOF = '1') then
				-- regular tx event: 
				-- just completed transmission of a frame with TX_PAYLOAD_SIZE payload bytes.
				TX_SEQ_NO_local(I) <= TX_SEQ_NO_local(I) + ext(TX_PAYLOAD_SIZE, TX_SEQ_NO_local(I)'length);
			elsif(TX_TCP_STREAM_NO = I) and (MAC_TX_EOF = '1') and ((TX_FLAGS(TX_TCP_STREAM_NO)(1) = '1') or (TX_FLAGS(TX_TCP_STREAM_NO)(0) = '1'))then
				-- tx event: 
				-- SYN and FIN flags consumes a sequence number
				-- Update sequence number upon tx completion, getting ready for comparison with the RX_TCP_ACK_NO
				TX_SEQ_NO_local(I) <= TX_SEQ_NO_local(I) + 1;
			elsif (RETRANSMIT_FLAG(I) = '1') and (TCP_STATE(I) = 3) then	-- NEW 11/4/11 AZ. this re-transmission scheme works only during connected state.
				-- tx event. timeout awaiting for ACK. Rewind TX_SEQ_NO which will indirectly cause a re-transmission since
				-- TCP_TXBUF will declare data ready to send.
				TX_SEQ_NO_local(I) <= RX_TCP_ACK_NO_D_local(I);
-- Seems unnecessary 10/15/13
--			elsif (RX_TCP_STREAM_NO_D = I) and (RX_TCP_STREAM_NO_VALID_D = '1') and 
--					(EVENT4B = '1') and (DUPLICATE_RX_TCP_ACK_CNTR(I)(1) = '1')  and 
--					(TX_SEQ_NO_local(I)(15 downto 0) /=  RX_TCP_ACK_NO_D_local(I)(15 downto 0)) then
--				-- rx event: received 3 or more duplicate acks (sign of congestion). 
--				-- Rewind tx sequence number to the last acknowledged seq no at the start of retransmission
--				TX_SEQ_NO_local(I) <= RX_TCP_ACK_NO_D_local(I);
			end if;
		end if;
	end process;
end generate;

-- Manage tx TCP flags:  
-- (MSb) CWR Congestion Window Reduced (CWR) flag/ECE - ECN-Echo/URG/ACK/PSH/RST/SYN/FIN (LSb)
TX_FLAGS_GENx: for I in 0 to (NTCPSTREAMS-1) generate
	TX_FLAGS_GEN_001: process(CLK)
	begin
		if rising_edge(CLK) then
			if(SYNC_RESET = '1') then
				TX_FLAGS(I) <= "00000000";	
			elsif(TCP_STATE(I) = 3) and (CONNECTION_RESET(I) = '1') then
				-- user-initiated selective connection request while connected. Send FIN.
				TX_FLAGS(I) <= "00000001";	
			elsif (TCP_STATE(I) = 7) and (EVENTS5(I) = '1') then
				-- received FIN after FIN. Send final ACK.
				TX_FLAGS(I) <= "00010000";	
			elsif (TCP_STATE(I) = 3) and (EVENTS5(I) = '1') then
				-- client-initiated connection termination . Send ACK
				TX_FLAGS(I) <= "00010000";	
			elsif (TCP_STATE(I) = 4) and (EVENTS8(I) = '1') then
				-- sent ACK after receiving FIN. send final FIN
				TX_FLAGS(I) <= "00000001";	


			elsif(TCP_STATE_localrx = 0) and (EVENT1 = '1') then
				-- Received valid SYN while in LISTEN state
				TX_FLAGS(I) <= "00010010";	-- SYN flag set in response
			elsif (EVENT8 = '1') then
				-- CONNECTED state(implied in EVENT8). send or re-send data. set PUSH flag
				TX_FLAGS(I) <= "00011000";	-- flags in response
			elsif (TCP_STATE_localrx = 3) and ((EVENT5 = '1') or (EVENT6 = '1') or (EVENTS10(I) = '1')) then
				-- CONNECTED state. ACK only. clear PUSH flag
				TX_FLAGS(I) <= "00010000";	-- flags in response
			elsif(TCP_STATE_localrx = 4) and (EVENT2 = '1') then
				-- Connection termination. Send FIN
				TX_FLAGS(I) <= "00010001";	-- FIN flag set in response
			end if;
		end if;
	end process;
end generate;
TX_FLAGS_OUT <= TX_FLAGS(TX_TCP_STREAM_NO);


-- Manage TX TCP flag: ACK
-- General rule: ACK is set if TX_SEQ_NO (expected) matches RX_TCP_ACK_NO (received)
-- unless we are receiving the first SYN (then ACK is 1 because we have no reference
-- sequence number to compare with).
--TX_FLAGS_GEN_002: process(ASYNC_RESET, CLK)
--begin
--	if(ASYNC_RESET = '1') then
--		TX_FLAGS(4) <= '0';	
--	elsif rising_edge(CLK) then
--		if(RX_TCP_VALID = '1') and (RX_TCP_VALID_RDY = '1') 
--			and (RX_TCP_DEST_PORT_NO = TCP_LOCAL_PORTS(0)) then
--			if (RX_TCP_ACK_NO = TX_SEQ_NO(0)) then
--				-- match -> set ACK flag in response
--				TX_FLAGS(4) <= '1';	
--			elsif (RX_TCP_FLAGS(1) = '1') and (TCP_STATE(0) = 0) then
--				-- special case: received SYN while in LISTEN mode-> set ACK flag in response
--				TX_FLAGS(4) <= '1';	
--			else
--				-- no match -> clear ACK flag in response
--				TX_FLAGS(4) <= '0';	
--			end if;
--		end if;
--	end if;
--end process;



--// TCP-IP connection status
CONNECTED_GENx: for I in 0 to (NTCPSTREAMS-1) generate
	CONNECTED_FLAG(I) <= '1' when (TCP_STATE(I) = 3) else '0';
end generate;


--// Test Point
TP(1) <= '1' when (TCP_STATE(0) = 0) else '0';	-- connected
TP(2) <= '1' when (TCP_STATE(0) = 1) else '0';	-- connected
TP(3) <= '1' when (TCP_STATE(0) = 2) else '0';	-- connected
TP(4) <= '1' when (TCP_STATE(0) = 3) else '0';	-- connected
TP(5) <= '1' when (TCP_STATE(0) = 4) else '0';	-- connected
TP(6) <= '1' when (TCP_STATE(0) = 5) else '0';	-- connected
TP(7) <= EVENT1;	-- SYN
TP(8) <= EVENT2;	-- SENT
TP(9) <= EVENT4;	-- ACK
TP(10) <= EVENT5;	-- FIN
--TP(2) <= TX_SEQ_NO_local(0)(0);
--TP(3) <= RX_TCP_ACK_NO_D_local(0)(0);
--TP(4) <= EVENT4;	-- ACK
--TP(5) <= '1' when (RX_TCP_STREAM_NO_D = 0) and (RX_TCP_STREAM_NO_VALID_D = '1') 
--				and (TCP_STATE_localrx = 0) and (EVENT1 = '1') else '0';  -- initialize TX_SEQ_NO
--TP(6) <= '1' when (TX_TCP_STREAM_NO = 0) and (TX_PACKET_TYPE = 3) and (MAC_TX_EOF = '1')  else '0';
--	-- TX_SEQ_NO regular tx event
--TP(7) <= '1' when (TX_TCP_STREAM_NO = 0) and (MAC_TX_EOF = '1') and (TX_FLAGS(1) = '1') else '0';
--TP(8) <= '1' when (TX_TCP_STREAM_NO = 0) and (MAC_TX_EOF = '1') and (TX_FLAGS(0) = '1') else '0';
--TP(9) <= RETRANSMIT_FLAG(0);
--TP(10) <= '1' when (RX_TCP_STREAM_NO_D = 0) and (RX_TCP_STREAM_NO_VALID_D = '1') and 
--					(EVENT4B = '1') and (DUPLICATE_RX_TCP_ACK_CNTR(0)(1) = '1')  and 
--					(TX_SEQ_NO_local(0)(15 downto 0) /=  RX_TCP_ACK_NO_D_local(0)(15 downto 0)) else '0';
--
							 

end Behavioral;

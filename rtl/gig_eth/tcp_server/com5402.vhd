-------------------------------------------------------------
-- MSS copyright 2011-2014
--	Filename:  COM5402.VHD
-- Author: Alain Zarembowitch / MSS
--	Version: 6
--	Date last modified: 1/31/14
-- Inheritance: 	N/A
--
-- description:  Internet IP stack: IP/TCP/UDP/ARP/PING.
-- The IP stack relies on the lower layers: MAC (COM5401) and PHY (Integrated circuit)
-- Interfaces directly with COM-5401SOFT MAC protocol layer or equivalent.
--
-- Rev 2 8/21/11 AZ
-- Change tx strategy. Transmission is triggered when MAC_TX_CTS = '1' without any 
-- flow control breaks within a frame. Reason: the MAC tx elastic buffer is now 4KB, 
-- large enough for 2 maximum size frames. 
--
-- Rev 3 11/10/13 AZ
-- Progressively replacing ASYNC_RESET with SYNC_RESET
--
-- Rev 4 11/10/13 AZ
-- Added MAC_TX_SOF flag for an easier interface with Xilinx tri-mode MAC
-- Corrected IP header bug in UDP_TX.vhd
--
-- Rev 5 1/28/14 AZ
-- Increased EFF_RX_WINDOW_SIZE_PARTIAL precision to 17 bits to detect abnormal negative window size reports
--
-- Rev 6 1/31/14 AZ
-- moved TX_IDLE_TIMEOUT up to a generic parameter.
---------------------------------------------------------------
library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.STD_LOGIC_UNSIGNED.ALL;
use work.com5402pkg.all;	-- defines global types, number of TCP streams, etc
library UNISIM;
use UNISIM.VComponents.all;

entity COM5402 is
	generic (
		CLK_FREQUENCY: integer := 56;
			-- CLK frequency in MHz. Needed to compute actual delays.
		TX_IDLE_TIMEOUT: integer range 0 to 50:= 50;	
			-- inactive input timeout, expressed in 4us units. -- 50*4us = 200us 
			-- Controls the transmit stream segmentation: data in the elastic buffer will be transmitted if
			-- no input is received within TX_IDLE_TIMEOUT, without waiting for the transmit frame to be filled with MSS data bytes.
		SIMULATION: std_logic := '0'
			-- 1 during simulation with Wireshark .cap file, '0' otherwise
			-- Wireshark many not be able to collect offloaded checksum computations.
			-- when SIMULATION =  '1': (a) IP header checksum is valid if 0000,
			-- (b) TCP checksum computation is forced to a valid 00001 irrespective of the 16-bit checksum
			-- captured by Wireshark.
	);
    Port ( 
		--//-- CLK, RESET
		CLK: in std_logic;
			-- All signals are synchronous with CLK
			-- CLK must be a global clock 125 MHz or faster to match the Gbps MAC speed.
		ASYNC_RESET: in std_logic;	-- to be phased out. replace with SYNC_RESET
		SYNC_RESET: in std_logic;
		
		--//-- CONFIGURATION
		-- configuration signals are synchonous with CLK
		-- Synchronous with CLK clock.
		MAC_ADDR : IN std_logic_vector(47 downto 0);
		IPv4_ADDR: in std_logic_vector(31 downto 0);
		IPv6_ADDR: in std_logic_vector(127 downto 0);
		SUBNET_MASK: in std_logic_vector(31 downto 0);
		GATEWAY_IP_ADDR: in std_logic_vector(31 downto 0);
			-- local IP address. 4 bytes for IPv4, 16 bytes for IPv6
			-- Natural order (MSB) 172.16.1.128 (LSB) as transmitted in the IP frame.

		--// User-initiated connection reset for stream I
		CONNECTION_RESET: in std_logic_vector((NTCPSTREAMS-1) downto 0);

		--//-- Protocol -> Transmit MAC Interface
		-- 32-bit CRC is automatically appended by the MAC layer. User should not supply it.
		-- Synchonous with the user-side CLK
		MAC_TX_DATA: out std_logic_vector(7 downto 0);
			-- MAC reads the data at the rising edge of CLK when MAC_TX_DATA_VALID = '1'
		MAC_TX_DATA_VALID: out std_logic;
			-- data valid
		MAC_TX_SOF: out std_logic;
			-- start of frame: '1' when sending the first byte. 
			-- Aligned with MAC_TX_DATA_VALID
		MAC_TX_EOF: out std_logic;
			-- End of frame: '1' when sending the last byte in a packet to be transmitted. 
			-- Aligned with MAC_TX_DATA_VALID
		MAC_TX_CTS: in std_logic;
			-- MAC-generated Clear To Send flow control signal, indicating room in the 
			-- MAC tx elastic buffer for a complete maximum size frame 1518B. 
			-- The user should check that this signal is high before deciding to send
			-- sending the next frame. 
			-- Note: MAC_TX_CTS may go low while the frame is transfered in. Ignore it as space is guaranteed
			-- at the start of frame.

		--//-- Receive MAC -> Protocol
		-- Valid rx packets only: packets with bad CRC or invalid address are discarded.
		-- The 32-bit CRC is always removed by the MAC layer.
		-- Synchonous with the user-side CLK
		MAC_RX_DATA: in std_logic_vector(7 downto 0);
			-- USER reads the data at the rising edge of CLK when MAC_RX_DATA_VALID = '1'
		MAC_RX_DATA_VALID: in std_logic;
			-- data valid
		MAC_RX_SOF: in std_logic;
			-- '1' when sending the first byte in a received packet. 
			-- Aligned with MAC_RX_DATA_VALID
		MAC_RX_EOF: in std_logic;
			-- '1' when sending the last byte in a received packet. 
			-- Aligned with MAC_RX_DATA_VALID

		--//-- Application <- UDP rx
		UDP_RX_DATA: out std_logic_vector(7 downto 0);
		UDP_RX_DATA_VALID: out std_logic;
		UDP_RX_SOF: out std_logic;	
		UDP_RX_EOF: out std_logic;	
			-- 1 CLK pulse indicating that UDP_RX_DATA is the last byte in the UDP data field.
			-- ALWAYS CHECK UDP_RX_DATA_VALID at the end of packet (UDP_RX_EOF = '1') to confirm
			-- that the UDP packet is valid. External buffer may have to backtrack to the the last
			-- valid pointer to discard an invalid UDP packet.
			-- Reason: we only knows about bad UDP packets at the end.
		UDP_RX_DEST_PORT_NO: in std_logic_vector(15 downto 0);
				
		--//-- Application -> UDP tx
		UDP_TX_DATA: in std_logic_vector(7 downto 0);
		UDP_TX_DATA_VALID: in std_logic;
		UDP_TX_SOF: in std_logic;	-- 1 CLK-wide pulse to mark the first byte in the tx UDP frame
		UDP_TX_EOF: in std_logic;	-- 1 CLK-wide pulse to mark the last byte in the tx UDP frame
		UDP_TX_CTS: out std_logic;	
		UDP_TX_ACK: out std_logic;	-- 1 CLK-wide pulse indicating that the previous UDP frame is being sent
		UDP_TX_NAK: out std_logic;	-- 1 CLK-wide pulse indicating that the previous UDP frame could not be sent
		UDP_TX_DEST_IP_ADDR: in std_logic_vector(127 downto 0);
		UDP_TX_DEST_PORT_NO: in std_logic_vector(15 downto 0);
		UDP_TX_SOURCE_PORT_NO: in std_logic_vector(15 downto 0);
		
		--//-- Application <- TCP rx
		-- NTCPSTREAMS can operate independently and concurrently. No scheduling arbitration needed here.
		TCP_RX_DATA: out SLV8xNTCPSTREAMStype;
		TCP_RX_DATA_VALID: out std_logic_vector((NTCPSTREAMS-1) downto 0);
		TCP_RX_RTS: out std_logic_vector((NTCPSTREAMS-1) downto 0);	-- Ready To Send
		TCP_RX_CTS: in std_logic_vector((NTCPSTREAMS-1) downto 0);	-- Clear To Send
		
		--//-- Application -> TCP tx
		-- NTCPSTREAMS can operate independently and concurrently. No scheduling arbitration needed here.
		TCP_TX_DATA: in SLV8xNTCPSTREAMStype;
		TCP_TX_DATA_VALID: in std_logic_vector((NTCPSTREAMS-1) downto 0);
		TCP_TX_CTS: out std_logic_vector((NTCPSTREAMS-1) downto 0);	
			-- Clear To Send = transmit flow control. 
			-- App is responsible for checking the CTS signal before sending APP_DATA

		--//-- TEST POINTS, COMSCOPE TRACES
		CS1: out std_logic_vector(7 downto 0);
		CS1_CLK: out std_logic;
		CS2: out std_logic_vector(7 downto 0);
		CS2_CLK: out std_logic;
		TP: out std_logic_vector(10 downto 1)
	   
 );
end entity;

architecture Behavioral of COM5402 is
--------------------------------------------------------
--      COMPONENTS
--------------------------------------------------------
	COMPONENT TIMER_4US
	GENERIC (
		CLK_FREQUENCY: integer 
	);
	PORT(
		ASYNC_RESET : IN std_logic;
		CLK : IN std_logic;          
		TICK_4US : OUT std_logic;
		TICK_100MS: out std_logic
		);
	END COMPONENT;

	COMPONENT PACKET_PARSING
	GENERIC (
		IPv6_ENABLED: std_logic;
		SIMULATION: std_logic
	);	
	PORT(
		ASYNC_RESET : IN std_logic;
		CLK : IN std_logic;
		TICK_4US : IN std_logic;
		MAC_RX_DATA : IN std_logic_vector(7 downto 0);
		MAC_RX_DATA_VALID : IN std_logic;
		MAC_RX_SOF : IN std_logic;
		MAC_RX_EOF : IN std_logic;
		IPv4_ADDR: in std_logic_vector(31 downto 0);
		IPv6_ADDR: in std_logic_vector(127 downto 0);
		IP_RX_DATA: out std_logic_vector(7 downto 0);
		IP_RX_DATA_VALID: out std_logic;	
		IP_RX_SOF: out std_logic;
		IP_RX_EOF: out std_logic;
		IP_BYTE_COUNT: out std_logic_vector(15 downto 0);	
		IP_HEADER_FLAG: out std_logic;
		RX_TYPE : OUT std_logic_vector(3 downto 0);
		RX_TYPE_RDY : OUT std_logic;
		RX_IPv4_6n: out std_logic;
		RX_IP_PROTOCOL : OUT std_logic_vector(7 downto 0);
		RX_IP_PROTOCOL_RDY : OUT std_logic;
		VALID_DEST_IP : OUT std_logic;
		VALID_DEST_IP_RDY : OUT std_logic;
		IP_HEADER_CHECKSUM_VALID: out std_logic;
		IP_HEADER_CHECKSUM_VALID_RDY: out std_logic;
		RX_SOURCE_MAC_ADDR: out std_logic_vector(47 downto 0);
		RX_SOURCE_IP_ADDR: out std_logic_vector(127 downto 0);
		RX_SOURCE_TCP_PORT_NO: out std_logic_vector(15 downto 0);
		RX_DEST_IP_ADDR: out std_logic_vector(127 downto 0);
		RX_DEST_TCP_PORT_NO: out std_logic_vector(15 downto 0);
		RX_UDP_CKSUM: out std_logic_vector(16 downto 0);
		RX_UDP_CKSUM_RDY: out std_logic;
		RX_TCP_BYTE_COUNT: out std_logic_vector(15 downto 0);
		RX_TCP_HEADER_FLAG: out std_logic;
		RX_TCP_FLAGS: out std_logic_vector(7 downto 0);
		RX_TCP_CKSUM: out std_logic_vector(16 downto 0);
		RX_TCP_SEQ_NO: out std_logic_vector(31 downto 0);
		RX_TCP_ACK_NO: out std_logic_vector(31 downto 0);
		RX_TCP_WINDOW_SIZE: out std_logic_vector(15 downto 0);
		
		CS1 : OUT std_logic_vector(7 downto 0);
		CS1_CLK : OUT std_logic;
		CS2 : OUT std_logic_vector(7 downto 0);
		CS2_CLK : OUT std_logic;
		TP : OUT std_logic_vector(10 downto 1)
		);
	END COMPONENT;

	COMPONENT PING
	GENERIC (
		IPv6_ENABLED: std_logic;
		MAX_PING_SIZE: std_logic_vector(15 downto 0)
	);	
	PORT(
		ASYNC_RESET : IN std_logic;
		CLK : IN std_logic;
		MAC_RX_DATA : IN std_logic_vector(7 downto 0);
		MAC_RX_DATA_VALID : IN std_logic;
		MAC_RX_SOF : IN std_logic;
		MAC_RX_EOF : IN std_logic;
		MAC_ADDR : IN std_logic_vector(47 downto 0);
		IPv4_ADDR: in std_logic_vector(31 downto 0);
		IPv6_ADDR: in std_logic_vector(127 downto 0);
		RX_IPv4_6n: in std_logic;
		RX_IP_PROTOCOL : IN std_logic_vector(7 downto 0);
		RX_IP_PROTOCOL_RDY : IN std_logic;
		IP_RX_DATA_VALID: in std_logic;	
		IP_RX_EOF : IN std_logic;
		MAC_TX_CTS : IN std_logic;          
		MAC_TX_DATA : OUT std_logic_vector(7 downto 0);
		MAC_TX_DATA_VALID : OUT std_logic;
		MAC_TX_EOF : OUT std_logic;
		RTS : OUT std_logic;
		TP : OUT std_logic_vector(10 downto 1)
		);
	END COMPONENT;

	COMPONENT ARP
	PORT(
		ASYNC_RESET : IN std_logic;
		CLK : IN std_logic;
		MAC_RX_DATA : IN std_logic_vector(7 downto 0);
		MAC_RX_DATA_VALID : IN std_logic;
		MAC_RX_SOF : IN std_logic;
		MAC_RX_EOF : IN std_logic;
		MAC_ADDR : IN std_logic_vector(47 downto 0);
		IPv4_ADDR: in std_logic_vector(31 downto 0);
		RX_TYPE : IN std_logic_vector(3 downto 0);
		RX_TYPE_RDY : IN std_logic;
		RX_SOURCE_MAC_ADDR: in std_logic_vector(47 downto 0);
		RX_SOURCE_IP_ADDR: in std_logic_vector(31 downto 0);
		MAC_TX_CTS : IN std_logic;          
		MAC_TX_DATA : OUT std_logic_vector(7 downto 0);
		MAC_TX_DATA_VALID : OUT std_logic;
		MAC_TX_EOF : OUT std_logic;
		RTS : OUT std_logic;
		TP : OUT std_logic_vector(10 downto 1)
		);
	END COMPONENT;

	COMPONENT WHOIS2
	PORT(
		CLK : IN std_logic;
		SYNC_RESET : IN std_logic;
		WHOIS_IP_ADDR : IN std_logic_vector(31 downto 0);
		WHOIS_START : IN std_logic;
		MAC_ADDR : IN std_logic_vector(47 downto 0);
		IPv4_ADDR : IN std_logic_vector(31 downto 0);
		MAC_TX_CTS : IN std_logic;          
		WHOIS_RDY : OUT std_logic;
		MAC_TX_DATA : OUT std_logic_vector(7 downto 0);
		MAC_TX_DATA_VALID : OUT std_logic;
		MAX_TX_EOF : OUT std_logic;
		RTS : OUT std_logic;
		TP : OUT std_logic_vector(10 downto 1)
		);
	END COMPONENT;

	COMPONENT ARP_CACHE2
	PORT(
		SYNC_RESET: in std_logic;
		CLK : IN std_logic;
		TICK_100MS : IN std_logic;          
		RT_IP_ADDR : IN std_logic_vector(31 downto 0);
		RT_REQ_RTS : IN std_logic;
		RT_CTS: out std_logic;	
		RT_MAC_REPLY : OUT std_logic_vector(47 downto 0);
		RT_MAC_RDY : OUT std_logic;
		RT_NAK: out std_logic;
		MAC_ADDR : IN std_logic_vector(47 downto 0);
		IPv4_ADDR : IN std_logic_vector(31 downto 0);
		SUBNET_MASK : IN std_logic_vector(31 downto 0);
		GATEWAY_IP_ADDR: in std_logic_vector(31 downto 0);
		RX_SOURCE_ADDR_RDY: in std_logic;
		RX_SOURCE_MAC_ADDR: in std_logic_vector(47 downto 0);	
		RX_SOURCE_IP_ADDR: in std_logic_vector(31 downto 0); 
		WHOIS_IP_ADDR : OUT std_logic_vector(31 downto 0);
		WHOIS_START : OUT std_logic;
		SREG1 : OUT std_logic_vector(7 downto 0);
		SREG2 : OUT std_logic_vector(7 downto 0);
		SREG3 : OUT std_logic_vector(7 downto 0);
		SREG4 : OUT std_logic_vector(7 downto 0);
		SREG5 : OUT std_logic_vector(7 downto 0);
		SREG6 : OUT std_logic_vector(7 downto 0);
		TP : OUT std_logic_vector(10 downto 1)
		);
	END COMPONENT;

	COMPONENT UDP2SERIAL
	GENERIC (
		PORT_NO: std_logic_vector(15 downto 0);
		CLK_FREQUENCY: integer
	);	
	PORT(
		ASYNC_RESET : IN std_logic;
		CLK : IN std_logic;
		IP_RX_DATA : IN std_logic_vector(7 downto 0);
		IP_RX_DATA_VALID : IN std_logic;
		IP_RX_SOF : IN std_logic;
		IP_RX_EOF : IN std_logic;
		IP_HEADER_FLAG : IN std_logic;
		RX_IP_PROTOCOL : IN std_logic_vector(7 downto 0);
		RX_IP_PROTOCOL_RDY : IN std_logic;
		SERIAL_OUT : OUT std_logic;
		TP : OUT std_logic_vector(10 downto 1)
		);
	END COMPONENT;

	COMPONENT UDP_RX
	PORT(
		ASYNC_RESET : IN std_logic;
		CLK : IN std_logic;
		IP_RX_DATA : IN std_logic_vector(7 downto 0);
		IP_RX_DATA_VALID : IN std_logic;
		IP_RX_SOF : IN std_logic;
		IP_RX_EOF : IN std_logic;
		IP_BYTE_COUNT: in std_logic_vector(15 downto 0);	
		IP_HEADER_FLAG : IN std_logic;
		RX_IP_PROTOCOL : IN std_logic_vector(7 downto 0);
		RX_IP_PROTOCOL_RDY : IN std_logic;          
		RX_UDP_CKSUM: in std_logic_vector(16 downto 0);
		RX_UDP_CKSUM_RDY: in std_logic;
		PORT_NO: in std_logic_vector(15 downto 0);
		APP_DATA : OUT std_logic_vector(7 downto 0);
		APP_DATA_VALID : OUT std_logic;
		APP_SOF : OUT std_logic;
		APP_EOF : OUT std_logic;
		APP_SRC_UDP_PORT: OUT std_logic_vector(15 downto 0);			
		TP : OUT std_logic_vector(10 downto 1)
		);
	END COMPONENT;

	COMPONENT UDP_TX
	generic (
		NBUFS: integer ;
		IPv6_ENABLED: std_logic
	);
	PORT(
		CLK : IN std_logic;
		SYNC_RESET : IN std_logic;
		TICK_4US: in std_logic;
		APP_DATA : IN std_logic_vector(7 downto 0);
		APP_DATA_VALID : IN std_logic;
		APP_SOF : IN std_logic;
		APP_EOF : IN std_logic;
		APP_CTS : OUT std_logic;
		DEST_IP_ADDR: in std_logic_vector(127 downto 0);	
		DEST_PORT_NO : IN std_logic_vector(15 downto 0);
		SOURCE_PORT_NO : IN std_logic_vector(15 downto 0);
		IPv4_6n: in std_logic;
		MAC_ADDR: in std_logic_vector(47 downto 0);
		IPv4_ADDR: in std_logic_vector(31 downto 0);
		IPv6_ADDR: in std_logic_vector(127 downto 0);
		IP_ID: in std_logic_vector(15 downto 0);
		ACK : OUT std_logic;
		NAK : OUT std_logic;
		RT_IP_ADDR : OUT std_logic_vector(31 downto 0);
		RT_REQ_RTS: out std_logic;
		RT_REQ_CTS: in std_logic;
		RT_MAC_REPLY : IN std_logic_vector(47 downto 0);
		RT_MAC_RDY : IN std_logic;
		RT_NAK: in std_logic;
		MAC_TX_DATA : OUT std_logic_vector(7 downto 0);
		MAC_TX_DATA_VALID : OUT std_logic;
		MAC_TX_EOF : OUT std_logic;
		MAC_TX_CTS : IN std_logic;          
		RTS: out std_logic := '0';
		TP : OUT std_logic_vector(10 downto 1)
		);
	END COMPONENT;

	COMPONENT TCP_SERVER
	GENERIC (
		MSS: std_logic_vector(15 downto 0);
		IPv6_ENABLED: std_logic;
		SIMULATION: std_logic
	);	
	PORT(
		CLK : IN std_logic;
		SYNC_RESET: in std_logic;
		TICK_4US: in std_logic;
		TICK_100MS: in std_logic;
		MAC_ADDR: in std_logic_vector(47 downto 0);
		TCP_LOCAL_PORTS: in SLV16xNTCPSTREAMStype;
		CONNECTION_RESET: in std_logic_vector((NTCPSTREAMS-1) downto 0);
		IP_RX_DATA: in std_logic_vector(7 downto 0);
		IP_RX_DATA_VALID: in std_logic;	
		IP_RX_SOF: in std_logic;
		IP_RX_EOF: in std_logic;
		IP_BYTE_COUNT: in std_logic_vector(15 downto 0);	
		IP_HEADER_FLAG: in std_logic;
		RX_IPv4_6n: in std_logic;
		RX_IP_PROTOCOL: in std_logic_vector(7 downto 0);
	  	RX_IP_PROTOCOL_RDY: in std_logic;
		RX_SOURCE_MAC_ADDR: in std_logic_vector(47 downto 0);
		RX_SOURCE_IP_ADDR: in std_logic_vector(127 downto 0);
		RX_SOURCE_TCP_PORT_NO: in std_logic_vector(15 downto 0);
		RX_TCP_HEADER_FLAG: in std_logic;
		RX_TCP_FLAGS: in std_logic_vector(7 downto 0);
		RX_TCP_CKSUM: in std_logic_vector(16 downto 0);
		RX_TCP_SEQ_NO: in std_logic_vector(31 downto 0);
		RX_TCP_ACK_NO: in std_logic_vector(31 downto 0);
		RX_TCP_WINDOW_SIZE: in std_logic_vector(15 downto 0);
		RX_DEST_TCP_PORT_NO: in std_logic_vector(15 downto 0);
		RX_DATA: out std_logic_vector(7 downto 0);
		RX_DATA_VALID: out std_logic;
		RX_SOF: out std_logic;
		RX_STREAM_NO: out integer range 0 to (NTCPSTREAMS-1);
		RX_EOF: out std_logic;
		RX_FREE_SPACE: in SLV16xNTCPSTREAMStype;
		TX_PACKET_SEQUENCE_START_OUT: out std_logic;	
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
		MAC_TX_EOF: in std_logic;	-- need to know when packet tx is complete
		RTS: out std_logic := '0';
		EFF_RX_WINDOW_SIZE_PARTIAL: out std_logic_vector(16 downto 0);
		EFF_RX_WINDOW_SIZE_PARTIAL_STREAM: out integer range 0 to (NTCPSTREAMS-1) := 0;
		EFF_RX_WINDOW_SIZE_PARTIAL_VALID: out std_logic; -- 1 CLK-wide pulse to indicate that the above information is valid
		TX_SEQ_NO: out SLV17xNTCPSTREAMStype;
		RX_TCP_ACK_NO_D: out SLV17xNTCPSTREAMStype;
		CONNECTED_FLAG: out std_logic_vector((NTCPSTREAMS-1) downto 0);
		TX_STREAM_SEL: in integer range 0 to (NTCPSTREAMS-1) := 0;	
		TX_PAYLOAD_RTS: in std_logic;
		TX_PAYLOAD_SIZE: in std_logic_vector(10 downto 0);
		TP: out std_logic_vector(10 downto 1)
		);
	END COMPONENT;
	
COMPONENT TCP_TXBUF is
	generic (
		NBUFS: integer;
		TX_IDLE_TIMEOUT: integer range 0 to 50;	
		MSS: std_logic_vector(15 downto 0)
	);
    Port ( 
		--//-- CLK, RESET
		CLK: in std_logic;		
		SYNC_RESET: in std_logic;
		TICK_4US: in std_logic;
		APP_DATA: in SLV8xNTCPSTREAMStype;
		APP_DATA_VALID: in std_logic_vector((NTCPSTREAMS-1) downto 0);
		APP_CTS: out std_logic_vector((NTCPSTREAMS-1) downto 0);	
		EFF_RX_WINDOW_SIZE_PARTIAL_IN: in std_logic_vector(16 downto 0);
		EFF_RX_WINDOW_SIZE_PARTIAL_STREAM: in integer range 0 to (NTCPSTREAMS-1) := 0;
		EFF_RX_WINDOW_SIZE_PARTIAL_VALID: in std_logic; -- 1 CLK-wide pulse to indicate that the above information is valid
		TX_SEQ_NO_IN: in SLV17xNTCPSTREAMStype;
		RX_TCP_ACK_NO_D: in SLV17xNTCPSTREAMStype;
		CONNECTED_FLAG: in std_logic_vector((NTCPSTREAMS-1) downto 0);
		TX_STREAM_SEL: out integer range 0 to (NTCPSTREAMS-1) := 0;	
		TX_PAYLOAD_RTS: out std_logic;
		TX_PAYLOAD_CHECKSUM: out std_logic_vector(16 downto 0);
		TX_PAYLOAD_SIZE: out std_logic_vector(10 downto 0);
		TX_PAYLOAD_CTS: in std_logic;
		TX_PAYLOAD_DATA: out std_logic_vector(7 downto 0);
		TX_PAYLOAD_DATA_VALID: out std_logic;
		MAC_TX_EOF: in std_logic;	-- need to know when packet tx is complete
		TP: out std_logic_vector(10 downto 1)

			);
end COMPONENT;
	

	COMPONENT TCP_TX
	GENERIC (
		MSS: std_logic_vector(15 downto 0);	
		IPv6_ENABLED: std_logic
	);	
	PORT(
		ASYNC_RESET : IN std_logic;
		CLK : IN std_logic;
		MAC_ADDR : IN std_logic_vector(47 downto 0);
		IPv4_ADDR : IN std_logic_vector(31 downto 0);
		IPv6_ADDR : IN std_logic_vector(127 downto 0);
		TX_PACKET_SEQUENCE_START : IN std_logic;
		TX_DEST_MAC_ADDR_IN : IN std_logic_vector(47 downto 0);
		TX_DEST_IP_ADDR_IN : IN std_logic_vector(127 downto 0);
		TX_DEST_PORT_NO_IN : IN std_logic_vector(15 downto 0);
		TX_SOURCE_PORT_NO_IN : IN std_logic_vector(15 downto 0);
		TX_IPv4_6n_IN : IN std_logic;
		TX_SEQ_NO_IN : IN std_logic_vector(31 downto 0);
		TX_ACK_NO_IN : IN std_logic_vector(31 downto 0);
		TX_ACK_WINDOW_LENGTH_IN : IN std_logic_vector(15 downto 0);
		IP_ID_IN : IN std_logic_vector(15 downto 0);
		TX_FLAGS_IN : IN std_logic_vector(7 downto 0);
		TX_PACKET_TYPE_IN : IN std_logic_vector(1 downto 0);
		TX_PAYLOAD_DATA : IN std_logic_vector(7 downto 0);
		TX_PAYLOAD_DATA_VALID : IN std_logic;
		TX_PAYLOAD_RTS : IN std_logic;
		TX_PAYLOAD_CTS : OUT std_logic;
		TX_PAYLOAD_SIZE : IN std_logic_vector(10 downto 0);
		TX_PAYLOAD_CHECKSUM: in std_logic_vector(16 downto 0);
		MAC_TX_CTS : IN std_logic;          
		MAC_TX_DATA : OUT std_logic_vector(7 downto 0);
		MAC_TX_DATA_VALID : OUT std_logic;
		MAC_TX_EOF : OUT std_logic;
		TP : OUT std_logic_vector(10 downto 1)
		);
	END COMPONENT;
	

	COMPONENT TCP_RXBUFNDEMUX2
	GENERIC (
		NBUFS: integer
	);	
	PORT(
		SYNC_RESET : IN std_logic;
		CLK : IN std_logic;
		RX_DATA : IN std_logic_vector(7 downto 0);
		RX_DATA_VALID : IN std_logic;
		RX_SOF : IN std_logic;
		RX_STREAM_NO: in integer range 0 to (NTCPSTREAMS-1);
		RX_EOF : IN std_logic;
		RX_FREE_SPACE: OUT SLV16xNTCPSTREAMStype;
		RX_APP_DATA: out SLV8xNTCPSTREAMStype;
		RX_APP_DATA_VALID: out std_logic_vector((NTCPSTREAMS-1) downto 0);
		RX_APP_SOF: out std_logic_vector((NTCPSTREAMS-1) downto 0);
		RX_APP_EOF: out std_logic_vector((NTCPSTREAMS-1) downto 0);
		RX_APP_RTS: out std_logic_vector((NTCPSTREAMS-1) downto 0);
		RX_APP_CTS: in std_logic_vector((NTCPSTREAMS-1) downto 0);
		TP : OUT std_logic_vector(10 downto 1)
		);
	END COMPONENT;


--------------------------------------------------------
--     SIGNALS
--------------------------------------------------------
-- NOTATIONS: 
-- _E as one-CLK early sample
-- _D as one-CLK delayed sample
-- _D2 as two-CLKs delayed sample

--//-- TIMERS -----------------------------
signal TICK_4US: std_logic := '0';
signal TICK_100MS_rt: std_logic := '0';
signal TICK_100MS: std_logic := '0';

--//-- MAC INTERFACE --------------
signal MAC_TX_DATA_VALID_local : std_logic  := '0';
signal MAC_TX_EOF_FLAG : std_logic  := '0';
signal MAC_TX_EOF_local : std_logic  := '0';

--//-- PARSE INCOMING PACKET --------------
signal RX_TYPE: std_logic_vector(3 downto 0) := (others => '0');
signal RX_TYPE_RDY : std_logic  := '0';
signal RX_IPv4_6n : std_logic  := '0';
signal RX_IP_PROTOCOL : std_logic_vector(7 downto 0) := (others => '0');
signal RX_IP_PROTOCOL_RDY : std_logic  := '0';
signal IP_RX_DATA : std_logic_vector(7 downto 0) := (others => '0');
signal IP_RX_DATA_VALID : std_logic  := '0';
signal IP_RX_SOF : std_logic  := '0';
signal IP_RX_EOF : std_logic  := '0';
signal IP_BYTE_COUNT : std_logic_vector(15 downto 0) := (others => '0');
signal IP_HEADER_FLAG : std_logic  := '0';
signal RX_UDP_CKSUM: std_logic_vector(16 downto 0) := (others => '0');
signal RX_UDP_CKSUM_RDY: std_logic := '0';
signal RX_TCP_HEADER_FLAG: std_logic  := '0';
signal RX_TCP_FLAGS: std_logic_vector(7 downto 0) := (others => '0');
signal RX_TCP_CKSUM: std_logic_vector(16 downto 0) := (others => '0');
signal RX_TCP_SEQ_NO: std_logic_vector(31 downto 0) := (others => '0');
signal RX_TCP_ACK_NO: std_logic_vector(31 downto 0) := (others => '0');
signal RX_TCP_WINDOW_SIZE: std_logic_vector(15 downto 0) := (others => '0');
signal RX_DEST_TCP_PORT_NO: std_logic_vector(15 downto 0) := (others => '0');
signal TP_PARSING: std_logic_vector(10 downto 1);
signal RX_SOURCE_MAC_ADDR: std_logic_vector(47 downto 0) := (others => '0');
signal RX_SOURCE_IP_ADDR: std_logic_vector(127 downto 0) := (others => '0');
signal RX_SOURCE_TCP_PORT_NO: std_logic_vector(15 downto 0) := (others => '0');
signal RX_DEST_IP_ADDR: std_logic_vector(127 downto 0) := (others => '0');
signal IP_HEADER_CHECKSUM_VALID: std_logic := '0';
signal IP_HEADER_CHECKSUM_VALID_RDY: std_logic := '0';


--//-- ARP REPLY --------------
signal ARP_MAC_TX_DATA: std_logic_vector(7 downto 0) := x"00";
signal ARP_MAC_TX_DATA_VALID: std_logic := '0';
signal ARP_MAC_TX_EOF: std_logic := '0';
signal ARP_MAC_TX_CTS: std_logic := '0';
signal ARP_RTS: std_logic := '0';
signal TP_ARP: std_logic_vector(10 downto 1);

--//-- PING REPLY --------------
signal PING_MAC_TX_DATA: std_logic_vector(7 downto 0) := x"00";
signal PING_MAC_TX_DATA_VALID: std_logic := '0';
signal PING_MAC_TX_EOF: std_logic := '0';
signal PING_MAC_TX_CTS: std_logic := '0';
signal PING_RTS: std_logic := '0';
signal TP_PING: std_logic_vector(10 downto 1);

--//-- WHOIS ---------------------------------------------
signal WHOIS_IP_ADDR: std_logic_vector(31 downto 0) := (others => '0');
signal WHOIS_START: std_logic := '0';
signal WHOIS_RDY: std_logic := '0';
signal WHOIS_MAC_TX_DATA: std_logic_vector(7 downto 0) := x"00";
signal WHOIS_MAC_TX_DATA_VALID: std_logic := '0';
signal WHOIS_MAC_TX_EOF: std_logic := '0';
signal WHOIS_MAC_TX_CTS: std_logic := '0';
signal WHOIS_RTS: std_logic := '0';
signal TP_WHOIS: std_logic_vector(10 downto 1)  := (others => '0');

--//-- ARP CACHE  -----------------------------------------
signal RT_IP_ADDR: std_logic_vector(31 downto 0) := (others => '0');
signal RT_REQ_RTS: std_logic := '0';
signal RT_CTS: std_logic := '0';
signal RT_MAC_REPLY: std_logic_vector(47 downto 0) := (others => '0');
signal RT_MAC_RDY:  std_logic := '0';
signal RT_NAK:  std_logic := '0';
signal TP_ARP_CACHE2: std_logic_vector(10 downto 1)  := (others => '0');


--//-- UDP RX ------------------------------------
signal TP_UDP_RX: std_logic_vector(10 downto 1) := (others => '0');

--//-- UDP TX ------------------------------------
signal UDP001_RT_REQ_RTS: std_logic := '0';
signal UDP001_RT_REQ_CTS: std_logic := '0';
signal UDP001_RT_IP_ADDR: std_logic_vector(31 downto 0) := (others => '0');
signal UDP001_RT_MAC_RDY: std_logic := '0';
signal UDP001_RT_NAK: std_logic := '0';
signal UDP001_MAC_TX_DATA: std_logic_vector(7 downto 0) := x"00";
signal UDP001_MAC_TX_DATA_VALID: std_logic := '0';
signal UDP001_MAC_TX_EOF: std_logic := '0';
signal UDP001_MAC_TX_CTS: std_logic := '0';
signal UDP001_RTS: std_logic := '0';
signal TP_UDP_TX: std_logic_vector(10 downto 1) := (others => '0');
signal UDP_TX_ACK_local: std_logic := '0';
signal UDP_TX_NAK_local: std_logic := '0';

--//-- TCP RX ------------------------------------
-- TCP server 001
signal TCP_LOCAL_PORTS: SLV16xNTCPSTREAMStype;
signal TCP001_MAC_TX_DATA: std_logic_vector(7 downto 0) := x"00";
signal TCP001_MAC_TX_DATA_VALID: std_logic := '0';
signal TCP001_MAC_TX_EOF: std_logic := '0';
signal TCP001_MAC_TX_CTS: std_logic := '0';
signal TCP001_RTS: std_logic := '0';
signal TCP001_RX_DATA: std_logic_vector(7 downto 0) := x"00";
signal TCP001_RX_DATA_VALID: std_logic := '0';
signal TCP001_RX_SOF: std_logic := '0';
signal TCP001_RX_STREAM_NO: integer range 0 to (NTCPSTREAMS-1);	
signal TCP001_RX_EOF: std_logic := '0';
signal TCP001_RX_FREE_SPACE: SLV16xNTCPSTREAMStype;
signal TCP001_TX_PACKET_SEQUENCE_START: std_logic  := '0';
signal TCP001_TX_DEST_MAC_ADDR: std_logic_vector(47 downto 0) := (others => '0');
signal TCP001_TX_DEST_IP_ADDR: std_logic_vector(127 downto 0) := (others => '0');
signal TCP001_TX_DEST_PORT_NO: std_logic_vector(15 downto 0) := (others => '0');
signal TCP001_TX_SOURCE_PORT_NO: std_logic_vector(15 downto 0) := (others => '0');
signal TCP001_TX_IPv4_6n: std_logic  := '0';
signal TCP001_TX_SEQ_NO: std_logic_vector(31 downto 0) := (others => '0');
signal TCP001_TX_ACK_NO: std_logic_vector(31 downto 0) := (others => '0');
signal TCP001_TX_ACK_WINDOW_LENGTH: std_logic_vector(15 downto 0) := (others => '0');
signal TCP001_TX_FLAGS: std_logic_vector(7 downto 0) := (others => '0');
signal TCP001_TX_PACKET_TYPE: std_logic_vector(1 downto 0) := (others => '0');
signal TCP001_EFF_RX_WINDOW_SIZE_PARTIAL: std_logic_vector(16 downto 0) := (others => '0');
signal TCP001_EFF_RX_WINDOW_SIZE_PARTIAL_STREAM: integer range 0 to (NTCPSTREAMS-1);
signal TCP001_EFF_RX_WINDOW_SIZE_PARTIAL_VALID: std_logic := '0'; -- 1 CLK-wide pulse to indicate that the above information is valid
signal TCP001_TX_SEQ_NOxNTCPSTREAMS: SLV17xNTCPSTREAMStype;
signal TCP001_RX_ACK_NOxNTCPSTREAMS: SLV17xNTCPSTREAMStype;
signal TCP001_CONNECTED_FLAG: std_logic_vector((NTCPSTREAMS-1) downto 0) := (others => '0');
signal TCP001_TX_PAYLOAD_DATA: std_logic_vector(7 downto 0) := x"00";
signal TCP001_TX_PAYLOAD_DATA_VALID: std_logic := '0';
signal TCP001_TX_PAYLOAD_RTS: std_logic := '0';
signal TCP001_TX_PAYLOAD_CTS: std_logic := '0';
signal TCP001_TX_PAYLOAD_SIZE: std_logic_vector(10 downto 0) := (others => '0');
signal TCP001_TX_PAYLOAD_CHECKSUM: std_logic_vector(16 downto 0) := "0" & x"0000";
signal TCP001_TX_STREAM_SEL: integer range 0 to (NTCPSTREAMS-1);	
signal TCP001_TCP_TX_CTS: std_logic_vector((NTCPSTREAMS-1) downto 0) := (others => '0');	
signal TP_TCP_SERVER: std_logic_vector(10 downto 1);
signal TP_TCP_TXBUF: std_logic_vector(10 downto 1);

-- TCP server 002
--signal TCP_LOCAL_PORTS: SLV16xNTCPSTREAMStype;
--signal TCP002_MAC_TX_DATA: std_logic_vector(7 downto 0) := x"00";
--signal TCP002_MAC_TX_DATA_VALID: std_logic := '0';
--signal TCP002_MAC_TX_EOF: std_logic := '0';
--signal TCP002_MAC_TX_CTS: std_logic := '0';
--signal TCP002_RTS: std_logic := '0';
--signal TCP002_RX_DATA: std_logic_vector(7 downto 0) := x"00";
--signal TCP002_RX_DATA_VALID: std_logic := '0';
--signal TCP002_RX_SOF: std_logic := '0';
--signal TCP002_RX_STREAM_NO: integer range 0 to (NTCPSTREAMS-1);
--signal TCP002_RX_EOF: std_logic := '0';
--signal TCP002_RX_FREE_SPACE: std_logic_vector(15 downto 0) := x"0400";
--signal TCP002_TX_PACKET_SEQUENCE_START: std_logic  := '0';
--signal TCP002_TX_DEST_MAC_ADDR: std_logic_vector(47 downto 0) := (others => '0');
--signal TCP002_TX_DEST_IP_ADDR: std_logic_vector(127 downto 0) := (others => '0');
--signal TCP002_TX_DEST_PORT_NO: std_logic_vector(15 downto 0) := (others => '0');
--signal TCP002_TX_SOURCE_PORT_NO: std_logic_vector(15 downto 0) := (others => '0');
--signal TCP002_TX_IPv4_6n: std_logic  := '0';
--signal TCP002_TX_SEQ_NO: std_logic_vector(31 downto 0) := (others => '0');
--signal TCP002_TX_ACK_NO: std_logic_vector(31 downto 0) := (others => '0');
--signal TCP002_TX_ACK_WINDOW_LENGTH: std_logic_vector(15 downto 0) := (others => '0');
--signal TCP002_TX_FLAGS: std_logic_vector(7 downto 0) := (others => '0');
--signal TCP002_TX_PACKET_TYPE: std_logic_vector(1 downto 0) := (others => '0');
--signal TCP002_EFF_RX_WINDOW_SIZE_PARTIAL: std_logic_vector(15 downto 0) := (others => '0');
--signal TCP002_EFF_RX_WINDOW_SIZE_PARTIAL_STREAM: integer range 0 to (NTCPSTREAMS-1);
--signal TCP002_EFF_RX_WINDOW_SIZE_PARTIAL_VALID: std_logic := '0'; -- 1 CLK-wide pulse to indicate that the above information is valid
--signal TCP002_TX_SEQ_NOxNTCPSTREAMS: SLV16xNTCPSTREAMStype;
--signal TCP002_RX_ACK_NOxNTCPSTREAMS: SLV16xNTCPSTREAMStype;
--signal TCP002_CONNECTED_FLAG: std_logic_vector((NTCPSTREAMS-1) downto 0) := (others => '0');
--signal TCP002_TX_PAYLOAD_DATA: std_logic_vector(7 downto 0) := x"00";
--signal TCP002_TX_PAYLOAD_DATA_VALID: std_logic := '0';
--signal TCP002_TX_PAYLOAD_RTS: std_logic := '0';
--signal TCP002_TX_PAYLOAD_CTS: std_logic := '0';
--signal TCP002_TX_PAYLOAD_SIZE: std_logic_vector(10 downto 0) := (others => '0');
--signal TCP002_TX_PAYLOAD_CHECKSUM: std_logic_vector(16 downto 0) := "0" & x"0000";
--signal TCP002_TX_STREAM_SEL: integer range 0 to (NTCPSTREAMS-1);	
--signal TCP002_TCP_TX_CTS: std_logic_vector((NTCPSTREAMS-1) downto 0) := (others => '0');	

--//-- APP -> TCP TX BUFFER
signal TCP_TXBUF_DATA: std_logic_vector(7 downto 0) := x"00";
signal TCP_TXBUF_DATA_VALID: std_logic := '0';
signal TCP_TXBUF_SOF: std_logic := '0';
signal TCP_TXBUF_EOF: std_logic := '0';
signal TCP_TXBUF_RTS: std_logic := '0';
signal TCP_TXBUF_CTS: std_logic := '0';
--???signal TCP_TXBUF_PAYLOAD_SIZE: std_logic_vector(15 downto 0) := x"0000";
signal TCP_TXBUF_PARTIAL_CKSUM: std_logic_vector(15 downto 0) := x"0000";
signal TCP_TXBUF_RPTR: std_logic_vector(31 downto 0) := x"00000000";
signal TCP_TXBUF_RPTR_CONFIRMED: std_logic_vector(31 downto 0) := x"00000000";


--//-- TRANSMISSION ARBITER --------------
signal IP_ID: std_logic_vector(15 downto 0) := x"0000";
signal TX_MUX_STATE: integer range 0 to 10;	-- up to 6 protocol engines. Increase size if more.

--//-- ROUTING TABLE ARBITER --------------
signal RT_MUX_STATE: integer range 0 to 10;	
	-- 1 + number of transmit components vying for access to the routing table. Adjust as needed.

--//-- TEST POINTS 
------------------------------------------------------
--      IMPLEMENTATION
--------------------------------------------------------
begin

--//-- TIMERS -----------------------------
	Inst_TIMER_4US: TIMER_4US 
	GENERIC MAP(
		CLK_FREQUENCY => CLK_FREQUENCY
	)
	PORT MAP(
		ASYNC_RESET => ASYNC_RESET,
		CLK => CLK,
		TICK_4US => TICK_4US,
		TICK_100MS => TICK_100MS_rt
	);

TICK_100MS <= TICK_4US when (SIMULATION = '1') else TICK_100MS_rt;	-- to accelerate simulations


--//-- PARSE INCOMING PACKET --------------
-- Code is common to all protocols. Extracts key information from incoming packets.
	Inst_PACKET_PARSING: PACKET_PARSING 
	GENERIC MAP(
		IPv6_ENABLED => IPv6_ENABLED,
		SIMULATION => SIMULATION
	)
	PORT MAP(
		ASYNC_RESET => ASYNC_RESET,
		CLK => CLK,
		TICK_4US => TICK_4US,
		MAC_RX_DATA => MAC_RX_DATA,
		MAC_RX_DATA_VALID => MAC_RX_DATA_VALID,
		MAC_RX_SOF => MAC_RX_SOF,
		MAC_RX_EOF => MAC_RX_EOF,
		IPv4_ADDR => IPv4_ADDR,
		IPv6_ADDR => IPv6_ADDR,
		IP_RX_DATA => IP_RX_DATA,
		IP_RX_DATA_VALID => IP_RX_DATA_VALID,
		IP_RX_SOF => IP_RX_SOF,
		IP_RX_EOF => IP_RX_EOF,
		IP_BYTE_COUNT => IP_BYTE_COUNT,
		IP_HEADER_FLAG => IP_HEADER_FLAG,
		RX_TYPE => RX_TYPE,
		RX_TYPE_RDY => RX_TYPE_RDY,
		RX_IPv4_6n => RX_IPv4_6n,
		RX_IP_PROTOCOL => RX_IP_PROTOCOL,
		RX_IP_PROTOCOL_RDY => RX_IP_PROTOCOL_RDY,
		VALID_DEST_IP => open,
		VALID_DEST_IP_RDY => open,
		IP_HEADER_CHECKSUM_VALID => IP_HEADER_CHECKSUM_VALID,
		IP_HEADER_CHECKSUM_VALID_RDY => IP_HEADER_CHECKSUM_VALID_RDY,
		RX_SOURCE_MAC_ADDR => RX_SOURCE_MAC_ADDR,
		RX_SOURCE_IP_ADDR => RX_SOURCE_IP_ADDR,
		RX_SOURCE_TCP_PORT_NO => RX_SOURCE_TCP_PORT_NO,
		RX_DEST_IP_ADDR => RX_DEST_IP_ADDR,
		RX_DEST_TCP_PORT_NO => RX_DEST_TCP_PORT_NO,
		RX_UDP_CKSUM => RX_UDP_CKSUM,
		RX_UDP_CKSUM_RDY => RX_UDP_CKSUM_RDY,
--		RX_TCP_BYTE_COUNT => RX_TCP_BYTE_COUNT,
		RX_TCP_HEADER_FLAG => RX_TCP_HEADER_FLAG,
		RX_TCP_FLAGS => RX_TCP_FLAGS,
		RX_TCP_CKSUM => RX_TCP_CKSUM,
		RX_TCP_SEQ_NO => RX_TCP_SEQ_NO,
		RX_TCP_ACK_NO => RX_TCP_ACK_NO,
		RX_TCP_WINDOW_SIZE => RX_TCP_WINDOW_SIZE,
		CS1 => open,
		CS1_CLK => open,
		CS2 => open,
		CS2_CLK => open,
		TP => TP_PARSING
	);
	
	
--//-- ARP REPLY --------------
-- Instantiated once per PHY.   IPv4-only. Use NDP for IPv6.
	Inst_ARP: ARP 
	PORT MAP(
		ASYNC_RESET => ASYNC_RESET,
		CLK => CLK,
		MAC_RX_DATA => MAC_RX_DATA,
		MAC_RX_DATA_VALID => MAC_RX_DATA_VALID,
		MAC_RX_SOF => MAC_RX_SOF,
		MAC_RX_EOF => MAC_RX_EOF,
		MAC_ADDR => MAC_ADDR,
		IPv4_ADDR => IPv4_ADDR,
		RX_TYPE => RX_TYPE,
		RX_TYPE_RDY => RX_TYPE_RDY,
		RX_SOURCE_MAC_ADDR => RX_SOURCE_MAC_ADDR,
		RX_SOURCE_IP_ADDR => RX_SOURCE_IP_ADDR(31 downto 0),
		MAC_TX_DATA => ARP_MAC_TX_DATA,
		MAC_TX_DATA_VALID => ARP_MAC_TX_DATA_VALID,
		MAC_TX_EOF => ARP_MAC_TX_EOF,
		MAC_TX_CTS => ARP_MAC_TX_CTS,
		RTS => ARP_RTS,
		TP => TP_ARP
	);
	
--//-- PING REPLY --------------
-- Instantiated once per PHY.
	Inst_PING: PING 
	GENERIC MAP(
		IPv6_ENABLED => IPv6_ENABLED,
		MAX_PING_SIZE => x"0200"	-- 512 byte threshold for ping requests
	)
	PORT MAP(
		ASYNC_RESET => ASYNC_RESET,
		CLK => CLK,
		MAC_RX_DATA => MAC_RX_DATA,
		MAC_RX_DATA_VALID => MAC_RX_DATA_VALID,
		MAC_RX_SOF => MAC_RX_SOF,
		MAC_RX_EOF => MAC_RX_EOF,
		MAC_ADDR => MAC_ADDR,
		IPv4_ADDR => IPv4_ADDR,
		IPv6_ADDR => IPv6_ADDR,
		RX_IPv4_6n => RX_IPv4_6n,
		RX_IP_PROTOCOL => RX_IP_PROTOCOL,
		RX_IP_PROTOCOL_RDY => RX_IP_PROTOCOL_RDY,
		IP_RX_DATA_VALID => IP_RX_DATA_VALID,
		IP_RX_EOF => IP_RX_EOF,		
		MAC_TX_DATA => PING_MAC_TX_DATA,	
		MAC_TX_DATA_VALID => PING_MAC_TX_DATA_VALID,
		MAC_TX_EOF => PING_MAC_TX_EOF,
		MAC_TX_CTS => PING_MAC_TX_CTS,
		RTS => PING_RTS,
		TP => TP_PING
	);
	
--//-- WHOIS ---------------------------------------------
-- Sends ARP requests 
-- Currently only used by UDP tx
WHOIS2_X: if(NUDPTX /= 0) generate
	WHOIS2_001: WHOIS2 PORT MAP(
		SYNC_RESET => SYNC_RESET,
		CLK => CLK,
		WHOIS_IP_ADDR => WHOIS_IP_ADDR,
		WHOIS_START => WHOIS_START,
		WHOIS_RDY => WHOIS_RDY,  -- unused
		MAC_ADDR => MAC_ADDR,
		IPv4_ADDR => IPv4_ADDR,
		MAC_TX_DATA => WHOIS_MAC_TX_DATA,
		MAC_TX_DATA_VALID => WHOIS_MAC_TX_DATA_VALID,
		MAX_TX_EOF => WHOIS_MAC_TX_EOF,
		MAC_TX_CTS => WHOIS_MAC_TX_CTS,
		RTS => WHOIS_RTS,
		TP => TP_WHOIS
	);
end generate;

--//-- ARP CACHE  (ROUTING TABLE) -----------------------------------------
-- Routing table mapping destination IP addresses and associated MAC addresses.
-- Currently only used by UDP tx
ARP_CACHE2_X: if(NUDPTX /= 0) generate
	ARP_CACHE2_001: ARP_CACHE2 PORT MAP(
		SYNC_RESET => SYNC_RESET,
		CLK => CLK,
		TICK_100MS => TICK_100MS,
		RT_IP_ADDR => RT_IP_ADDR,	
		RT_REQ_RTS => RT_REQ_RTS,	
		RT_CTS => RT_CTS,	
		RT_MAC_REPLY => RT_MAC_REPLY,
		RT_MAC_RDY => RT_MAC_RDY,
		RT_NAK => RT_NAK,
		MAC_ADDR => MAC_ADDR,
		IPv4_ADDR => IPv4_ADDR,
		SUBNET_MASK => SUBNET_MASK,
		GATEWAY_IP_ADDR => GATEWAY_IP_ADDR,
		WHOIS_IP_ADDR => WHOIS_IP_ADDR,
		WHOIS_START => WHOIS_START,
		RX_SOURCE_ADDR_RDY => MAC_RX_EOF,
		RX_SOURCE_MAC_ADDR => RX_SOURCE_MAC_ADDR,
		RX_SOURCE_IP_ADDR => RX_SOURCE_IP_ADDR(31 downto 0),	-- IPv4 only
		SREG1 => open,
		SREG2 => open,
		SREG3 => open,
		SREG4 => open,
		SREG5 => open,
		SREG6 => open,
		TP => TP_ARP_CACHE2
	);
end generate;

--//-- UDP RX to Serial (Monitoring and control) ---------
	Inst_UDP2SERIAL: UDP2SERIAL 
	GENERIC MAP(
		PORT_NO => x"0405",  --1029
		CLK_FREQUENCY => CLK_FREQUENCY
	)
	PORT MAP(
		ASYNC_RESET => ASYNC_RESET,
		CLK => CLK,
		IP_RX_DATA => IP_RX_DATA,
		IP_RX_DATA_VALID => IP_RX_DATA_VALID,
		IP_RX_SOF => IP_RX_SOF,
		IP_RX_EOF => IP_RX_EOF,
		IP_HEADER_FLAG => IP_HEADER_FLAG,
		RX_IP_PROTOCOL => RX_IP_PROTOCOL,
		RX_IP_PROTOCOL_RDY => RX_IP_PROTOCOL_RDY,
		SERIAL_OUT => open,
		TP => open
	);

--//-- UDP RX ------------------------------------
UDP_RX_X: if(NUDPRX /= 0) generate
	UDP_RX_001: UDP_RX 
	PORT MAP(
		ASYNC_RESET => ASYNC_RESET,
		CLK => CLK,
		IP_RX_DATA => IP_RX_DATA,
		IP_RX_DATA_VALID => IP_RX_DATA_VALID,
		IP_RX_SOF => IP_RX_SOF,
		IP_RX_EOF => IP_RX_EOF,
		IP_BYTE_COUNT => IP_BYTE_COUNT,
		IP_HEADER_FLAG => IP_HEADER_FLAG,
		RX_IP_PROTOCOL => RX_IP_PROTOCOL,
		RX_IP_PROTOCOL_RDY => RX_IP_PROTOCOL_RDY,
		RX_UDP_CKSUM => RX_UDP_CKSUM,
		RX_UDP_CKSUM_RDY => RX_UDP_CKSUM_RDY,
		-- configuration
		PORT_NO => UDP_RX_DEST_PORT_NO,
		-- Application interface
		APP_DATA => UDP_RX_DATA,
		APP_DATA_VALID => UDP_RX_DATA_VALID,
		APP_SOF => UDP_RX_SOF,
		APP_EOF => UDP_RX_EOF,
		APP_SRC_UDP_PORT => open,
		TP => TP_UDP_RX
	);
end generate;


--//-- UDP TX ------------------------------------
UDP_TX_NZ: if(NUDPTX /= 0) generate
	UDP_TX_001: UDP_TX 
	GENERIC MAP(
		NBUFS => 1,
		IPv6_ENABLED => '0'
	)
	PORT MAP(
		CLK => CLK,
		SYNC_RESET => SYNC_RESET,
		TICK_4US => TICK_4US,
		-- Application interface
		APP_DATA => UDP_TX_DATA,
		APP_DATA_VALID => UDP_TX_DATA_VALID,
		APP_SOF => UDP_TX_SOF,
		APP_EOF => UDP_TX_EOF,
		APP_CTS => UDP_TX_CTS,
		ACK => UDP_TX_ACK_local,
		NAK => UDP_TX_NAK_local,
		DEST_IP_ADDR => UDP_TX_DEST_IP_ADDR,
		DEST_PORT_NO => UDP_TX_DEST_PORT_NO,
		SOURCE_PORT_NO => UDP_TX_SOURCE_PORT_NO,	
		IPv4_6n => '1',
		-- Configuration
		MAC_ADDR => MAC_ADDR,
		IPv4_ADDR => IPv4_ADDR,
		IPv6_ADDR => IPv6_ADDR,
		IP_ID => IP_ID,
		-- Routing
		RT_IP_ADDR => UDP001_RT_IP_ADDR,
		RT_REQ_RTS => UDP001_RT_REQ_RTS,
		RT_REQ_CTS => UDP001_RT_REQ_CTS,
		RT_MAC_REPLY => RT_MAC_REPLY,
		RT_MAC_RDY => UDP001_RT_MAC_RDY,
		RT_NAK => UDP001_RT_NAK,
		-- MAC interface
		MAC_TX_DATA => UDP001_MAC_TX_DATA,
		MAC_TX_DATA_VALID => UDP001_MAC_TX_DATA_VALID,
		MAC_TX_EOF => UDP001_MAC_TX_EOF,
		MAC_TX_CTS => UDP001_MAC_TX_CTS,
		RTS => UDP001_RTS,
		TP => TP_UDP_TX
	);
end generate;
UDP_TX_ACK <= UDP_TX_ACK_local;
UDP_TX_NAK <= UDP_TX_NAK_local;

--//-- TCP SERVER 001 ------------------------------------
-- declare the port number for each TCP stream (NTCPSTREAMS streams, declared in com5402pkg)
TCP_SERVER_X: if (NTCPSTREAMS /= 0) generate
	-- TCP_SERVER does the conversion between TCP port number and stream number (and vice versa)
	TCP_LOCAL_PORTS(0) <= x"0400";	--  port 1024
	--TCP_LOCAL_PORTS(1) <= x"0401";	--  port 1025
	--TCP_LOCAL_PORTS(2) <= x"0402";	--  port 1026

		TCP_SERVER_001: TCP_SERVER 
		GENERIC MAP(
			MSS => x"05B4",	-- 1460 bytes	
			IPv6_ENABLED => IPv6_ENABLED,
			SIMULATION => SIMULATION
		)
		PORT MAP(
			CLK => CLK,
			SYNC_RESET => SYNC_RESET,
			TICK_4US => TICK_4US,
			TICK_100MS => TICK_100MS,
			MAC_ADDR => MAC_ADDR,
			TCP_LOCAL_PORTS => TCP_LOCAL_PORTS,
			CONNECTION_RESET => CONNECTION_RESET,
			IP_RX_DATA => IP_RX_DATA,
			IP_RX_DATA_VALID => IP_RX_DATA_VALID,
			IP_RX_SOF => IP_RX_SOF,
			IP_RX_EOF => IP_RX_EOF,
			IP_BYTE_COUNT => IP_BYTE_COUNT,
			IP_HEADER_FLAG => IP_HEADER_FLAG,
			RX_IPv4_6n => RX_IPv4_6n,
			RX_IP_PROTOCOL => RX_IP_PROTOCOL,
			RX_IP_PROTOCOL_RDY => RX_IP_PROTOCOL_RDY,
			RX_SOURCE_MAC_ADDR => RX_SOURCE_MAC_ADDR,
			RX_SOURCE_IP_ADDR => RX_SOURCE_IP_ADDR,
			RX_SOURCE_TCP_PORT_NO => RX_SOURCE_TCP_PORT_NO,
	--		RX_TCP_BYTE_COUNT => RX_TCP_BYTE_COUNT,
			RX_TCP_HEADER_FLAG => RX_TCP_HEADER_FLAG,
			RX_TCP_FLAGS => RX_TCP_FLAGS,
			RX_TCP_CKSUM => RX_TCP_CKSUM,
			RX_TCP_SEQ_NO => RX_TCP_SEQ_NO,
			RX_TCP_ACK_NO => RX_TCP_ACK_NO,
			RX_TCP_WINDOW_SIZE => RX_TCP_WINDOW_SIZE,
			RX_DEST_TCP_PORT_NO => RX_DEST_TCP_PORT_NO,
			RX_DATA => TCP001_RX_DATA,
			RX_DATA_VALID => TCP001_RX_DATA_VALID,
			RX_SOF => TCP001_RX_SOF,
			RX_STREAM_NO => TCP001_RX_STREAM_NO,
			RX_EOF => TCP001_RX_EOF,
			RX_FREE_SPACE => TCP001_RX_FREE_SPACE,	
			TX_PACKET_SEQUENCE_START_OUT => TCP001_TX_PACKET_SEQUENCE_START,
			TX_DEST_MAC_ADDR_OUT => TCP001_TX_DEST_MAC_ADDR,
			TX_DEST_IP_ADDR_OUT => TCP001_TX_DEST_IP_ADDR,
			TX_DEST_PORT_NO_OUT => TCP001_TX_DEST_PORT_NO,
			TX_SOURCE_PORT_NO_OUT => TCP001_TX_SOURCE_PORT_NO,
			TX_IPv4_6n_OUT => TCP001_TX_IPv4_6n,
			TX_SEQ_NO_OUT => TCP001_TX_SEQ_NO,
			TX_ACK_NO_OUT => TCP001_TX_ACK_NO,
			TX_ACK_WINDOW_LENGTH_OUT => TCP001_TX_ACK_WINDOW_LENGTH,
			TX_FLAGS_OUT => TCP001_TX_FLAGS,
			TX_PACKET_TYPE_OUT => TCP001_TX_PACKET_TYPE,
			MAC_TX_EOF => TCP001_MAC_TX_EOF,
			RTS => TCP001_RTS,
			EFF_RX_WINDOW_SIZE_PARTIAL => TCP001_EFF_RX_WINDOW_SIZE_PARTIAL,
			EFF_RX_WINDOW_SIZE_PARTIAL_STREAM => TCP001_EFF_RX_WINDOW_SIZE_PARTIAL_STREAM,
			EFF_RX_WINDOW_SIZE_PARTIAL_VALID => TCP001_EFF_RX_WINDOW_SIZE_PARTIAL_VALID,
			TX_SEQ_NO => TCP001_TX_SEQ_NOxNTCPSTREAMS,
			RX_TCP_ACK_NO_D => TCP001_RX_ACK_NOxNTCPSTREAMS,
			TX_STREAM_SEL => TCP001_TX_STREAM_SEL,
			TX_PAYLOAD_RTS => TCP001_TX_PAYLOAD_RTS,
			TX_PAYLOAD_SIZE => TCP001_TX_PAYLOAD_SIZE,
			CONNECTED_FLAG => TCP001_CONNECTED_FLAG,
			TP => TP_TCP_SERVER
		);

		
	-- assemble tx packet (MAC/IP/TCP)
		Inst_TCP_TX: TCP_TX 
		GENERIC MAP(
			MSS => x"05B4",	-- 1460 bytes	
			IPv6_ENABLED => IPv6_ENABLED
		)
		PORT MAP(
			ASYNC_RESET => ASYNC_RESET,
			CLK => CLK,
			MAC_ADDR => MAC_ADDR,
			IPv4_ADDR => IPv4_ADDR,
			IPv6_ADDR => IPv6_ADDR,
			TX_PACKET_SEQUENCE_START => TCP001_TX_PACKET_SEQUENCE_START,
			TX_DEST_MAC_ADDR_IN => TCP001_TX_DEST_MAC_ADDR,
			TX_DEST_IP_ADDR_IN => TCP001_TX_DEST_IP_ADDR,
			TX_DEST_PORT_NO_IN => TCP001_TX_DEST_PORT_NO,
			TX_SOURCE_PORT_NO_IN => TCP001_TX_SOURCE_PORT_NO,
			TX_IPv4_6n_IN => TCP001_TX_IPv4_6n,
			TX_SEQ_NO_IN => TCP001_TX_SEQ_NO,
			TX_ACK_NO_IN => TCP001_TX_ACK_NO,
			TX_ACK_WINDOW_LENGTH_IN => TCP001_TX_ACK_WINDOW_LENGTH,
			IP_ID_IN => IP_ID,
			TX_FLAGS_IN => TCP001_TX_FLAGS,
			TX_PACKET_TYPE_IN => TCP001_TX_PACKET_TYPE,
			TX_PAYLOAD_DATA => TCP001_TX_PAYLOAD_DATA,
			TX_PAYLOAD_DATA_VALID => TCP001_TX_PAYLOAD_DATA_VALID,
			TX_PAYLOAD_RTS => TCP001_TX_PAYLOAD_RTS,
			TX_PAYLOAD_CTS => TCP001_TX_PAYLOAD_CTS,
			TX_PAYLOAD_SIZE => TCP001_TX_PAYLOAD_SIZE,
			TX_PAYLOAD_CHECKSUM => TCP001_TX_PAYLOAD_CHECKSUM,
			MAC_TX_DATA => TCP001_MAC_TX_DATA,	
			MAC_TX_DATA_VALID => TCP001_MAC_TX_DATA_VALID,
			MAC_TX_EOF => TCP001_MAC_TX_EOF,
			MAC_TX_CTS => TCP001_MAC_TX_CTS,
			TP => open
		);


		Inst_TCP_RXBUFNDEMUX2: TCP_RXBUFNDEMUX2 
		GENERIC MAP(
			NBUFS => 8		-- must be large enough to include 2 MSS per enabled TCP stream. Min = 2. Recommended 4 or 8.
		)
		PORT MAP(
			SYNC_RESET => SYNC_RESET,
			CLK => CLK,
			RX_DATA => TCP001_RX_DATA,
			RX_DATA_VALID => TCP001_RX_DATA_VALID,
			RX_SOF => TCP001_RX_SOF,
			RX_STREAM_NO => TCP001_RX_STREAM_NO,
			RX_EOF => TCP001_RX_EOF,
			RX_FREE_SPACE => TCP001_RX_FREE_SPACE,	
			RX_APP_DATA => TCP_RX_DATA,
			RX_APP_DATA_VALID => TCP_RX_DATA_VALID,
			RX_APP_SOF => open,
			RX_APP_EOF => open,
			RX_APP_CTS => TCP_RX_CTS,
			RX_APP_RTS => TCP_RX_RTS,
			TP => open
		);

		Inst_TCP_TXBUF: TCP_TXBUF 
		GENERIC MAP(
			NBUFS => 8,
			TX_IDLE_TIMEOUT => TX_IDLE_TIMEOUT,
			MSS => x"05B4"	-- 1460 bytes, consistent with Ethernet MTU of 1500 bytes.
		)
		PORT MAP(
			CLK => CLK,
			SYNC_RESET => SYNC_RESET,
			TICK_4US => TICK_4US,
			-- application interface -------
			APP_DATA => TCP_TX_DATA,
			APP_DATA_VALID => TCP_TX_DATA_VALID,
			APP_CTS => TCP001_TCP_TX_CTS,
			-- TCP_SERVER interface -------
			EFF_RX_WINDOW_SIZE_PARTIAL_IN => TCP001_EFF_RX_WINDOW_SIZE_PARTIAL,
			EFF_RX_WINDOW_SIZE_PARTIAL_STREAM => TCP001_EFF_RX_WINDOW_SIZE_PARTIAL_STREAM,
			EFF_RX_WINDOW_SIZE_PARTIAL_VALID => TCP001_EFF_RX_WINDOW_SIZE_PARTIAL_VALID,
			TX_SEQ_NO_IN => TCP001_TX_SEQ_NOxNTCPSTREAMS,
			RX_TCP_ACK_NO_D => TCP001_RX_ACK_NOxNTCPSTREAMS,
			CONNECTED_FLAG => TCP001_CONNECTED_FLAG,
			TX_STREAM_SEL => TCP001_TX_STREAM_SEL,
			-- TCP_TX interface -------
			TX_PAYLOAD_DATA => TCP001_TX_PAYLOAD_DATA,
			TX_PAYLOAD_DATA_VALID => TCP001_TX_PAYLOAD_DATA_VALID,
			TX_PAYLOAD_RTS => TCP001_TX_PAYLOAD_RTS,
			TX_PAYLOAD_CTS => TCP001_TX_PAYLOAD_CTS,
			TX_PAYLOAD_SIZE => TCP001_TX_PAYLOAD_SIZE,
			TX_PAYLOAD_CHECKSUM => TCP001_TX_PAYLOAD_CHECKSUM,
			MAC_TX_EOF => TCP001_MAC_TX_EOF,
			TP => TP_TCP_TXBUF
		);
		TCP_TX_CTS <= TCP001_TCP_TX_CTS;
end generate;
	
 --//-- IP ID generation
-- Increment IP ID every time an IP datagram is sent
IP_ID_GEN_001: process(ASYNC_RESET, CLK)
begin
	if(ASYNC_RESET = '1') then
		IP_ID <= (others => '0');	
	elsif rising_edge(CLK) then
		if(TCP001_MAC_TX_EOF = '1') or (UDP001_MAC_TX_EOF = '1') then
--		if(TCP001_MAC_TX_EOF = '1') or (TCP002_MAC_TX_EOF = '1') or (UDP001_MAC_TX_EOF = '1') then
			-- increment every time an IP packet is send. 
			-- Adjust as needed when other IP/UDP/TCP components are instantiated
			IP_ID <= IP_ID + 1;
		end if;
	end if;
end process;

	
--//-- TRANSMISSION ARBITER --------------
-- determines the source for the next packet to be transmitted.
-- State machine to prevent overlapping between two packets ready... 
-- For example, one has to wait until a UDP packet has completed transmission 
-- before starting to send a TCP packet.
TX_MUX_001: process(CLK)
begin
	if rising_edge(CLK) then
		if(SYNC_RESET = '1') then
			TX_MUX_STATE <= 0;	-- idle
		elsif(TX_MUX_STATE = 0) and (MAC_TX_CTS = '1') then
			-- from idle to ...
			if(ARP_RTS = '1') then
				TX_MUX_STATE <= 1;	-- enable ARP response
			elsif(PING_RTS = '1') then
				TX_MUX_STATE <= 2;	-- enable PING response
			elsif(TCP001_RTS = '1') and (NTCPSTREAMS /= 0) then
				TX_MUX_STATE <= 3;	-- enable TCP001 transmission 
			elsif(WHOIS_RTS = '1') and (NUDPTX /= 0) then
				TX_MUX_STATE <= 4;	-- enable WHOIS transmission
			elsif(UDP001_RTS = '1') and (NUDPTX /= 0) then
				TX_MUX_STATE <= 5;	-- enable UDP001 transmission (duplicate as needed)
--			elsif(TCP002_RTS = '1') and (NTCPSTREAMS /= 0) then
--				TX_MUX_STATE <= 6;	-- enable TCP002 transmission 
			end if;

		-- Done transmitting. go from ... to idle
	 	elsif(TX_MUX_STATE = 1) and (ARP_MAC_TX_EOF = '1') then
			TX_MUX_STATE <= 0;	-- idle
	 	elsif(TX_MUX_STATE = 2) and (PING_MAC_TX_EOF = '1') then
			TX_MUX_STATE <= 0;	-- idle
	 	elsif(TX_MUX_STATE = 3) and (TCP001_MAC_TX_EOF = '1') and (NTCPSTREAMS /= 0)  then 
			TX_MUX_STATE <= 0;	-- idle
	 	elsif(TX_MUX_STATE = 4) and (WHOIS_MAC_TX_EOF = '1') and (NUDPTX /= 0) then
			TX_MUX_STATE <= 0;	-- idle
	 	elsif(TX_MUX_STATE = 5) and (UDP001_MAC_TX_EOF = '1') and (NUDPTX /= 0) then -- (duplicate as needed)
			TX_MUX_STATE <= 0;	-- idle
--	 	elsif(TX_MUX_STATE = 6) and (TCP002_MAC_TX_EOF = '1') and (NTCPSTREAMS /= 0)  then 
--			TX_MUX_STATE <= 0;	-- idle
	 	end if;
	end if;
end process;
	
TX_MUX_002: process(TX_MUX_STATE, ARP_MAC_TX_EOF, ARP_MAC_TX_DATA_VALID, ARP_MAC_TX_DATA,
							PING_MAC_TX_EOF, PING_MAC_TX_DATA_VALID, PING_MAC_TX_DATA,
							TCP001_MAC_TX_EOF, TCP001_MAC_TX_DATA_VALID, TCP001_MAC_TX_DATA,
							WHOIS_MAC_TX_DATA, WHOIS_MAC_TX_DATA_VALID, WHOIS_MAC_TX_EOF,
							UDP001_MAC_TX_DATA, UDP001_MAC_TX_DATA_VALID, UDP001_MAC_TX_EOF)
begin
	case(TX_MUX_STATE) is
		when (1) =>
			MAC_TX_DATA <= ARP_MAC_TX_DATA;
			MAC_TX_DATA_VALID_local <= ARP_MAC_TX_DATA_VALID;
			MAC_TX_EOF_local <= ARP_MAC_TX_EOF;
		when (2) =>
			MAC_TX_DATA <= PING_MAC_TX_DATA;
			MAC_TX_DATA_VALID_local <= PING_MAC_TX_DATA_VALID;
			MAC_TX_EOF_local <= PING_MAC_TX_EOF;
		when (3) =>
			MAC_TX_DATA <= TCP001_MAC_TX_DATA;
			MAC_TX_DATA_VALID_local <= TCP001_MAC_TX_DATA_VALID;
			MAC_TX_EOF_local <= TCP001_MAC_TX_EOF;
		when (4) =>
			MAC_TX_DATA <= WHOIS_MAC_TX_DATA;
			MAC_TX_DATA_VALID_local <= WHOIS_MAC_TX_DATA_VALID;
			MAC_TX_EOF_local <= WHOIS_MAC_TX_EOF;
		when (5) =>
			MAC_TX_DATA <= UDP001_MAC_TX_DATA;
			MAC_TX_DATA_VALID_local <= UDP001_MAC_TX_DATA_VALID;
			MAC_TX_EOF_local <= UDP001_MAC_TX_EOF;
--		when (6) =>
--			MAC_TX_DATA <= TCP002_MAC_TX_DATA;
--			MAC_TX_DATA_VALID_local <= TCP002_MAC_TX_DATA_VALID;
--			MAC_TX_EOF_local <= TCP002_MAC_TX_EOF;
		when others => 
			MAC_TX_DATA <= (others => '0');
			MAC_TX_DATA_VALID_local <= '0';
			MAC_TX_EOF_local <= '0';
	end case;
end process;

MAC_TX_DATA_VALID <= MAC_TX_DATA_VALID_local;
MAC_TX_EOF <= MAC_TX_EOF_local;

-- reconstruct a SOF pulse for local loopback
SOF_GEN: process(CLK)
begin
	if rising_edge(CLK) then
		if(SYNC_RESET = '1') then
			MAC_TX_EOF_FLAG <= '1';
		elsif(MAC_TX_EOF_local = '1') then
			MAC_TX_EOF_FLAG <= '1';
		elsif(MAC_TX_DATA_VALID_local = '1') then
			MAC_TX_EOF_FLAG <= '0';
		end if;
	end if;
end process;
MAC_TX_SOF <= '1' when (MAC_TX_DATA_VALID_local = '1') and (MAC_TX_EOF_FLAG = '1') else '0';


-- Route "Clear To Send" signal from the MAC to the proper protocol component
ARP_MAC_TX_CTS <= '1' when (TX_MUX_STATE = 1) else '0';
PING_MAC_TX_CTS <= '1' when (TX_MUX_STATE = 2) else '0';
TCP001_MAC_TX_CTS <= '1' when (TX_MUX_STATE = 3) else '0';
WHOIS_MAC_TX_CTS <= '1' when (TX_MUX_STATE = 4) else '0';
UDP001_MAC_TX_CTS <= '1' when (TX_MUX_STATE = 5) else '0';
--TCP002_MAC_TX_CTS <= '1' when (TX_MUX_STATE = 6) else '0';


--//-- ROUTING TABLE ARBITER --------------
-- Since several components could send simultaneous routing (RT) requests, one must 
-- determine who can access the routing table next
RT_MUX_001: process(ASYNC_RESET, CLK)
begin
	if(ASYNC_RESET = '1') then
		RT_MUX_STATE <= 0;	-- idle
	elsif rising_edge(CLK) then
		if(RT_MUX_STATE = 0) then
			-- from idle to ...
			if(UDP001_RT_REQ_RTS = '1') then
				RT_MUX_STATE <= 1;	-- gives UDP001 access to the routing table
--			elsif(UDP002_RT_REQ_RTS = '1') then
--				RT_MUX_STATE <= 2;	-- gives UDP002 access to the routing table
--			elsif(UDP003_RT_REQ_RTS = '1') then
--				RT_MUX_STATE <= 3;	-- gives UDP003 access to the routing table
			end if;

		-- Routing table transaction complete. go back to idle
	 	elsif (RT_MAC_RDY = '1') or (RT_NAK = '1') then
			RT_MUX_STATE <= 0;	-- idle
	 	end if;
	end if;
end process;
	
RT_MUX_002: process(RT_MUX_STATE, UDP001_RT_IP_ADDR, UDP001_RT_REQ_RTS)
begin
	case(RT_MUX_STATE) is
		when (1) =>
			RT_IP_ADDR <= UDP001_RT_IP_ADDR;
			RT_REQ_RTS <= UDP001_RT_REQ_RTS;
--		when (2) =>
--			RT_IP_ADDR <= UDP002_RT_IP_ADDR;
--		--when (3) =>
--			RT_IP_ADDR <= UDP003_RT_IP_ADDR;
-- etc...
		when others =>
			RT_IP_ADDR <= (others => '0');
			RT_REQ_RTS <= '0';
	end case;
end process;
		
UDP001_RT_REQ_CTS <= RT_CTS when (RT_MUX_STATE = 1) else '0';
--UDP002_RT_REQ_CTS <= RT_CTS when (RT_MUX_STATE = 2) else '0';
--UDP003_RT_REQ_CTS <= RT_CTS when (RT_MUX_STATE = 3) else '0';
-- etc...

UDP001_RT_MAC_RDY <= RT_MAC_RDY when (RT_MUX_STATE = 1) else '0';
--UDP002_RT_MAC_RDY <= RT_MAC_RDY when (RT_MUX_STATE = 2) else '0';
--UDP003_RT_MAC_RDY <= RT_MAC_RDY when (RT_MUX_STATE = 3) else '0';
-- etc...

UDP001_RT_NAK <= RT_NAK when (RT_MUX_STATE = 1) else '0';
--UDP002_RT_NAK <= RT_NAK when (RT_MUX_STATE = 2) else '0';
--UDP003_RT_NAK <= RT_NAK when (RT_MUX_STATE = 3) else '0';
-- etc...

--//-- TEST POINTS
TP <= TP_TCP_SERVER;
--TP(1) <= '1' when (TX_MUX_STATE=1) else '0';	-- arp
--TP(2) <= '1' when (TX_MUX_STATE=2) else '0';	-- ping
--TP(3) <= '1' when (TX_MUX_STATE=4) else '0';	-- whois
--TP(4) <= '1' when (TX_MUX_STATE=5) else '0';	-- udp tx
--TP(5) <= UDP_TX_DATA_VALID;
--TP(6) <= UDP_TX_ACK_local;
--TP(7) <= UDP_TX_NAK_local;
--TP(8)	<= WHOIS_START;
--TP(9) <= RT_REQ_RTS;
--TP(10) <= RT_MAC_RDY;


end Behavioral;

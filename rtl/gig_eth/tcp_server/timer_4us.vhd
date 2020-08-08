-------------------------------------------------------------
-- MSS copyright 2004-2014
--	Filename:  TIMER_1MS.VHD
-- Author: Alain Zarembowitch / MSS
--	Version: 4
--	Date last modified: 1/11/14
-- Inheritance: 	none
--
-- description:  Creates a 4us timer tick which can be used to create other timers
-- with 4us increment. Function is shared with all.
--
-- Rev 3 5/15/11 AZ
-- Added 100ms tick
--
-- Rev 4 1/11/14 AZ
-- Extended CLK_COUNTER precision to operate at higher FPGA clock frequency (from ?????? ???????)
-- Switched to numeric_std.
---------------------------------------------------------------
library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;
use IEEE.STD_LOGIC_UNSIGNED.ALL;

entity TIMER_4US is
	generic (
		CLK_FREQUENCY: integer := 120
			-- CLK frequency in MHz. Needed to compute actual delays.
	);
    Port ( 
		--// CLK, RESET
		ASYNC_RESET: in std_logic;
		CLK: in std_logic;
			-- Key assumption: 40 MHz clock. If not, CLK_RATE constant below
			-- should be modified accordingly.

		TICK_4US: out std_logic;
		TICK_100MS: out std_logic
			-- 1 CLK-wide pulse every four microseconds and 100ms
			);
end entity;

architecture Behavioral of TIMER_4US is
--------------------------------------------------------
--      COMPONENTS
--------------------------------------------------------
--------------------------------------------------------
--     SIGNALS
--------------------------------------------------------
signal CLK_COUNTER: std_logic_vector(9 downto 0) := (others => '0');
constant CLK_DIV: integer := (CLK_FREQUENCY * 4 - 1); --  CLK_FREQ MHz*4usec -1;
signal TICK_4US_local: std_logic := '0';
signal CLK_COUNTER2: std_logic_vector(15 downto 0) := (others => '0');
constant CLK_DIV2: integer := 24999; --  100ms/4us - 1
-- TEST TEST TEST TEST
--constant CLK_DIV2: integer := 24; --  100Us/4us - 1
--constant CLK_DIV2: integer := 2; --  10Us/4us - 1
--------------------------------------------------------
--      IMPLEMENTATION
--------------------------------------------------------
begin

CLK_DIV_001: process(ASYNC_RESET, CLK)
begin
	if(ASYNC_RESET = '1') then
		CLK_COUNTER <= (others => '0');
		TICK_4US_local <= '0';
	elsif rising_edge(CLK) then
		if(CLK_COUNTER /= CLK_DIV) then
			CLK_COUNTER <= CLK_COUNTER + 1;
			TICK_4US_local <= '0';
		else
			CLK_COUNTER <= (others => '0');
			TICK_4US_local <= '1';
		end if;
	end if;
end process;
TICK_4US <= TICK_4US_local;

TICK_100MS_GEN: process(ASYNC_RESET, CLK)
begin
	if(ASYNC_RESET = '1') then
		CLK_COUNTER2 <= (others => '0');
		TICK_100MS <= '0';
	elsif rising_edge(CLK) then
		if(TICK_4US_local = '1') then
			if(CLK_COUNTER2 /= CLK_DIV2) then
				CLK_COUNTER2 <= CLK_COUNTER2 + 1;
				TICK_100MS <= '0';
			else
				CLK_COUNTER2 <= (others => '0');
				TICK_100MS <= '1';
			end if;
		else
			TICK_100MS <= '0';
		end if;
	end if;
end process;

end Behavioral;

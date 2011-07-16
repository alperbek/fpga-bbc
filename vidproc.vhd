-- BBC Micro "VIDPROC" Video ULA
--
-- Synchronous implementation for FPGA
--
-- (C) 2011 Mike Stirling
--
library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

entity vidproc is
port (
	CLOCK		:	in	std_logic;
	-- Clock enable qualifies display cycles (interleaved with CPU cycles)
	CLKEN		:	in	std_logic;
	nRESET		:	in	std_logic;
	
	-- Clock enable output to CRTC
	CLKEN_CRTC	:	out	std_logic;
	
	-- Bus interface
	ENABLE		:	in	std_logic;
	A0			:	in	std_logic;
	-- CPU data bus (for register writes)
	DI_CPU		:	in	std_logic_vector(7 downto 0);
	-- Display RAM data bus (for display data fetch)
	DI_RAM		:	in	std_logic_vector(7 downto 0);
	
	-- Control interface
	nINVERT		:	in	std_logic;
	DISEN		:	in	std_logic;
	CURSOR		:	in	std_logic;
	
	-- Video in (teletext mode)
	R_IN		:	in	std_logic;
	G_IN		:	in	std_logic;
	B_IN		:	in	std_logic;
	
	-- Video out
	R			:	out	std_logic;
	G			:	out	std_logic;
	B			:	out	std_logic
	);
end entity;

architecture rtl of vidproc is
-- Write-only registers
signal r0_cursor0		:	std_logic;
signal r0_cursor1		:	std_logic;
signal r0_cursor2 		: 	std_logic;
signal r0_crtc_2mhz		:	std_logic;
signal r0_pixel_rate	:	std_logic_vector(1 downto 0);
signal r0_teletext		:	std_logic;
signal r0_flash			:	std_logic;

type palette_t is array(0 to 15) of std_logic_vector(3 downto 0);
signal palette 			:	palette_t;

-- Pixel shift register
signal shiftreg			:	std_logic_vector(7 downto 0);
-- Delayed display enable
signal delayed_disen	:	std_logic;

-- Internal clock enable generation
signal clken_pixel		:	std_logic;
signal clken_counter	:	unsigned(3 downto 0);

begin
	-- Synchronous register access, enabled on every clock
	process(CLOCK,nRESET)
	begin
		if nRESET = '0' then
			r0_cursor0 <= '0';
			r0_cursor1 <= '0';
			r0_cursor2 <= '0';
			r0_crtc_2mhz <= '0';
			r0_pixel_rate <= "00";
			r0_teletext <= '0';
			r0_flash <= '0';
			
			for colour in 0 to 15 loop
				palette(colour) <= (others => '0');
			end loop;			
		elsif rising_edge(CLOCK) then
			if ENABLE = '1' then
				if A0 = '0' then
					-- Access control register
					r0_cursor0 <= DI_CPU(7);
					r0_cursor1 <= DI_CPU(6);
					r0_cursor2 <= DI_CPU(5);
					r0_crtc_2mhz <= DI_CPU(4);
					r0_pixel_rate <= DI_CPU(3 downto 2);
					r0_teletext <= DI_CPU(1);
					r0_flash <= DI_CPU(0);
				else
					-- Access palette register
					palette(to_integer(unsigned(DI_CPU(7 downto 4)))) <= DI_CPU(3 downto 0);
				end if;
			end if;
		end if;
	end process;
	
	-- Clock enable generation.  
	-- Pixel clock can be divided by 1,2,4 or 8 depending on the value
	-- programmed at r0_pixel_rate
	-- 00 = /8, 01 = /4, 10 = /2, 11 = /1
	clken_pixel <= 
		CLKEN													when r0_pixel_rate = "11" else
		(CLKEN and not clken_counter(0))						when r0_pixel_rate = "10" else
		(CLKEN and not (clken_counter(0) or clken_counter(1)))	when r0_pixel_rate = "01" else
		(CLKEN and not (clken_counter(0) or clken_counter(1) or clken_counter(2)));
		
	-- The CRT controller is always enabled in the 15th cycle, so that the result
	-- is ready for latching into the shift register in cycle 0.  If 2 MHz mode is
	-- selected then the CRTC is also enabled in the 7th cycle
	CLKEN_CRTC <= CLKEN and
		clken_counter(0) and clken_counter(1) and clken_counter(2) and
		(clken_counter(3) or r0_crtc_2mhz);
		
	process(CLOCK,nRESET)
	begin
		if nRESET = '0' then
			clken_counter <= (others => '0');
		elsif rising_edge(CLOCK) and CLKEN = '1' then
			-- Increment internal cycle counter during each video clock
			clken_counter <= clken_counter + 1;
		end if;
	end process;
	
	-- Fetch control
	process(CLOCK,nRESET)
	begin
		if nRESET = '0' then
			shiftreg <= (others => '0');
		elsif rising_edge(CLOCK) and clken_pixel = '1' then
			if clken_counter = "0000" or
				(clken_counter = "1000" and r0_crtc_2mhz = '1') then
				-- Fetch next byte from RAM into shift register.  This always occurs in
				-- cycle 0, and also in cycle 8 if the CRTC is clocked at double rate.
				shiftreg <= DI_RAM;
			else
				-- Clock shift register and input '1' at LSB
				shiftreg <= shiftreg(6 downto 0) & "1";
			end if;
		end if;
	end process;
	
	-- Pixel generation
	-- The new shift register contents are loaded during
	-- cycle 0 (and 8) but will not be read here until the next cycle.
	-- By running this process on every single video tick instead of at
	-- the pixel rate we ensure that the resulting delay is minimal and
	-- constant (running this at the pixel rate would cause
	-- the display to move slightly depending on which mode was selected). 
	process(CLOCK,nRESET)
	variable palette_a : std_logic_vector(3 downto 0);
	variable dot_val : std_logic_vector(3 downto 0);
	variable red_val : std_logic;
	variable green_val : std_logic;
	variable blue_val : std_logic;
	begin
		if nRESET = '0' then
			R <= '0';
			G <= '0';
			B <= '0';
			delayed_disen <= '0';
		elsif rising_edge(CLOCK) and CLKEN = '1' then
			-- Look up dot value in the palette.  Bits are as follows:
			-- bit 3 - FLASH
			-- bit 2 - Not BLUE
			-- bit 1 - Not GREEN
			-- bit 0 - Not RED
			palette_a := shiftreg(7) & shiftreg(5) & shiftreg(3) & shiftreg(1);
			dot_val := palette(to_integer(unsigned(palette_a)));
		
			-- Apply flash inversion if required
			red_val := (dot_val(3) and r0_flash) xor not dot_val(0);
			green_val := (dot_val(3) and r0_flash) xor not dot_val(1);
			blue_val := (dot_val(3) and r0_flash) xor not dot_val(2);
		
			-- To output
			-- FIXME: Cursor and INVERT option, teletext
			R <= red_val and delayed_disen;
			G <= green_val and delayed_disen;
			B <= blue_val and delayed_disen;
			
			-- Display enable signal delayed by one clock
			delayed_disen <= DISEN;
		end if;
	end process;
end architecture;

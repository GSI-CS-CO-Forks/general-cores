--==============================================================================
-- CERN (BE-CO-HT)
-- I2C slave core
--==============================================================================
--
-- author: Theodor Stana (t.stana@cern.ch)
--
-- date of creation: 2013-03-13
--
-- version: 1.0
--
-- description:
--
--    Simple I2C slave interface, providing the basic low-level functionality
--    of the I2C protocol.
--
--    The gc_i2c_slave module waits for a master to initiate a transfer via
--    a start condition. The address is sent next and if the address matches
--    the slave address set via the i2c_addr_i input, the done_p_o output
--    is set. Based on the eighth bit of the first I2C transfer byte, the module
--    then starts shifting in or out each byte in the transfer, setting the
--    done_p_o output after each received/sent byte.
--
--    For master write (slave read) transfers, the received byte can be read at
--    the rx_byte_o output when the done_p_o pin is high. For master read (slave
--    write) transfers, the slave sends the byte at the tx_byte_i input, which
--    should be set when the done_p_o output is high, either after I2C address
--    reception, or a successful send of a previous byte.
--
-- dependencies:
--    none.
--
-- references:
--    [1] The I2C bus specification, version 2.1, NXP Semiconductor, Jan. 2000
--        http://www.nxp.com/documents/other/39340011.pdf
--
--==============================================================================
-- GNU LESSER GENERAL PUBLIC LICENSE
--==============================================================================
-- This source file is free software; you can redistribute it and/or modify it
-- under the terms of the GNU Lesser General Public License as published by the
-- Free Software Foundation; either version 2.1 of the License, or (at your
-- option) any later version. This source is distributed in the hope that it
-- will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty
-- of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.
-- See the GNU Lesser General Public License for more details. You should have
-- received a copy of the GNU Lesser General Public License along with this
-- source; if not, download it from http://www.gnu.org/licenses/lgpl-2.1.html
--==============================================================================
-- last changes:
--    2013-03-13   Theodor Stana     t.stana@cern.ch     File created
--    2013-11-22   Theodor Stana                         Changed to sampling SDA
--                                                       on SCL rising edge
--==============================================================================
-- TODO:
--    - Stop condition
--==============================================================================

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

use work.gencores_pkg.all;

entity gc_i2c_slave is
  generic
  (
    -- Length of glitch filter
    -- 0 - SCL and SDA lines are passed only through synchronizer
    -- 1 - one clk_i glitches filtered
    -- 2 - two clk_i glitches filtered
    g_gf_len : natural := 0
  );
  port
  (
    -- Clock, reset ports
    clk_i         : in  std_logic;
    rst_n_i       : in  std_logic;

    -- I2C lines
    scl_i         : in  std_logic;
    scl_o         : out std_logic;
    scl_en_o      : out std_logic;
    sda_i         : in  std_logic;
    sda_o         : out std_logic;
    sda_en_o      : out std_logic;

    -- Slave address
    addr_i        : in  std_logic_vector(6 downto 0);

    -- ACK input, should be set after done_p_o = '1'
    -- (note that the bit is reversed wrt I2C ACK bit)
    -- '1' - ACK
    -- '0' - NACK
    ack_i         : in  std_logic;

    -- Byte to send, should be loaded while done_p_o = '1'
    tx_byte_i     : in  std_logic_vector(7 downto 0);

    -- Received byte, valid after done_p_o = '1'
    rx_byte_o     : out std_logic_vector(7 downto 0);

    -- Pulse outputs signaling various I2C actions
    -- Start and stop conditions
    sta_p_o       : out std_logic;
    sto_p_o       : out std_logic;
    -- Received address corresponds addr_i
    addr_good_p_o : out std_logic;
    -- Read and write done
    r_done_p_o    : out std_logic;
    w_done_p_o    : out std_logic;

    -- I2C bus operation, set after address detection
    -- '0' - write
    -- '1' - read
    op_o          : out std_logic
  );
end entity gc_i2c_slave;


architecture behav of gc_i2c_slave is

  --============================================================================
  -- Type declarations
  --============================================================================
  type t_state is
    (
      IDLE,            -- idle
      ADDR,            -- shift in I2C address bits
      ADDR_CHECK,      -- check received I2C address
      ADDR_ACK,        -- ACK/NACK to I2C address
      RD,              -- shift in byte to read
      RD_ACK,          -- ACK/NACK to received byte
      WR_LOAD_TXSR,    -- load byte to send via I2C
      WR,              -- shift out byte
      WR_ACK           -- get ACK/NACK from master
    );

  --============================================================================
  -- Signal declarations
  --============================================================================
  -- Deglitched signals and delays for SCL and SDA lines
  signal scl_deglitched    : std_logic;
  signal scl_deglitched_d0 : std_logic;
  signal sda_deglitched    : std_logic;
  signal sda_deglitched_d0 : std_logic;
  signal scl_r_edge_p      : std_logic;
  signal scl_f_edge_p      : std_logic;
  signal sda_f_edge_p      : std_logic;
  signal sda_r_edge_p      : std_logic;

  -- FSM signals
  signal state             : t_state;
  signal inhibit           : std_logic;

  -- RX and TX shift registers
  signal txsr              : std_logic_vector(7 downto 0);
  signal rxsr              : std_logic_vector(7 downto 0);

  -- Bit counter on RX & TX
  signal bit_cnt           : unsigned(2 downto 0);

  -- Start and stop condition pulse signals
  signal sta_p, sto_p      : std_logic;

  -- Master ACKed after it has read a byte from the slave
  signal mst_acked         : std_logic;


  signal sda_en : std_logic;

--==============================================================================
--  architecture begin
--==============================================================================
begin

  sda_en_o  <= sda_en;
  --============================================================================
  -- I/O logic
  --============================================================================
  -- No clock stretching implemented, always disable SCL line
  scl_o     <= '0';
  scl_en_o  <= '0';

  -- SDA line driven low; SDA_EN line controls when the tristate buffer is enabled
  sda_o     <= '0';

  -- Assign RX byte output
  rx_byte_o <= rxsr;

  --============================================================================
  -- Deglitching logic
  --============================================================================
  -- Generate deglitched SCL signal with 54-ns max. glitch width
  cmp_scl_deglitch : gc_glitch_filt
    generic map
    (
      g_len => g_gf_len
    )
    port map
    (
      clk_i   => clk_i,
      rst_n_i => rst_n_i,
      dat_i   => scl_i,
      dat_o   => scl_deglitched
    );

  -- and create a delayed version of this signal, together with one-tick-long
  -- falling-edge detection signal
  p_scl_degl_d0 : process(clk_i) is
  begin
    if rising_edge(clk_i) then
      if (rst_n_i = '0') then
        scl_deglitched_d0 <= '0';
        scl_f_edge_p      <= '0';
        scl_r_edge_p      <= '0';
      else
        scl_deglitched_d0 <= scl_deglitched;
        scl_f_edge_p      <= (not scl_deglitched) and scl_deglitched_d0;
        scl_r_edge_p      <= scl_deglitched and (not scl_deglitched_d0);
      end if;
    end if;
  end process p_scl_degl_d0;

  -- Generate deglitched SDA signal with 54-ns max. glitch width
  cmp_sda_deglitch : gc_glitch_filt
    generic map
    (
      g_len => g_gf_len
    )
    port map
    (
      clk_i   => clk_i,
      rst_n_i => rst_n_i,
      dat_i   => sda_i,
      dat_o   => sda_deglitched
    );

  -- and create a delayed version of this signal, together with one-tick-long
  -- falling- and rising-edge detection signals
  p_sda_deglitched_d0 : process(clk_i) is
  begin
    if rising_edge(clk_i) then
      if (rst_n_i = '0') then
        sda_deglitched_d0 <= '0';
        sda_f_edge_p      <= '0';
        sda_r_edge_p      <= '0';
      else
        sda_deglitched_d0 <= sda_deglitched;
        sda_f_edge_p      <= (not sda_deglitched) and sda_deglitched_d0;
        sda_r_edge_p      <= sda_deglitched and (not sda_deglitched_d0);
      end if;
    end if;
  end process p_sda_deglitched_d0;

  --============================================================================
  -- Start and stop condition outputs
  --============================================================================
  p_sta_sto : process (clk_i) is
  begin
    if rising_edge(clk_i) then
      if (rst_n_i = '0') then
        sta_p <= '0';
        sto_p <= '0';
      else
        sta_p <= sda_f_edge_p and scl_deglitched;
        sto_p <= sda_r_edge_p and scl_deglitched;
      end if;
    end if;
  end process p_sta_sto;

  sta_p_o <= sta_p;
  sto_p_o <= sto_p;

  --============================================================================
  -- FSM logic
  --============================================================================
  p_fsm: process (clk_i) is
  begin
    if rising_edge(clk_i) then
      if (rst_n_i = '0') then
        state         <= IDLE;
        inhibit       <= '0';
        bit_cnt       <= (others => '0');
        rxsr          <= (others => '0');
        txsr          <= (others => '0');
        mst_acked     <= '0';
        sda_en      <= '0';
        r_done_p_o    <= '0';
        w_done_p_o    <= '0';
        addr_good_p_o <= '0';
        op_o          <= '0';

      -- start and stop conditions take the FSM back to IDLE and reset the
      -- FSM inhibit signal to read the address
      elsif (sta_p = '1') or (sto_p = '1') then
        state   <= IDLE;
        inhibit <= '0';

      -- state machine logic
      else
        case state is
          ---------------------------------------------------------------------
          -- IDLE
          ---------------------------------------------------------------------
          -- When idle, outputs and bit counters are cleared, while waiting
          -- for a falling edge on SCL. The falling edge has to be validated
          -- by the inhibit signal, which states whether it is this or another
          -- slave being addressed.
          ---------------------------------------------------------------------
          when IDLE =>
            bit_cnt       <= (others => '0');
            sda_en      <= '0';
            mst_acked     <= '0';
            r_done_p_o    <= '0';
            w_done_p_o    <= '0';
            addr_good_p_o <= '0';
            if (scl_f_edge_p = '1') and (inhibit = '0') then
              state <= ADDR;
            end if;

          ---------------------------------------------------------------------
          -- ADDR
          ---------------------------------------------------------------------
          -- Shift in the seven address bits and the R/W bit, and go to address
          -- acknowledgement. When the eighth bit has been shifted in, check
          -- if address is ours and signal to external module. Then, go to
          -- ADDR_ACK state.
          ---------------------------------------------------------------------
          when ADDR =>
            -- Shifting in is done on rising edge of SCL
            if (scl_r_edge_p = '1') then
              rxsr    <= rxsr(6 downto 0) & sda_deglitched;
              bit_cnt <= bit_cnt + 1;
            end if;

            if (scl_f_edge_p = '1') then
              -- Shifted in 8 bits, go to ADDR_ACK. Check to see if received
              -- address is ours and set op_o if so.
              if (bit_cnt = 0) then
                state <= ADDR_CHECK;
              end if;
            end if;

          ---------------------------------------------------------------------
          -- ADDR_CHECK
          ---------------------------------------------------------------------
          when ADDR_CHECK =>
            -- if the address is ours, set the OP output and go to ACK state
            if (rxsr(7 downto 1) = addr_i) then
              op_o          <= rxsr(0);
              addr_good_p_o <= '1';
              state         <= ADDR_ACK;

            -- if the address is not ours, the FSM should be inhibited so a
            -- byte sent to another slave doesn't get interpreted as this
            -- slave's address
            else
              inhibit <= '1';
              state   <= IDLE;
            end if;

          ---------------------------------------------------------------------
          -- ADDR_ACK
          ---------------------------------------------------------------------
          when ADDR_ACK =>
            addr_good_p_o <= '0';
            sda_en      <= ack_i;
            if (scl_f_edge_p = '1') then
              if (rxsr(0) = '0') then
                state <= RD;
              else
                state <= WR_LOAD_TXSR;
              end if;
            end if;

          ---------------------------------------------------------------------
          -- RD
          ---------------------------------------------------------------------
          -- Shift in bits sent by the master
          ---------------------------------------------------------------------
          when RD =>
            sda_en <= '0';
            if (scl_r_edge_p = '1') then
              rxsr    <= rxsr(6 downto 0) & sda_deglitched;
              bit_cnt <= bit_cnt + 1;
            end if;

            if (scl_f_edge_p = '1') then
              -- Received 8 bits, go to RD_ACK and signal external module
              if (bit_cnt = 0) then
                state      <= RD_ACK;
                r_done_p_o <= '1';
              end if;
            end if;

          ---------------------------------------------------------------------
          -- RD_ACK
          ---------------------------------------------------------------------
          -- Send ACK/NACK, as received from external command
          ---------------------------------------------------------------------
          when RD_ACK =>
            -- Clear done pulse
            r_done_p_o <= '0';

            -- we write the ACK bit, so enable output and send the ACK bit
            sda_en <= ack_i;

            -- based on the ACK received by external command, we read the next
            -- bit (ACK) or go back to idle state (NACK)
            if (scl_f_edge_p = '1') then
              if (ack_i = '1') then
                state <= RD;
              else
                state <= IDLE;
              end if;
            end if;

          ---------------------------------------------------------------------
          -- WR_LOAD_TXSR
          ---------------------------------------------------------------------
          -- Load TXSR with the input value
          ---------------------------------------------------------------------
          when WR_LOAD_TXSR =>
            txsr  <= tx_byte_i;
            state <= WR;

          ---------------------------------------------------------------------
          -- WR
          ---------------------------------------------------------------------
          -- Shift out the eight bits of TXSR
          ---------------------------------------------------------------------
          when WR =>
            -- slave writes, SDA output enable is the negated value of the bit
            -- to send (since on I2C, '1' is a release of the bus)
            sda_en <= not txsr(7);

            -- increment bit counter on rising edge
            if (scl_r_edge_p = '1') then
              bit_cnt <= bit_cnt + 1;
            end if;

            -- Shift TXSR after falling edge of SCL
            if (scl_f_edge_p = '1') then
              txsr     <= txsr(6 downto 0) & '0';

              -- Eight bits sent, disable SDA and go to WR_ACK
              if (bit_cnt = 0) then
                state      <= WR_ACK;
                w_done_p_o <= '1';
              end if;
            end if;

          ---------------------------------------------------------------------
          -- WR_ACK
          ---------------------------------------------------------------------
          -- Check the ACK bit received from the master and go back to writing
          -- another byte if ACKed, or to IDLE if NACKed
          ---------------------------------------------------------------------
          when WR_ACK =>
            sda_en   <= '0';
            w_done_p_o <= '0';
            if (scl_r_edge_p = '1') then
              if (sda_deglitched = '0') then
                mst_acked <= '1';
              else
                mst_acked <= '0';
              end if;
            end if;

            if (scl_f_edge_p = '1') then
              if (mst_acked = '1') then
                state <= WR_LOAD_TXSR;
              else
                state <= IDLE;
              end if;
            end if;

          ---------------------------------------------------------------------
          -- Any other state: go back to IDLE
          ---------------------------------------------------------------------
          when others =>
            state <= IDLE;

        end case;
      end if;
    end if;
  end process p_fsm;

end architecture behav;
--==============================================================================
--  architecture end
--==============================================================================

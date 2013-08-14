-- eLua configurations description

module( ..., package.seeall )

local sf = string.format
local at = require "attributes"
local gen = require "generators"

local use_multiple_allocator
local pinmaps

-- Maximum number of peripherals for pin mappins
local max_uart = 16
local max_spi = 16

-------------------------------------------------------------------------------
-- Attribute checkers

local function ram_checker( eldesc, vals )
  local startvals = vals.MEM_START_ADDRESS and vals.MEM_START_ADDRESS.value
  local sizevals = vals.MEM_END_ADDRESS and vals.MEM_END_ADDRESS.value
  local ninternal = vals._NUM_INTERNAL_RAMS.value
  if ( not startvals or not sizevals ) and ninternal == 0 then
    return false, "RAM configuration must be defined in element 'ram' of section 'config'"
  end
  if not startvals and not sizevals then return true end
  if not startvals then
    return false, "attribute 'ext_start' must also be specified for element 'ram' of section 'config'"
  elseif not sizevals then
    return false, "attribute 'ext_size' must also be specified for element 'ram' of section 'config'"
  end
  if #startvals == 0 then
    return false, "attribute 'ext_start' of element 'ram' in section 'config' must have at least one element"
  elseif #sizevals == 0 then
    return false, "attribute 'ext_size' of element 'ram' in section 'config' must have at least one element"
  end
  if #startvals ~= #sizevals then
    return false, "attributes 'ext_start' and 'ext_size' of element 'ram' in section 'config' must have the same number of elements"
  end
  return true
end

local egc_mode_map = 
{
  disabled = "EGC_NOT_ACTIVE",
  alloc = "EGC_ON_ALLOC_FAILURE",
  limit = "EGC_ON_MEM_LIMIT",
  always = "EGC_ALWAYS"
}

local function egc_checker( eldesc, vals )
  local modev = vals.EGC_INITIAL_MODE.value
  local limv = vals.EGC_INITIAL_MEMLIMIT and vals.EGC_INITIAL_MEMLIMIT.value
  local allmodes = {}
  for w in modev:gmatch( "(%w+)" ) do allmodes[ #allmodes + 1 ] = w:lower() end
  local has_memlimit
  for k, v in pairs( allmodes ) do
    if not egc_mode_map[ v ] then
      return false, sf( "'%s' is not a valid value for attribute 'mode' of element 'egc' in section 'config'", v )
    end
    if v == "limit" then has_memlimit = true end
  end
  if has_memlimit and not limv then
    return false, sf( "you must specify the 'limit' attribute when using 'limit' as a value for attribute 'mode' of element 'egc' in section 'config'" )
  end
  return true
end

-------------------------------------------------------------------------------
-- Specific generators

-- Automatically generates the MEM_START_ADDRESS and MEM_END_ADDRESS macros
-- Assumes that definitions for INTERNAL_RAMx_FIRST_FREE and INTERNAL_RAMx_LAST_FREE
-- exist (they should come from <cpu>.h)
local function ram_generator( desc, vals, generated )
  -- Prepare internal memory configuration first
  local ninternal = vals._NUM_INTERNAL_RAMS.value
  local istart, iend = {}, {}
  for i = 1, ninternal do
    table.insert( istart, sf( "( u32 )( INTERNAL_RAM%d_FIRST_FREE )", i ) )
    table.insert( iend, sf( "( u32 )( INTERNAL_RAM%d_LAST_FREE )", i ) )
  end
  if not vals.MEM_START_ADDRESS then
    -- Generate configuration only for the internal memory
    local gstr = gen.print_define( "MEM_START_ADDRESS", "{ " .. table.concat( istart, "," ) .. " }" )
    gstr = gstr .. gen.print_define( "MEM_END_ADDRESS", "{ " .. table.concat( iend, "," ) .. " }" ) 
    generated.MEM_START_ADDRESS = true
    generated.MEM_END_ADDRESS = true
    use_multiple_allocator = ninternal > 1
    return gstr
  end
  local function fmtval( s ) return tonumber( s ) and tostring( s ) .. "UL" or ( "( u32 )( " .. s .. " )" ) end
  local startvals, sizevals = vals.MEM_START_ADDRESS.value, vals.MEM_END_ADDRESS.value
  for i = 1, ninternal do
    table.insert( startvals, i, sf( "( u32 )( INTERNAL_RAM%d_FIRST_FREE )", i ) )
    table.insert( sizevals, i, sf( "( u32 )( INTERNAL_RAM%d_LAST_FREE )", i ) )
  end
  for i = ninternal + 1, #sizevals do
    sizevals[ i ] = sf( "( %s + %s - 1 )", fmtval( startvals[ i ] ), fmtval( sizevals[ i ] ) )
    startvals[ i ] = sf( "( %s )", fmtval( startvals[ i ] ) )
  end
  use_multiple_allocator = #startvals > 1
  local gstr = gen.simple_gen( "MEM_START_ADDRESS", vals, generated )
  gstr = gstr .. gen.simple_gen( "MEM_END_ADDRESS", vals, generated )
  return gstr
end

local function egc_generator( desc, vals, generated )
  local modev = vals.EGC_INITIAL_MODE.value
  local limv = vals.EGC_INITIAL_MEMLIMIT and vals.EGC_INITIAL_MEMLIMIT.value
  local allmodes = {}
  local has_memlimit, has_always
  for w in modev:gmatch( "(%w+)" ) do 
    w = w:lower()
    if w == "limit" then has_memlimit = true end
    if w == "always" then has_always = true end
    allmodes[ #allmodes + 1 ] = w:lower()
  end
  if has_always then
    local gstr = gen.print_define( "EGC_INITIAL_MODE", "EGC_ALWAYS" )
    generated.EGC_INITIAL_MODE = true
    return gstr
  end
  local cmodes = {}
  for k, v in pairs( allmodes ) do 
    cmodes[ #cmodes + 1 ] = egc_mode_map[ v ]
  end
  local gstr = gen.print_define( "EGC_INITIAL_MODE", "( " .. table.concat( cmodes, "|" ) .. " )" )
  generated.EGC_INITIAL_MODE = true
  if has_memlimit then gstr = gstr .. gen.simple_gen( "EGC_INITIAL_MEMLIMIT", vals, generated ) end
  return gstr
end

local function uart_pinmap_generator( desc, vals, generated )
  local uart_id = desc.info
  assert( tonumber( uart_id ), "invalid UART ID in uart_pinmap_generator (internal error?)" )
  -- Look for all pins, save them in the local 'pinmaps' dictionary
  pinmaps = pinmaps or {}
  pinmaps.uart = pinmaps.uart or {}
  pinmaps.uart[ #pinmaps.uart + 1 ] = { uart_id, 
    vals[ sf( '_UART%s_RX_PIN', uart_id ) ].value,
    vals[ sf( '_UART%s_TX_PIN', uart_id ) ].value,
    vals[ sf( '_UART%s_RTS_PIN', uart_id ) ].value,
    vals[ sf( '_UART%s_CTS_PIN', uart_id ) ].value
  }
  return ""
end

local function spi_pinmap_generator( desc, vals, generated )
  local spi_id = desc.info
  assert( tonumber( spi_id ), "invalid SPI ID in spi_pinmap_generator (internal error?)" )
  -- Look for all pins, save them in the local 'pinmaps' dictionary
  pinmaps = pinmaps or {}
  pinmaps.spi = pinmaps.spi or {}
  pinmaps.spi[ #pinmaps.spi + 1 ] = { spi_id, 
    vals[ sf( '_SPI%s_MOSI_PIN', spi_id ) ].value,
    vals[ sf( '_SPI%s_MISO_PIN', spi_id ) ].value,
    vals[ sf( '_SPI%s_SCK_PIN', spi_id ) ].value,
    vals[ sf( '_SPI%s_SCK_SS', spi_id ) ].value
  }
  return ""
end

local function pinmap_c_generator( key, data )
  local s = sf( '#define INITIAL_%s_PINMAPS             { ', key:upper() )
  for _, v in pairs( data ) do
    for i = 1, #v do s = s .. tostring( v[ i ] ) .. ", " end
  end
  s = s .. "-1 }\n"
  return s
end

-------------------------------------------------------------------------------
-- Public interface

-- Build the configuration data needed by eLua, save it in the "configs" table
function init()
  local configs = {}

  -- Virtual timers
  configs.vtmr = {
    attrs = {
      num = at.int_attr( 'VTMR_NUM_TIMERS', 1 ),
      freq = at.int_attr( 'VTMR_FREQ_HZ', 1 )
    },
    required = { num = 0, freq = 1 }
  }

  -- EGC
  configs.egc = {
    confcheck = egc_checker,
    gen = egc_generator,
    attrs = {
      mode = at.string_attr( 'EGC_INITIAL_MODE' ),
      limit = at.make_optional( at.int_attr( 'EGC_INITIAL_MEMLIMIT', 1 ) )
    },
  }

  -- Clocks
  configs.clocks = {
    attrs = {
      external = at.make_optional( at.int_attr( 'ELUA_BOARD_EXTERNAL_CLOCK_HZ', 1 ) ),
      cpu = at.make_optional( at.int_attr( 'ELUA_BOARD_CPU_CLOCK_HZ', 1 ) )
    }
  }

  -- RAM configuration generator
  configs.ram = {
    gen = ram_generator,
    confcheck = ram_checker,
    attrs = {
      internal_rams = at.int_attr( '_NUM_INTERNAL_RAMS', 0, nil, 1 ), 
      ext_start = at.array_of( at.combine_attr( 'MEM_START_ADDRESS', { at.int_attr( '' ), at.string_attr( '' ) } ) ),
      ext_size = at.array_of( at.combine_attr( 'MEM_END_ADDRESS', { at.int_attr( '', 1 ), at.string_attr( '' ) } ) ),
    },
    required = { internal_rams = 1, ext_start = {}, ext_size = {} }
  }

  -----------------------------------------------------------------------------
  -- Pinmap  generators

  -- UARTs
  for i = 0, max_uart - 1 do
    configs[ sf( "uart%d_pins", i ) ] = {
      gen = uart_pinmap_generator,
      info = i,
      attrs = {
        rx = at.make_optional( at.int_attr( sf( '_UART%d_RX_PIN', i ), 0, nil, -1 ) ),
        tx = at.make_optional( at.int_attr( sf( '_UART%d_TX_PIN', i ), 0, nil, -1 ) ),
        rts = at.make_optional( at.int_attr( sf( '_UART%d_RTS_PIN', i ), 0, nil, -1 ) ),
        cts = at.make_optional( at.int_attr( sf( '_UART%d_CTS_PIN', i ), 0, nil, -1 ) ),
      }
    }
  end

  -- SPIs
  for i = 0, max_spi - 1 do
    configs[ sf( "spi%d_pins", i ) ] = {
      gen = spi_pinmap_generator,
      info = i,
      attrs = {
        mosi = at.make_optional( at.int_attr( sf( '_SPI%d_MOSI_PIN', i ), 0, nil, -1 ) ),
        miso = at.make_optional( at.int_attr( sf( '_SPI%d_MISO_PIN', i ), 0, nil, -1 ) ),
        sck = at.make_optional( at.int_attr( sf( '_SPI%d_SCK_PIN', i ), 0, nil, -1 ) ),
        ss = at.make_optional( at.int_attr( sf( '_SPI%d_SCK_SS', i ), 0, nil, -1 ) ),
      }
    }
  end

  -- All done
  return configs
end

-- Returns true if a multiple allocator is needed for this configuration, 
-- false otherwise
function needs_multiple_allocator()
  return use_multiple_allocator
end

-- Returns the initial pinmap configurations
function gen_pin_mappings()
  if not pinmaps then return end
  local s = ""
  for key, data in pairs( pinmaps ) do s = s .. pinmap_c_generator( key, data ) .. "\n" end
  return s
end


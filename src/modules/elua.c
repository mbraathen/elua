// Interface with core services

#include "lua.h"
#include "lualib.h"
#include "lauxlib.h"
#include "platform.h"
#include "auxmods.h"
#include "lrotable.h"
#include "legc.h"
#include "platform_conf.h"
#include "linenoise.h"
#include "shell.h"
#include "pinmap.h"
#include <string.h>
#include <stdlib.h>

#if defined( USE_GIT_REVISION )
#include "git_version.h"
#else
#include "version.h"
#endif

// Lua: elua.egc_setup( mode, [ memlimit ] )
static int elua_egc_setup( lua_State *L )
{
  int mode = luaL_checkinteger( L, 1 );
  unsigned memlimit = 0;

  if( lua_gettop( L ) >= 2 )
    memlimit = ( unsigned )luaL_checkinteger( L, 2 );
  legc_set_mode( L, mode, memlimit );
  return 0;
}

// Lua: elua.version()
static int elua_version( lua_State *L )
{
  lua_pushstring( L, ELUA_STR_VERSION );
  return 1;
}

// Lua: elua.save_history( filename )
// Only available if linenoise support is enabled
static int elua_save_history( lua_State *L )
{
#ifdef BUILD_LINENOISE
  const char* fname = luaL_checkstring( L, 1 );
  int res;

  res = linenoise_savehistory( LINENOISE_ID_LUA, fname );
  if( res == 0 )
    printf( "History saved to %s.\n", fname );
  else if( res == LINENOISE_HISTORY_NOT_ENABLED )
    printf( "linenoise not enabled for Lua.\n" );
  else if( res == LINENOISE_HISTORY_EMPTY )
    printf( "History empty, nothing to save.\n" );
  else
    printf( "Unable to save history to %s.\n", fname );
  return 0;
#else // #ifdef BUILD_LINENOISE
  return luaL_error( L, "linenoise support not enabled." );
#endif // #ifdef BUILD_LINENOISE
}

#ifdef HAS_PINMAPS
static void eluah_show_pin_functions( int pin )
{ 
  int total = pinmap_get_num_pins(), i;
  const char* pinmap_peripheral_names[] = PINMAP_PERIPHERAL_NAMES;
  const char* uart_pin_names[] = PINMAP_UART_PIN_NAMES;
  const char* spi_pin_names[] = PINMAP_SPI_PIN_NAMES;
  const pin_info *pinfo;
  const pin_function *pfunc;

  for( i = 0; i < total; i ++ )
  {
    pinfo = pinmap_get_at( i );
    if( pin != PINMAP_IGNORE_PIN && pinfo->pin != pin )
      continue;
    printf( "%s_%d: ", platform_pio_get_prefix( PLATFORM_IO_GET_PORT( pinfo->pin ) ), PLATFORM_IO_GET_PIN( pinfo->pin ) );
    pfunc = pinfo->pfuncs;
    while( pfunc->peripheral != PINMAP_NONE )
    {
      printf( "%s%d.", pinmap_peripheral_names[ pfunc->peripheral ], pfunc->id );
      switch( pfunc->peripheral )
      {
        case PINMAP_UART:
          printf( uart_pin_names[ pfunc->pin_id ] );
          break;
        case PINMAP_SPI:
          printf( spi_pin_names[ pfunc->pin_id ] );
          break;
      }
      printf( " " );
      pfunc ++;
    }
    printf( "\n" );
  }
}

// Lua: elua.print_pin_functions( [ pin1 ], [ pin2 ], ..., [ pinn ] )
static int elua_print_pin_functions( lua_State *L )
{
  int i;

  if( lua_gettop( L ) == 0 )
    eluah_show_pin_functions( PINMAP_IGNORE_PIN );
  else
    for( i = 1; i <= lua_gettop( L ); i ++ )
      eluah_show_pin_functions( luaL_checkinteger( L, i ) );
  return 0;
}
#endif // #ifdef HAS_PINMAPS

#ifdef BUILD_SHELL
// Lua: elua.shell( <shell_command> )
static int elua_shell( lua_State *L )
{
  const char *pcmd = luaL_checkstring( L, 1 );
  char *cmdcpy;

  // "+2" below comes from the string terminator (+1) and the '\n'
  // that will be added by the shell code (+1)
  if( ( cmdcpy = ( char* )malloc( strlen( pcmd ) + 2 ) ) == NULL )
    return luaL_error( L, "not enough memory for elua_shell" );
  strcpy( cmdcpy, pcmd );
  shellh_execute_command( cmdcpy, 0 );
  free( cmdcpy );
  return 0;
}
#endif // #ifdef BUILD_SHELL

// Module function map
#define MIN_OPT_LEVEL 2
#include "lrodefs.h"
const LUA_REG_TYPE elua_map[] =
{
  { LSTRKEY( "egc_setup" ), LFUNCVAL( elua_egc_setup ) },
  { LSTRKEY( "version" ), LFUNCVAL( elua_version ) },
  { LSTRKEY( "save_history" ), LFUNCVAL( elua_save_history ) },
#ifdef BUILD_SHELL
  { LSTRKEY( "shell" ), LFUNCVAL( elua_shell ) },
#endif
#ifdef HAS_PINMAPS
  { LSTRKEY( "print_pin_functions" ), LFUNCVAL( elua_print_pin_functions ) },
#endif
#if LUA_OPTIMIZE_MEMORY > 0
  { LSTRKEY( "EGC_NOT_ACTIVE" ), LNUMVAL( EGC_NOT_ACTIVE ) },
  { LSTRKEY( "EGC_ON_ALLOC_FAILURE" ), LNUMVAL( EGC_ON_ALLOC_FAILURE ) },
  { LSTRKEY( "EGC_ON_MEM_LIMIT" ), LNUMVAL( EGC_ON_MEM_LIMIT ) },
  { LSTRKEY( "EGC_ALWAYS" ), LNUMVAL( EGC_ALWAYS ) },
#endif
  { LNILKEY, LNILVAL }
};

LUALIB_API int luaopen_elua( lua_State *L )
{
#if LUA_OPTIMIZE_MEMORY > 0
  return 0;
#else
  luaL_register( L, AUXLIB_ELUA, elua_map );
  MOD_REG_NUMBER( L, "EGC_NOT_ACTIVE", EGC_NOT_ACTIVE );
  MOD_REG_NUMBER( L, "EGC_ON_ALLOC_FAILURE", EGC_ON_ALLOC_FAILURE );
  MOD_REG_NUMBER( L, "EGC_ON_MEM_LIMIT", EGC_ON_MEM_LIMIT );
  MOD_REG_NUMBER( L, "EGC_ALWAYS", EGC_ALWAYS );
  return 1;
#endif
}

#if _WIN32
  // https://devblogs.microsoft.com/commandline/windows-command-line-introducing-the-windows-pseudo-console-conpty/
  #if __MINGW32__ || __MINGW64__ // https://stackoverflow.com/questions/66419746/is-there-support-for-winpty-in-mingw-w64
    #define NTDDI_VERSION 0x0A000006 //NTDDI_WIN10_RS5
    #undef _WIN32_WINNT
    #define _WIN32_WINNT 0x0A00 // _WIN32_WINNT_WIN10
  #endif
  #include <windows.h>
#else
  #include <unistd.h>
  #include <fcntl.h>
  #include <sys/ioctl.h>
  #include <sys/types.h>
  #if __APPLE__
    #include <util.h>
  #else
    #include <pty.h>
  #endif
#endif
#include <stdio.h>
#include <string.h>
#include <errno.h>

#ifdef LIBVIML_STANDALONE
  #include <lua.h>
  #include <lauxlib.h>
  #include <lualib.h>
#else
  #define LITE_XL_PLUGIN_ENTRYPOINT
  #include <lite_xl_plugin_api.h>
#endif

static int f_vim_size(lua_State* L) {
  if (strcmp(luaL_checkstring(L, 1), "stdout") == 0) {
    struct winsize size = {0};
    ioctl(STDOUT_FILENO, TIOCGWINSZ, &size);
    lua_pushinteger(L, size.ws_col);
    lua_pushinteger(L, size.ws_row);
  } else {
    lua_pushnil(L);
    lua_pushnil(L);
  }
  return 2;
}

static int f_vim_isatty(lua_State *L) {
  if (strcmp(luaL_checkstring(L, 1), "stdout") == 0) {
    lua_pushboolean(L, isatty(STDOUT_FILENO));
  } else {
    lua_pushnil(L);
  }
  return 1;
}

static int f_vim_read(lua_State* L) {
  static int nonblocked = 0;
  if (!nonblocked) {
    int flags = fcntl(STDIN_FILENO, F_GETFL, 0);
    if (flags == -1)
      return luaL_error(L, "can't get flags for stdin");
    flags = (flags | O_NONBLOCK);
    fcntl(STDIN_FILENO, F_SETFL, flags);
    nonblocked = 1;
  }
  char block[1024];
  int length = read(STDIN_FILENO, block, sizeof(block));
  if (length >= 0) {
    lua_pushlstring(L, block, length);
    return 1;
  }
  if (length == -1 && (errno == EWOULDBLOCK || errno == EAGAIN))
    return 0;
  return luaL_error(L, "error getting input: %s", strerror(errno));
}

static const luaL_Reg vim_api[] = {
  { "size",    f_vim_size    },
  { "is_atty", f_vim_isatty  },
  { "read",    f_vim_read    },
  { NULL,      NULL          }
};


#ifndef LIBTERMINAL_VERSION
  #define LIBTERMINAL_VERSION "unknown"
#endif

#ifndef LIBTERMINAL_STANDALONE
int luaopen_lite_xl_libvim(lua_State* L, void* XL) {
  lite_xl_plugin_init(XL);
#else
int luaopen_libvim(lua_State* L) {
#endif
  luaL_newmetatable(L, "libvim");
  luaL_setfuncs(L, vim_api, 0);
  lua_pushliteral(L, LIBTERMINAL_VERSION);
  lua_setfield(L, -2, "version");
  lua_pushvalue(L, -1);
  lua_setfield(L, -2, "__index");
  return 1;
}

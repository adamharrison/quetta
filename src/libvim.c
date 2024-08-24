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
  #include <math.h>
  #include <sys/ioctl.h>
  #include <sys/types.h>
  #include <sys/stat.h>
  #include <sys/select.h>
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
  double timeout = luaL_checknumber(L, 1);

  fd_set set;
  struct timeval tv = { .tv_sec = (int)timeout, .tv_usec = fmod(timeout, 1.0) * 100000 };
  FD_ZERO(&set);
  FD_SET(STDIN_FILENO, &set);
  int rv = select(1, &set, NULL, NULL, &tv);
  if (rv <= 0)
    return 0;
  char block[1024];
  int length = read(STDIN_FILENO, block, sizeof(block));
  if (length >= 0) {
    lua_pushlstring(L, block, length);
    return 1;
  }
  return luaL_error(L, "error getting input: %s", strerror(errno));
}

struct termios original_term = {0};
int f_vim_gc(lua_State* L) {
  if (isatty(STDIN_FILENO)) {
    original_term.c_lflag |= (ECHO | ICANON);
    tcsetattr(STDIN_FILENO, TCSANOW, &original_term);
  }
  return 0;
}

static const luaL_Reg vim_api[] = {
  { "__gc",    f_vim_gc      },
  { "size",    f_vim_size    },
  { "is_atty", f_vim_isatty  },
  { "read",    f_vim_read    },
  { NULL,      NULL          }
};


#ifndef LIBVIM_VERSION
  #define LIBVIM_VERSION "unknown"
#endif

#ifndef LIBVIM_STANDALONE
int luaopen_lite_xl_libvim(lua_State* L, void* XL) {
  lite_xl_plugin_init(XL);
#else
int luaopen_libvim(lua_State* L) {
#endif
  luaL_newmetatable(L, "libvim");
  luaL_setfuncs(L, vim_api, 0);
  lua_pushliteral(L, LIBVIM_VERSION);
  lua_setfield(L, -2, "version");
  lua_pushvalue(L, -1);
  lua_setfield(L, -2, "__index");
  lua_pushvalue(L, -1);
  lua_setmetatable(L, -2);

  struct termios term={0};
  if (isatty(STDIN_FILENO)) {
    tcgetattr(STDIN_FILENO, &original_term);
    tcgetattr(STDIN_FILENO, &term);
    term.c_lflag &= ~(ECHO | ICANON);
    tcsetattr(STDIN_FILENO, TCSANOW, &term);
  }
  return 1;
}

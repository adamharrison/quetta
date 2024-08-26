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


/* 32bit fnv-1a hash */
typedef struct {
  union {
    struct {
      int codepoint;
      unsigned char foreground;
      unsigned char background;
    };
    long long value;
  };
} s_pixel;
typedef struct {
  int x, y;
  s_pixel* pixels;
} s_display;

s_display stdout_display = {0};
s_display buffered_display = {0};

static int display_resize(s_display* display, int x, int y) {
  if (display->x != x || display->y != y) {
    display->x = x;
    display->y = y;
    if (display->pixels)
      free(display->pixels);
    display->pixels = calloc(sizeof(s_pixel) * x * y, 1);
  }
}


static int f_vim_size(lua_State* L) {
  if (strcmp(luaL_checkstring(L, 1), "stdout") == 0) {
    struct winsize size = {0};
    ioctl(STDOUT_FILENO, TIOCGWINSZ, &size);
    lua_pushinteger(L, size.ws_col);
    lua_pushinteger(L, size.ws_row);
    display_resize(&stdout_display, size.ws_col, size.ws_row);
    display_resize(&buffered_display, size.ws_col, size.ws_row);
  } else {
    lua_pushnil(L);
    lua_pushnil(L);
  }
  return 2;
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
    original_term.c_lflag |= (ECHO | ICANON | ISIG | IXON | IEXTEN);
    tcsetattr(STDIN_FILENO, TCSANOW, &original_term);
    fprintf(stdout, "\x1B[?25h");
    fprintf(stdout, "\x1B[?47l");
    fflush(stdout);
  }
  return 0;
}


static const char* utf8_to_codepoint(const char *p, unsigned *dst) {
  const unsigned char *up = (unsigned char*)p;
  unsigned res, n;
  switch (*p & 0xf0) {
    case 0xf0 :  res = *up & 0x07;  n = 3;  break;
    case 0xe0 :  res = *up & 0x0f;  n = 2;  break;
    case 0xd0 :
    case 0xc0 :  res = *up & 0x1f;  n = 1;  break;
    default   :  res = *up;         n = 0;  break;
  }
  while (n--) {
    res = (res << 6) | (*(++up) & 0x3f);
  }
  *dst = res;
  return (const char*)up + 1;
}


static int f_vim_draw_text(lua_State* L) {
  size_t length;
  const char* text = luaL_checklstring(L, 2, &length);
  const char* end = text + length;
  int x = luaL_checkinteger(L, 3);
  int y = luaL_checkinteger(L, 4);
  int color = luaL_checkinteger(L, 5);
  int codepoint;
  int limit = buffered_display.x * buffered_display.y;

  for (int idx = buffered_display.x * y + x; text < end && idx < limit; ++idx) {
    text = utf8_to_codepoint(text, &codepoint);
    buffered_display.pixels[idx].foreground = color;
    buffered_display.pixels[idx].codepoint = codepoint;
  };
  return 0;
}

static int f_vim_draw_rect(lua_State* L) {
  int x = luaL_checkinteger(L, 1);
  int y = luaL_checkinteger(L, 2);
  int w = luaL_checkinteger(L, 3);
  int h = luaL_checkinteger(L, 4);
  int color = luaL_checkinteger(L, 5);
  int limit = buffered_display.x * buffered_display.y;
  for (int i = 0; i < h; ++i) {
    for (int j = 0; j < w; ++j) {
      int idx = (y + i) * buffered_display.x + (j + x);
      if (idx >= limit)
        break;
      buffered_display.pixels[idx].codepoint = ' ';
      buffered_display.pixels[idx].background = color;
    }
  }
  return 0;
}


static int f_vim_begin_frame(lua_State* L) {
  return 0;
}

static int codepoint_to_utf8(unsigned int codepoint, char* target) {
  if (codepoint < 128) {
    *(target++) = codepoint;
    return 1;
  } else if (codepoint < 2048) {
    *(target++) = 0xC0 | (codepoint >> 6);
    *(target++) = 0x80 | ((codepoint >> 0) & 0x3F);
    return 2;
  } else if (codepoint < 65536) {
    *(target++) = 0xE0 | (codepoint >> 12);
    *(target++) = 0x80 | ((codepoint >> 6) & 0x3F);
    *(target++) = 0x80 | ((codepoint >> 0) & 0x3F);
    return 3;
  }
  *(target++) = 0xF0 | (codepoint >> 18);
  *(target++) = 0x80 | ((codepoint >> 12) & 0x3F);
  *(target++) = 0x80 | ((codepoint >> 6) & 0x3F);
  *(target++) = 0x80 | ((codepoint >> 0) & 0x3F);
  return 4;
}



static int f_vim_end_frame(lua_State* L) {
  int cursor_position = -1;
  int foreground_color = -1;
  int background_color = -1;
  int length = buffered_display.y * buffered_display.x;
  char buffer[5] = {0};
  for (int idx = 0; idx < length; ++idx) {
    if (buffered_display.pixels[idx].value != stdout_display.pixels[idx].value) {
      stdout_display.pixels[idx].value = buffered_display.pixels[idx].value;
      if (cursor_position++ != idx) {
        int x = idx % buffered_display.x;
        int y = idx / buffered_display.x;
        fprintf(stdout,"\x1B[%d;%dH", y + 1, x + 1);
        cursor_position = idx + 1;
      }
      if (foreground_color != buffered_display.pixels[idx].foreground) {
        foreground_color = buffered_display.pixels[idx].foreground;
        fprintf(stdout, "\x1B[38;5;%dm", foreground_color);
      }
      if (background_color != buffered_display.pixels[idx].background) {
        background_color = buffered_display.pixels[idx].background;
        fprintf(stdout, "\x1B[48;5;%dm", background_color);
      }
      int codepoint_length = codepoint_to_utf8(buffered_display.pixels[idx].codepoint, buffer);
      fwrite(buffer, 1, codepoint_length, stdout);
    }
  }
  return 0;
}

static const luaL_Reg vim_api[] = {
  { "__gc",        f_vim_gc          },
  { "size",        f_vim_size        },
  { "read",        f_vim_read        },
  { "begin_frame", f_vim_begin_frame },
  { "end_frame",   f_vim_end_frame   },
  { "draw_rect",   f_vim_draw_rect   },
  { "draw_text",   f_vim_draw_text   },
  { NULL,      NULL                  }
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
    term.c_lflag &= ~(ECHO | ICANON | ISIG | IXON | IEXTEN);
    term.c_iflag &= ~(IXON);
    tcsetattr(STDIN_FILENO, TCSANOW, &term);
    fprintf(stdout, "\x1B[?25l"); // Disable curosr.
    fprintf(stdout, "\x1B[?47h"); // Use alternate screen buffer.
    fflush(stdout);
  }
  return 1;
}

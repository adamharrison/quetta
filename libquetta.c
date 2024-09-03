#if _WIN32
  // https://devblogs.microsoft.com/commandline/windows-command-line-introducing-the-windows-pseudo-console-conpty/
  #if __MINGW32__ || __MINGW64__ // https://stackoverflow.com/questions/66419746/is-there-support-for-winpty-in-mingw-w64
    #define NTDDI_VERSION 0x0A000006 //NTDDI_WIN10_RS5
    #undef _WIN32_WINNT
    #define _WIN32_WINNT 0x0A00 // _WIN32_WINNT_WIN10
  #endif
  #include <windows.h>
#else
  #include <fcntl.h>
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
#include <assert.h>
#include <math.h>
#include <unistd.h>
#include <stdio.h>
#include <string.h>
#include <errno.h>

#ifdef LIBQUETTA_STANDALONE
  #include <lua.h>
  #include <lauxlib.h>
  #include <lualib.h>
#else
  #define LITE_XL_PLUGIN_ENTRYPOINT
  #include <lite_xl_plugin_api.h>
#endif

typedef struct {
  int codepoint;
  union {
    struct {
      unsigned int foreground;
      unsigned int background;
    };
    unsigned long long color;
  };
} s_pixel;

typedef enum {
  COLOR_8BIT,
  COLOR_24BIT
} e_color_model;

static e_color_model color_model = COLOR_8BIT;

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


static int f_quetta_size(lua_State* L) {
  #ifdef _WIN32
    CONSOLE_SCREEN_BUFFER_INFO info;
    GetConsoleScreenBufferInfo(GetStdHandle(STD_OUTPUT_HANDLE), &info);
    //lua_pushinteger(L, info.srWindow.Right - info.srWindow.Left + 1);
    //lua_pushinteger(L, info.srWindow.Bottom - info.srWindow.Top + 1);
    
    //lua_pushinteger(L, info.dwMaximumWindowSize.X);
    //lua_pushinteger(L, info.dwMaximumWindowSize.Y);

    lua_pushinteger(L, info.dwSize.X);
    lua_pushinteger(L, info.dwSize.Y);
  #else
    struct winsize size = {0};
    ioctl(STDOUT_FILENO, TIOCGWINSZ, &size);
    lua_pushinteger(L, size.ws_col);
    lua_pushinteger(L, size.ws_row);
  #endif
  display_resize(&stdout_display, lua_tointeger(L, -2), lua_tointeger(L, -1));
  display_resize(&buffered_display, lua_tointeger(L, -2), lua_tointeger(L, -1));
  return 2;
}


static int f_quetta_read(lua_State* L) {
  double timeout = luaL_checknumber(L, 1);
  char block[1024];
  #ifdef _WIN32
    if (WaitForSingleObject(GetStdHandle(STD_INPUT_HANDLE), (int)(timeout * 1000)) != WAIT_OBJECT_0)
      return 0;
  #else
    fd_set set;
    struct timeval tv = { .tv_sec = (int)timeout, .tv_usec = fmod(timeout, 1.0) * 100000 };
    FD_ZERO(&set);
    FD_SET(STDIN_FILENO, &set);
    int rv = select(1, &set, NULL, NULL, &tv);
    if (rv <= 0)
      return 0;
  #endif
  int length = read(STDIN_FILENO, block, sizeof(block));
  if (length >= 0) {
    lua_pushlstring(L, block, length);
    return 1;
  }
  return luaL_error(L, "error getting input: %s", strerror(errno));
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


static int f_quetta_draw_text(lua_State* L) {
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

static int alpha_blend(int srcr, int srcg, int srcb, int dstr, int dstg, int dstb, float alpha) {
  float ialpha = 1.0f - alpha;
  return ((int)((srcr * alpha) + (dstr * ialpha)) & 0xFF) << 24 | 
    ((int)((srcg * alpha) + (dstg * ialpha)) & 0xFF) << 16 |
    ((int)((srcb * alpha) + (dstb * ialpha)) & 0xFF) << 8 |
    255;
}

static int f_quetta_draw_rect(lua_State* L) {
  int x = luaL_checkinteger(L, 1);
  int y = luaL_checkinteger(L, 2);
  int w = luaL_checkinteger(L, 3);
  int h = luaL_checkinteger(L, 4);
  int color = luaL_checkinteger(L, 5);
  int limit = buffered_display.x * buffered_display.y;
  int r = ((color >> 24) & 0xFF), g = ((color >> 16) & 0xFF), b = ((color >> 8) & 0xFF), a = (color & 0xFF);
  float alpha = a / 255.0f;
  for (int i = 0; i < h; ++i) {
    for (int j = 0; j < w; ++j) {
      int idx = (y + i) * buffered_display.x + (j + x);
      if (idx >= limit)
        break;
      if (a == 255) {
        buffered_display.pixels[idx].codepoint = ' ';
        buffered_display.pixels[idx].background = color;
      } else {
        buffered_display.pixels[idx].foreground = alpha_blend(r, g, b, (buffered_display.pixels[idx].foreground >> 24) & 0xFF, (buffered_display.pixels[idx].foreground >> 16) & 0xFF, (buffered_display.pixels[idx].foreground >> 8) & 0xFF, alpha);
        buffered_display.pixels[idx].background = alpha_blend(r, g, b, (buffered_display.pixels[idx].background >> 24) & 0xFF, (buffered_display.pixels[idx].background >> 16) & 0xFF, (buffered_display.pixels[idx].background >> 8) & 0xFF, alpha);
      }
    }
  }
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



static int f_quetta_end_frame(lua_State* L) {
  int cursor_position = -1;
  int foreground_color = -1;
  int background_color = -1;
  int length = buffered_display.y * buffered_display.x;
  char buffer[5] = {0};
  for (int idx = 0; idx < length; ++idx) {
    if (buffered_display.pixels[idx].color != stdout_display.pixels[idx].color || buffered_display.pixels[idx].codepoint != stdout_display.pixels[idx].codepoint) {
      stdout_display.pixels[idx].color = buffered_display.pixels[idx].color;
      stdout_display.pixels[idx].codepoint = buffered_display.pixels[idx].codepoint;
      if (cursor_position++ != idx) {
        int x = idx % buffered_display.x;
        int y = idx / buffered_display.x;
        fprintf(stdout,"\x1B[%d;%dH", y + 1, x + 1);
        cursor_position = idx + 1;
      }
      if (foreground_color != buffered_display.pixels[idx].foreground) {
        foreground_color = buffered_display.pixels[idx].foreground;
        if (color_model == COLOR_24BIT)
          fprintf(stdout, "\x1B[38;2;%d;%d;%dm", (foreground_color >> 24) & 0xFF, (foreground_color >> 16) & 0xFF, (foreground_color >> 8) & 0xFF);
        else
          fprintf(stdout, "\x1B[38;5;%dm", foreground_color);
      }
      if (background_color != buffered_display.pixels[idx].background) {
        background_color = buffered_display.pixels[idx].background;
        if (color_model == COLOR_24BIT)
          fprintf(stdout, "\x1B[48;2;%d;%d;%dm", (background_color >> 24) & 0xFF, (background_color >> 16) & 0xFF, (background_color >> 8) & 0xFF);
        else
          fprintf(stdout, "\x1B[48;5;%dm", background_color);
      }
      int codepoint_length = codepoint_to_utf8(buffered_display.pixels[idx].codepoint, buffer);
      fwrite(buffer, 1, codepoint_length, stdout);
    }
  }
  fflush(stdout);
  return 0;
}


static int initialized = -1;
static int restore = 0;

#ifndef _WIN32
  struct termios original_term = {0};
#else
  DWORD original_mode_in = 0, original_mode_out = 0;
#endif

int f_quetta_gc(lua_State* L) {
  if (initialized) {
    #ifndef _WIN32
      if (!restore)
        original_term.c_lflag |= (ECHO | ICANON | ISIG | IXON | IEXTEN);
      tcsetattr(STDIN_FILENO, TCSANOW, &original_term);
    #else
      if (restore) {
        SetConsoleMode(GetStdHandle(STD_INPUT_HANDLE), original_mode_in);
        SetConsoleMode(GetStdHandle(STD_OUTPUT_HANDLE), original_mode_out);
      }
    #endif
    lua_rawgeti(L, LUA_REGISTRYINDEX, initialized);
    lua_pcall(L, 0, 0, 0);
    luaL_unref(L, LUA_REGISTRYINDEX, initialized);
  }
  return 0;
}

static int f_quetta_init(lua_State* L) {
  restore = lua_toboolean(L, 1);
  color_model = strcmp(luaL_checkstring(L, 2), "24bit") == 0 ? COLOR_24BIT : COLOR_8BIT;
  luaL_checktype(L, 3, LUA_TFUNCTION);
  #ifdef _WIN32  
    BOOL success = AttachConsole(ATTACH_PARENT_PROCESS) || AllocConsole();
    if (success) {
      HANDLE hConOut = CreateFile("CONOUT$", GENERIC_READ | GENERIC_WRITE, FILE_SHARE_READ | FILE_SHARE_WRITE, NULL, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, NULL);
      SetStdHandle(STD_OUTPUT_HANDLE, hConOut);
      HANDLE hConIn = CreateFile("CONIN$", GENERIC_READ | GENERIC_WRITE, FILE_SHARE_READ | FILE_SHARE_WRITE, NULL, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, NULL);
      SetStdHandle(STD_INPUT_HANDLE, hConIn);
      success = GetConsoleMode(hConIn, &original_mode_in) && GetConsoleMode(hConOut, &original_mode_out) &&
        SetConsoleMode(hConIn, (original_mode_in & ~(ENABLE_ECHO_INPUT | ENABLE_LINE_INPUT | ENABLE_INSERT_MODE | ENABLE_PROCESSED_INPUT | ENABLE_QUICK_EDIT_MODE)) | ENABLE_VIRTUAL_TERMINAL_INPUT) &&
        SetConsoleMode(hConOut, ((original_mode_out & ~ENABLE_WRAP_AT_EOL_OUTPUT) | ENABLE_PROCESSED_OUTPUT | ENABLE_VIRTUAL_TERMINAL_PROCESSING | DISABLE_NEWLINE_AUTO_RETURN));
    }
    if (!success) {
      lua_pushboolean(L, 0);
      char error_buffer[2048];
      int last_error_code = GetLastError();
      FormatMessageA(FORMAT_MESSAGE_FROM_SYSTEM | FORMAT_MESSAGE_IGNORE_INSERTS, NULL, last_error_code, MAKELANGID(LANG_NEUTRAL, SUBLANG_DEFAULT), (LPSTR)error_buffer, sizeof(error_buffer), NULL);
      lua_pushstring(L, error_buffer);
    } else {
      initialized = luaL_ref(L, LUA_REGISTRYINDEX);
      lua_pushboolean(L, 1);
    }
  #else
    if (isatty(STDIN_FILENO)) {
      initialized = luaL_ref(L, LUA_REGISTRYINDEX);
      tcgetattr(STDIN_FILENO, &original_term);
      struct termios term = {0};
      tcgetattr(STDIN_FILENO, &term);
      term.c_lflag &= ~(ECHO | ICANON | ISIG | IXON | IEXTEN);
      term.c_iflag &= ~(IXON);
      tcsetattr(STDIN_FILENO, TCSANOW, &term);
      lua_pushboolean(L, 1);
    } else
      lua_pushboolean(L, 0);
  #endif
  return 2;
}

static const luaL_Reg quetta_api[] = {
  { "__gc",        f_quetta_gc          },
  { "init",        f_quetta_init        },
  { "size",        f_quetta_size        },
  { "read",        f_quetta_read        },
  { "end_frame",   f_quetta_end_frame   },
  { "draw_rect",   f_quetta_draw_rect   },
  { "draw_text",   f_quetta_draw_text   },
  { NULL,      NULL                     }
};


#ifndef LIBQUETTA_VERSION
  #define LIBQUETTA_VERSION "unknown"
#endif

#ifndef LIBQUETTA_STANDALONE
int luaopen_lite_xl_libquetta(lua_State* L, void* XL) {
  lite_xl_plugin_init(XL);
#else
int luaopen_libquetta(lua_State* L) {
#endif
  luaL_newmetatable(L, "libquetta");
  luaL_setfuncs(L, quetta_api, 0);
  lua_pushliteral(L, LIBQUETTA_VERSION);
  lua_setfield(L, -2, "version");
  lua_pushvalue(L, -1);
  lua_setfield(L, -2, "__index");
  lua_pushvalue(L, -1);
  lua_setmetatable(L, -2);

  return 1;
}

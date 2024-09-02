#!/bin/bash

: ${CC=gcc}
: ${BIN=libquetta.so}

CFLAGS="$CFLAGS -fPIC -Ilib/lite-xl/resources/include"
LDFLAGS=""

[[ "$@" == "clean" ]] && rm -f *.so *.dll && exit 0
[[ $OSTYPE != 'msys'* && $CC != *'mingw'* ]] && LDFLAGS="$LDFLAGS -lutil"
$CC $CFLAGS *.c $@ -shared -o $BIN


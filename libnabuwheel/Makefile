# libnabuwheel - static library

CFLAGS  ?= -std=c11 -Wall -Wextra -O2
override CFLAGS += -Iinclude

SRCS := src/wheel.c src/scramble.c src/pak.c src/packets.c
OBJS := $(SRCS:.c=.o)

all: libnabuwheel.a

libnabuwheel.a: $(OBJS)
	ar rcs $@ $^

%.o: %.c include/nabuwheel.h src/internal.h
	$(CC) $(CFLAGS) -c -o $@ $<

clean:
	rm -f $(OBJS) libnabuwheel.a

.PHONY: all clean

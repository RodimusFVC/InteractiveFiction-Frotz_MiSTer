# Makefile for Amiga Frotz 2.55
# Cross-compilation with m68k-amigaos-gcc
# GNU make is required.

# Cross-compiler toolchain
PREFIX_TOOL = /opt/amiga/bin/m68k-amigaos-
CC      = $(PREFIX_TOOL)gcc
STRIP   = $(PREFIX_TOOL)strip

# Compiler flags
CFLAGS  = -O2 -noixemul -I. -DAMIGA -Wall -Wno-int-conversion
LDFLAGS = -noixemul
LIBS    = -lm

# Installation directory (parent of Source/)
DESTDIR = ..

# Targets
FROTZ      = Frotz
FROTZSTDIO = FrotzStdIO

# ---------- Source files ----------

# Z-machine core (shared by both targets)
CORE_SRCS = \
	buffer.c \
	err.c \
	fastmem.c \
	files.c \
	getopt.c \
	hotkey.c \
	input.c \
	main.c \
	math.c \
	missing.c \
	object.c \
	process.c \
	quetzal.c \
	random.c \
	redirect.c \
	screen.c \
	sound.c \
	stream.c \
	table.c \
	text.c \
	variable.c \
	blorblib.c \
	amiga_port.c

# Amiga GUI interface
GUI_SRCS = \
	amiga.c \
	amiga_prefs.c \
	amiga_sound.c \
	amiga_start.c \
	amiga_list.c \
	checkbox.c \
	bgui_varargs.c

# Amiga StdIO (serial/console) interface
STDIO_SRCS = \
	amiga_stdio.c

# ---------- Object files ----------

CORE_OBJS  = $(CORE_SRCS:.c=.o)
GUI_OBJS   = $(GUI_SRCS:.c=.o)
STDIO_OBJS = $(STDIO_SRCS:.c=.o)

# ---------- Header dependencies ----------

CORE_HDRS  = frotz.h defs.h setup.h hash.h missing.h unused.h
BLORB_HDRS = blorb.h blorblow.h
AMIGA_HDRS = amiga.h amiga_port.h

# ---------- Targets ----------

.PHONY: all clean install strip test

all: $(FROTZ) $(FROTZSTDIO)

# Host regression checks do not require the Amiga SDK.
test:
	python3 tests/test_port.py

$(FROTZ): $(CORE_OBJS) $(GUI_OBJS)
	$(CC) $(LDFLAGS) -o $@ $^ $(LIBS)

$(FROTZSTDIO): $(CORE_OBJS) $(STDIO_OBJS)
	$(CC) $(LDFLAGS) -o $@ $^ $(LIBS)

strip: all
	$(STRIP) $(FROTZ) $(FROTZSTDIO)

install: all
	cp $(FROTZ) $(FROTZSTDIO) $(DESTDIR)/

clean:
	rm -f *.o $(FROTZ) $(FROTZSTDIO)

# ---------- Implicit rule ----------

%.o: %.c
	$(CC) $(CFLAGS) -c $< -o $@

# ---------- Dependencies ----------

# Core Z-machine sources depend on frotz.h and its includes
$(CORE_OBJS): $(CORE_HDRS)

# Blorb-aware sources
blorblib.o: $(BLORB_HDRS)

# Amiga GUI sources depend on amiga.h and frotz.h
amiga.o:         $(CORE_HDRS) $(BLORB_HDRS) $(AMIGA_HDRS)
amiga_prefs.o:   $(CORE_HDRS) $(AMIGA_HDRS) checkbox.h
amiga_sound.o:   $(CORE_HDRS) $(BLORB_HDRS) $(AMIGA_HDRS)
amiga_start.o:   $(CORE_HDRS) $(AMIGA_HDRS)
amiga_list.o:    $(CORE_HDRS) $(AMIGA_HDRS)
checkbox.o:      checkbox.h

# Amiga StdIO source
amiga_stdio.o amiga_port.o: $(CORE_HDRS) $(BLORB_HDRS) amiga_port.h

# BGUI varargs stubs (no local header dependencies)
bgui_varargs.o:  bgui_varargs.c

LUA_VERSION = 5.2
LUA = lua$(LUA_VERSION)

ALL_LUA := $(wildcard cqp/*.lua cqp/*/*.lua)
ALL_SO  := cqp/protocol/modem.so cqp/protocol/i2c.so

all: $(ALL_SO)

%.so: %.c
	gcc $(CFLAGS) -fPIC $(shell pkg-config --cflags $(LUA)) -shared $< -o $@ $(shell pkg-config --libs $(LUA))

install: all
	for f in $(ALL_LUA); do \
		install -D -m644 $$f $(DESTDIR)/usr/share/lua/$(LUA_VERSION)/$$f ; \
	done
	for f in $(ALL_SO); do \
		install -D -m644 $$f $(DESTDIR)/usr/lib/lua/$(LUA_VERSION)/$$f ; \
	done

clean:
	rm $(ALL_SO)

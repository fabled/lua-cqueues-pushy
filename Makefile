LUA = lua5.2

ALL_LUA := $(wildcard cqp/*.lua cqp/*/*.lua)

all: cqp/protocol/modem.so

%.so: %.c
	gcc $(CFLAGS) -fPIC $(shell pkg-config --cflags $(LUA)) -shared $< -o $@ $(shell pkg-config --libs $(LUA))

install: all
	for f in $(ALL_LUA) cqp/protocol/modem.so; do \
		install -D -m644 $$f $(DESTDIR)/usr/share/lua/5.2/$$f ; \
	done

clean:
	rm cqp/protocol/modem.so

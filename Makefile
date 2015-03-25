LUA = lua5.2

all: tvsc/protocol/modem.so

%.so: %.c
	gcc $(CFLAGS) -fPIC $(shell pkg-config --cflags $(LUA)) -shared $< -o $@ $(shell pkg-config --libs $(LUA))

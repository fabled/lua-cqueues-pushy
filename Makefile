LUA = lua5.2

all: cqp/protocol/modem.so

%.so: %.c
	gcc $(CFLAGS) -fPIC $(shell pkg-config --cflags $(LUA)) -shared $< -o $@ $(shell pkg-config --libs $(LUA))

clean:
	rm cqp/protocol/modem.so

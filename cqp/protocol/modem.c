#include <stdio.h>
#include <errno.h>
#include <string.h>
#include <sys/ioctl.h>

#include "lua.h"
#include "lualib.h"
#include "lauxlib.h"

static int pusherror(lua_State *L, const char *info)
{
	lua_pushnil(L);
	lua_pushfstring(L, "%s: %s", info, strerror(errno));
	lua_pushinteger(L, errno);
	return 3;
}

static int PTIOCMGET(lua_State *L)
{
	int fd = luaL_checkinteger(L, 1);
	unsigned int mflags;
	if (ioctl(fd, TIOCMGET, &mflags) < 0) return pusherror(L, "TIOCMGET");
	lua_pushinteger(L, mflags);
	return 1;
}

static int PTIOCMBIS(lua_State *L)
{
	lua_Integer fd = luaL_checkinteger(L, 1);
	unsigned int mflags = luaL_checkinteger(L, 2);
	if (ioctl(fd, TIOCMBIS, &mflags) < 0) return pusherror(L, "TIOCMBIS");
	lua_pushinteger(L, mflags);
	return 0;
}

static int PTIOCMBIC(lua_State *L)
{
	int fd = luaL_checkinteger(L, 1);
	unsigned int mflags = luaL_checkinteger(L, 2);
	if (ioctl(fd, TIOCMBIC, &mflags) < 0) return pusherror(L, "TIOCMBIC");
	return 0;
}

static int PTIOCMSET(lua_State *L)
{
	int fd = luaL_checkinteger(L, 1);
	unsigned int mflags = luaL_checkinteger(L, 2);
	if (ioctl(fd, TIOCMSET, &mflags) < 0) return pusherror(L, "TIOCMSET");
	return 0;
}

static const luaL_Reg R[] = {
	{ "TIOCMGET", PTIOCMGET },
	{ "TIOCMBIS", PTIOCMBIS },
	{ "TIOCMBIC", PTIOCMBIC  },
	{ "TIOCMSET", PTIOCMSET },
	{ 0 }
};

static void setuint(lua_State *L, const char *key, unsigned value)
{
	lua_pushinteger(L, value);
	lua_setfield(L, -2, key);
}

#define defineuint(x) setuint(L, #x, x)

LUALIB_API int luaopen_cqp_protocol_modem(lua_State *L)
{
	lua_newtable(L);
	luaL_setfuncs(L, R, 0);

	defineuint(TIOCM_LE);
	defineuint(TIOCM_DTR);
	defineuint(TIOCM_RTS);
	defineuint(TIOCM_ST);
	defineuint(TIOCM_SR);
	defineuint(TIOCM_CTS);
	defineuint(TIOCM_CAR);
	defineuint(TIOCM_RNG);
	defineuint(TIOCM_DSR);
	defineuint(TIOCM_OUT1);
	defineuint(TIOCM_OUT2);
	defineuint(TIOCM_LOOP);

	return 1;
}


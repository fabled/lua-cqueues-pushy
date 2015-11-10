#include <stdio.h>
#include <errno.h>
#include <string.h>
#include <sys/ioctl.h>
#include <linux/i2c-dev.h>

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

static int PI2C_SLAVE(lua_State *L)
{
	int fd = luaL_checkinteger(L, 1);
	int addr = luaL_checkinteger(L, 2);
	if (ioctl(fd, I2C_SLAVE, addr) < 0) return pusherror(L, "I2C_SLAVE");
	return 1;
}

static const luaL_Reg R[] = {
	{ "I2C_SLAVE", PI2C_SLAVE },
	{ 0 }
};

static void setuint(lua_State *L, const char *key, unsigned value)
{
	lua_pushinteger(L, value);
	lua_setfield(L, -2, key);
}

#define defineuint(x) setuint(L, #x, x)

LUALIB_API int luaopen_cqp_protocol_i2c(lua_State *L)
{
	lua_newtable(L);
	luaL_setfuncs(L, R, 0);

	return 1;
}


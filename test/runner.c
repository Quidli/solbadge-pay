// Host runner: the badge's own Lua (vendored sources, 32-bit numbers) with the
// same standard libraries the badge opens, plus host_load/host_read for the harness.
#include <stdio.h>
#include <stdlib.h>
#include "lua.h"
#include "lauxlib.h"
#include "lualib.h"

int lh_cstack_check(void) { return 0; }
void lh_charge_steps(lua_State *L, unsigned int n) { (void)L; (void)n; }
void lh_thread_new(lua_State *L1) { (void)L1; }

static int host_load(lua_State *L) {
    const char *path = luaL_checkstring(L, 1);
    if (luaL_loadfilex(L, path, "t") != LUA_OK) { lua_pushnil(L); lua_insert(L, -2); return 2; }
    return 1;
}
static int host_read(lua_State *L) {
    FILE *f = fopen(luaL_checkstring(L, 1), "rb");
    if (!f) return 0;
    luaL_Buffer b; luaL_buffinit(L, &b);
    char buf[4096]; size_t n;
    while ((n = fread(buf, 1, sizeof buf, f)) > 0) luaL_addlstring(&b, buf, n);
    fclose(f); luaL_pushresult(&b); return 1;
}
int main(int argc, char **argv) {
    if (argc < 3) { fprintf(stderr, "usage: runner harness.lua app/main.lua [dir]\n"); return 2; }
    lua_State *L = luaL_newstate();
    static const luaL_Reg libs[] = {
        {LUA_GNAME, luaopen_base}, {LUA_COLIBNAME, luaopen_coroutine}, {LUA_STRLIBNAME, luaopen_string},
        {LUA_TABLIBNAME, luaopen_table}, {LUA_MATHLIBNAME, luaopen_math}, {LUA_UTF8LIBNAME, luaopen_utf8},
    };
    for (size_t i = 0; i < sizeof libs / sizeof libs[0]; i++) { luaL_requiref(L, libs[i].name, libs[i].func, 1); lua_pop(L, 1); }
    lua_register(L, "host_load", host_load);
    lua_register(L, "host_read", host_read);
    lua_pushstring(L, argv[2]); lua_setglobal(L, "APP");
    lua_pushstring(L, argc > 3 ? argv[3] : "."); lua_setglobal(L, "DATA");
    if (luaL_dofile(L, argv[1]) != LUA_OK) { fprintf(stderr, "ERROR: %s\n", lua_tostring(L, -1)); return 1; }
    return 0;
}

-- JNI bridge to org.koreader.kbhelper.Kb (shipped as kbhelper.dex, loaded at runtime).
local android = require("android")
local ffi = require("ffi")
local logger = require("logger")

local Bridge = { cls = nil }

local function vm() return android.app.activity.vm end
local function activity() return android.app.activity.clazz end

-- Run fn(env, jni) attached to the JVM, clearing any pending Java exception.
local function withEnv(fn)
    return android.jni:context(vm(), function(jni)
        local env = jni.env
        local ok, res = pcall(fn, env, jni)
        if env[0].ExceptionCheck(env) ~= 0 then
            env[0].ExceptionDescribe(env)
            env[0].ExceptionClear(env)
            ok, res = false, "java exception"
        end
        if not ok then logger.warn("androidkeyboard bridge:", res) return nil end
        return res
    end)
end

-- A JNI call on a null object aborts the whole app, so check every object first.
local function nn(v, what)
    if v == nil then error(what .. " is null") end
    return v
end

local function jstr(env, s) return env[0].NewStringUTF(env, s) end

-- dex_src: path of kbhelper.dex inside the plugin. Returns true on success.
function Bridge:load(dex_src)
    if self.cls then return true end
    local ok = withEnv(function(env, jni)
        -- (Android 8.0 throws an NPE from DexClassLoader unless optimizedDirectory is non-null.)
        -- Copy to the app's private code cache and make it read-only (required on Android 14+).
        local cache = nn(jni:callObjectMethod(nn(activity(), "activity"), "getCodeCacheDir", "()Ljava/io/File;"), "code cache dir")
        local cache_path = jni:to_string(nn(jni:callObjectMethod(cache, "getAbsolutePath", "()Ljava/lang/String;"), "cache path"))
        local dst = cache_path .. "/kbhelper.dex"

        local fcls = env[0].FindClass(env, "java/io/File")
        local fctor = env[0].GetMethodID(env, fcls, "<init>", "(Ljava/lang/String;)V")
        local old = nn(env[0].NewObject(env, fcls, fctor, jstr(env, dst)), "File")
        local exists = jni:callBooleanMethod(old, "exists", "()Z")
        if exists ~= 0 and exists ~= false then
            jni:callBooleanMethod(old, "setWritable", "(Z)Z", 1)
            jni:callBooleanMethod(old, "delete", "()Z")
        end
        local i = io.open(dex_src, "rb")
        if not i then error("cannot read " .. dex_src) end
        local data = i:read("*a"); i:close()
        local o = assert(io.open(dst, "wb")); o:write(data); o:close()
        local f = nn(env[0].NewObject(env, fcls, fctor, jstr(env, dst)), "File")
        jni:callBooleanMethod(f, "setReadOnly", "()Z")

        local lcls = env[0].FindClass(env, "dalvik/system/DexClassLoader")
        local lctor = env[0].GetMethodID(env, lcls, "<init>",
            "(Ljava/lang/String;Ljava/lang/String;Ljava/lang/String;Ljava/lang/ClassLoader;)V")
        local parent = nn(jni:callObjectMethod(activity(), "getClassLoader", "()Ljava/lang/ClassLoader;"), "parent class loader")
        local loader = nn(env[0].NewObject(env, lcls, lctor, jstr(env, dst), jstr(env, cache_path), nil, parent), "DexClassLoader")
        local cls = jni:callObjectMethod(loader, "loadClass", "(Ljava/lang/String;)Ljava/lang/Class;",
            jstr(env, "org.koreader.kbhelper.Kb"))
        nn(cls, "Kb class")
        self.cls = env[0].NewGlobalRef(env, cls)

        local mid = env[0].GetStaticMethodID(env, self.cls, "init", "(Landroid/app/Activity;)V")
        env[0].CallStaticVoidMethod(env, self.cls, mid, activity())
        return true
    end)
    if not ok then self.cls = nil end
    return ok == true
end

local function callStaticVoid(name, sig, ...)
    local args = { ... }
    return withEnv(function(env)
        local mid = env[0].GetStaticMethodID(env, Bridge.cls, name, sig)
        local conv = {}
        for i, a in ipairs(args) do
            if type(a) == "function" then
                conv[i] = a(env)
            elseif type(a) == "number" then
                -- JNI varargs read C ints; a bare Lua number would be passed as a double.
                conv[i] = ffi.cast("int32_t", a)
            else
                conv[i] = a
            end
        end
        env[0].CallStaticVoidMethod(env, Bridge.cls, mid, unpack(conv))
        return true
    end)
end

local function S(s) return function(env) return jstr(env, s) end end

function Bridge:show(text, cursor, input_type, ime_options, single_line)
    callStaticVoid("show", "(Ljava/lang/String;IIIZ)V", S(text), cursor, input_type, ime_options, single_line and 1 or 0)
end
function Bridge:reshow() callStaticVoid("reshow", "()V") end
function Bridge:hide() callStaticVoid("hide", "()V") end
function Bridge:push(text, cursor) callStaticVoid("push", "(Ljava/lang/String;I)V", S(text), cursor) end

function Bridge:imeHeight()
    return withEnv(function(env)
        local mid = env[0].GetStaticMethodID(env, self.cls, "imeHeight", "()I")
        return tonumber(env[0].CallStaticIntMethod(env, self.cls, mid))
    end) or 0
end

-- Returns cursor (code points), flags, text; or nil if nothing changed.
function Bridge:poll()
    local res = withEnv(function(env, jni)
        local mid = env[0].GetStaticMethodID(env, self.cls, "poll", "()Ljava/lang/String;")
        local js = env[0].CallStaticObjectMethod(env, self.cls, mid)
        if js == nil then return false end
        return jni:to_string(js)
    end)
    if not res then return nil end
    local cur, flags, text = res:match("^(%d+),(%d+),(.*)$")
    if not cur then return nil end
    return tonumber(cur), tonumber(flags), text
end

return Bridge

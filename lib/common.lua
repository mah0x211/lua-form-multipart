--
-- Copyright (C) 2022 Masatoshi Fukunaga
--
-- Permission is hereby granted, free of charge, to any person obtaining a copy
-- of this software and associated documentation files (the "Software"), to deal
-- in the Software without restriction, including without limitation the rights
-- to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
-- copies of the Software, and to permit persons to whom the Software is
-- furnished to do so, subject to the following conditions:
--
-- The above copyright notice and this permission notice shall be included in
-- all copies or substantial portions of the Software.
--
-- THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
-- IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
-- FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT.  IN NO EVENT SHALL THE
-- AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
-- LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
-- OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
-- THE SOFTWARE.
--
local pcall = pcall
local type = type
local find = string.find
local format = string.format
local sub = string.sub

local IS_LUA51 = _VERSION == 'Lua 5.1' and not _G.jit

-- Stock Lua 5.1 cannot yield across pcall. Keep the real pcall for validation.
local function unsecure_pcall(fn, ...)
    return true, fn(...)
end

local protected_call = pcall
if IS_LUA51 then
    protected_call = unsecure_pcall
end

--- Validate the optional timeout returned by an I/O method.
--- @param timeout any
--- @param method string
local function check_timeout(timeout, method)
    if timeout ~= nil and type(timeout) ~= 'boolean' then
        error(method .. ' timeout must be boolean or nil', 2)
    end
end

--- is_valid_boundary
--- @param boundary string
--- @return boolean ok
--- @return string? err
local function is_valid_boundary(boundary)
    --
    -- boundary := 0*69<bchars> bcharsnospace
    --
    -- bchars := bcharsnospace / " "
    --
    -- bcharsnospace := DIGIT / ALPHA / "'" / "(" / ")" /
    --                  "+" / "_" / "," / "-" / "." /
    --                  "/" / ":" / "=" / "?"
    --
    if type(boundary) ~= 'string' then
        error('boundary must be string', 2)
    end

    if #boundary < 1 or #boundary > 70 then
        return false, 'boundary length must be between 1 and 70 bytes'
    elseif sub(boundary, -1) == ' ' then
        return false, 'boundary must not end with a space'
    end

    local pos = find(boundary, '[^0-9a-zA-Z \'()+_,-./:=?]')
    if pos then
        -- A character outside bchars was found.
        return false, format('invalid character %q found in boundary',
                             sub(boundary, pos, pos))

    end
    return true
end

return {
    IS_LUA51 = IS_LUA51,
    protected_call = protected_call,
    check_timeout = check_timeout,
    is_valid_boundary = is_valid_boundary,
}

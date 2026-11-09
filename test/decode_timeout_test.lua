local testcase = require('testcase')
local assert = require('assert')
local errlib = require('error')
local errno = require('errno')
local mkstemp = require('mkstemp')
local readdir = require('testcase.readdir')
local multipart = require('form.multipart')
local prefixes = {}
local header = '--b\r\nContent-Disposition: form-data; name="text"\r\n\r\n'
local file_header = '--b\r\nContent-Disposition: form-data; name="upload"; filename="x"\r\n\r\n'
local body = header .. 'value\r\n--b--'

local function paths(prefix)
    local found = {}
    assert.is_nil(readdir('.', function(name)
        if name:sub(1, #prefix + 1) == prefix .. '_' then found[#found + 1] = name end
    end))
    return found
end

local function temp_prefix()
    local file, _, pathname = assert(mkstemp('./decode_timeout_XXXXXX'))
    file:close()
    assert(os.remove(pathname))
    local prefix = pathname:gsub('^%./', '')
    prefixes[#prefixes + 1] = prefix
    return prefix
end

function testcase.after_each()
    collectgarbage('restart')
    for _, prefix in ipairs(prefixes) do
        for _, pathname in ipairs(paths(prefix)) do os.remove(pathname) end
    end
    prefixes = {}
end

function testcase.decode_preserves_reader_timeouts_in_every_parsing_phase()
    for _, input in ipairs({
        false, '--', string.rep('x', 32), '--b \t', '--b \r', '--bfoo\r\n',
        '--b\r\nContent-Disposition:',
        '--b\r\nContent-Disposition: form-data;\r\n ',
        header .. 'value', file_header .. string.rep('x', 32),
        header .. 'value\r\n--b \t', header .. 'value\r\n--b \r',
        body, body .. ' \t', body .. '\r', body .. '\r\n', body .. '\r\nepilogue',
        file_header .. 'value\r\n--b--\r\n',
        file_header .. 'first\r\n--b\r\n' ..
            'Content-Disposition: form-data; name="upload"; filename="y"\r\n\r\nsecond',
    }) do
        for _, cause in ipairs({ false, 'read timed out', errno.EAGAIN:new('read timed out') }) do
            for _, with_data in ipairs({ false, true }) do
                local prefix = temp_prefix()
                local calls = 0
                collectgarbage('stop')
                local form, err, timeout = multipart.decode({
                    read = function()
                        calls = calls + 1
                        if input and calls == 1 then return input end
                        return with_data and 'ignored data' or nil, cause or nil, true
                    end,
                }, 'b', { filetmpl = prefix, maxsize = 1024 })
                collectgarbage('restart')
                assert.is_nil(form)
                assert.is_true(timeout)
                assert.equal(calls, input and 2 or 1)
                if cause then
                    assert.equal(errlib.typeof(err), multipart.EDECODE)
                    local original = errlib.unwrap(err)
                    if type(cause) == 'string' then
                        assert.equal(tostring(original.message), cause)
                    else
                        assert.is_true(original == cause)
                    end
                else
                    assert.is_nil(err)
                end
                assert.empty(paths(prefix))
            end
        end
    end
end

function testcase.decode_reader_timeout_after_yield_preserves_error_and_flag()
    for _, cause in ipairs({ false, errno.EAGAIN:new('waiting timed out') }) do
        local co = coroutine.create(function()
            return multipart.decode({ read = function()
                coroutine.yield('waiting')
                return nil, cause or nil, true
            end }, 'b')
        end)
        local ok, form = coroutine.resume(co)
        assert(ok, form)
        assert.equal(form, 'waiting')
        local err, timeout
        ok, form, err, timeout = coroutine.resume(co)
        assert(ok, form)
        assert.is_nil(form)
        assert.is_true(timeout)
        if cause then
            assert.equal(errlib.typeof(err), multipart.EDECODE)
            assert.is_true(errlib.unwrap(err) == cause)
        else
            assert.is_nil(err)
        end
        assert.equal(coroutine.status(co), 'dead')
    end
end

function testcase.decode_accepts_real_eof_with_a_false_timeout_flag()
    for _, ending in ipairs({ '', ' \t', '\r\n' }) do
        local calls = 0
        local form, err, timeout = multipart.decode({ read = function()
            calls = calls + 1
            if calls == 1 then return body .. ending, nil, false end
            assert.equal(calls, 2)
            return nil, nil, false
        end }, 'b')
        assert.is_nil(err)
        assert.is_nil(timeout)
        assert.equal(form.text[1].data, 'value')
        assert.equal(calls, 2)
    end
end

function testcase.decode_file_reader_errno_is_not_a_timeout()
    local prefix = temp_prefix()
    local file = assert(io.open(prefix .. '_input', 'w'))
    local ok, form, err, timeout = pcall(multipart.decode, file, 'b')
    local state = io.type(file)
    file:close()
    assert.is_true(ok)
    assert.is_nil(form)
    assert.equal(errlib.typeof(err), multipart.EDECODE)
    assert.not_nil(errlib.is(err, errno.EBADF))
    assert.equal(errlib.is(err, errno.EBADF).op, 'read')
    assert.is_nil(timeout)
    assert.equal(state, 'file')
end

function testcase.decode_rejects_nonboolean_reader_timeout_results()
    local is_lua51 = _VERSION == 'Lua 5.1' and not _G.jit
    for _, invalid in ipairs({ 0, 1, -1, 'true', {}, function() end,
        coroutine.create(function() end), io.stdout }) do
        for _, cause in ipairs({ false, errno.EIO:new('read failed') }) do
            local calls = 0
            local ok, form, err, timeout = pcall(multipart.decode, {
                read = function()
                    calls = calls + 1
                    return 'partial data', cause or nil, invalid
                end,
            }, 'b')
            if is_lua51 then
                assert.is_false(ok)
                assert.match(tostring(form), 'reader.read timeout must be boolean or nil')
            else
                assert.is_true(ok)
                assert.is_nil(form)
                assert.equal(errlib.typeof(err), multipart.EDECODE)
                assert.match(tostring(err), 'reader.read timeout must be boolean or nil')
            end
            assert.is_nil(timeout)
            assert.equal(calls, 1)
        end
    end
end

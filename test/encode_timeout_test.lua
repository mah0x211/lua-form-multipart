local testcase = require('testcase')
local assert = require('assert')
local errlib = require('error')
local errno = require('errno')
local mkstemp = require('mkstemp')
local multipart = require('form.multipart')
local file, pathname

function testcase.before_all()
    local err
    file, err, pathname = mkstemp('./encode_timeout_XXXXXX')
    assert(file, err)
    assert(file:write('payload'))
end

function testcase.after_all()
    if file and io.type(file) == 'file' then file:close() end
    if pathname then os.remove(pathname) end
end

local function text_form()
    return { text = {{
        data = 'value',
        header = { ['X-Test'] = { 'metadata' } },
    }} }
end

function testcase.encode_stops_at_every_write_on_timeout()
    for _, case in ipairs({
        { form = text_form(), steps = 6 },
        { form = { text = { 'value' } }, steps = 5 },
    }) do
        for fail_at = 1, case.steps do
            for _, partial in ipairs({ false, true }) do
                local calls = 0
                local n, err, timeout = multipart.encode(case.form, 'b', {
                    write = function(_, s)
                        calls = calls + 1
                        if calls == fail_at then return partial and 1 or nil, nil, true end
                        return #s
                    end,
                    writefile = function() error('not a file part') end,
                })
                assert.is_nil(n)
                assert.is_nil(err)
                assert.is_true(timeout)
                assert.equal(calls, fail_at)
            end
        end
    end
end

function testcase.encode_keeps_error_causes_and_timeout_flags()
    for fail_at = 1, 6 do
        for _, partial in ipairs({ false, true }) do
            for _, typed in ipairs({ false, true }) do
                local cause = typed and errno.EAGAIN:new('write timed out') or 'write timed out'
                local calls = 0
                local n, err, timeout = multipart.encode(text_form(), 'b', {
                    write = function(_, s)
                        calls = calls + 1
                        if calls == fail_at then return partial and 1 or nil, cause, true end
                        return #s
                    end,
                    writefile = function() error('not a file part') end,
                })
                assert.is_nil(n)
                assert.is_true(timeout)
                assert.equal(errlib.typeof(err), multipart.EENCODE)
                if typed then
                    assert.is_true(errlib.unwrap(err) == cause)
                else
                    assert.equal(tostring(errlib.unwrap(err).message), cause)
                end
                assert.equal(calls, fail_at)
            end
        end
    end
end

function testcase.encode_file_timeouts_close_only_owned_handles()
    for _, owned in ipairs({ false, true }) do
        for fail_at = 1, 6 do
            for _, cause in ipairs({ false, 'file timed out' }) do
                assert(file:seek('set'))
                local part = {
                    filename = 'x',
                    header = { ['X-Test'] = { 'metadata' } },
                }
                if owned then part.pathname = pathname else part.file = file end
                local calls = 0
                local captured
                local function result(n)
                    calls = calls + 1
                    if calls == fail_at then return 1, cause or nil, true end
                    return n
                end
                collectgarbage('stop')
                local n, err, timeout = multipart.encode({ upload = { part } }, 'b', {
                    write = function(_, s) return result(#s) end,
                    writefile = function(_, src, len)
                        captured = src
                        return result(len)
                    end,
                })
                collectgarbage('restart')
                assert.is_nil(n)
                assert.is_true(timeout)
                assert.equal(calls, fail_at)
                if cause then
                    assert.equal(errlib.typeof(err), multipart.EENCODE)
                    assert.equal(tostring(errlib.unwrap(err).message), cause)
                else
                    assert.is_nil(err)
                end
                if captured then
                    assert.equal(io.type(captured), owned and 'closed file' or 'file')
                end
                assert.equal(io.type(file), 'file')
                assert.is_nil(part.is_tmpfile)
                if owned then assert.is_nil(part.file) end
            end
        end
    end
end

function testcase.encode_writer_timeout_after_yield_is_returned_to_caller()
    assert(file:seek('set'))
    local co = coroutine.create(function()
        return multipart.encode({ upload = {{ filename = 'x', file = file }} }, 'b', {
            write = function(_, s) return #s end,
            writefile = function()
                coroutine.yield('waiting')
                return nil, nil, true
            end,
        })
    end)
    local ok, n = coroutine.resume(co)
    assert(ok, n)
    assert.equal(n, 'waiting')
    local err, timeout
    ok, n, err, timeout = coroutine.resume(co)
    assert(ok, n)
    assert.is_nil(n)
    assert.is_nil(err)
    assert.is_true(timeout)
    assert.equal(coroutine.status(co), 'dead')
    assert.equal(io.type(file), 'file')
end

function testcase.encode_counts_complete_writes_without_retrying()
    local calls, total = 0, 0
    local n, err, timeout = multipart.encode(text_form(), 'b', {
        write = function(_, s)
            calls = calls + 1
            total = total + #s
            return #s, nil, false
        end,
        writefile = function() error('not a file part') end,
    })
    assert.equal(calls, 6)
    assert.equal(n, total)
    assert.is_nil(err)
    assert.is_nil(timeout)
end

function testcase.encode_stops_on_missing_byte_count_without_error_or_timeout()
    for fail_at = 1, 6 do
        local calls = 0
        local n, err, timeout = multipart.encode(text_form(), 'b', {
            write = function(_, s)
                calls = calls + 1
                if calls == fail_at then return nil end
                return #s
            end,
            writefile = function() error('not a file part') end,
        })
        assert.is_nil(n)
        assert.equal(errlib.typeof(err), multipart.EENCODE)
        assert.is_nil(timeout)
        assert.equal(calls, fail_at)
    end
end

local IS_LUA51 = _VERSION == 'Lua 5.1' and not _G.jit

local function invalid_timeouts()
    return { 0, 1, -1, 'true', {}, function() end,
        coroutine.create(function() end), file }
end

local function assert_timeout_type_error(method, ok, result, err, timeout)
    local message = method .. ' timeout must be boolean or nil'
    if IS_LUA51 then
        assert.is_false(ok)
        assert.match(tostring(result), message)
    else
        assert.is_true(ok)
        assert.is_nil(result)
        assert.equal(errlib.typeof(err), multipart.EENCODE)
        assert.match(tostring(err), message)
    end
    assert.is_nil(timeout)
end

function testcase.encode_rejects_nonboolean_write_timeout_results()
    for _, invalid in ipairs(invalid_timeouts()) do
        for fail_at = 1, 6 do
            local calls = 0
            assert_timeout_type_error('writer.write',
                pcall(multipart.encode, text_form(), 'b', {
                    write = function(_, s)
                        calls = calls + 1
                        if calls == fail_at then return #s, 'I/O error', invalid end
                        return #s
                    end,
                    writefile = function() error('not a file part') end,
                }))
            assert.equal(calls, fail_at)
        end
    end
end

function testcase.encode_rejects_nonboolean_writefile_timeout_results()
    for _, invalid in ipairs(invalid_timeouts()) do
        assert(file:seek('set'))
        local calls = 0
        assert_timeout_type_error('writer.writefile',
            pcall(multipart.encode, { upload = {{ filename = 'x', file = file }} }, 'b', {
                write = function(_, s) return #s end,
                writefile = function(_, _, len)
                    calls = calls + 1
                    return len, nil, invalid
                end,
            }))
        assert.equal(calls, 1)
        assert.equal(io.type(file), 'file')
    end
end

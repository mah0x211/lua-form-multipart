local testcase = require('testcase')
local assert = require('assert')
local errlib = require('error')
local errno = require('errno')
local mkstemp = require('mkstemp')
local readdir = require('testcase.readdir')
local multipart = require('form.multipart')
local IS_LUA51 = _VERSION == 'Lua 5.1' and not _G.jit
local files, prefixes = {}, {}
local header = '--b\r\nContent-Disposition: form-data; name="upload"; filename="x"\r\n\r\n'
local payload = '0123456789\r\nabcdefghijklmnopqrstuvwxyz'

local function paths(prefix)
    local found = {}
    assert.is_nil(readdir('.', function(name)
        if name:sub(1, #prefix + 1) == prefix .. '_' then found[#found + 1] = name end
    end))
    return found
end

local function temp_prefix()
    local file, _, pathname = assert(mkstemp('./decode_writer_XXXXXX'))
    file:close()
    assert(os.remove(pathname))
    local prefix = pathname:gsub('^%./', '')
    prefixes[#prefixes + 1] = prefix
    return prefix
end

function testcase.after_each()
    collectgarbage('restart')
    for _, file in ipairs(files) do
        if io.type(file) == 'file' then file:close() end
    end
    for _, prefix in ipairs(prefixes) do
        for _, pathname in ipairs(paths(prefix)) do os.remove(pathname) end
    end
    files, prefixes = {}, {}
end

function testcase.decode_custom_writer_saves_files_and_leaves_text_fields_unchanged()
    local input = header .. payload .. '\r\n--b\r\n' ..
        'Content-Disposition: form-data; name="text"\r\n\r\nvalue\r\n--b\r\n' ..
        'Content-Disposition: form-data; name="upload"; filename="empty"\r\n\r\n\r\n--b--'
    for _, streaming in ipairs({ false, true }) do
        local calls, written, pos = 0, 0, 1
        local writer = setmetatable({}, { __index = {
            writefile = function(_, file, s)
                assert.equal(io.type(file), 'file')
                calls = calls + 1
                written = written + #s
                files[#files + 1] = file
                assert(file:write(s))
                return #s, nil, false
            end,
        } })
        local source = input
        if streaming then
            source = { read = function(_, n)
                local s = input:sub(pos, pos + n - 1)
                pos = pos + #s
                if #s > 0 then return s end
            end }
        end
        local opts = { filetmpl = temp_prefix(), chunksize = 7, writer = writer }
        local form, err, timeout = multipart.decode(source, 'b', opts)
        assert.is_nil(err)
        assert.is_nil(timeout)
        assert.equal(form.text[1].data, 'value')
        assert.equal(#form.upload, 2)
        assert.equal(written, #payload)
        assert.greater(calls, 1)
        for i, part in ipairs(form.upload) do
            assert.equal(part.file:seek(), 0)
            assert.equal(part.file:read('*a'), i == 1 and payload or '')
        end
        assert.is_true(opts.writer == writer)
        assert.equal(opts.chunksize, 7)
    end
end

function testcase.decode_custom_writer_failures_stop_and_dispose_of_files()
    for _, streaming in ipairs({ false, true }) do
        for _, cause in ipairs({ false, 'write failed', errno.EAGAIN:new('write failed') }) do
            for _, timed_out in ipairs({ false, true }) do
                for _, partial in ipairs({ false, true }) do
                    if cause or timed_out or not partial then
                        local prefix = temp_prefix()
                        local captured, calls = nil, 0
                        local source = header .. payload .. '\r\n--b--'
                        if streaming then
                            source = { read = function()
                                calls = calls + 1
                                assert.equal(calls, 1)
                                return header .. payload
                            end }
                        end
                        local writes = 0
                        collectgarbage('stop')
                        local form, err, timeout = multipart.decode(source, 'b', {
                            filetmpl = prefix,
                            writer = { writefile = function(_, file, s)
                                writes = writes + 1
                                captured = file
                                files[#files + 1] = file
                                if partial then assert(file:write(s:sub(1, 1))) end
                                return partial and 1 or nil, cause or nil, timed_out
                            end },
                        })
                        collectgarbage('restart')
                        assert.is_nil(form)
                        assert.equal(timeout, timed_out)
                        if cause or not timed_out then
                            assert.equal(errlib.typeof(err), multipart.EDECODE)
                            if type(cause) == 'string' then
                                assert.equal(tostring(errlib.unwrap(err).message), cause)
                            elseif cause then
                                assert.is_true(errlib.unwrap(err) == cause)
                            end
                        else
                            assert.is_nil(err)
                        end
                        assert.equal(writes, 1)
                        assert.equal(io.type(captured), 'closed file')
                        assert.empty(paths(prefix))
                    end
                end
            end
        end
    end
end

function testcase.decode_custom_writer_exceptions_obey_the_runtime_cleanup_contract()
    for _, close_first in ipairs({ false, true }) do
        for _, cause in ipairs({ 'writer raised', errno.EIO:new('writer raised') }) do
            local prefix = temp_prefix()
            local captured
            collectgarbage('stop')
            local ok, form, err = pcall(multipart.decode, header .. payload .. '\r\n--b--', 'b', {
                filetmpl = prefix,
                writer = { writefile = function(_, file)
                    captured = file
                    files[#files + 1] = file
                    if close_first then file:close() end
                    error(cause, 0)
                end },
            })
            if IS_LUA51 then
                assert.is_false(ok)
                assert.is_true(form == cause)
                assert.not_empty(paths(prefix))
                collectgarbage('collect')
            else
                assert.is_true(ok)
                assert.is_nil(form)
                assert.equal(errlib.typeof(err), multipart.EDECODE)
            end
            collectgarbage('restart')
            assert.equal(io.type(captured), 'closed file')
            assert.empty(paths(prefix))
        end
    end
end

function testcase.decode_reader_and_writer_can_yield_in_the_same_operation()
    for _, timed_out in ipairs({ false, true }) do
        local prefix = temp_prefix()
        local input = header .. payload .. '\r\n--b--'
        local pos, reads, writes = 1, 0, 0
        local captured
        local co = coroutine.create(function()
            return multipart.decode({ read = function(_, n)
                coroutine.yield('read')
                local s = input:sub(pos, pos + n - 1)
                pos = pos + #s
                if #s > 0 then return s end
            end }, 'b', {
                filetmpl = prefix, chunksize = 7,
                writer = { writefile = function(_, file, s)
                    captured = file
                    files[#files + 1] = file
                    coroutine.yield('write')
                    if timed_out then return nil, nil, true end
                    assert(file:write(s))
                    return #s
                end },
            })
        end)
        while true do
            local ok, result, err, timeout = coroutine.resume(co)
            assert(ok, result)
            if coroutine.status(co) == 'dead' then
                assert.is_nil(err)
                if timed_out then
                    assert.is_nil(result)
                    assert.is_true(timeout)
                    assert.equal(io.type(captured), 'closed file')
                    assert.empty(paths(prefix))
                else
                    assert.is_nil(timeout)
                    assert.equal(result.upload[1].file:read('*a'), payload)
                    assert.equal(io.type(captured), 'file')
                end
                break
            elseif result == 'read' then
                reads = reads + 1
            else
                assert.equal(result, 'write')
                writes = writes + 1
            end
        end
        assert.greater(reads, 0)
        assert.greater(writes, 0)
    end
end

function testcase.decode_rejects_invalid_writers_before_reading()
    local file = assert(io.tmpfile())
    files[#files + 1] = file
    for _, writer in ipairs({
        false, 1, 'writer', function() end, {}, { writefile = false },
        { writefile = 1 }, file,
        setmetatable({}, { __index = function() error('bad writer') end }),
    }) do
        local calls = 0
        local ok, err = pcall(multipart.decode, {
            read = function() calls = calls + 1 end,
        }, 'b', { writer = writer })
        assert.is_false(ok)
        assert.match(tostring(err), 'writer.writefile must be function')
        assert.is_nil(errlib.is(err, multipart.EDECODE))
        assert.equal(calls, 0)
    end
end

function testcase.decode_rejects_nonboolean_writer_timeout_results()
    for _, invalid in ipairs({ 0, 1, -1, 'true', {}, function() end,
        coroutine.create(function() end), io.stdout }) do
        for _, cause in ipairs({ false, errno.EIO:new('write failed') }) do
            local prefix = temp_prefix()
            local captured, calls = nil, 0
            collectgarbage('stop')
            local ok, form, err, timeout = pcall(multipart.decode, header .. payload .. '\r\n--b--', 'b', {
                filetmpl = prefix,
                writer = { writefile = function(_, file, s)
                    captured = file
                    files[#files + 1] = file
                    calls = calls + 1
                    return #s, cause or nil, invalid
                end },
            })
            if IS_LUA51 then
                assert.is_false(ok)
                assert.match(tostring(form), 'writer.writefile timeout must be boolean or nil')
                collectgarbage('collect')
            else
                assert.is_true(ok)
                assert.is_nil(form)
                assert.equal(errlib.typeof(err), multipart.EDECODE)
                assert.match(tostring(err), 'writer.writefile timeout must be boolean or nil')
            end
            collectgarbage('restart')
            assert.is_nil(timeout)
            assert.equal(calls, 1)
            assert.equal(io.type(captured), 'closed file')
            assert.empty(paths(prefix))
        end
    end
end

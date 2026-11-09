local testcase = require('testcase')
local assert = require('assert')
local mkstemp = require('mkstemp')
local readdir = require('testcase.readdir')
local multipart = require('form.multipart')
local IS_LUA51 = _VERSION == 'Lua 5.1' and not _G.jit
local paths = {}
local files = {}

local function temp_file()
    local file, _, pathname = assert(mkstemp('./async_protection_XXXXXX'))
    files[#files + 1] = file
    paths[#paths + 1] = pathname
    return file, pathname
end

function testcase.after_each()
    collectgarbage('restart')
    collectgarbage('collect')
    for _, file in ipairs(files) do
        if io.type(file) == 'file' then file:close() end
    end
    for _, pathname in ipairs(paths) do os.remove(pathname) end
    files, paths = {}, {}
end

function testcase.encode_writer_can_yield_with_owned_and_caller_files()
    local file, pathname = temp_file()
    assert(file:write('payload'))
    assert(file:seek('set'))
    local input = { upload = {
        { filename = 'owned', pathname = pathname },
        { filename = 'caller', file = file },
    } }
    local expected = assert(multipart.encode(input, 'b'))
    assert(file:seek('set'))
    local chunks, captured = {}, {}
    local co = coroutine.create(function()
        return multipart.encode(input, 'b', {
            write = function(_, s)
                coroutine.yield('write')
                chunks[#chunks + 1] = s
                return #s
            end,
            writefile = function(_, src, len, offset, part)
                coroutine.yield('writefile')
                captured[#captured + 1] = { src, part.is_tmpfile }
                assert(src:seek('set', offset))
                chunks[#chunks + 1] = assert(src:read(len))
                return len
            end,
        })
    end)
    local yields = 0
    while true do
        local ok, result, err = coroutine.resume(co)
        assert(ok, result)
        assert.is_nil(err)
        if coroutine.status(co) == 'dead' then
            assert.equal(result, #expected)
            break
        end
        assert.is_true(result == 'write' or result == 'writefile')
        yields = yields + 1
    end
    assert.greater(yields, 2)
    assert.equal(table.concat(chunks), expected)
    for _, item in ipairs(captured) do
        assert.equal(io.type(item[1]), item[2] and 'closed file' or 'file')
    end
    assert.equal(io.type(file), 'file')
end

function testcase.decode_reader_can_yield_and_successful_files_survive_gc()
    local placeholder, prefix = temp_file()
    placeholder:close()
    assert(os.remove(prefix))
    local input = '--b\r\nContent-Disposition: form-data; name="upload"; filename="x"' ..
        '\r\n\r\npayload\r\n--b\r\nContent-Disposition: form-data; name="text"' ..
        '\r\n\r\nvalue\r\n--b--'
    local pos = 1
    local form
    local yields = 0
    do
        local co = coroutine.create(function()
            return multipart.decode({
                read = function(_, n)
                    coroutine.yield('read')
                    if pos > #input then return nil end
                    local s = input:sub(pos, pos + n - 1)
                    pos = pos + #s
                    return s
                end,
            }, 'b', { filetmpl = prefix, chunksize = 7 })
        end)
        while true do
            local ok, result, err = coroutine.resume(co)
            assert(ok, result)
            assert.is_nil(err)
            if coroutine.status(co) == 'dead' then
                form = result
                break
            end
            assert.equal(result, 'read')
            yields = yields + 1
        end
    end
    assert.greater(yields, 2)
    collectgarbage('collect')
    collectgarbage('collect')
    assert.equal(form.text[1].data, 'value')
    local part = form.upload[1]
    files[#files + 1] = part.file
    paths[#paths + 1] = part.pathname
    assert.equal(io.type(part.file), 'file')
    assert.equal(part.file:read('*a'), 'payload')
    local check = assert(io.open(part.pathname))
    check:close()
end

function testcase.encode_raised_errors_clean_owned_files_even_when_retained()
    for _, close_first in ipairs({ false, true }) do
        local file, pathname = temp_file()
        file:write('payload')
        file:close()
        local captured
        local cause = {}
        collectgarbage('stop')
        local ok, result, err = pcall(multipart.encode, {
            upload = {{ filename = 'x', pathname = pathname }},
        }, 'b', {
            write = function(_, s) return #s end,
            writefile = function(_, src)
                captured = src
                files[#files + 1] = src
                if close_first then src:close() end
                error(cause, 0)
            end,
        })
        if IS_LUA51 then
            assert.is_false(ok)
            assert.is_true(result == cause)
            assert.equal(io.type(captured), close_first and 'closed file' or 'file')
        else
            assert.is_true(ok)
            assert.is_nil(result)
            assert.not_nil(err)
            assert.equal(io.type(captured), 'closed file')
        end
        collectgarbage('collect')
        collectgarbage('restart')
        assert.equal(io.type(captured), 'closed file')
        -- Only the library-owned handle is disposed; its source path is kept.
        local check = assert(io.open(pathname))
        check:close()
    end
end

function testcase.decode_raised_errors_remove_all_owned_files_on_gc()
    local file, prefix = temp_file()
    file:close()
    assert(os.remove(prefix))
    local first = true
    local created = {}
    local cause = {}
    collectgarbage('stop')
    local ok, form, err = pcall(multipart.decode, {
        read = function()
            if first then
                first = false
                return '--b\r\nContent-Disposition: form-data; name="upload"; filename="x"' ..
                    '\r\n\r\ncomplete\r\n--b\r\n' ..
                    'Content-Disposition: form-data; name="upload"; filename="y"' ..
                    '\r\n\r\nunfinished'
            end
            assert.is_nil(readdir('.', function(name)
                if name:sub(1, #prefix - 2) == prefix:sub(3) then
                    created[#created + 1] = name
                    paths[#paths + 1] = name
                end
            end))
            assert.equal(#created, 2)
            error(cause, 0)
        end,
    }, 'b', prefix)
    if IS_LUA51 then
        assert.is_false(ok)
        assert.is_true(form == cause)
        for _, pathname in ipairs(created) do
            local check = assert(io.open(pathname))
            check:close()
        end
    else
        assert.is_true(ok)
        assert.is_nil(form)
        assert.not_nil(err)
    end
    collectgarbage('collect')
    collectgarbage('restart')
    for _, pathname in ipairs(created) do
        assert.is_nil(io.open(pathname))
    end
end

function testcase.encode_gc_guard_does_not_keep_failed_writer_tasks_alive()
    local file, pathname = temp_file()
    file:write('payload')
    file:close()
    local captured
    local cause = {}
    collectgarbage('stop')
    do
        local writer = {
            write = function(_, s) return #s end,
            writefile = function(self, src)
                -- Async writers may retain the current task while waiting.
                self.task = coroutine.running()
                captured = src
                files[#files + 1] = src
                coroutine.yield('waiting')
                error(cause, 0)
            end,
        }
        local co = coroutine.create(function()
            return multipart.encode({
                upload = {{ filename = 'x', pathname = pathname }},
            }, 'b', writer)
        end)
        local ok, result = coroutine.resume(co)
        assert.is_true(ok)
        assert.equal(result, 'waiting')
        ok, result = coroutine.resume(co)
        if IS_LUA51 then
            assert.is_false(ok)
            assert.is_true(result == cause)
        else
            assert.is_true(ok)
            assert.is_nil(result)
        end
        assert.equal(coroutine.status(co), 'dead')
    end
    collectgarbage('collect')
    collectgarbage('restart')
    assert.equal(io.type(captured), 'closed file')
end

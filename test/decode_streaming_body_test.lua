local IS_LUA51 = _VERSION == 'Lua 5.1' and not _G.jit
local testcase = require('testcase')
local assert = require('assert')
local errlib = require('error')
local errno = require('errno')
local mkstemp = require('mkstemp')
local readdir = require('testcase.readdir')
local stat = require('testcase.stat')
local multipart = require('form.multipart')
local prefixes = {}
local files = {}

local header = '--b\r\nContent-Disposition: form-data; name="upload"; filename="a"\r\n\r\n'
local ending = '\r\n--b--'

local function files_with_prefix(prefix)
    local found = {}
    local err = readdir('.', function(name)
        if name:sub(1, #prefix + 1) == prefix .. '_' then
            found[#found + 1] = name
        end
    end)
    assert.is_nil(err)
    return found
end

local function unused_prefix()
    local file, _, pathname = assert(mkstemp('./stream_body_XXXXXX'))
    file:close()
    assert(os.remove(pathname))
    local prefix = pathname:gsub('^%./', '')
    prefixes[#prefixes + 1] = prefix
    return prefix
end

local function reader(input)
    local pos = 1
    return {
        read = function(_, n)
            local chunk = input:sub(pos, pos + n - 1)
            pos = pos + #chunk
            if #chunk > 0 then return chunk end
        end,
    }
end

function testcase.before_each()
    collectgarbage('stop')
end

function testcase.after_each()
    for _, file in ipairs(files) do
        if io.type(file) == 'file' then file:close() end
    end
    files = {}
    for _, prefix in ipairs(prefixes) do
        for _, pathname in ipairs(files_with_prefix(prefix)) do os.remove(pathname) end
    end
    prefixes = {}
    collectgarbage('restart')
end

function testcase.decode_writes_newline_free_file_before_reading_its_end()
    local payload = string.rep('x', 64 * 1024)
    local input = header .. payload .. ending
    local prefix = unused_prefix()
    local pos, saved_before_end = 1, 0
    local source = {
        read = function(_, n)
            if pos > #header + 32768 and pos <= #header + #payload then
                for _, pathname in ipairs(files_with_prefix(prefix)) do
                    saved_before_end = assert(stat(pathname)).size
                end
            end
            local chunk = input:sub(pos, pos + n - 1)
            pos = pos + #chunk
            if #chunk > 0 then return chunk end
        end,
    }
    local form, err = multipart.decode(source, 'b', prefix, nil, 4096)
    assert.is_nil(err)
    local file = form.upload[1].file
    files[#files + 1] = file
    -- Observe the real temporary file, allowing for stdio buffering.
    assert.greater(saved_before_end, 32768)
    assert.equal(file:read('*a'), payload)
end

function testcase.decode_keeps_newline_free_file_buffer_bounded()
    local payload = string.rep('x', 256 * 1024)
    local prefix = unused_prefix()
    local baseline = collectgarbage('count')
    local calls = 0
    local source = {
        read = function()
            calls = calls + 1
            collectgarbage('collect')
            -- Generate eight MiB without retaining an eight-MiB input string.
            -- Allow several chunks of headroom, independent of total length.
            assert.less(collectgarbage('count') - baseline, 2048)
            if calls == 1 then return header end
            if calls <= 33 then return payload end
            if calls == 34 then return ending end
        end,
    }
    local form, err = multipart.decode(source, 'b', prefix, nil, #payload)
    assert.is_nil(err)
    local file = form.upload[1].file
    files[#files + 1] = file
    assert.equal(file:seek('end'), 8 * 1024 * 1024)
    assert(file:seek('set'))
    for _ = 1, 32 do assert.equal(file:read(#payload), payload) end
    assert.is_nil(file:read(1))
end

function testcase.decode_preserves_binary_body_and_fragmented_boundaries()
    local bytes = {}
    for i = 0, 255 do bytes[#bytes + 1] = string.char(i) end
    for _, boundary in ipairs({ 'stream', string.rep('b', 70) }) do
        -- Almost-delimiters are data; they differ before the full boundary.
        local payload = string.rep('x', 256) .. table.concat(bytes) ..
            '\r\n--' .. boundary:sub(1, -2) .. '!\n\r' .. string.rep('y', 256)
        for _, newline in ipairs({ '\r\n', '\n' }) do
            local input = '--' .. boundary .. newline ..
                'Content-Disposition: form-data; name="upload"; filename="a"' ..
                newline .. newline .. payload .. newline .. '--' .. boundary ..
                ' \t' .. newline .. 'Content-Disposition: form-data; name="text"' ..
                newline .. newline .. payload .. newline .. '--' .. boundary .. '--'
            for _, chunksize in ipairs({ 1, 2, 7, 64, 4096 }) do
                local form, err = multipart.decode(reader(input), boundary,
                                                  unused_prefix(), #payload, chunksize)
                assert.is_nil(err)
                local file = form.upload[1].file
                files[#files + 1] = file
                assert.equal(file:read('*a'), payload)
                assert.equal(form.text[1].data, payload)
            end
        end
    end
end

function testcase.decode_preserves_newline_heavy_file_and_text_bodies()
    for _, payload in ipairs({
        string.rep('\n', 64),
        string.rep('\r\n', 32),
        string.rep('a\n--!\r\n', 16) .. 'tail\r',
    }) do
        local input = header .. payload ..
            '\r\n--b\r\nContent-Disposition: form-data; name="text"\r\n\r\n' ..
            payload .. ending
        for _, source in ipairs({ input, reader(input) }) do
            local form, err = multipart.decode(source, 'b', {
                filetmpl = unused_prefix(),
                maxfilesize = #payload,
                chunksize = 7,
                maxsize = #input,
            })
            assert.is_nil(err)
            local file = form.upload[1].file
            files[#files + 1] = file
            assert.equal(file:read('*a'), payload)
            assert.equal(form.text[1].data, payload)
        end
    end
end

function testcase.decode_enforces_file_limit_after_streamed_writes()
    local payload = string.rep('x', 16 * 1024)
    local input = header .. payload .. ending
    local form, err = multipart.decode(reader(input), 'b', unused_prefix(),
                                      #payload, 1024)
    assert.is_nil(err)
    local file = form.upload[1].file
    files[#files + 1] = file
    assert.equal(file:read('*a'), payload)

    for _, limit in ipairs({ #payload - 1, 1024, 0 }) do
        local prefix = unused_prefix()
        form, err = multipart.decode(reader(input), 'b', prefix, limit, 1024)
        assert.is_nil(form)
        assert.equal(errlib.typeof(err), multipart.EDECODE)
        assert.not_nil(errlib.is(err, errno.EFBIG))
        assert.match(tostring(err), 'multipart body too large')
        assert.empty(files_with_prefix(prefix))
    end
end

function testcase.decode_cleans_streamed_file_on_total_size_limit()
    local prefix = unused_prefix()
    local input = header .. string.rep('x', 64 * 1024) .. ending
    local maxsize = #header + 48 * 1024
    local pos, saved_before_error = 1, 0
    local source = {
        read = function(_, n)
            for _, pathname in ipairs(files_with_prefix(prefix)) do
                saved_before_error = assert(stat(pathname)).size
            end
            local chunk = input:sub(pos, pos + n - 1)
            pos = pos + #chunk
            if #chunk > 0 then return chunk end
        end,
    }
    local form, err = multipart.decode(source, 'b', {
        filetmpl = prefix,
        chunksize = 1024,
        maxsize = maxsize,
    })
    assert.is_nil(form)
    assert.equal(errlib.typeof(err), multipart.EDECODE)
    assert.not_nil(errlib.is(err, errno.EFBIG))
    assert.match(tostring(err), 'maxsize')
    assert.equal(pos - 1, maxsize + 1)
    assert.greater(saved_before_error, 32768)
    assert.empty(files_with_prefix(prefix))
end

function testcase.decode_cleans_streamed_file_on_reader_failure()
    local payload = string.rep('x', 64 * 1024)
    for _, raises in ipairs({ false, true }) do
        local prefix = unused_prefix()
        local cause = errno.EIO:new('streamed body read failed')
        local calls, saved_before_error = 0, 0
        local source = {
            read = function()
                calls = calls + 1
                if calls == 1 then return header end
                if calls == 2 then return payload end
                for _, pathname in ipairs(files_with_prefix(prefix)) do
                    saved_before_error = assert(stat(pathname)).size
                end
                if raises then error(cause, 0) end
                return nil, cause
            end,
        }
        local ok, form, err = pcall(multipart.decode, source, 'b', prefix)
        if IS_LUA51 and raises then
            assert.is_false(ok)
            assert.is_true(form == cause)
        else
            assert.is_true(ok)
            assert.is_nil(form)
            assert.equal(errlib.typeof(err), multipart.EDECODE)
            assert.is_true(errlib.unwrap(err) == cause)
        end
        if IS_LUA51 and raises then collectgarbage('collect') end
        assert.greater(saved_before_error, 32768)
        assert.empty(files_with_prefix(prefix))
    end
end

function testcase.decode_cleans_streamed_file_on_truncated_body()
    local prefix = unused_prefix()
    local input = header .. string.rep('x', 64 * 1024) .. '\r\n--b-'
    local form, err = multipart.decode(reader(input), 'b', prefix, nil, 4096)
    assert.is_nil(form)
    assert.equal(errlib.typeof(err), multipart.EDECODE)
    assert.not_nil(errlib.is(err, errno.EINVAL))
    assert.empty(files_with_prefix(prefix))
end

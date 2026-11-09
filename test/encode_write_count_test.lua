local testcase = require('testcase')
local assert = require('assert')
local errlib = require('error')
local errno = require('errno')
local mkstemp = require('mkstemp')
local multipart = require('form.multipart')
local files, paths = {}, {}

local function sourcefile(data)
    local file, err, path = mkstemp('./encode_count_XXXXXX')
    assert(file, err)
    files[#files + 1] = file
    paths[#paths + 1] = path
    assert(file:write(data))
    assert(file:seek('set'))
    return file, path
end

function testcase.after_each()
    for _, file in ipairs(files) do
        if io.type(file) == 'file' then file:close() end
    end
    for _, path in ipairs(paths) do os.remove(path) end
    files, paths = {}, {}
end

local function text_form()
    return { text = {{
        data = 'payload',
        header = { ['X-Test'] = { 'metadata' } },
    }} }
end

function testcase.encode_stops_on_incomplete_or_excessive_string_counts()
    -- Delimiter, arbitrary header, disposition, data, CRLF, closing delimiter.
    for fail_at = 1, 6 do
        for _, delta in ipairs({ -1, 0, 1 }) do
            local calls = 0
            local n, err, timeout = multipart.encode(text_form(), 'b', {
                write = function(_, s)
                    calls = calls + 1
                    if calls == fail_at then
                        return delta == 0 and 0 or #s + delta, nil, false
                    end
                    return #s
                end,
                writefile = function() error('not a file part') end,
            })
            assert.is_nil(n)
            assert.equal(errlib.typeof(err), multipart.EENCODE)
            assert.not_nil(errlib.is(err, errno.EIO))
            assert.is_false(timeout)
            assert.equal(calls, fail_at)
        end
    end
end

function testcase.encode_stops_on_incomplete_or_excessive_file_counts()
    local file = sourcefile('payload')
    -- Includes the file disposition and writefile paths.
    for fail_at = 1, 6 do
        for _, delta in ipairs({ -1, 0, 1 }) do
            assert(file:seek('set'))
            local calls = 0
            local function result(expected)
                calls = calls + 1
                if calls == fail_at then
                    return delta == 0 and 0 or expected + delta, nil, false
                end
                return expected
            end
            local n, err, timeout = multipart.encode({ upload = {{
                file = file, filename = 'x',
                header = { ['X-Test'] = { 'metadata' } },
            }} }, 'b', {
                write = function(_, s) return result(#s) end,
                writefile = function(_, src, len, offset)
                    assert.equal(src, file)
                    assert.equal(offset, 0)
                    assert.equal(len, 7)
                    return result(len)
                end,
            })
            assert.is_nil(n)
            assert.equal(errlib.typeof(err), multipart.EENCODE)
            assert.not_nil(errlib.is(err, errno.EIO))
            assert.is_false(timeout)
            assert.equal(calls, fail_at)
            assert.equal(io.type(file), 'file')
        end
    end
end

function testcase.encode_checks_closing_only_output()
    for _, count in ipairs({ 0, 4, 6 }) do
        local calls = 0
        local n, err, timeout = multipart.encode({}, 'b', {
            write = function(_, s)
                calls = calls + 1
                assert.equal(s, '--b--')
                return count
            end,
            writefile = function() error('not a file part') end,
        })
        assert.is_nil(n)
        assert.equal(errlib.typeof(err), multipart.EENCODE)
        assert.not_nil(errlib.is(err, errno.EIO))
        assert.is_nil(timeout)
        assert.equal(calls, 1)
    end
end

function testcase.encode_accepts_complete_and_zero_length_writes()
    for _, data in ipairs({ '', 'payload' }) do
        local file = sourcefile(data)
        local output, calls = {}, 0
        local n, err, timeout = multipart.encode({ upload = {{
            file = file, filename = 'x',
        }} }, 'b', {
            write = function(_, s)
                calls = calls + 1
                output[#output + 1] = s
                return #s, nil, false
            end,
            writefile = function(_, src, len, offset)
                calls = calls + 1
                assert.equal(offset, 0)
                assert.equal(len, #data)
                local s = len > 0 and assert(src:read(len)) or ''
                output[#output + 1] = s
                return #s, nil, false
            end,
        })
        local expected = '--b\r\n' ..
            'Content-Disposition: form-data; name="upload"; filename="x"\r\n\r\n' ..
            data .. '\r\n--b--'
        assert.equal(table.concat(output), expected)
        assert.equal(n, #expected)
        assert.is_nil(err)
        assert.is_nil(timeout)
        assert.equal(calls, 5)
        assert.equal(io.type(file), 'file')
    end

    local output = {}
    local n, err, timeout = multipart.encode({ text = { '' } }, 'b', {
        write = function(_, s)
            output[#output + 1] = s
            return #s
        end,
        writefile = function() error('not a file part') end,
    })
    local expected = '--b\r\nContent-Disposition: form-data; name="text"\r\n\r\n\r\n--b--'
    assert.equal(table.concat(output), expected)
    assert.equal(n, #expected)
    assert.is_nil(err)
    assert.is_nil(timeout)
end

function testcase.encode_keeps_original_errors_instead_of_count_errors()
    local file = sourcefile('payload')
    for _, file_part in ipairs({ false, true }) do
        for _, typed in ipairs({ false, true }) do
            assert(file:seek('set'))
            local cause = typed and errno.EAGAIN:new('original error') or 'original error'
            local calls = 0
            local form = file_part and { upload = {{ file = file, filename = 'x' }} } or text_form()
            local n, err, timeout = multipart.encode(form, 'b', {
                write = function(_, s)
                    calls = calls + 1
                    if not file_part then return 1, cause, false end
                    return #s
                end,
                writefile = function()
                    calls = calls + 1
                    return 1, cause, false
                end,
            })
            assert.is_nil(n)
            assert.equal(errlib.typeof(err), multipart.EENCODE)
            assert.is_nil(errlib.is(err, errno.EIO))
            if typed then
                assert.is_true(errlib.unwrap(err) == cause)
            else
                assert.equal(tostring(errlib.unwrap(err).message), cause)
            end
            assert.is_false(timeout)
            assert.equal(calls, file_part and 3 or 1)
            assert.equal(io.type(file), 'file')
        end
    end
end

function testcase.encode_does_not_retry_a_closed_owned_file_after_a_short_write()
    local _, path = sourcefile('payload')
    local part = { pathname = path, filename = 'x' }
    local calls, captured = 0
    local n, err, timeout = multipart.encode({ upload = { part } }, 'b', {
        write = function(_, s)
            calls = calls + 1
            return #s
        end,
        writefile = function(_, file, len, offset, filepart)
            calls = calls + 1
            captured = file
            assert.equal(len, 7)
            assert.equal(offset, 0)
            assert.is_true(filepart.is_tmpfile)
            assert.equal(assert(file:read(1)), 'p')
            assert(file:close())
            return 1
        end,
    })
    assert.is_nil(n)
    assert.equal(errlib.typeof(err), multipart.EENCODE)
    assert.not_nil(errlib.is(err, errno.EIO))
    assert.is_nil(timeout)
    assert.equal(calls, 3)
    assert.equal(io.type(captured), 'closed file')
    assert.is_nil(part.file)
    assert.is_nil(part.is_tmpfile)
end

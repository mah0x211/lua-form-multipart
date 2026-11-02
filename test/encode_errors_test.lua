local testcase = require('testcase')
local assert = require('assert')
local multipart = require('form.multipart')
local errlib = require('error')
local errno = require('errno')
local files = {}

function testcase.after_each()
    for _, file in ipairs(files) do
        if io.type(file) == 'file' then file:close() end
    end
    files = {}
end

local function assert_encode_error(err, cause_type)
    assert.not_nil(multipart.EENCODE)
    assert.equal(errlib.typeof(err), multipart.EENCODE)
    assert.not_nil(errlib.is(err, cause_type))
    assert.is_nil(errlib.is(errlib.unwrap(err), multipart.EENCODE))
end

local function file_part()
    local file = assert(io.tmpfile())
    files[#files + 1] = file
    assert(file:write('payload'))
    assert(file:seek('set'))
    return { filename = 'x.txt', file = file }
end

function testcase.encode_invalid_part_fields_return_field_errors()
    for _, case in ipairs({
        { part = { filename = 'x', pathname = false }, message = 'pathname field in "foo" must be string' },
        { part = { filename = 'x', file = false }, message = 'file field in "foo" must be file*' },
        { part = { data = 'value', header = false }, message = 'header field in "foo" must be table' },
        { part = { filename = false }, message = 'filename field in "foo" must be string' },
    }) do
        local result, err = multipart.encode({ foo = { case.part } }, 'b')
        assert.is_nil(result)
        assert_encode_error(err, errno.EINVAL)
        assert.match(tostring(err), 'form.multipart.encode')
        assert.match(tostring(err), case.message)
    end
end

function testcase.encode_preserves_writer_error_objects()
    for _, raises in ipairs({ false, true }) do
        for fail_at = 1, 6 do
            local cause = errno.EIO:new('write failed')
            local calls = 0
            local result, err = multipart.encode({ foo = {{
                data = 'value', header = { ['X-Example'] = { 'metadata' } },
            }} }, 'b', {
                write = function(_, str)
                    calls = calls + 1
                    if calls == fail_at then
                        if raises then error(cause, 0) end
                        return nil, cause
                    end
                    return #str
                end,
                writefile = function() error('must not be reached') end,
            })
            assert.is_nil(result)
            assert_encode_error(err, errno.EIO)
            assert.is_true(errlib.unwrap(err) == cause)
            assert.equal(calls, fail_at)
        end
    end
end

function testcase.encode_wraps_string_writer_errors()
    for _, raises in ipairs({ false, true }) do
        for _, message in ipairs({ 'write stopped', 'EIO' }) do
            local result, err = multipart.encode({ foo = { 'value' } }, 'b', {
                write = function()
                    if raises then error(message, 0) end
                    return nil, message
                end,
                writefile = function() error('must not be reached') end,
            })
            assert.is_nil(result)
            assert.not_nil(multipart.EENCODE)
            assert.equal(errlib.typeof(err), multipart.EENCODE)
            local cause = errlib.unwrap(err)
            assert.equal(tostring(cause.message), message)
            assert.is_nil(errlib.typeof(cause))
        end
    end
end

function testcase.encode_preserves_writefile_error_objects()
    for _, raises in ipairs({ false, true }) do
        local part = file_part()
        local cause = errno.EIO:new('writefile failed')
        local result, err = multipart.encode({ foo = { part } }, 'b', {
            write = function(_, str) return #str end,
            writefile = function()
                if raises then error(cause, 0) end
                return nil, cause
            end,
        })
        assert.is_nil(result)
        assert_encode_error(err, errno.EIO)
        assert.is_true(errlib.unwrap(err) == cause)
        assert.equal(io.type(part.file), 'file')
    end
end

function testcase.encode_wraps_string_writefile_errors()
    for _, raises in ipairs({ false, true }) do
        local part = file_part()
        local result, err = multipart.encode({ foo = { part } }, 'b', {
            write = function(_, str) return #str end,
            writefile = function()
                if raises then error('writefile stopped', 0) end
                return nil, 'writefile stopped'
            end,
        })
        assert.is_nil(result)
        assert.not_nil(multipart.EENCODE)
        assert.equal(errlib.typeof(err), multipart.EENCODE)
        local cause = errlib.unwrap(err)
        assert.equal(tostring(cause.message), 'writefile stopped')
        assert.is_nil(errlib.typeof(cause))
        assert.equal(io.type(part.file), 'file')
    end
end

function testcase.encode_preserves_nonseekable_file_errno()
    -- popen supplies a real FILE* whose pipe cannot be positioned with fseek.
    local file = assert(io.popen('printf payload', 'r'))
    files[#files + 1] = file
    local result, err = multipart.encode({ foo = {{
        filename = 'pipe.txt', file = file,
    }} }, 'b')
    assert.is_nil(result)
    assert_encode_error(err, errno.ESPIPE)
    assert.equal(errlib.is(err, errno.ESPIPE).op, 'seek')
    assert.equal(io.type(file), 'file')
end

function testcase.encode_argument_contract_violations_still_raise()
    for _, args in ipairs({
        { 42, 'b' },
        { {}, '' },
        { {}, 'b', false },
        { {}, 'b', { write = function() end } },
    }) do
        local ok, err = pcall(multipart.encode, args[1], args[2], args[3])
        assert.is_false(ok)
        assert.is_nil(errlib.is(err, multipart.EENCODE))
    end
end

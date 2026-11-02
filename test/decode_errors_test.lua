local testcase = require('testcase')
local assert = require('assert')
local errlib = require('error')
local errno = require('errno')
local mkstemp = require('mkstemp')
local multipart = require('form.multipart')

local header = '--b\r\nContent-Disposition: form-data; name="foo"\r\n\r\n'
local body = header .. 'value\r\n--b--'

local function assert_decode_error(err, cause_type)
    assert.equal(errlib.typeof(err), multipart.EDECODE)
    assert.not_nil(multipart.EDECODE)
    assert.not_nil(errlib.is(err, cause_type))
    assert.is_nil(errlib.is(errlib.unwrap(err), multipart.EDECODE))
end

local function reader_for(chunks, err)
    local i = 0
    return {
        read = function()
            i = i + 1
            if chunks[i] then return chunks[i] end
            return nil, err
        end,
    }
end

function testcase.decode_classifies_invalid_input_as_einval()
    for _, input in ipairs({
        '',
        '--b--\r\n',
        '--b\r\ninvalid-header\r\n\r\n',
        '--b\r\nContent-Type: text/plain\r\n\r\nx\r\n--b--',
        header .. 'value',
        '--b\r\nContent-Disposition: form-data; name=foo; custom=\r\n\r\nx\r\n--b--',
        '--b\r\nContent-Disposition: form-data; name=foo; custom="unterminated\r\n\r\nx\r\n--b--',
        '--b\r\nContent-Disposition: form-data; name=foo; custom="x"junk\r\n\r\nx\r\n--b--',
        '--b\r\nContent-Disposition: form-data; name=foo; NAME=bar\r\n\r\nx\r\n--b--',
        '--b\r\nContent-Disposition: form-data; name=foo; custom=hello/world\r\n\r\nx\r\n--b--',
        '--b\r\nContent-Disposition: form-data; name="foo"\r\n' ..
            'Content-Disposition: form-data; name="bar"\r\n\r\nvalue\r\n--b--',
    }) do
        local form, err = multipart.decode(input, 'b')
        assert.is_nil(form)
        assert_decode_error(err, errno.EINVAL)
    end
end

function testcase.decode_classifies_file_size_limit_as_efbig()
    local input = '--b\r\nContent-Disposition: form-data; name="foo"; filename="x"' ..
        '\r\n\r\npayload\r\n--b--'
    local form, err = multipart.decode(input, 'b', nil, 0)
    assert.is_nil(form)
    assert_decode_error(err, errno.EFBIG)
    assert.is_nil(errlib.is(err, errno.EINVAL))
end

function testcase.decode_preserves_temporary_file_errno()
    local file, _, prefix = assert(mkstemp('./test_decode_errno_XXXXXX'))
    file:close()
    assert(os.remove(prefix))
    local input = '--b\r\nContent-Disposition: form-data; name="foo"; filename="x"' ..
        '\r\n\r\npayload\r\n--b--'
    local form, err = multipart.decode(input, 'b', prefix .. '/file')
    assert.is_nil(form)
    assert_decode_error(err, errno.ENOENT)
    assert.match(tostring(err), 'failed to create multipart temporary file')
    assert.equal(errlib.is(err, errno.ENOENT).op, 'mkstemp')
end

function testcase.decode_preserves_returned_reader_error_objects()
    for _, chunks in ipairs({
        {},
        { '--b\r\nContent-Disposition' },
        { header .. 'value' },
        { header .. 'value\r\n--b \t' },
        { body },
    }) do
        local cause = errno.EIO:new('reader failed')
        local form, err = multipart.decode(reader_for(chunks, cause), 'b')
        assert.is_nil(form)
        assert_decode_error(err, errno.EIO)
        assert.is_true(errlib.unwrap(err) == cause)
    end
end

function testcase.decode_wraps_string_reader_errors()
    for _, message in ipairs({ 'reader stopped', 'EIO', 'Permission denied' }) do
        local form, err = multipart.decode(reader_for({}, message), 'b')
        assert.is_nil(form)
        assert.equal(errlib.typeof(err), multipart.EDECODE)
        assert.not_nil(multipart.EDECODE)
        local cause = errlib.unwrap(err)
        assert.not_nil(cause)
        assert.equal(tostring(cause.message), message)
        assert.is_nil(errlib.typeof(cause))
    end
end

function testcase.decode_preserves_raised_reader_error_objects()
    local cause = errno.EIO:new('reader raised')
    local ok, form, err = pcall(multipart.decode, {
        read = function() error(cause, 0) end,
    }, 'b')
    assert.is_true(ok)
    assert.is_nil(form)
    assert_decode_error(err, errno.EIO)
    assert.is_true(errlib.unwrap(err) == cause)
end

function testcase.decode_argument_contract_violations_still_raise()
    for _, args in ipairs({
        { 42, 'b' },
        { body, '' },
        { body, 'b', 42 },
        { body, 'b', nil, -1 },
        { reader_for({ body }), 'b', nil, nil, 0 },
    }) do
        local ok, err = pcall(multipart.decode, args[1], args[2], args[3], args[4], args[5])
        assert.is_false(ok)
        assert.is_nil(errlib.is(err, multipart.EDECODE))
    end
end

function testcase.decode_preserves_raised_string_reader_errors()
    local form, err = multipart.decode({
        read = function() error('reader stopped', 0) end,
    }, 'b')
    assert.is_nil(form)
    assert.equal(errlib.typeof(err), multipart.EDECODE)
    assert.not_nil(multipart.EDECODE)
    assert.equal(tostring(errlib.unwrap(err).message), 'reader stopped')
end

local testcase = require('testcase')
local assert = require('assert')
local errlib = require('error')
local errno = require('errno')
local mkstemp = require('mkstemp')
local readdir = require('testcase.readdir')
local multipart = require('form.multipart')
local prefixes = {}

local function input_for(line)
    return '--b\r\nContent-Disposition: form-data; name="foo"\r\n' ..
        line .. '\r\n\r\nvalue\r\n--b--'
end

local function reader(input)
    local pos = 1
    return {
        read = function(_, n)
            local s = input:sub(pos, pos + n - 1)
            pos = pos + #s
            if #s > 0 then return s end
        end,
    }
end

local function assert_invalid_header(form, err)
    assert.is_nil(form)
    assert.equal(errlib.typeof(err), multipart.EDECODE)
    assert.not_nil(errlib.is(err, errno.EINVAL))
    assert.match(tostring(err), 'invalid header')
end

local function files_with_prefix(prefix)
    local files = {}
    local err = readdir('.', function(name)
        if name:sub(1, #prefix + 1) == prefix .. '_' then
            files[#files + 1] = name
        end
    end)
    assert.is_nil(err)
    return files
end

function testcase.before_each()
    collectgarbage('stop')
end

function testcase.after_each()
    for _, prefix in ipairs(prefixes) do
        for _, pathname in ipairs(files_with_prefix(prefix)) do os.remove(pathname) end
    end
    prefixes = {}
    collectgarbage('restart')
end

function testcase.decode_rejects_junk_before_header_names()
    for _, prefix in ipairs({ 'junk ', 'junk\t', ' ', '\t', ': ' }) do
        local input = input_for(prefix .. 'X-Test: value')
        assert_invalid_header(multipart.decode(input, 'b'))
        for _, chunksize in ipairs({ 1, 7, 4096 }) do
            assert_invalid_header(multipart.decode(reader(input), 'b', nil, nil, chunksize))
        end
    end
end

function testcase.decode_rejects_non_ftext_bytes_in_header_names()
    -- RFC 5322 section 3.6.8: ftext is ASCII 33-57 / 59-126.
    -- A colon terminates a name, so it cannot be tested as a name byte.
    for byte = 0, 255 do
        if byte ~= 58 and (byte < 33 or byte > 126) then
            local input = input_for('X' .. string.char(byte) .. 'Y: value')
            assert_invalid_header(multipart.decode(input, 'b'))
            for _, chunksize in ipairs({ 1, 7, 4096 }) do
                assert_invalid_header(multipart.decode(reader(input), 'b', nil, nil, chunksize))
            end
        end
    end
end

function testcase.decode_rejects_controls_in_padding_before_colon()
    for _, padding in ipairs({ ' \v', '\t\f', ' \r', '\t\r\v' }) do
        local input = input_for('X-Test' .. padding .. ': value')
        assert_invalid_header(multipart.decode(input, 'b'))
        assert_invalid_header(multipart.decode(reader(input), 'b', nil, nil, 1))
    end
end

function testcase.decode_rejects_non_lwsp_before_disposition_type()
    -- RFC 822 section 3.3: VT/FF/bare CR are not linear whitespace.
    for _, padding in ipairs({ '\v', '\f', '\r', ' \v', '\t\f', ' \r', '\t\r\v' }) do
        local input = '--b\r\nContent-Disposition:' .. padding ..
            'form-data; name="foo"\r\n\r\nvalue\r\n--b--'
        for _, source in ipairs({ input, reader(input) }) do
            local form, err = multipart.decode(source, 'b', nil, nil, 1)
            assert.is_nil(form)
            assert.equal(errlib.typeof(err), multipart.EDECODE)
            assert.not_nil(errlib.is(err, errno.EINVAL))
            assert.match(tostring(err), 'Content-Disposition type must be form-data')
        end
    end
end

function testcase.decode_accepts_sp_htab_or_no_padding_before_disposition_type()
    for _, padding in ipairs({ '', ' ', '\t', ' \t ', '\t \t' }) do
        local input = '--b\r\nContent-Disposition:' .. padding ..
            'form-data; name="foo"\r\n\r\nvalue\r\n--b--'
        for _, source in ipairs({ input, reader(input) }) do
            local form, err = multipart.decode(source, 'b', nil, nil, 1)
            assert.is_nil(err)
            assert.equal(form.foo[1].data, 'value')
            assert.equal(form.foo[1].header['content-disposition'], {
                'form-data; name="foo"',
            })
        end
    end
end

function testcase.decode_accepts_all_mime_field_name_characters()
    -- MIME field names allow punctuation that HTTP/parameter tokens exclude.
    for byte = 33, 126 do
        if byte ~= 58 then
            local name = 'X' .. string.char(byte) .. 'Y'
            local input = input_for(name .. ': value')
            for _, source in ipairs({ input, reader(input) }) do
                local form, err = multipart.decode(source, 'b', nil, nil, 1)
                assert.is_nil(err)
                assert.equal(form.foo[1].data, 'value')
                assert.is_nil(form.foo[1].header[name:lower()])
            end
        end
    end
end

function testcase.decode_preserves_header_padding_values_and_repeated_headers()
    for _, newline in ipairs({ '\r\n', '\n' }) do
        local input = input_for('Content-Type \t:\t text/plain; source="urn:example"\r\n' ..
            'content-TYPE\t : application/octet-stream')
        input = input:gsub('\r\n', newline)
        for _, source in ipairs({ input, reader(input) }) do
            local form, err = multipart.decode(source, 'b', nil, nil, 1)
            assert.is_nil(err)
            assert.equal(form.foo[1].data, 'value')
            assert.equal(form.foo[1].header['content-type'], {
                'text/plain; source="urn:example"', 'application/octet-stream',
            })
        end
    end
end

function testcase.decode_removes_completed_upload_after_invalid_header_name()
    local file, _, pathname = assert(mkstemp('./header_syntax_XXXXXX'))
    file:close()
    assert(os.remove(pathname))
    local prefix = pathname:gsub('^%./', '')
    prefixes[#prefixes + 1] = prefix
    local input = '--b\r\nContent-Disposition: form-data; name="upload"; filename="a"\r\n\r\n' ..
        'payload\r\n' .. input_for('junk X-Test: value')
    assert_invalid_header(multipart.decode(reader(input), 'b', prefix, nil, 1))
    assert.empty(files_with_prefix(prefix))
end

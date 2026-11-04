local testcase = require('testcase')
local assert = require('assert')
local errlib = require('error')
local errno = require('errno')
local mkstemp = require('mkstemp')
local readdir = require('testcase.readdir')
local multipart = require('form.multipart')
local prefixes = {}

local function input_for(disposition, params)
    return '--b\r\nContent-Disposition: ' .. disposition ..
        (params or '; name="foo"') .. '\r\n\r\nvalue\r\n--b--'
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

local function assert_invalid_type(form, err)
    assert.is_nil(form)
    assert.equal(errlib.typeof(err), multipart.EDECODE)
    assert.not_nil(errlib.is(err, errno.EINVAL))
    assert.match(tostring(err), 'Content-Disposition type must be form-data')
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

function testcase.decode_rejects_missing_other_and_malformed_disposition_types()
    for _, disposition in ipairs({
        '', 'attachment', 'inline', 'other', 'form-dataX', 'xform-data',
        'form-data junk', 'form-data\tjunk', 'form-data=', 'form-data/other',
        '"form-data"', 'form-data,attachment', 'form-data\v', 'form-\tdata',
    }) do
        local input = input_for(disposition)
        assert_invalid_type(multipart.decode(input, 'b'))
        for _, chunksize in ipairs({ 1, 2, 7, 4096 }) do
            assert_invalid_type(multipart.decode(reader(input), 'b', nil, nil, chunksize))
        end
    end
end

function testcase.decode_accepts_case_insensitive_form_data_and_type_padding()
    for _, disposition in ipairs({ 'form-data', 'FORM-DATA', 'FoRm-DaTa', 'form-data \t', 'FORM-DATA\t ' }) do
        local params = '; name="foo"; custom="a;b"'
        local input = input_for(disposition, params)
        for _, source in ipairs({ input, reader(input) }) do
            local form, err = multipart.decode(source, 'b', nil, nil, 1)
            assert.is_nil(err)
            assert.equal(form.foo[1].data, 'value')
            assert.equal(form.foo[1].params.custom, 'a;b')
            assert.equal(form.foo[1].header['content-disposition'], { disposition .. params })
        end
    end
end

function testcase.decode_still_requires_name_for_valid_disposition_types()
    for _, disposition in ipairs({ 'form-data', 'FORM-DATA', 'form-data \t' }) do
        local input = input_for(disposition, '')
        local form, err = multipart.decode(input, 'b')
        assert.is_nil(form)
        assert.not_nil(errlib.is(err, errno.EINVAL))
        assert.match(tostring(err), 'does not contain a name parameter')
    end
end

function testcase.decode_rejects_invalid_type_before_reading_part_body()
    local calls = 0
    local source = {
        read = function()
            calls = calls + 1
            assert.equal(calls, 1)
            return '--b\r\nContent-Disposition: attachment; name="foo"\r\n'
        end,
    }
    assert_invalid_type(multipart.decode(source, 'b'))
    assert.equal(calls, 1)
end

function testcase.decode_removes_completed_upload_after_invalid_disposition_type()
    local file, _, pathname = assert(mkstemp('./disposition_type_XXXXXX'))
    file:close()
    assert(os.remove(pathname))
    local prefix = pathname:gsub('^%./', '')
    prefixes[#prefixes + 1] = prefix
    local input = '--b\r\nContent-Disposition: form-data; name="upload"; filename="a"\r\n\r\n' ..
        'payload\r\n' .. input_for('attachment')
    assert_invalid_type(multipart.decode(reader(input), 'b', prefix, nil, 1))
    assert.empty(files_with_prefix(prefix))
end

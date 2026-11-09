local IS_LUA51 = _VERSION == 'Lua 5.1' and not _G.jit
local testcase = require('testcase')
local assert = require('assert')
local mkstemp = require('mkstemp')
local multipart = require('form.multipart')
local files = {}

function testcase.after_each()
    for _, part in ipairs(files) do
        if io.type(part.file) == 'file' then part.file:close() end
        os.remove(part.pathname)
    end
    files = {}
end

function testcase.decode_keeps_extension_parameters_out_of_internal_fields()
    local disposition = 'form-data; name="foo"; FiLe="spoof"; pathname="spoof"; ' ..
        'gc="spoof"; header="spoof"; data="spoof"; params="spoof"; custom="extension"'
    local input = '--b\r\nContent-Disposition: ' .. disposition .. '\r\n\r\nvalue\r\n--b--'
    local form, err = multipart.decode(input, 'b')
    assert.is_nil(err)
    local part = form.foo[1]
    assert.equal(part.name, 'foo')
    assert.equal(part.params, {
        name = 'foo', file = 'spoof', pathname = 'spoof', gc = 'spoof',
        header = 'spoof', data = 'spoof', params = 'spoof', custom = 'extension',
    })
    assert.equal(part.data, 'value')
    assert.is_nil(part.file)
    assert.is_nil(part.pathname)
    assert.is_nil(part.gc)
    assert.is_nil(part.custom)
    assert.equal(part.header['content-disposition'], { disposition })
end

function testcase.decode_returns_parse_error_after_file_extension_parameter()
    local input = '--b\r\nContent-Disposition: form-data; name="foo"; file="spoof"' ..
        '\r\n\r\nvalue\r\n--b\r\ninvalid-header\r\n\r\n'
    local ok, form, err = pcall(multipart.decode, input, 'b')
    assert.is_true(ok)
    assert.is_nil(form)
    assert.match(tostring(err), 'invalid header')
end

function testcase.decode_returns_reader_error_after_file_extension_parameter()
    local first = true
    local input = '--b\r\nContent-Disposition: form-data; name="foo"; file="spoof"' ..
        '\r\n\r\nvalue\r\n--b--'
    local reader = {
        read = function()
            if first then first = false; return input end
            error('reader raised')
        end,
    }
    local ok, form, err = pcall(multipart.decode, reader, 'b')
    if IS_LUA51 then
        assert.is_false(ok)
        assert.match(tostring(form), 'reader raised')
    else
        assert.is_true(ok)
        assert.is_nil(form)
        assert.match(tostring(err), 'reader raised')
    end
end

function testcase.decode_preserves_file_parameters_and_raw_header()
    local file, _, prefix = assert(mkstemp('./test_disposition_XXXXXX'))
    file:close()
    assert(os.remove(prefix))
    local disposition = 'form-data; NAME="foo"; filename="old"; filename*="new"; ' ..
        'file="spoof"; pathname="spoof"; gc="spoof"'
    local input = '--b\r\nContent-Disposition: ' .. disposition .. '\r\n\r\npayload\r\n--b--'
    local form, err = multipart.decode(input, 'b', prefix)
    assert.is_nil(err)
    local part = form.foo[1]
    files[#files + 1] = part
    assert.equal(part.name, 'foo')
    assert.equal(part.filename, 'old')
    assert.is_nil(part['filename*'])
    assert.equal(part.params, {
        name = 'foo', filename = 'old', ['filename*'] = 'new',
        file = 'spoof', pathname = 'spoof', gc = 'spoof',
    })
    assert.equal(part.file:read('*a'), 'payload')
    assert.match(part.pathname, prefix .. '_')
    assert.equal(part.header['content-disposition'], { disposition })
end

function testcase.decode_keeps_filename_star_only_in_params()
    local disposition = "form-data; name=\"foo\"; filename*=UTF-8''example.txt"
    local input = '--b\r\nContent-Disposition: ' .. disposition .. '\r\n\r\npayload\r\n--b--'
    local form, err = multipart.decode(input, 'b')
    assert.is_nil(err)
    local part = form.foo[1]
    assert.equal(part.name, 'foo')
    assert.equal(part.params, {
        name = 'foo', ['filename*'] = "UTF-8''example.txt",
    })
    assert.is_nil(part.filename)
    assert.is_nil(part.file)
    assert.is_nil(part.pathname)
    assert.is_nil(part.gc)
    assert.equal(part.data, 'payload')
    assert.equal(part.header['content-disposition'], { disposition })
end

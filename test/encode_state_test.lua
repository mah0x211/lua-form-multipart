local testcase = require('testcase')
local assert = require('assert')
local multipart = require('form.multipart')

function testcase.encode_nested_default_writer_preserves_outer_output()
    local inner
    local value = setmetatable({}, {
        __tostring = function()
            inner = assert(multipart.encode({ inner = { 'nested' } }, 'b'))
            return 'header value'
        end,
    })
    local encoded, err = multipart.encode({ foo = {
        { data = 'outer', header = { ['X-Example'] = { value } } },
    } }, 'b')
    assert.is_nil(err)
    assert.equal(encoded, '--b\r\nX-Example: header value\r\n' ..
        'Content-Disposition: form-data; name="foo"\r\n' ..
        '\r\nouter\r\n--b--')
    assert.equal(inner, '--b\r\n' ..
        'Content-Disposition: form-data; name="inner"\r\n' ..
        '\r\nnested\r\n--b--')
end

function testcase.encode_nested_failure_preserves_outer_output()
    local value = setmetatable({}, {
        __tostring = function()
            local encoded, err = multipart.encode({ inner = {
                { filename = 1 },
            } }, 'b')
            assert.is_nil(encoded)
            assert.match(tostring(err), 'filename field in "inner" must be string')
            return 'header value'
        end,
    })
    local encoded, err = multipart.encode({ foo = {
        { data = 'outer', header = { ['X-Example'] = { value } } },
    } }, 'b')
    assert.is_nil(err)
    assert.equal(encoded, '--b\r\nX-Example: header value\r\n' ..
        'Content-Disposition: form-data; name="foo"\r\n' ..
        '\r\nouter\r\n--b--')
end

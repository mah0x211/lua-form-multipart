local testcase = require('testcase')
local assert = require('assert')
local errlib = require('error')
local errno = require('errno')
local multipart = require('form.multipart')

function testcase.encode_preserves_valid_header_names()
    for _, key in ipairs({
        'X-Test', 'x_test', 'X!#$%&\'*+-.^_|~', 'X()<>@,;=[]?/', 'X"\\',
        '!', '~',
    }) do
        local header = { [key] = { 'value' } }
        local encoded, err, timeout = multipart.encode({
            foo = {{ data = 'body', header = header }},
        }, 'b')
        assert.is_nil(err)
        assert.is_nil(timeout)
        assert.match(encoded, key .. ': value\r\n')
        assert.equal(header, { [key] = { 'value' } })
    end
end

function testcase.encode_ignores_unsupported_header_entries()
    local encoded, err, timeout = multipart.encode({
        foo = {{
            data = 'body',
            header = {
                [1] = { 'ignored' },
                ['X-Test'] = 'not a value table',
            },
        }},
    }, 'b')
    assert.is_nil(err)
    assert.is_nil(timeout)
    assert.equal(encoded, '--b\r\n' ..
                 'Content-Disposition: form-data; name="foo"\r\n\r\n' ..
                 'body\r\n--b--')
end

function testcase.encode_rejects_invalid_header_names()
    for _, key in ipairs({
        '', ' ', ' X', 'X ', 'X Y', 'X\tY', 'X\rY', 'X\nY',
        'X\0Y', 'X\1Y', 'X\31Y', 'X\127Y', 'X\128Y', 'X\255Y',
        ':', 'X:Y', 'Content-Type:extra', 'this-header-is-ignored ',
    }) do
        local encoded, err, timeout = multipart.encode({
            foo = {{ data = 'body', header = { [key] = { 'value' } } }},
        }, 'b')
        assert.is_nil(encoded)
        assert.is_nil(timeout)
        assert.equal(errlib.typeof(err), multipart.EENCODE)
        assert.not_nil(errlib.is(err, errno.EINVAL))
        assert.match(tostring(err), 'invalid header name')
    end
end

function testcase.encode_stops_before_writing_an_invalid_header_name()
    local output = {}
    local n, err, timeout = multipart.encode({
        foo = {{
            data = 'body',
            header = { ['Content-Type:extra'] = { 'text/plain' } },
        }},
    }, 'b', {
        write = function(_, s)
            output[#output + 1] = s
            return #s
        end,
        writefile = function() error('not a file part') end,
    })
    assert.is_nil(n)
    assert.is_nil(timeout)
    assert.equal(errlib.typeof(err), multipart.EENCODE)
    assert.not_nil(errlib.is(err, errno.EINVAL))
    assert.match(tostring(err), 'invalid header name')
    assert.equal(table.concat(output), '--b\r\n')
end

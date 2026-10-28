local testcase = require("testcase")
local assert = require("assert")
local mkstemp = require("mkstemp")
local multipart = require("form.multipart")

function testcase.encode_empty_caller_file()
    local file = assert(io.tmpfile())
    local encoded, err = multipart.encode({ foo = {
        { filename = 'empty.txt', file = file },
    } }, 'b')
    local state = io.type(file)
    file:close()
    assert.is_nil(err)
    assert.equal(state, 'file')
    assert.equal(encoded, '--b\r\n' ..
        'Content-Disposition: form-data; name="foo"; filename="empty.txt"\r\n' ..
        '\r\n\r\n--b--')
end

function testcase.encode_empty_pathname_file()
    local file, _, path = assert(mkstemp('./test_empty_XXXXXX'))
    file:close()
    local part = { filename = 'empty.txt', pathname = path }
    local encoded, err = multipart.encode({ foo = { part } }, 'b')
    os.remove(path)
    assert.is_nil(err)
    assert.equal(encoded, '--b\r\n' ..
        'Content-Disposition: form-data; name="foo"; filename="empty.txt"\r\n' ..
        '\r\n\r\n--b--')
end

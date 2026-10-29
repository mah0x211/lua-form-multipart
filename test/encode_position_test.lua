local testcase = require('testcase')
local assert = require('assert')
local multipart = require('form.multipart')
local file

function testcase.before_each()
    file = assert(io.tmpfile())
    assert(file:write('abcdef'))
end

function testcase.after_each()
    if file then
        file:close()
        file = nil
    end
end

function testcase.encode_reads_from_current_position()
    for _, case in ipairs({
        { offset = 0, content = 'abcdef' },
        { offset = 3, content = 'def' },
    }) do
        assert(file:seek('set', case.offset))
        local encoded, err = multipart.encode({ foo = {
            { filename = 'x.txt', file = file },
        } }, 'b')
        assert.is_nil(err)
        assert.equal(encoded, '--b\r\n' ..
            'Content-Disposition: form-data; name="foo"; filename="x.txt"\r\n' ..
            '\r\n' .. case.content .. '\r\n--b--')
    end
end

function testcase.encode_empty_remaining_range()
    for _, offset in ipairs({ 6, 9 }) do
        assert(file:seek('set', offset))
        local encoded, err = multipart.encode({ foo = {
            { filename = 'x.txt', file = file },
        } }, 'b')
        assert.is_nil(err)
        assert.equal(encoded, '--b\r\n' ..
            'Content-Disposition: form-data; name="foo"; filename="x.txt"\r\n' ..
            '\r\n\r\n--b--')
    end
end

function testcase.encode_passes_current_position_to_custom_writer()
    for _, case in ipairs({
        { offset = 0, len = 6, content = 'abcdef' },
        { offset = 3, len = 3, content = 'def' },
        { offset = 6, len = 0, content = '' },
        { offset = 9, len = 0, content = '' },
    }) do
        assert(file:seek('set', case.offset))
        local chunks = {}
        local n, err = multipart.encode({ foo = {
            { filename = 'x.txt', file = file },
        } }, 'b', {
            write = function(_, s)
                chunks[#chunks + 1] = s
                return #s
            end,
            writefile = function(self, f, len, offset)
                assert.equal(offset, case.offset)
                assert.equal(len, case.len)
                assert.equal(f:seek(), case.offset)
                return self:write(assert(f:read('*a')))
            end,
        })
        assert.is_nil(err)
        local encoded = table.concat(chunks)
        assert.equal(encoded, '--b\r\n' ..
            'Content-Disposition: form-data; name="foo"; filename="x.txt"\r\n' ..
            '\r\n' .. case.content .. '\r\n--b--')
        assert.equal(n, #encoded)
    end
end

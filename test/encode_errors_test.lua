local testcase = require('testcase')
local assert = require('assert')
local multipart = require('form.multipart')

function testcase.encode_invalid_part_fields_return_field_errors()
    for _, case in ipairs({
        { part = { filename = 'x', pathname = false }, message = 'pathname field in "foo" must be string' },
        { part = { filename = 'x', file = false }, message = 'file field in "foo" must be file*' },
        { part = { data = 'value', header = false }, message = 'header field in "foo" must be table' },
        { part = { filename = false }, message = 'filename field in "foo" must be string' },
    }) do
        local result, err = multipart.encode({ foo = { case.part } }, 'b')
        assert.is_nil(result)
        assert.match(tostring(err), 'form.multipart.encode')
        assert.match(tostring(err), case.message)
    end
end

local testcase = require('testcase')
local assert = require('assert')
local multipart = require('form.multipart')

local function body(boundary)
    return '--' .. boundary .. '\r\n' ..
           'Content-Disposition: form-data; name="foo"\r\n\r\n' ..
           'value\r\n--' .. boundary .. '--'
end

function testcase.is_valid_boundary_accepts_valid_grammar()
    for _, boundary in ipairs({
        'b', string.rep('a', 70), 'a b', ' a', "a'()+_,-./:=?z",
    }) do
        assert.equal(multipart.is_valid_boundary(boundary), true)
        local encoded = assert(multipart.encode({ foo = { 'value' } }, boundary))
        assert.equal(encoded, body(boundary))
        local form = assert(multipart.decode(encoded, boundary))
        assert.equal(form.foo[1].data, 'value')
    end
end

function testcase.is_valid_boundary_rejects_invalid_grammar_in_both_apis()
    for _, boundary in ipairs({
        '', string.rep('a', 71), 'a ', 'a#b', 'a\tb', 'a\r\nb', 'a\0b',
    }) do
        local ok, err = multipart.is_valid_boundary(boundary)
        assert.is_false(ok)
        assert.is_string(err)
        assert.throws(multipart.encode, {}, boundary)
        assert.throws(multipart.decode, '', boundary)
    end
end

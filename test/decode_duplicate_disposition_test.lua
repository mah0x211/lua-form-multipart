local testcase = require('testcase')
local assert = require('assert')
local multipart = require('form.multipart')

function testcase.decode_rejects_duplicate_disposition_headers()
    local headers = {
        'Content-Disposition: form-data; name="foo"',
        'content-disposition: form-data; name="bar"',
        'CONTENT-DISPOSITION: form-data; filename="a.txt"',
    }
    for _, second in ipairs(headers) do
        local input = '--b\r\nContent-Disposition: form-data; name="foo"\r\n' ..
            second .. '\r\n\r\nvalue\r\n--b--'
        local ok, form, err = pcall(multipart.decode, input, 'b')
        assert.is_true(ok)
        assert.is_nil(form)
        assert.match(tostring(err), 'duplicate Content-Disposition header')
        for _, chunksize in ipairs({ 1, 2, 17, 4096 }) do
            local pos = 1
            local reader = {
                read = function(_, n)
                    if pos > #input then return nil end
                    local chunk = input:sub(pos, pos + n - 1)
                    pos = pos + #chunk
                    return chunk
                end,
            }
            ok, form, err = pcall(multipart.decode, reader, 'b', nil, nil, chunksize)
            assert.is_true(ok)
            assert.is_nil(form)
            assert.match(tostring(err), 'duplicate Content-Disposition header')
        end
    end
end

function testcase.decode_allows_disposition_in_each_part_and_repeated_content_type()
    local input = table.concat({
        '--b',
        'Content-Disposition: form-data; name="foo"',
        'Content-Type: text/plain',
        'content-type: application/octet-stream',
        '',
        'one',
        '--b',
        'Content-Disposition: form-data; name="foo"',
        '',
        'two',
        '--b--',
    }, '\r\n')
    local form, err = multipart.decode(input, 'b')
    assert.is_nil(err)
    assert.equal(#form.foo, 2)
    assert.equal(form.foo[1].data, 'one')
    assert.equal(form.foo[2].data, 'two')
    assert.equal(form.foo[1].params, { name = 'foo' })
    assert.equal(form.foo[2].params, { name = 'foo' })
    assert.equal(form.foo[1].header['content-type'], {
        'text/plain', 'application/octet-stream',
    })
end

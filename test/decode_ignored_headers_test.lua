local testcase = require('testcase')
local assert = require('assert')
local errlib = require('error')
local errno = require('errno')
local multipart = require('form.multipart')

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

local function input_for(headers, body)
    return '--b\r\nContent-Disposition: form-data; name="foo"\r\n' ..
        headers .. '\r\n\r\n' .. (body or 'value') .. '\r\n--b--'
end

function testcase.decode_retains_only_disposition_and_content_type()
    local input = input_for(table.concat({
        'cOnTeNt-TyPe: text/plain',
        'X-Custom: first',
        'X-Custom: second',
        'Content-Length: 99999',
        'MIME-Version: 1.0',
        'name: other',
        'filename: fake.txt',
        'X(Extension): "uninterpreted; parameters',
    }, '\r\n'))
    for _, source in ipairs({ input, reader(input) }) do
        local form, err = multipart.decode(source, 'b', nil, nil, 1)
        assert.is_nil(err)
        assert.equal(form.foo[1].data, 'value')
        assert.equal(form.foo[1].params, { name = 'foo' })
        assert.equal(form.foo[1].header, {
            ['content-disposition'] = { 'form-data; name="foo"' },
            ['content-type'] = { 'text/plain' },
        })
    end
end

function testcase.decode_ignores_unsupported_headers_with_empty_values()
    for _, line in ipairs({ 'X-Empty:', 'X-Empty: \t', 'Content-Transfer-Encoding:' }) do
        local input = input_for(line)
        for _, source in ipairs({ input, reader(input) }) do
            local form, err = multipart.decode(source, 'b', nil, nil, 1)
            assert.is_nil(err)
            assert.equal(form.foo[1].data, 'value')
            assert.equal(form.foo[1].header, {
                ['content-disposition'] = { 'form-data; name="foo"' },
            })
        end
    end
end

function testcase.decode_ignores_transfer_encoding_without_transforming_payload()
    local input = input_for('Content-Transfer-Encoding: base64', 'dmFsdWU=')
    for _, source in ipairs({ input, reader(input) }) do
        local form, err = multipart.decode(source, 'b', nil, nil, 1)
        assert.is_nil(err)
        assert.equal(form.foo[1].data, 'dmFsdWU=')
        assert.is_nil(form.foo[1].header['content-transfer-encoding'])
    end
end

function testcase.decode_still_rejects_empty_supported_headers()
    for _, name in ipairs({ 'Content-Disposition', 'Content-Type' }) do
        local input = '--b\r\n' .. name .. ':\r\n\r\nvalue\r\n--b--'
        for _, source in ipairs({ input, reader(input) }) do
            local form, err = multipart.decode(source, 'b', nil, nil, 1)
            assert.is_nil(form)
            assert.equal(errlib.typeof(err), multipart.EDECODE)
            assert.not_nil(errlib.is(err, errno.EINVAL))
            assert.match(tostring(err), 'invalid header')
        end
    end
end

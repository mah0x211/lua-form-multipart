local testcase = require('testcase')
local assert = require('assert')
local errlib = require('error')
local errno = require('errno')
local multipart = require('form.multipart')

function testcase.encode_preserves_header_values_with_valid_folding()
    local values = {
        'metadata',
        'first\tsecond',
        '日本語',
        'first\r\n second',
        'first\r\n\tsecond',
        'first\r\n \tsecond\r\n third',
    }
    local encoded, err, timeout = multipart.encode({
        text = {{
            data = 'value',
            header = { ['X-Test'] = values },
        }},
    }, 'b')
    assert.is_nil(err)
    assert.is_nil(timeout)
    for _, value in ipairs(values) do
        assert.match(encoded, 'X-Test: ' .. value .. '\r\n')
    end
    local form, decode_err = multipart.decode(encoded, 'b')
    assert.is_nil(decode_err)
    assert.equal(form.text[1].data, 'value')
end

function testcase.encode_converts_each_header_value_only_once()
    local calls = 0
    local value = setmetatable({}, {
        __tostring = function()
            calls = calls + 1
            return calls == 1 and 'metadata' or 'changed\r\nInjected: yes'
        end,
    })
    local encoded, err, timeout = multipart.encode({
        text = {{
            data = 'value',
            header = { ['X-Test'] = { value } },
        }},
    }, 'b')
    assert.is_nil(err)
    assert.is_nil(timeout)
    assert.equal(calls, 1)
    assert.match(encoded, 'X-Test: metadata\r\n')
    assert.not_match(encoded, 'Injected: yes')
end

function testcase.encode_rejects_header_line_breaks_that_are_not_folding()
    for _, value in ipairs({
        '\r',
        '\n',
        '\r\n',
        'first\rnext',
        'first\nInjected: yes',
        'first\r\nInjected: yes',
        'first\r\n\r\nbody',
        'first\r\n next\nInjected: yes',
        'first\r\n next\rgarbage',
    }) do
        for _, streaming in ipairs({ false, true }) do
            local output = {}
            local writer
            if streaming then
                writer = {
                    write = function(_, s)
                        output[#output + 1] = s
                        return #s
                    end,
                    writefile = function() error('not a file part') end,
                }
            end
            local encoded, err, timeout = multipart.encode({
                text = {{
                    data = 'value',
                    header = { ['X-Test'] = { value } },
                }},
            }, 'b', writer)
            assert.is_nil(encoded)
            assert.is_nil(timeout)
            assert.equal(errlib.typeof(err), multipart.EENCODE)
            assert.not_nil(errlib.is(err, errno.EINVAL))
            assert.match(tostring(err), 'invalid line break')
            if streaming then
                assert.equal(table.concat(output), '--b\r\n')
            end
        end
    end
end

function testcase.encode_rejects_control_bytes_in_header_values()
    for _, byte in ipairs({ 0, 1, 8, 11, 12, 14, 31, 127 }) do
        for _, prefix in ipairs({ '', string.rep('a', 100) }) do
            local value = prefix .. 'before' .. string.char(byte) .. 'after'
            for _, streaming in ipairs({ false, true }) do
                local output = {}
                local writer
                if streaming then
                    writer = {
                        write = function(_, s)
                            output[#output + 1] = s
                            return #s
                        end,
                        writefile = function() error('not a file part') end,
                    }
                end
                local encoded, err, timeout = multipart.encode({
                    text = {{
                        data = 'value',
                        header = { ['X-Test'] = { value } },
                    }},
                }, 'b', writer)
                assert.is_nil(encoded)
                assert.is_nil(timeout)
                assert.equal(errlib.typeof(err), multipart.EENCODE)
                assert.not_nil(errlib.is(err, errno.EINVAL))
                assert.match(tostring(err), 'control character')
                if streaming then
                    assert.equal(table.concat(output), '--b\r\n')
                end
            end
        end
    end
end

local testcase = require('testcase')
local assert = require('assert')
local multipart = require('form.multipart')

local body = 'Content-Disposition: form-data; name="foo"\r\n\r\nvalue\r\n--b--'

local function split_reader(input, split)
    local chunks = { input:sub(1, split), input:sub(split + 1) }
    local pos = 0
    return {
        read = function()
            pos = pos + 1
            return chunks[pos]
        end,
    }
end

function testcase.decode_accepts_padded_first_boundary_at_every_split()
    for _, preamble in ipairs({ '', 'preamble\r\n', 'preamble \t\r\nnext\r\n', ' \t\r\n\r\n' }) do
        for _, padding in ipairs({ '', ' ', '\t', ' \t \t ', string.rep(' \t', 32) }) do
            for _, newline in ipairs({ '\n', '\r\n' }) do
                local first = preamble .. '--b' .. padding .. newline
                local input = first .. body
                for split = 1, #first do
                    local form, err = multipart.decode(split_reader(input, split), 'b')
                    assert.is_nil(err)
                    assert.equal(form.foo[1].data, 'value')
                end
            end
        end
    end
end

function testcase.decode_rejects_padded_closing_first_boundary_at_every_split()
    for _, padding in ipairs({ '', ' ', '\t', ' \t \t ', string.rep(' \t', 32) }) do
        for _, newline in ipairs({ '\n', '\r\n' }) do
            local first = '--b--' .. padding .. newline
            local input = first .. '--b\r\n' .. body
            for split = 1, #first do
                local form, err = multipart.decode(split_reader(input, split), 'b')
                assert.is_nil(form)
                assert.match(tostring(err), 'end of boundary found, but boundary not started')
            end
        end
    end
end

function testcase.decode_does_not_accept_boundary_prefix_in_preamble()
    local preamble = '--b suffix\r\n--b-- suffix\r\n --b \t\r\n'
    local input = preamble .. '--b \t\r\n' .. body
    for split = 1, #preamble + 7 do
        local form, err = multipart.decode(split_reader(input, split), 'b')
        assert.is_nil(err)
        assert.equal(form.foo[1].data, 'value')
    end
end

function testcase.decode_accepts_padding_across_many_reads()
    local input = 'preamble\r\n--b' .. string.rep(' \t', 32) .. '\r\n' .. body
    for _, chunksize in ipairs({ 1, 2, 7 }) do
        local pos = 1
        local reader = {
            read = function(_, n)
                if pos > #input then return nil end
                local chunk = input:sub(pos, pos + n - 1)
                pos = pos + #chunk
                return chunk
            end,
        }
        local form, err = multipart.decode(reader, 'b', nil, nil, chunksize)
        assert.is_nil(err)
        assert.equal(form.foo[1].data, 'value')
    end
end

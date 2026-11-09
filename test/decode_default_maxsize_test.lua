local testcase = require('testcase')
local assert = require('assert')
local errlib = require('error')
local errno = require('errno')
local multipart = require('form.multipart')
local unpack = table.unpack or unpack

local default_size = 128 * 1024
local prefix = 'preamble\r\n--b\r\nContent-Disposition: form-data; name="text"\r\n\r\n'
local suffix = '\r\n--b--\r\n'

local function text_body(size)
    local data = string.rep('x', size - #prefix - #suffix)
    return prefix .. data .. suffix, data
end

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

function testcase.decode_defaults_named_options_to_131072_total_bytes()
    local input, data = text_body(default_size)
    assert.equal(#input, 131072)
    for _, opts in ipairs({ {}, { maxsize = nil, chunksize = 4096 } }) do
        for _, source in ipairs({ input, reader(input) }) do
            local form, err, timeout = multipart.decode(source, 'b', opts)
            assert.is_nil(err)
            assert.is_nil(timeout)
            assert.equal(form.text[1].data, data)
        end
        local oversized = input .. 'x'
        for _, source in ipairs({ oversized, reader(oversized) }) do
            local form, err, timeout = multipart.decode(source, 'b', opts)
            assert.is_nil(form)
            assert.is_nil(timeout)
            assert.equal(errlib.typeof(err), multipart.EDECODE)
            assert.not_nil(errlib.is(err, errno.EFBIG))
            assert.match(tostring(err), 'maxsize')
        end
        assert.is_nil(opts.maxsize)
    end
end

function testcase.decode_honors_an_explicit_total_above_the_default()
    local input, data = text_body(default_size + 1)
    for _, source in ipairs({ input, reader(input) }) do
        local form, err, timeout = multipart.decode(source, 'b', {
            maxsize = #input,
        })
        assert.is_nil(err)
        assert.is_nil(timeout)
        assert.equal(form.text[1].data, data)
    end
end

function testcase.decode_keeps_legacy_total_sizes_unlimited()
    local input, data = text_body(default_size + 1)
    for _, args in ipairs({
        { n = 0 },
        { n = 1 },
        { n = 3 },
        { n = 1, './legacy_template' },
        { n = 3, [3] = 4096 },
        { n = 4, [3] = 4096, [4] = 0 },
        { n = 5, [3] = 4096, [4] = 0, [5] = { maxsize = 0 } },
    }) do
        for _, source in ipairs({ input, reader(input) }) do
            local form, err, timeout = multipart.decode(source, 'b',
                unpack(args, 1, args.n))
            assert.is_nil(err)
            assert.is_nil(timeout)
            assert.equal(form.text[1].data, data)
        end
    end
end

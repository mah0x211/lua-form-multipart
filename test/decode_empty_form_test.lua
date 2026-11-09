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

function testcase.decode_round_trips_empty_forms()
    for _, boundary in ipairs({ 'b', string.rep('b', 70) }) do
        local encoded = assert(multipart.encode({}, boundary))
        assert.equal(encoded, '--' .. boundary .. '--')
        for _, source in ipairs({ encoded, reader(encoded) }) do
            local form, err, timeout = multipart.decode(source, boundary, {
                chunksize = 1,
            })
            assert.is_nil(err)
            assert.is_nil(timeout)
            assert.is_table(form)
            assert.empty(form)
        end
    end
end

function testcase.decode_accepts_empty_forms_at_every_split()
    for _, input in ipairs({
        '--b--',
        '--b-- ',
        '--b--\t',
        '--b-- \t',
        '--b--\r\n',
        '\r\n--b--\r\n',
        'preamble\r\n--b-- \t\r\nepilogue',
        '--b--\nepilogue',
    }) do
        local form, err, timeout = multipart.decode(input, 'b')
        assert.is_nil(err)
        assert.is_nil(timeout)
        assert.is_table(form)
        assert.empty(form)
        for split = 1, #input do
            local chunks = { input:sub(1, split), input:sub(split + 1) }
            local calls = 0
            form, err, timeout = multipart.decode({
                read = function()
                    calls = calls + 1
                    return chunks[calls]
                end,
            }, 'b')
            assert.is_nil(err)
            assert.is_nil(timeout)
            assert.is_table(form)
            assert.empty(form)
        end
    end
end

function testcase.decode_applies_size_and_part_limits_to_empty_forms()
    local input = '--b-- \t\r\nepilogue'
    for _, source in ipairs({ input, reader(input) }) do
        local form, err, timeout = multipart.decode(source, 'b', {
            maxparts = 0, maxfilesize = 0, maxsize = #input, chunksize = 1,
        })
        assert.is_nil(err)
        assert.is_nil(timeout)
        assert.is_table(form)
        assert.empty(form)
    end
    for _, maxsize in ipairs({ 0, #input - 1 }) do
        for _, source in ipairs({ input, reader(input) }) do
            local form, err, timeout = multipart.decode(source, 'b', {
                maxparts = 0, maxsize = maxsize, chunksize = 1,
            })
            assert.is_nil(form)
            assert.is_nil(timeout)
            assert.equal(errlib.typeof(err), multipart.EDECODE)
            assert.not_nil(errlib.is(err, errno.EFBIG))
        end
    end
end

function testcase.decode_rejects_malformed_empty_forms_and_headerless_parts()
    for _, input in ipairs({
        '', '--b', '--b-', '--b--\r', '--b-- \t\r',
        '--b--X\r\n', '--b----\r\n', '--b-- \tX\r\n', '--b--\rX\n',
        '--b\r\n--b--\r\n', '--b\r\n\r\n--b--',
    }) do
        for _, source in ipairs({ input, reader(input) }) do
            local form, err, timeout = multipart.decode(source, 'b', {
                chunksize = 1,
            })
            assert.is_nil(form)
            assert.is_nil(timeout)
            assert.equal(errlib.typeof(err), multipart.EDECODE)
            assert.not_nil(errlib.is(err, errno.EINVAL))
        end
    end
end

function testcase.decode_preserves_empty_form_read_errors_and_timeouts()
    local cause = errno.new('EIO', 'empty form read failed')
    for _, prefix in ipairs({ '--b-', '--b--', '--b--\r', '--b--\r\n' }) do
        for _, failure in ipairs({
            { timeout = true },
            { err = cause },
            { err = cause, timeout = true },
        }) do
            local calls = 0
            local form, err, timeout = multipart.decode({
                read = function()
                    calls = calls + 1
                    if calls == 1 then return prefix end
                    assert.equal(calls, 2)
                    return nil, failure.err, failure.timeout
                end,
            }, 'b')
            assert.is_nil(form)
            assert.equal(timeout, failure.timeout)
            if failure.err then
                assert.equal(errlib.typeof(err), multipart.EDECODE)
                assert.is_true(errlib.unwrap(err) == cause)
            else
                assert.is_nil(err)
            end
            assert.equal(calls, 2)
        end
    end
end

function testcase.decode_does_not_read_again_after_empty_form_eof()
    for _, empty_eof in ipairs({ false, true }) do
        local calls = 0
        local form, err, timeout = multipart.decode({
            read = function()
                calls = calls + 1
                if calls == 1 then return '--b-- \t' end
                assert.equal(calls, 2)
                if empty_eof then return '' end
            end,
        }, 'b')
        assert.is_nil(err)
        assert.is_nil(timeout)
        assert.is_table(form)
        assert.empty(form)
        assert.equal(calls, 2)
    end
end

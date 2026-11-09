local IS_LUA51 = _VERSION == 'Lua 5.1' and not _G.jit
local testcase = require('testcase')
local assert = require('assert')
local errlib = require('error')
local errno = require('errno')
local multipart = require('form.multipart')

local header = '--b\r\nContent-Disposition: form-data; name="foo"\r\n\r\n'
local body = header .. 'value\r\n--b--'

local function reader(input, empty_eof)
    return {
        pos = 1,
        calls = 0,
        read = function(self, n)
            self.calls = self.calls + 1
            local s = input:sub(self.pos, self.pos + n - 1)
            self.pos = self.pos + #s
            if #s == 0 and not empty_eof then return nil end
            return s
        end,
    }
end

local function assert_maxsize_error(form, err)
    assert.is_nil(form)
    assert.equal(errlib.typeof(err), multipart.EDECODE)
    assert.not_nil(errlib.is(err, errno.EFBIG))
    assert.match(tostring(err), 'maxsize')
end

function testcase.decode_checks_whole_string_byte_count()
    local input = 'preamble\r\n' .. header .. '日本語\r\n--b--\r\nepilogue'
    for _, maxsize in ipairs({ #input, #input + 1 }) do
        local form, err = multipart.decode(input, 'b', { maxsize = maxsize })
        assert.is_nil(err)
        assert.equal(form.foo[1].data, '日本語')
    end
    assert_maxsize_error(multipart.decode(input, 'b', { maxsize = #input - 1 }))
end

function testcase.decode_checks_exact_stream_limit_across_chunk_sizes()
    local input = 'preamble\r\n' .. body .. '\r\nepilogue'
    for chunksize = 1, #input + 1 do
        for _, empty_eof in ipairs({ false, true }) do
            local source = reader(input, empty_eof)
            local form, err = multipart.decode(source, 'b', {
                chunksize = chunksize, maxsize = #input,
            })
            assert.is_nil(err)
            assert.equal(form.foo[1].data, 'value')
            assert.equal(source.pos, #input + 1)
            assert_maxsize_error(multipart.decode(reader(input, empty_eof), 'b', {
                chunksize = chunksize, maxsize = #input - 1,
            }))
        end
    end
end

function testcase.decode_zero_budget_rejects_input_but_preserves_empty_input_error()
    assert_maxsize_error(multipart.decode(body, 'b', { maxsize = 0 }))
    local source = reader(body)
    assert_maxsize_error(multipart.decode(source, 'b', { maxsize = 0 }))
    assert.equal(source.pos, 2)
    assert.equal(source.calls, 1)
    for _, input in ipairs({ '', reader(''), reader('', true) }) do
        local form, err = multipart.decode(input, 'b', { maxsize = 0 })
        assert.is_nil(form)
        assert.not_nil(errlib.is(err, errno.EINVAL))
        assert.is_nil(errlib.is(err, errno.EFBIG))
    end
end

function testcase.decode_negative_total_limits_match_zero()
    for _, limit in ipairs({ -1, -100 }) do
        local opts = { maxsize = limit }
        assert_maxsize_error(multipart.decode(body, 'b', opts))
        local source = reader(body)
        assert_maxsize_error(multipart.decode(source, 'b', opts))
        assert.equal(source.pos, 2)
        assert.equal(source.calls, 1)
        assert.equal(opts.maxsize, limit)

        for _, input in ipairs({ '', reader(''), reader('', true) }) do
            local form, err = multipart.decode(input, 'b', opts)
            assert.is_nil(form)
            assert.not_nil(errlib.is(err, errno.EINVAL))
            assert.is_nil(errlib.is(err, errno.EFBIG))
        end
    end
end

function testcase.decode_limits_bytes_in_every_multipart_region()
    local input = 'preamble\r\n--b \t\r\n' ..
        'Content-Disposition: form-data; name="foo"\r\n\r\nvalue\r\n' ..
        '--b \t\r\nContent-Disposition: form-data; name="bar"\r\n\r\nother\r\n' ..
        '--b-- \t\r\nepilogue'
    for maxsize = 0, #input - 1 do
        local source = reader(input)
        assert_maxsize_error(multipart.decode(source, 'b', {
            chunksize = 7, maxsize = maxsize,
        }))
        assert.equal(source.pos, maxsize + 2)
        local form, err = multipart.decode(input, 'b', { maxsize = maxsize })
        assert_maxsize_error(form, err)
    end
    local form, err = multipart.decode(reader(input), 'b', {
        chunksize = 7, maxsize = #input,
    })
    assert.is_nil(err)
    assert.equal(form.foo[1].data, 'value')
    assert.equal(form.bar[1].data, 'other')
end

function testcase.decode_limits_epilogue_reads_to_remaining_bytes_plus_one()
    local calls = 0
    local source = {
        read = function(_, n)
            calls = calls + 1
            if calls == 1 then
                assert.equal(n, #body + 3)
                return body
            elseif calls == 2 then
                assert.equal(n, 3)
                return 'abc'
            end
            error('must stop reading after maxsize is exceeded')
        end,
    }
    assert_maxsize_error(multipart.decode(source, 'b', {
        chunksize = 4096, maxsize = #body + 2,
    }))
    assert.equal(calls, 2)
end

function testcase.decode_counts_actual_bytes_when_reader_exceeds_requested_size()
    for _, chunks in ipairs({ { body .. '\r\nextra' }, { body, '\r\nextra' } }) do
        local calls = 0
        local source = {
            read = function()
                calls = calls + 1
                if chunks[calls] then return chunks[calls] end
                error('must stop reading after oversized chunk')
            end,
        }
        assert_maxsize_error(multipart.decode(source, 'b', {
            chunksize = 1, maxsize = #body,
        }))
        assert.equal(calls, #chunks)
    end
end

function testcase.decode_unlimited_default_keeps_previous_read_requests()
    local input = body .. '\r\n' .. string.rep('x', 8192)
    local source = reader(input)
    local read = source.read
    source.read = function(self, n)
        assert.equal(n, 13)
        return read(self, n)
    end
    local form, err = multipart.decode(source, 'b', nil, nil, 13)
    assert.is_nil(err)
    assert.equal(form.foo[1].data, 'value')
    assert.equal(source.pos, #input + 1)
end

function testcase.decode_maxsize_argument_contract_violations_raise()
    for _, value in ipairs({ false, '1', {}, -1.5, 1.5, math.huge, -math.huge, 0 / 0 }) do
        local calls = 0
        local ok, err = pcall(multipart.decode, {
            read = function() calls = calls + 1 end,
        }, 'b', { maxsize = value })
        assert.is_false(ok)
        assert.match(tostring(err), 'maxsize must be integer')
        assert.is_nil(errlib.is(err, multipart.EDECODE))
        assert.equal(calls, 0)
    end
end

function testcase.decode_preserves_reader_failures_with_a_size_budget()
    for _, after_body in ipairs({ false, true }) do
        for _, raises in ipairs({ false, true }) do
            for _, typed in ipairs({ false, true }) do
                local cause = typed and errno.EIO:new('read failed') or 'read failed'
                local calls = 0
                local source = {
                    read = function()
                        calls = calls + 1
                        if after_body and calls == 1 then return body end
                        if raises then error(cause, 0) end
                        -- A reader error takes precedence even with oversized data.
                        return string.rep('x', #body + 1), cause
                    end,
                }
                local ok, form, err = pcall(multipart.decode, source, 'b', { maxsize = #body })
                if IS_LUA51 and raises then
                    assert.is_false(ok)
                    assert.is_true(form == cause)
                else
                    assert.is_true(ok)
                    assert.is_nil(form)
                    assert.equal(errlib.typeof(err), multipart.EDECODE)
                    assert.is_nil(errlib.is(err, errno.EFBIG))
                    if typed then
                        assert.is_true(errlib.unwrap(err) == cause)
                    else
                        assert.equal(tostring(errlib.unwrap(err).message), cause)
                    end
                end
                assert.equal(calls, after_body and 2 or 1)
            end
        end
    end
end

function testcase.decode_does_not_replace_syntax_errors_with_budget_errors()
    for _, input in ipairs({ header .. 'unfinished', '--b--X\r\n' }) do
        for _, source in ipairs({ input, reader(input) }) do
            local form, err = multipart.decode(source, 'b', {
                chunksize = 2, maxsize = #input,
            })
            assert.is_nil(form)
            assert.equal(errlib.typeof(err), multipart.EDECODE)
            assert.not_nil(errlib.is(err, errno.EINVAL))
            assert.is_nil(errlib.is(err, errno.EFBIG))
        end
    end
end

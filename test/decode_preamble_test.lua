local IS_LUA51 = _VERSION == 'Lua 5.1' and not _G.jit
local testcase = require('testcase')
local assert = require('assert')
local multipart = require('form.multipart')
local errlib = require('error')
local errno = require('errno')

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

function testcase.decode_discards_newline_heavy_preamble_at_every_split()
    for _, preamble in ipairs({
        string.rep('\n', 64),
        string.rep('\r\n', 32),
        string.rep('x\n', 16) .. '--bgarbage\r\n--b \rX\n' ..
            string.rep('\r\n', 16),
    }) do
        local input = preamble .. '--b\r\n' .. body
        local form, err = multipart.decode(input, 'b', { maxsize = #input })
        assert.is_nil(err)
        assert.equal(form.foo[1].data, 'value')
        for split = 1, #preamble + 5 do
            form, err = multipart.decode(split_reader(input, split), 'b', {
                maxsize = #input,
            })
            assert.is_nil(err)
            assert.equal(form.foo[1].data, 'value')
        end
    end
end

function testcase.decode_accepts_padded_closing_first_boundary_at_every_split()
    for _, padding in ipairs({ '', ' ', '\t', ' \t \t ', string.rep(' \t', 32) }) do
        for _, newline in ipairs({ '\n', '\r\n' }) do
            local first = '--b--' .. padding .. newline
            local input = first .. '--b\r\n' .. body
            for split = 1, #first do
                local form, err = multipart.decode(split_reader(input, split), 'b')
                assert.is_nil(err)
                assert.is_table(form)
                assert.empty(form)
            end
        end
    end
end

function testcase.decode_does_not_accept_boundary_prefix_in_preamble()
    local preamble = '--bfoo\r\n--b----\r\n--b--foo\r\n' ..
        '--b suffix\r\n--b-- suffix\r\n --b \t\r\n'
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

function testcase.decode_discards_large_preamble_fragments_without_accumulating_them()
    for _, case in ipairs({
        {
            prefix = 'preamble',
            chunk = string.rep('x', 256 * 1024),
            suffix = '\r\n--b\r\n' .. body,
        },
        {
            prefix = '--b',
            chunk = string.rep(' \t', 128 * 1024),
            suffix = '\r\n' .. body,
        },
        {
            prefix = '--b -',
            chunk = string.rep(' \t', 128 * 1024),
            suffix = '\r\n--b\r\n' .. body,
        },
    }) do
        local baseline = collectgarbage('count')
        local calls = 0
        local source = {
            read = function()
                calls = calls + 1
                collectgarbage('collect')
                -- Reuse a chunk to generate eight MiB. Discarded preamble
                -- and transport padding must not remain live in the parser.
                -- Lua reports managed memory in KiB; allow chunk headroom.
                assert.less(collectgarbage('count') - baseline, 2048)
                if calls == 1 then return case.prefix end
                if calls <= 33 then return case.chunk end
                if calls == 34 then return case.suffix end
            end,
        }
        local form, err = multipart.decode(source, 'b', nil, nil, #case.chunk)
        assert.is_nil(err)
        assert.equal(form.foo[1].data, 'value')
    end
end

function testcase.decode_does_not_restart_boundary_matching_inside_a_discarded_line()
    local preamble = string.rep('x', 4096)
    local input = preamble .. '--b\r\n' ..
        'Content-Disposition: form-data; name="wrong"\r\n\r\nwrong\r\n--b\r\n' .. body
    local form, err = multipart.decode(split_reader(input, #preamble), 'b')
    assert.is_nil(err)
    assert.equal(form.foo[1].data, 'value')
    assert.is_nil(form.wrong)
end

function testcase.decode_keeps_long_first_boundary_at_every_split()
    local boundary = string.rep('b', 70)
    local header = 'Content-Disposition: form-data; name="foo"\r\n\r\nvalue\r\n--' ..
        boundary .. '--'
    for _, newline in ipairs({ '\n', '\r\n' }) do
        local preamble = string.rep('x', 4096) .. newline
        local first = '--' .. boundary .. ' \t' .. newline
        local input = preamble .. first .. header
        for split = 1, #first do
            local form, err = multipart.decode(split_reader(input, #preamble + split),
                                              boundary)
            assert.is_nil(err)
            assert.equal(form.foo[1].data, 'value')
        end
    end
end

function testcase.decode_keeps_reader_errors_during_preamble_and_boundary_reads()
    for _, prefix in ipairs({
        '--', '--b', '--b-', '--b ', '--b\r', '--b \r', '--b-- ', string.rep('x', 65536),
    }) do
        for _, raises in ipairs({ false, true }) do
            local cause = errno.EIO:new('preamble read failed')
            local calls = 0
            local source = {
                read = function()
                    calls = calls + 1
                    if calls == 1 then return prefix end
                    if raises then error(cause, 0) end
                    return nil, cause
                end,
            }
            local ok, form, err = pcall(multipart.decode, source, 'b')
            if IS_LUA51 and raises then
                assert.is_false(ok)
                assert.is_true(form == cause)
            else
                assert.is_true(ok)
                assert.is_nil(form)
                assert.equal(errlib.typeof(err), multipart.EDECODE)
                assert.is_true(errlib.unwrap(err) == cause)
            end
        end
    end
end

function testcase.decode_counts_discarded_preamble_toward_total_size_limit()
    local input = string.rep('x', 16384) .. '\r\n--b\r\n' .. body
    local pos = 1
    local source = {
        read = function(_, n)
            local chunk = input:sub(pos, pos + n - 1)
            pos = pos + #chunk
            if #chunk > 0 then return chunk end
        end,
    }
    local form, err = multipart.decode(source, 'b', { chunksize = 1024, maxsize = 8192 })
    assert.is_nil(form)
    assert.equal(errlib.typeof(err), multipart.EDECODE)
    assert.not_nil(errlib.is(err, errno.EFBIG))
    assert.equal(pos - 1, 8193)
end

function testcase.decode_rejects_eof_during_preamble_and_boundary_reads()
    for _, input in ipairs({
        '--', '--b', '--b-', '--b ', '--b\r', '--b \r', string.rep('x', 16384),
    }) do
        local form, err = multipart.decode(split_reader(input, #input - 1), 'b')
        assert.is_nil(form)
        assert.equal(errlib.typeof(err), multipart.EDECODE)
        assert.not_nil(errlib.is(err, errno.EINVAL))
        assert.match(tostring(err), 'insufficient multipart/form-data')
    end
end

function testcase.decode_discards_invalid_first_boundary_terminators()
    for _, line in ipairs({
        '--b\r ', '--b\t\r\t', '--b\r\r', '--b--\rX', '--b \t--', '--b \r--',
    }) do
        local input = line .. '\n--b\r\n' .. body
        for split = 1, #line + 3 do
            local form, err = multipart.decode(split_reader(input, split), 'b')
            assert.is_nil(err)
            assert.equal(form.foo[1].data, 'value')
        end
    end
end

function testcase.decode_preserves_reader_errors_after_closing_first_boundary()
    for _, newline in ipairs({ '\n', '\r\n' }) do
        local cause = errno.EIO:new('read beyond closing first boundary')
        local calls = 0
        local source = {
            read = function()
                calls = calls + 1
                if calls == 1 then return '--b--' .. newline end
                return nil, cause
            end,
        }
        local form, err = multipart.decode(source, 'b')
        assert.is_nil(form)
        assert.equal(errlib.typeof(err), multipart.EDECODE)
        assert.is_true(errlib.unwrap(err) == cause)
        assert.equal(calls, 2)
    end
end

function testcase.decode_preserves_reader_einval_at_boundary_terminator()
    local cause = errno.new('EINVAL', 'invalid multipart boundary terminator')
    local calls = 0
    local source = {
        read = function()
            calls = calls + 1
            if calls == 1 then return '--b \t' end
            assert.equal(calls, 2)
            return nil, cause
        end,
    }
    local form, err = multipart.decode(source, 'b')
    assert.is_nil(form)
    assert.equal(errlib.typeof(err), multipart.EDECODE)
    assert.is_true(errlib.unwrap(err) == cause)
    assert.equal(calls, 2)
end

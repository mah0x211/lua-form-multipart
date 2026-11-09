local IS_LUA51 = _VERSION == 'Lua 5.1' and not _G.jit
local testcase = require('testcase')
local assert = require('assert')
local errlib = require('error')
local errno = require('errno')
local mkstemp = require('mkstemp')
local readdir = require('testcase.readdir')
local multipart = require('form.multipart')
local prefixes = {}

local LIMIT = 16384
local disposition = 'Content-Disposition: form-data; name="foo"'
local names = { 'Content-Disposition', 'Content-Type', 'X-Ignored' }

local function reader(input, split)
    return {
        pos = 1,
        read = function(self, n)
            local last = self.pos + n - 1
            if split and self.pos <= split then last = math.min(last, split) end
            local s = input:sub(self.pos, last)
            self.pos = self.pos + #s
            if #s > 0 then return s end
        end,
    }
end

local function field(name, size, newline)
    local prefix = name .. ': '
    if name == 'Content-Disposition' then
        prefix = disposition .. '; custom='
    elseif name == 'Content-Type' then
        prefix = prefix .. 'text/plain; custom='
    end
    if newline then prefix = prefix .. newline .. '\t' end
    return prefix .. string.rep('x', size - #prefix)
end

local function headers(name, size, newline, folded)
    local prefix = name == 'Content-Disposition' and '' or disposition .. newline
    local line = field(name, size - #prefix - 2 * #newline, folded and newline)
    return prefix .. line .. newline .. newline, line
end

local function input_for(block, newline, payload)
    return '--b' .. newline .. block .. (payload or 'value') .. newline .. '--b--'
end

local function assert_size_error(form, err)
    assert.is_nil(form)
    assert.equal(errlib.typeof(err), multipart.EDECODE)
    assert.not_nil(errlib.is(err, errno.EFBIG))
    assert.match(tostring(err), 'header')
    assert.match(tostring(err), '16384')
end

local function assert_decoded(input, source, chunksize)
    local form, err = multipart.decode(source or input, 'b', nil, nil, chunksize)
    assert.is_nil(err)
    assert.equal(form.foo[1].data, 'value')
    return form.foo[1]
end

local function files_with_prefix(prefix)
    local files = {}
    local err = readdir('.', function(name)
        if name:sub(1, #prefix + 1) == prefix .. '_' then
            files[#files + 1] = name
        end
    end)
    assert.is_nil(err)
    return files
end

function testcase.after_each()
    for _, prefix in ipairs(prefixes) do
        for _, pathname in ipairs(files_with_prefix(prefix)) do os.remove(pathname) end
    end
    prefixes = {}
    collectgarbage('restart')
end

function testcase.decode_accepts_exactly_16384_header_bytes_per_part()
    for _, newline in ipairs({ '\r\n', '\n' }) do
        for _, name in ipairs(names) do
            local block, line = headers(name, LIMIT, newline)
            assert.equal(#block, LIMIT)
            local input = input_for(block, newline)
            assert_decoded(input)
            for _, chunksize in ipairs({ 31, 4096 }) do
                local part = assert_decoded(input, reader(input), chunksize)
                if name ~= 'X-Ignored' then
                    assert.equal(part.header[name:lower()], { line:sub(#name + 3) })
                else
                    assert.is_nil(part.header['x-ignored'])
                end
            end
        end
    end
end

function testcase.decode_rejects_16385_header_bytes_in_supported_and_ignored_fields()
    for _, newline in ipairs({ '\r\n', '\n' }) do
        for _, name in ipairs(names) do
            local block = headers(name, LIMIT + 1, newline)
            local input = input_for(block, newline)
            assert_size_error(multipart.decode(input, 'b'))
            for _, chunksize in ipairs({ 31, 4096 }) do
                assert_size_error(multipart.decode(reader(input), 'b', nil, nil, chunksize))
            end
        end
    end
end

function testcase.decode_counts_fold_line_endings_and_indentation()
    for _, newline in ipairs({ '\r\n', '\n' }) do
        for _, name in ipairs(names) do
            for _, size in ipairs({ LIMIT, LIMIT + 1 }) do
                local block = headers(name, size, newline, true)
                assert.equal(#block, size)
                local input = input_for(block, newline)
                if size == LIMIT then
                    assert_decoded(input)
                else
                    assert_size_error(multipart.decode(input, 'b'))
                end
                for _, chunksize in ipairs({ 17, 4096 }) do
                    if size == LIMIT then
                        assert_decoded(input, reader(input), chunksize)
                    else
                        assert_size_error(multipart.decode(reader(input), 'b', nil, nil, chunksize))
                    end
                end
            end
        end
    end
end

function testcase.decode_counts_small_fields_cumulatively()
    for _, newline in ipairs({ '\r\n', '\n' }) do
        local prefix = disposition .. newline ..
            string.rep('X-Ignored:' .. newline, 1000)
        local last = field('Content-Type', LIMIT - #prefix - 2 * #newline)
        local block = prefix .. last .. newline .. newline
        assert.equal(#block, LIMIT)
        assert_decoded(input_for(block, newline))
        assert_decoded(input_for(block, newline), reader(input_for(block, newline)), 31)
        local input = input_for(prefix .. last .. 'x' .. newline .. newline, newline)
        assert_size_error(multipart.decode(input, 'b'))
        assert_size_error(multipart.decode(reader(input), 'b', nil, nil, 31))
    end
end

function testcase.decode_handles_splits_at_the_limit_and_header_separator()
    for _, newline in ipairs({ '\r\n', '\n' }) do
        for _, size in ipairs({ LIMIT, LIMIT + 1 }) do
            local block = headers('Content-Disposition', size, newline, true)
            local input = input_for(block, newline)
            local start = #'--b' + #newline
            for split = start + LIMIT - 2 * #newline - 1, start + size do
                if size == LIMIT then
                    assert_decoded(input, reader(input, split))
                else
                    assert_size_error(multipart.decode(reader(input, split), 'b'))
                end
            end
        end
    end
end

function testcase.decode_counts_header_bytes_with_one_byte_reads()
    for _, newline in ipairs({ '\r\n', '\n' }) do
        local input = input_for(headers('Content-Disposition', LIMIT, newline), newline)
        assert_decoded(input, reader(input), 1)
        input = input_for(headers('Content-Disposition', LIMIT + 1, newline), newline)
        assert_size_error(multipart.decode(reader(input), 'b', nil, nil, 1))
    end
end

function testcase.decode_counts_names_padding_and_multibyte_values()
    local newline = '\r\n'
    local prefix = disposition .. newline
    local size = LIMIT - #prefix - 2 * #newline
    for _, name in ipairs({ string.rep('X', size - 1), 'X' .. string.rep(' ', size - 2) }) do
        local block = prefix .. name .. ':' .. newline .. newline
        assert.equal(#block, LIMIT)
        assert_decoded(input_for(block, newline))
        assert_size_error(multipart.decode(
            input_for(prefix .. name .. ' :' .. newline .. newline, newline), 'b'))
    end
    prefix = prefix .. 'X-Ignored: '
    local n = LIMIT - #prefix - 2 * #newline
    local value = string.rep('é', math.floor(n / 2)) .. string.rep('x', n % 2)
    local block = prefix .. value .. newline .. newline
    assert.equal(#block, LIMIT)
    assert_decoded(input_for(block, newline))
    assert_size_error(multipart.decode(
        input_for(prefix .. value .. 'x' .. newline .. newline, newline), 'b'))
end

function testcase.decode_resets_the_budget_per_part_and_excludes_preamble_and_payload()
    local block = headers('Content-Disposition', LIMIT, '\r\n')
    local payload = string.rep(' ', LIMIT + 1) .. 'value'
    local input = string.rep('p', LIMIT + 1) .. '\r\n--b\r\n' ..
        block .. payload .. '\r\n--b\r\n' .. block .. payload .. '\r\n--b--'
    for _, source in ipairs({ input, reader(input) }) do
        local form, err = multipart.decode(source, 'b', nil, nil, 4096)
        assert.is_nil(err)
        assert.equal(#form.foo, 2)
        assert.equal(form.foo[1].data, payload)
        assert.equal(form.foo[2].data, payload)
    end
end

function testcase.decode_stops_reading_oversized_unterminated_headers()
    local input = '--b\r\nX-Ignored: ' .. string.rep('x', 3 * LIMIT)
    for _, chunksize in ipairs({ 13, 4096 }) do
        local source = reader(input)
        assert_size_error(multipart.decode(source, 'b', nil, nil, chunksize))
        assert.is_true(source.pos <= #'--b\r\n' + LIMIT + 1 + chunksize)
        assert.is_true(source.pos < #input)
    end
end

function testcase.decode_preserves_reader_errors_before_header_completion()
    for _, raises in ipairs({ false, true }) do
        local cause = errno.EIO:new('header reader failed')
        local calls = 0
        local block = headers('Content-Disposition', LIMIT, '\r\n')
        local source = {
            read = function()
                calls = calls + 1
                if calls == 1 then return '--b\r\n' .. block:sub(1, -3) end
                assert.equal(calls, 2)
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

function testcase.decode_keeps_incomplete_headers_within_budget_as_syntax_errors()
    local block = headers('Content-Disposition', LIMIT, '\r\n')
    for _, suffix in ipairs({ '', '\r', '\r\n' }) do
        local input = '--b\r\n' .. block:sub(1, -5) .. suffix
        for _, source in ipairs({ input, reader(input) }) do
            local form, err = multipart.decode(source, 'b', nil, nil, 31)
            assert.is_nil(form)
            assert.not_nil(errlib.is(err, errno.EINVAL))
            assert.is_nil(errlib.is(err, errno.EFBIG))
        end
    end
end

function testcase.decode_removes_completed_uploads_after_a_header_size_error()
    local file, _, pathname = assert(mkstemp('./header_limit_cleanup_XXXXXX'))
    file:close()
    assert(os.remove(pathname))
    local prefix = pathname:gsub('^%./', '')
    prefixes[#prefixes + 1] = prefix

    collectgarbage('stop')
    local block = headers('Content-Disposition', LIMIT + 1, '\r\n')
    local input = '--b\r\n' .. disposition .. '; filename="a.txt"\r\n\r\npayload\r\n' ..
        '--b\r\n' .. block .. 'last\r\n--b--'
    assert_size_error(multipart.decode(reader(input), 'b', prefix, nil, 31))
    assert.equal(files_with_prefix(prefix), {})
end

local testcase = require('testcase')
local assert = require('assert')
local errlib = require('error')
local errno = require('errno')
local mkstemp = require('mkstemp')
local readdir = require('testcase.readdir')
local multipart = require('form.multipart')
local prefixes = {}
local sources = {}

local header = '--b\r\nContent-Disposition: form-data; name="foo"\r\n\r\n'
local body = header .. 'value\r\n--b--'
local next_part = 'Content-Disposition: form-data; name="bar"\r\n\r\nlast\r\n--b--'

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

local function assert_invalid(form, err)
    assert.is_nil(form)
    assert.equal(errlib.typeof(err), multipart.EDECODE)
    assert.not_nil(errlib.is(err, errno.EINVAL))
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

local function unused_prefix()
    local file, _, pathname = assert(mkstemp('./boundary_cleanup_XXXXXX'))
    file:close()
    assert(os.remove(pathname))
    local prefix = pathname:gsub('^%./', '')
    prefixes[#prefixes + 1] = prefix
    return prefix
end

function testcase.before_each()
    collectgarbage('stop')
end

function testcase.after_each()
    for _, source in ipairs(sources) do
        if io.type(source) == 'file' then source:close() end
    end
    sources = {}
    for _, prefix in ipairs(prefixes) do
        for _, pathname in ipairs(files_with_prefix(prefix)) do os.remove(pathname) end
    end
    prefixes = {}
    collectgarbage('restart')
end

function testcase.decode_rejects_garbage_after_normal_boundary()
    for _, suffix in ipairs({
        'GARBAGE\r\n', 'X\r\n', '-\r\n', ' \tX\r\n', '\v\r\n', '\rX\r\n', '\r\r\n',
        '\r \n', '\r\t\n',
    }) do
        local input = header .. 'value\r\n--b' .. suffix .. next_part
        assert_invalid(multipart.decode(input, 'b'))
        for _, chunksize in ipairs({ 1, 2, 3, 4, 7, 32, 4096 }) do
            assert_invalid(multipart.decode(reader(input), 'b', nil, nil, chunksize))
        end
    end
end

function testcase.decode_rejects_garbage_after_closing_boundary()
    for _, suffix in ipairs({
        'GARBAGE', '-\r\n', '--\r\n', ' \tX\r\n', '\rX', '\r', '\v', '\t\r',
        '\r \n', '\r\t\n',
    }) do
        local input = body .. suffix
        assert_invalid(multipart.decode(input, 'b'))
        for _, chunksize in ipairs({ 1, 2, 3, 4, 7, 32, 4096 }) do
            assert_invalid(multipart.decode(reader(input), 'b', nil, nil, chunksize))
        end
    end
end

function testcase.decode_accepts_normal_boundary_padding_and_line_endings()
    for _, suffix in ipairs({ '\r\n', '\n', ' \t\r\n', ' \t\n' }) do
        local input = header .. 'value\r\n--b' .. suffix .. next_part
        for _, source in ipairs({ input, reader(input) }) do
            local form, err = multipart.decode(source, 'b', nil, nil, 1)
            assert.is_nil(err)
            assert.equal(form.foo[1].data, 'value')
            assert.equal(form.bar[1].data, 'last')
        end
    end
end

function testcase.decode_accepts_closing_boundary_eof_padding_and_epilogue()
    for _, suffix in ipairs({
        '', ' ', '\t', ' \t', '\r\n', '\n', ' \t\r\n', '\r\nepilogue', '\nepilogue',
        ' \t\r\nepilogue',
    }) do
        local input = body .. suffix
        local form, err = multipart.decode(input, 'b')
        assert.is_nil(err)
        assert.equal(form.foo[1].data, 'value')
        for _, chunksize in ipairs({ 1, 2, 3, 4, 7, 32, 4096 }) do
            form, err = multipart.decode(reader(input), 'b', nil, nil, chunksize)
            assert.is_nil(err)
            assert.equal(form.foo[1].data, 'value')
        end
    end
end

function testcase.decode_validates_closing_boundary_at_every_split()
    for _, suffix in ipairs({ '', ' \t', '\r\nepilogue', ' \t\r\nepilogue', ' \tX\r\n' }) do
        local input = body .. suffix
        for split = 1, #input - 1 do
            local chunks = { input:sub(1, split), input:sub(split + 1) }
            local calls = 0
            local source = {
                read = function()
                    calls = calls + 1
                    return chunks[calls]
                end,
            }
            local form, err = multipart.decode(source, 'b')
            if suffix == ' \tX\r\n' then
                assert_invalid(form, err)
            else
                assert.is_nil(err)
                assert.equal(form.foo[1].data, 'value')
            end
        end
    end
end

function testcase.decode_does_not_read_after_closing_boundary_eof()
    for _, empty_eof in ipairs({ false, true }) do
        local calls = 0
        local source = {
            read = function()
                calls = calls + 1
                if calls == 1 then return body .. ' \t' end
                assert.equal(calls, 2)
                if empty_eof then return '' end
            end,
        }
        local form, err = multipart.decode(source, 'b')
        assert.is_nil(err)
        assert.equal(form.foo[1].data, 'value')
        assert.equal(calls, 2)
    end
end

function testcase.decode_keeps_reader_errors_while_reading_boundary_terminators()
    for _, prefix in ipairs({ header .. 'value\r\n--b \t', body .. ' \t' }) do
        for _, raises in ipairs({ false, true }) do
            local cause = errno.EIO:new('terminator read failed')
            local calls = 0
            local source = {
                read = function()
                    calls = calls + 1
                    if calls == 1 then return prefix end
                    if raises then error(cause, 0) end
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
end

function testcase.decode_rejects_unterminated_normal_boundary()
    for _, suffix in ipairs({ '', ' \t', '\r', ' \t\r' }) do
        local input = header .. 'value\r\n--b' .. suffix
        for _, source in ipairs({ input, reader(input) }) do
            assert_invalid(multipart.decode(source, 'b', nil, nil, 1))
        end
    end
end

function testcase.decode_removes_uploads_after_invalid_boundary_terminators()
    local fileheader = '--b\r\nContent-Disposition: form-data; name="upload"; filename="a"\r\n\r\n'
    local first_file = fileheader .. 'first\r\n--b\r\n'
    for _, input in ipairs({
        fileheader .. 'payload\r\n--bGARBAGE\r\n' .. next_part,
        fileheader .. 'payload\r\n--b--GARBAGE',
        first_file .. fileheader:sub(6) .. 'second\r\n--b--GARBAGE',
    }) do
        local prefix = unused_prefix()
        assert_invalid(multipart.decode(reader(input), 'b', prefix, nil, 1))
        assert.empty(files_with_prefix(prefix))
    end
end

function testcase.decode_accepts_file_and_indexed_reader_objects_at_eof()
    local file = assert(io.tmpfile())
    sources[#sources + 1] = file
    assert(file:write(body .. ' \t'))
    assert(file:seek('set'))
    local form, err = multipart.decode(file, 'b', { chunksize = 3, maxsize = #body + 2 })
    assert.is_nil(err)
    assert.equal(form.foo[1].data, 'value')
    assert.equal(io.type(file), 'file')

    local source = reader(body)
    source[1] = 'reader metadata'
    form, err = multipart.decode(source, 'b', { chunksize = 3, maxsize = #body })
    assert.is_nil(err)
    assert.equal(form.foo[1].data, 'value')
    assert.equal(source[1], 'reader metadata')
end

function testcase.decode_discards_verified_boundary_padding_while_reading()
    local padding = string.rep('\t', 256 * 1024)
    for _, closing in ipairs({ false, true }) do
        local prefix = closing and body or header .. 'value\r\n--b'
        local suffix = closing and '\r\nepilogue' or '\r\n' .. next_part
        collectgarbage('collect')
        local baseline = collectgarbage('count')
        local calls = 0
        local source = {
            read = function()
                calls = calls + 1
                collectgarbage('collect')
                -- Eight MiB of padding must not remain live in the parser.
                -- Allow several chunks of headroom rather than a byte-exact
                -- allocator assertion. Memory is reported in KiB by Lua.
                assert.is_true(collectgarbage('count') - baseline < 2048)
                if calls == 1 then return prefix end
                if calls <= 33 then return padding end
                if calls == 34 then return suffix end
            end,
        }
        local form, err = multipart.decode(source, 'b', nil, nil, #padding)
        assert.is_nil(err)
        assert.equal(form.foo[1].data, 'value')
        if not closing then assert.equal(form.bar[1].data, 'last') end
        assert.equal(calls, 35)
    end
end

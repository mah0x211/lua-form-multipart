local testcase = require('testcase')
local assert = require('assert')
local errlib = require('error')
local errno = require('errno')
local mkstemp = require('mkstemp')
local readdir = require('testcase.readdir')
local multipart = require('form.multipart')
local unpack = table.unpack or unpack
local files = {}
local prefixes = {}

local empty_field = 'Content-Disposition: form-data; name="field"\r\n\r\n'
local empty_file = 'Content-Disposition: form-data; name="upload"; filename="empty"\r\n\r\n'

local function body(parts)
    return '--b\r\n' .. table.concat(parts, '\r\n--b\r\n') .. '\r\n--b--'
end

local function repeated_fields(n)
    return string.rep('--b\r\n' .. empty_field .. '\r\n', n) .. '--b--'
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

local function files_with_prefix(prefix)
    local found = {}
    local err = readdir('.', function(name)
        if name:sub(1, #prefix + 1) == prefix .. '_' then
            found[#found + 1] = name
        end
    end)
    assert.is_nil(err)
    return found
end

local function unused_prefix()
    local file, _, prefix = assert(mkstemp('./decode_parts_XXXXXX'))
    file:close()
    assert(os.remove(prefix))
    prefixes[#prefixes + 1] = prefix
    return prefix
end

function testcase.before_each()
    collectgarbage('stop')
end

function testcase.after_each()
    for _, part in ipairs(files) do
        if io.type(part.file) == 'file' then part.file:close() end
    end
    files = {}
    for _, prefix in ipairs(prefixes) do
        for _, path in ipairs(files_with_prefix(prefix)) do os.remove(path) end
    end
    prefixes = {}
    collectgarbage('restart')
end

function testcase.decode_defaults_to_1000_parts_for_named_and_legacy_calls()
    local exact = repeated_fields(1000)
    local excess = repeated_fields(1001)
    for _, args in ipairs({ { n = 0 }, { n = 1 }, { n = 1, {} } }) do
        local form, err = multipart.decode(exact, 'b', unpack(args, 1, args.n))
        assert.is_nil(err)
        assert.equal(#form.field, 1000)

        form, err = multipart.decode(excess, 'b', unpack(args, 1, args.n))
        assert.is_nil(form)
        assert.equal(errlib.typeof(err), multipart.EDECODE)
        assert.not_nil(errlib.is(err, errno.E2BIG))
    end
end

function testcase.decode_accepts_an_explicit_limit_above_the_default()
    local form, err = multipart.decode(repeated_fields(1001), 'b', { maxparts = 1001 })
    assert.is_nil(err)
    assert.equal(#form.field, 1001)
end

function testcase.decode_counts_empty_file_text_and_repeated_name_parts()
    local input = body({ empty_file, empty_field, empty_field })
    for _, limit in ipairs({ 3, 4 }) do
        for _, source in ipairs({ input, reader(input) }) do
            local opts = {
                filetmpl = unused_prefix(),
                maxparts = limit,
                chunksize = 7,
                maxfilesize = 0,
                maxsize = #input,
            }
            local form, err = multipart.decode(source, 'b', opts)
            assert.is_nil(err)
            local part = form.upload[1]
            files[#files + 1] = part
            assert.equal(part.file:seek('end'), 0)
            assert.equal(#form.field, 2)
            assert.equal(form.field[1].data, '')
            assert.equal(form.field[2].data, '')
            assert.equal(opts.maxparts, limit)
        end
    end
end

function testcase.decode_cleans_prior_uploads_when_the_part_limit_is_exceeded()
    local input = body({ empty_file, empty_field, empty_field })
    for _, limit in ipairs({ 1, 2 }) do
        for _, source in ipairs({ input, reader(input) }) do
            local prefix = unused_prefix()
            local form, err = multipart.decode(source, 'b', {
                filetmpl = prefix,
                maxparts = limit,
                chunksize = 7,
            })
            assert.is_nil(form)
            assert.equal(errlib.typeof(err), multipart.EDECODE)
            assert.not_nil(errlib.is(err, errno.E2BIG))
            assert.is_nil(errlib.is(err, errno.EFBIG))
            assert.match(tostring(err), 'maxparts')
            assert.empty(files_with_prefix(prefix))
        end
    end
end

function testcase.decode_rejects_zero_and_negative_part_limits()
    local input = body({ empty_field })
    for _, limit in ipairs({ 0, -1, -100 }) do
        for _, source in ipairs({ input, reader(input) }) do
            local opts = { maxparts = limit, chunksize = 2 }
            local form, err = multipart.decode(source, 'b', opts)
            assert.is_nil(form)
            assert.equal(errlib.typeof(err), multipart.EDECODE)
            assert.not_nil(errlib.is(err, errno.E2BIG))
            assert.equal(opts.maxparts, limit)
        end
    end
end

function testcase.decode_stops_before_reading_the_first_part_headers()
    for _, limit in ipairs({ 0, -1 }) do
        local calls = 0
        local cause = errno.EIO:new('first part headers must not be read')
        local source = {
            read = function()
                calls = calls + 1
                if calls == 1 then return '--b\r\n' end
                return nil, cause
            end,
        }
        local form, err = multipart.decode(source, 'b', { maxparts = limit })
        assert.is_nil(form)
        assert.equal(errlib.typeof(err), multipart.EDECODE)
        assert.not_nil(errlib.is(err, errno.E2BIG))
        assert.is_nil(errlib.is(err, errno.EIO))
        assert.equal(calls, 1)
    end
end

function testcase.decode_stops_before_reading_excess_headers_and_cleans_files()
    local prefix = unused_prefix()
    local calls = 0
    local cause = errno.EIO:new('excess part headers must not be read')
    local source = {
        read = function()
            calls = calls + 1
            if calls == 1 then return '--b\r\n' .. empty_file .. '\r\n--b\r\n' end
            return nil, cause
        end,
    }
    local form, err = multipart.decode(source, 'b', {
        filetmpl = prefix,
        maxparts = 1,
    })
    assert.is_nil(form)
    assert.equal(errlib.typeof(err), multipart.EDECODE)
    assert.not_nil(errlib.is(err, errno.E2BIG))
    assert.is_nil(errlib.is(err, errno.EIO))
    assert.equal(calls, 1)
    assert.empty(files_with_prefix(prefix))
end

function testcase.decode_keeps_byte_limits_independent_of_the_part_limit()
    local input = body({ empty_file .. 'abc' })
    for _, opts in ipairs({
        { filetmpl = unused_prefix(), maxparts = 1, maxfilesize = 2 },
        { filetmpl = unused_prefix(), maxparts = 1, maxsize = #input - 1 },
    }) do
        local form, err = multipart.decode(reader(input), 'b', opts)
        assert.is_nil(form)
        assert.equal(errlib.typeof(err), multipart.EDECODE)
        assert.not_nil(errlib.is(err, errno.EFBIG))
        assert.is_nil(errlib.is(err, errno.E2BIG))
        assert.empty(files_with_prefix(opts.filetmpl))
    end
end

function testcase.decode_invalid_part_limits_raise_before_reading()
    for _, value in ipairs({ false, '1', {}, 1.5, -1.5, math.huge, -math.huge, 0 / 0 }) do
        local calls = 0
        local source = { read = function() calls = calls + 1 end }
        local ok, err = pcall(multipart.decode, source, 'b', { maxparts = value })
        assert.is_false(ok)
        assert.match(tostring(err), 'maxparts must be integer')
        assert.is_nil(errlib.is(err, multipart.EDECODE))
        assert.equal(calls, 0)
    end
end

function testcase.decode_still_rejects_a_closing_boundary_before_any_part()
    local form, err = multipart.decode('--b--\r\n', 'b', { maxparts = 0 })
    assert.is_nil(form)
    assert.equal(errlib.typeof(err), multipart.EDECODE)
    assert.not_nil(errlib.is(err, errno.EINVAL))
    assert.match(tostring(err), 'boundary not started')
end
